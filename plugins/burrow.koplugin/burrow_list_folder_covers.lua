-- Burrow folder and automatic-series cover consistency.
--
-- Cover Grid and Cover List build directory artwork through separate widget
-- paths. Physical folders receive one book-like cover and one caption. Virtual
-- series keep their native Burrow renderer in Cover Grid so they are not drawn
-- twice, while Cover List still receives the same full-size rounded artwork.

local BD = require("ui/bidi")
local Blitbuffer = require("ffi/blitbuffer")
local BottomContainer = require("ui/widget/container/bottomcontainer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local IconWidget = require("ui/widget/iconwidget")
local ImageWidget = require("ui/widget/imagewidget")
local LeftContainer = require("ui/widget/container/leftcontainer")
local OverlapGroup = require("ui/widget/overlapgroup")
local Screen = require("device").screen
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local TopContainer = require("ui/widget/container/topcontainer")
local Widget = require("ui/widget/widget")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local BookInfoManager = require("bookinfomanager")
local burrow_debug = require("burrow_debug")
local burrow_util = require("burrow_util")
local logger = require("logger")
local userpatch = require("userpatch")
local _ = require("l10n.gettext")

local Module = {
    key = "burrow.folder_cover_consistency",
}

local COVER_RATIO = 2 / 3
local CAPTION_FONT_SIZE = 12
local CAPTION_HEIGHT = Screen:scaleBySize(18)
local CAPTION_GAP = Screen:scaleBySize(3)
local CAPTION_VERTICAL_RESERVE = 2 * (CAPTION_HEIGHT + CAPTION_GAP)
local CAPTION_SIDE_MARGIN = Screen:scaleBySize(4)
local LIST_PADDING = Screen:scaleBySize(4)
local DIRECTORY_MARKER_SIZE = Screen:scaleBySize(26)
local DIRECTORY_MARKER_INSET = Screen:scaleBySize(6)

local function entryIsFile(entry)
    return entry and (entry.is_file or entry.file) and true or false
end

local automatic_series_cache

local function seriesItems(item)
    local entry = item and item.entry or item
    if entry and type(entry.series_items) == "table" and #entry.series_items > 0 then
        return entry.series_items
    end

    if automatic_series_cache == nil then
        local ok, MosaicMenu = pcall(require, "mosaicmenu")
        if ok and MosaicMenu then
            local MosaicMenuItem = userpatch.getUpValue(
                MosaicMenu._updateItemsBuildUI,
                "MosaicMenuItem"
            )
            automatic_series_cache = MosaicMenuItem
                and MosaicMenuItem._automatic_series_items_cache
                or false
        else
            automatic_series_cache = false
        end
    end

    local path = entry and (entry.path or entry.file)
    if automatic_series_cache and path then
        return automatic_series_cache[path]
    end
end

local function entryIsSeries(item)
    local entry = item and item.entry or item
    return entry and (
        entry.is_series_group == true
        or seriesItems(item) ~= nil
    )
end

local function entryIsReturnToLibrary(entry)
    return entry and (
        entry.is_return_to_library == true
        or entry._burrow_return_tile_token ~= nil
    )
end

local function entryIsNavigation(entry)
    return entry and (
        entry.is_go_up == true
        or entryIsReturnToLibrary(entry)
    )
end

local function fitPortrait(max_w, max_h)
    max_w = math.max(1, math.floor(max_w or 1))
    max_h = math.max(1, math.floor(max_h or 1))

    local w, h
    if max_w / max_h > COVER_RATIO then
        h = max_h
        w = math.floor(h * COVER_RATIO)
    else
        w = max_w
        h = math.floor(w / COVER_RATIO)
    end
    return math.max(1, w), math.max(1, h)
end

local function imageFromBook(path, width, height)
    if not path then
        return nil
    end

    local bookinfo = BookInfoManager:getBookInfo(path, true)
    if not bookinfo
        or not bookinfo.cover_bb
        or not bookinfo.has_cover
        or not bookinfo.cover_fetched
        or bookinfo.ignore_cover
        or not bookinfo.cover_w
        or not bookinfo.cover_h
        or bookinfo.cover_w <= 0
        or bookinfo.cover_h <= 0
    then
        return nil
    end

    local scale_to_fill = math.max(
        width / bookinfo.cover_w,
        height / bookinfo.cover_h
    )
    return ImageWidget:new {
        image = bookinfo.cover_bb,
        width = width,
        height = height,
        scale_factor = scale_to_fill,
        center_x_ratio = 0.5,
        center_y_ratio = 0.5,
    }
end

local function imageFromFile(path, width, height)
    if not path then
        return nil
    end

    local ok, orig_w, orig_h = pcall(function()
        local probe = ImageWidget:new { file = path, scale_factor = 1 }
        probe:_render()
        local w = probe:getOriginalWidth()
        local h = probe:getOriginalHeight()
        probe:free()
        return w, h
    end)
    if not ok or not orig_w or not orig_h or orig_w <= 0 or orig_h <= 0 then
        return nil
    end

    local scale_to_fill = math.max(width / orig_w, height / orig_h)
    return ImageWidget:new {
        file = path,
        width = width,
        height = height,
        scale_factor = scale_to_fill,
        center_x_ratio = 0.5,
        center_y_ratio = 0.5,
    }
end

local function firstSeriesCover(item, width, height)
    for _, book_entry in ipairs(seriesItems(item) or {}) do
        local image = imageFromBook(book_entry.path or book_entry.file, width, height)
        if image then
            return image
        end
    end
end

local function physicalFolderEntries(item)
    local menu = item and item.menu
    local entry = item and item.entry
    local path = item and (item.filepath or (entry and entry.path))
    if not menu or type(menu.genItemTableFromPath) ~= "function" or not path then
        return nil
    end

    local previous_dummy = menu._dummy
    menu._dummy = true
    local ok, entries = pcall(menu.genItemTableFromPath, menu, path)
    menu._dummy = previous_dummy
    if ok and type(entries) == "table" then
        return entries
    end
end

local function firstPhysicalFolderCover(item, width, height)
    for _, book_entry in ipairs(physicalFolderEntries(item) or {}) do
        if entryIsFile(book_entry) then
            local image = imageFromBook(
                book_entry.path or book_entry.file,
                width,
                height
            )
            if image then
                return image
            end
        end
    end
end

local function directoryArtwork(item, width, height)
    local entry = item.entry or {}

    if entryIsSeries(item) then
        local series_cover = firstSeriesCover(item, width, height)
        if series_cover then
            return series_cover
        end
    else
        local path = item.filepath or entry.path
        local local_cover_path = burrow_util.findCover(path)
        if local_cover_path then
            -- Keep the unified physical-folder cover's artwork as a direct
            -- ImageWidget. cover_layout receives an explicit reference to this
            -- image and can resize it together with the outer rounded frame.
            -- The old getFolderCover() path inserted another FrameContainer
            -- between them, which made post-build cover discovery ambiguous.
            local folder_cover = imageFromFile(local_cover_path, width, height)
            if folder_cover then
                return folder_cover
            end
        end

        local first_book = firstPhysicalFolderCover(item, width, height)
        if first_book then
            return first_book
        end
    end

    local _, _, scale_factor = BookInfoManager.getCachedCoverSize(
        250,
        500,
        width,
        height
    )
    return ImageWidget:new {
        file = burrow_util.getPluginDir() .. "/resources/folder.svg",
        alpha = true,
        scale_factor = scale_factor,
        width = width,
        height = height,
        original_in_nightmode = false,
    }
end

-- FrameContainer draws a rounded border but does not clip its child image.
-- Use the same explicit corner masking used by Burrow's book and hero covers so
-- physical-folder artwork is actually rounded in both Cover Grid and Cover List.
local RoundedDirectoryCover = Widget:extend {
    inner = nil,
    width = nil,
    height = nil,
    radius = 0,
    border_size = 0,
}

function RoundedDirectoryCover:init()
    self.dimen = Geom:new { w = self.width, h = self.height }
end

function RoundedDirectoryCover:getSize()
    return self.dimen
end

function RoundedDirectoryCover:free(...)
    if self.inner and self.inner.free then
        self.inner:free(...)
    end
end

function RoundedDirectoryCover:paintTo(bb, x, y)
    local border = self.border_size or 0
    local radius = math.min(
        self.radius or 0,
        math.floor(self.width / 2),
        math.floor(self.height / 2)
    )

    bb:paintRect(x, y, self.width, self.height, Blitbuffer.COLOR_WHITE)
    if self.inner then
        self.inner:paintTo(bb, x + border, y + border)
    end

    if radius > 0 then
        local radius_sq = radius * radius
        for dy = 0, radius - 1 do
            local cutoff = 0
            local ddy = dy - radius
            while cutoff < radius
                    and (cutoff - radius) * (cutoff - radius) + ddy * ddy > radius_sq do
                cutoff = cutoff + 1
            end
            if cutoff > 0 then
                bb:paintRect(x, y + dy, cutoff, 1, Blitbuffer.COLOR_WHITE)
                bb:paintRect(x + self.width - cutoff, y + dy, cutoff, 1, Blitbuffer.COLOR_WHITE)
                bb:paintRect(x, y + self.height - dy - 1, cutoff, 1, Blitbuffer.COLOR_WHITE)
                bb:paintRect(
                    x + self.width - cutoff,
                    y + self.height - dy - 1,
                    cutoff,
                    1,
                    Blitbuffer.COLOR_WHITE
                )
            end
        end
    end

    if border > 0 then
        bb:paintBorder(
            x,
            y,
            self.width,
            self.height,
            border,
            -- Match the page background in light mode; KOReader night mode
            -- inverts this white to black, so the reserved border remains
            -- geometrically present without becoming a visible outline.
            Blitbuffer.COLOR_WHITE,
            radius,
            true
        )
    end
end

local function roundedDirectoryCover(item, max_w, max_h)
    local border = Size.border.thin
    local border_total = border * 2
    local art_w, art_h = fitPortrait(
        math.max(1, max_w - border_total),
        math.max(1, max_h - border_total)
    )
    local artwork = directoryArtwork(item, art_w, art_h)

    local cover = RoundedDirectoryCover:new {
        width = art_w + border_total,
        height = art_h + border_total,
        radius = math.max(Screen:scaleBySize(6), Size.radius.default),
        border_size = border,
        inner = artwork,
    }
    return cover, artwork
end

local function cleanTitle(item)
    local text = (item.entry and item.entry.text) or item.text or ""
    text = text:gsub("[/\\]+$", "")
    return text
end

local function directoryMarkerLayer(width, height)
    local marker_size = math.min(
        DIRECTORY_MARKER_SIZE,
        math.max(Screen:scaleBySize(12), math.floor(math.min(width, height) * 0.24))
    )
    local marker = IconWidget:new {
        icon = "series.folder",
        alpha = true,
        width = marker_size,
        height = marker_size,
    }

    -- LeftContainer vertically centers its child inside its own dimensions.
    -- Giving it the full cover height placed the marker halfway down the cover.
    -- Limit it to a shallow top row so the centered marker lands at the same
    -- top/left inset used by Burrow's automatic-series marker.
    local top_row_height = math.min(
        height,
        marker_size + (2 * DIRECTORY_MARKER_INSET)
    )
    return TopContainer:new {
        dimen = Geom:new { w = width, h = height },
        LeftContainer:new {
            dimen = Geom:new { w = width, h = top_row_height },
            HorizontalGroup:new {
                HorizontalSpan:new { width = DIRECTORY_MARKER_INSET },
                marker,
            },
        },
    }
end

local function rebuildMosaicPhysicalFolder(item)
    local entry = item and item.entry
    if not entry
        or entryIsFile(entry)
        or entryIsSeries(item)
        or entryIsNavigation(entry)
        or not item.do_cover_image
        or not item.width
        or not item.height
    then
        return
    end

    -- Use the same vertical reserve as normal book and automatic-series covers.
    -- The cover remains centered in the full tile and the caption occupies the
    -- final line at the bottom, matching Burrow's standard book presentation.
    local max_cover_h = math.max(
        Screen:scaleBySize(40),
        item.height - CAPTION_VERTICAL_RESERVE
    )
    local cover, primary_image = roundedDirectoryCover(item, item.width, max_cover_h)
    local cover_size = cover:getSize()
    local cover_dimen = Geom:new { w = cover_size.w, h = cover_size.h }
    local marked_cover = OverlapGroup:new {
        dimen = cover_dimen,
        cover,
        directoryMarkerLayer(cover_size.w, cover_size.h),
    }
    local caption = TextWidget:new {
        text = BD.auto(cleanTitle(item)),
        face = Font:getFace("cfont", CAPTION_FONT_SIZE),
        bold = true,
        max_width = math.max(1, item.width - 2 * CAPTION_SIDE_MARGIN),
        alignment = "center",
        padding = 0,
        forced_height = CAPTION_HEIGHT,
    }

    local tile_dimen = Geom:new { w = item.width, h = item.height }
    local tile = OverlapGroup:new {
        dimen = tile_dimen,
        CenterContainer:new {
            dimen = tile_dimen,
            marked_cover,
        },
        BottomContainer:new {
            dimen = tile_dimen,
            caption,
        },
    }

    local previous = item._underline_container and item._underline_container[1]
    if item._underline_container then
        item._underline_container[1] = tile
    end
    if previous and previous.free then
        previous:free(true)
    end

    -- Disable the older physical-folder paint hook so it cannot redraw its
    -- title overlay, item-count circle, border, or corner masks over this tile.
    item._folder_frame_dimen = nil
    item._folder_image_size = nil
    item._foldercover_processed = true
    item._burrow_unified_mosaic_folder = true

    -- Expose the exact visual elements to the final cover-layout pass. Do not
    -- make it rediscover a folder cover by walking the widget tree: the folder
    -- marker is also image-like and the rounded cover keeps its artwork in a
    -- named field rather than a numeric child.
    item._burrow_primary_cover_frame = cover
    item._burrow_primary_cover_image = primary_image
    item._burrow_folder_caption = caption
    item.bookinfo_found = true
    if item.menu then
        item.menu._has_cover_images = true
    end
    item._has_cover_image = true
end

local function findListFolderSlot(item)
    local root = item and item._underline_container and item._underline_container[1]
    local left = root and root[1]
    local horizontal = left and left[1]
    if horizontal and horizontal[1] then
        return horizontal, 1
    end
end

local function replaceListArtwork(item, replacement, marker)
    local horizontal, index = findListFolderSlot(item)
    if not horizontal then
        logger.warn(burrow_debug.logprefix, "Could not locate Cover List folder slot")
        return false
    end

    local previous = horizontal[index]
    horizontal[index] = replacement
    if previous and previous.free then
        previous:free(true)
    end

    replacement[marker] = true
    if item.menu then
        item.menu._has_cover_images = true
    end
    item._has_cover_image = true
    return true
end

local function rebuildListReturnToLibrary(item)
    local row_height = math.max(
        1,
        tonumber(item.height)
            or (item.dimen and tonumber(item.dimen.h))
            or 1
    )
    local frame_size = math.max(1, row_height - 2 * LIST_PADDING)
    local icon_padding = math.max(
        Screen:scaleBySize(3),
        math.floor(frame_size * 0.17)
    )
    local icon_size = math.max(
        Screen:scaleBySize(12),
        frame_size - 2 * icon_padding
    )
    local replacement = CenterContainer:new {
        dimen = Geom:new { w = row_height, h = row_height },
        margin = 0,
        padding = LIST_PADDING,
        color = Blitbuffer.COLOR_WHITE,
        FrameContainer:new {
            width = frame_size,
            height = frame_size,
            margin = 0,
            padding = icon_padding,
            bordersize = Size.border.thin,
            radius = Size.radius.default,
            color = Blitbuffer.COLOR_GRAY_3,
            background = Blitbuffer.COLOR_WHITE,
            IconWidget:new {
                icon = "return.library",
                width = icon_size,
                height = icon_size,
                alpha = false,
                file_do_cache = false,
                scale_factor = 0,
            },
        },
    }
    return replaceListArtwork(
        item,
        replacement,
        "_burrow_return_to_library_list_icon"
    )
end

local function rebuildListDirectory(item)
    local entry = item and item.entry
    if not entry
        or entryIsFile(entry)
        or not item.do_cover_image
        or burrow_util.isPathChooser(item)
    then
        return
    end

    if entryIsReturnToLibrary(entry) then
        rebuildListReturnToLibrary(item)
        return
    end
    if entryIsNavigation(entry) then
        return
    end

    local row_height = math.max(
        1,
        tonumber(item.height)
            or (item.dimen and tonumber(item.dimen.h))
            or 1
    )
    local max_cover = math.max(1, row_height - 2 * LIST_PADDING)
    local list_cover = roundedDirectoryCover(item, max_cover, max_cover)
    local replacement = CenterContainer:new {
        dimen = Geom:new { w = row_height, h = row_height },
        margin = 0,
        padding = LIST_PADDING,
        color = Blitbuffer.COLOR_WHITE,
        dim = item.file_deleted,
        list_cover,
    }
    replaceListArtwork(
        item,
        replacement,
        "_burrow_unified_list_folder"
    )
end

local function removeSeriesBadge(item)
    if not BookInfoManager:getSetting("hide_series_number_badge") then
        return
    end

    if item._series_badge_background then
        item._series_badge_background:free(true)
        item._series_badge_background = nil
    end
    if item._series_text then
        item._series_text:free(true)
        item._series_text = nil
    end
    item._series_badge_diameter = nil
    item.series_index = nil
    item.has_series_badge = nil
end

local function patchMosaic()
    local MosaicMenu = require("mosaicmenu")
    local MosaicMenuItem = userpatch.getUpValue(
        MosaicMenu._updateItemsBuildUI,
        "MosaicMenuItem"
    )
    if not MosaicMenuItem then
        return false, "Could not find Cover Grid item class"
    end
    if MosaicMenuItem._burrow_physical_folder_consistency then
        return true
    end
    MosaicMenuItem._burrow_physical_folder_consistency = true

    local original_init = MosaicMenuItem.init
    function MosaicMenuItem:init(...)
        local result = original_init(self, ...)
        removeSeriesBadge(self)
        return result
    end

    local original_update = MosaicMenuItem.update
    function MosaicMenuItem:update(...)
        local result = original_update(self, ...)
        removeSeriesBadge(self)
        local ok, err = pcall(rebuildMosaicPhysicalFolder, self)
        if not ok then
            logger.warn(burrow_debug.logprefix, "Could not restyle physical Cover Grid folder", err)
        end
        return result
    end
    return true
end

local function patchList()
    local ListMenu = require("listmenu")
    local ListMenuItem = userpatch.getUpValue(
        ListMenu._updateItemsBuildUI,
        "ListMenuItem"
    )
    if not ListMenuItem then
        return false, "Could not find Cover List item class"
    end
    if ListMenuItem._burrow_unified_directory_covers then
        return true
    end
    ListMenuItem._burrow_unified_directory_covers = true

    local original_update = ListMenuItem.update
    function ListMenuItem:update(...)
        local result = original_update(self, ...)
        local ok, err = pcall(rebuildListDirectory, self)
        if not ok then
            logger.warn(burrow_debug.logprefix, "Could not restyle Cover List folder", err)
        end
        return result
    end

    local original_build = ListMenu._updateItemsBuildUI
    function ListMenu:_updateItemsBuildUI(...)
        local result = original_build(self, ...)
        for _, child in ipairs(self.item_group or {}) do
            if type(child) == "table" and child.entry and child._underline_container then
                local ok, err = pcall(rebuildListDirectory, child)
                if not ok then
                    logger.warn(burrow_debug.logprefix, "Could not restyle Cover List row", err)
                end
            end
        end
        return result
    end
    return true
end

local function findMenuItem(items, text)
    for _, item in ipairs(items or {}) do
        local item_text = item.text or (item.text_func and item.text_func())
        if item_text == text then
            return item
        end
    end
end

local function patchSettingsMenu(Burrow)
    if type(Burrow) ~= "table" or type(Burrow.addToMainMenu) ~= "function" then
        return false, "Burrow settings menu was not available"
    end
    if Burrow._burrow_series_badge_setting_added then
        return true
    end
    Burrow._burrow_series_badge_setting_added = true

    local original_addToMainMenu = Burrow.addToMainMenu
    function Burrow:addToMainMenu(menu_items)
        original_addToMainMenu(self, menu_items)

        local root = menu_items.filemanager_display_mode
        local advanced = root and findMenuItem(root.sub_item_table, _("Advanced settings"))
        local book_display = advanced and findMenuItem(advanced.sub_item_table, _("Book display"))
        if not book_display or findMenuItem(book_display.sub_item_table, _("Show series number badges")) then
            return
        end

        table.insert(book_display.sub_item_table, {
            text = _("Show series number badges"),
            checked_func = function()
                return not BookInfoManager:getSetting("hide_series_number_badge")
            end,
            callback = function()
                BookInfoManager:toggleSetting("hide_series_number_badge")
                local fc = self.ui and self.ui.file_chooser
                if fc then
                    fc:updateItems(1, true)
                end
            end,
        })
    end
    return true
end

function Module.apply(Burrow)
    if Module.applied then
        return true
    end

    local mosaic_ok, mosaic_error = patchMosaic()
    local list_ok, list_error = patchList()
    local menu_ok, menu_error = patchSettingsMenu(Burrow)
    if not mosaic_ok or not list_ok or not menu_ok then
        return false, table.concat({
            mosaic_error or "",
            list_error or "",
            menu_error or "",
        }, " ")
    end

    Module.applied = true
    logger.info(
        burrow_debug.logprefix,
        "Physical-folder markers and Cover List navigation styling loaded"
    )
    return true
end

return Module

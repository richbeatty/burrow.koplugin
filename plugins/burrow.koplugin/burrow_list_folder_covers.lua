-- Burrow folder and automatic-series cover consistency.
--
-- KOReader's mosaic and detailed-list renderers build directory artwork through
-- separate widget paths. Automatic series also borrow the folder path but use a
-- mosaic-specific caption reserve. This module gives physical folders and
-- automatic-series folders the same full-height, rounded treatment in Cover
-- List, and gives physical folders the same caption-under-cover layout used by
-- automatic series in Cover Grid.

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local ImageWidget = require("ui/widget/imagewidget")
local Screen = require("device").screen
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local BookInfoManager = require("bookinfomanager")
local BurrowMigration = require("burrow_migration")
local burrow_debug = require("burrow_debug")
local burrow_util = require("burrow_util")
local logger = require("logger")
local userpatch = require("userpatch")

local Module = {
    key = "burrow.folder_cover_consistency",
}

local COVER_RATIO = 2 / 3
local CAPTION_FONT_SIZE = 12
local CAPTION_HEIGHT = Screen:scaleBySize(18)
local CAPTION_GAP = Screen:scaleBySize(3)
local SIDE_MARGIN = Screen:scaleBySize(4)
local LIST_PADDING = Screen:scaleBySize(4)

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

local function entryIsNavigation(entry)
    return entry and (
        entry.is_go_up == true
        or entry.is_return_to_library == true
        or entry._burrow_return_tile_token ~= nil
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

local function firstSeriesCover(entry, width, height)
    for _, book_entry in ipairs(seriesItems(entry) or {}) do
        local path = book_entry.path or book_entry.file
        if path then
            local bookinfo = BookInfoManager:getBookInfo(path, true)
            if bookinfo
                and bookinfo.cover_bb
                and bookinfo.has_cover
                and bookinfo.cover_fetched
                and not bookinfo.ignore_cover
                and bookinfo.cover_w
                and bookinfo.cover_h
                and bookinfo.cover_w > 0
                and bookinfo.cover_h > 0
            then
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
        end
    end
end

local function directoryArtwork(item, width, height)
    local entry = item.entry or {}

    if entryIsSeries(item) then
        local series_cover = firstSeriesCover(entry, width, height)
        if series_cover then
            return series_cover
        end
    else
        local folder_cover = burrow_util.getFolderCover(
            item.filepath or entry.path,
            width,
            height,
            BurrowMigration.folderCoverPath(entry)
        )
        if folder_cover then
            return folder_cover
        end

        if not BookInfoManager:getSetting("disable_auto_foldercovers") then
            local generated = burrow_util.getSubfolderCoverImages(
                item.filepath or entry.path,
                width,
                height
            )
            if generated then
                return generated
            end
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

local function roundedDirectoryCover(item, max_w, max_h)
    local border_total = Size.border.thin * 2
    local art_w, art_h = fitPortrait(
        math.max(1, max_w - border_total),
        math.max(1, max_h - border_total)
    )
    local artwork = directoryArtwork(item, art_w, art_h)
    return FrameContainer:new {
        width = art_w + border_total,
        height = art_h + border_total,
        margin = 0,
        padding = 0,
        radius = Size.radius.default,
        bordersize = Size.border.thin,
        color = Blitbuffer.COLOR_GRAY_3,
        background = Blitbuffer.COLOR_GRAY_3,
        artwork,
    }
end

local function cleanTitle(item)
    local text = (item.entry and item.entry.text) or item.text or ""
    text = text:gsub("[/\\]+$", "")
    return text
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

    local available_h = math.max(
        Screen:scaleBySize(40),
        item.height - CAPTION_HEIGHT - CAPTION_GAP
    )
    local cover = roundedDirectoryCover(
        item,
        math.max(1, item.width - 2 * SIDE_MARGIN),
        available_h
    )
    local caption = TextWidget:new {
        text = cleanTitle(item),
        face = Font:getFace("cfont", CAPTION_FONT_SIZE),
        bold = true,
        max_width = math.max(1, item.width - 2 * SIDE_MARGIN),
        alignment = "center",
        padding = 0,
        forced_height = CAPTION_HEIGHT,
    }

    local tile = CenterContainer:new {
        dimen = Geom:new { w = item.width, h = item.height },
        VerticalGroup:new {
            cover,
            VerticalSpan:new { width = CAPTION_GAP },
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

    -- Prevent the older physical-folder paint hook from drawing its former
    -- frame, title overlay, and corner masks over the replacement widget.
    item._folder_frame_dimen = nil
    item._folder_image_size = nil
    item._burrow_unified_mosaic_folder = true
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

local function rebuildListDirectory(item)
    local entry = item and item.entry
    if not entry
        or entryIsFile(entry)
        or entryIsNavigation(entry)
        or not item.do_cover_image
        or burrow_util.isPathChooser(item)
    then
        return
    end

    local horizontal, index = findListFolderSlot(item)
    if not horizontal then
        logger.warn(burrow_debug.logprefix, "Could not locate Cover List folder slot")
        return
    end

    local row_height = math.max(
        1,
        tonumber(item.height)
            or (item.dimen and tonumber(item.dimen.h))
            or 1
    )
    local max_cover = math.max(1, row_height - 2 * LIST_PADDING)
    local replacement = CenterContainer:new {
        dimen = Geom:new { w = row_height, h = row_height },
        margin = 0,
        padding = LIST_PADDING,
        color = Blitbuffer.COLOR_WHITE,
        dim = item.file_deleted,
        roundedDirectoryCover(item, max_cover, max_cover),
    }
    replacement._burrow_unified_list_folder = true

    local previous = horizontal[index]
    horizontal[index] = replacement
    if previous and previous.free then
        previous:free(true)
    end

    if item.menu then
        item.menu._has_cover_images = true
    end
    item._has_cover_image = true
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
    if MosaicMenuItem._burrow_unified_physical_folders then
        return true
    end
    MosaicMenuItem._burrow_unified_physical_folders = true

    local original_update = MosaicMenuItem.update
    function MosaicMenuItem:update(...)
        local result = original_update(self, ...)
        local ok, err = pcall(rebuildMosaicPhysicalFolder, self)
        if not ok then
            logger.warn(burrow_debug.logprefix, "Could not unify Cover Grid folder", err)
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
            logger.warn(burrow_debug.logprefix, "Could not unify Cover List folder", err)
        end
        return result
    end
    return true
end

function Module.apply()
    if Module.applied then
        return true
    end

    local mosaic_ok, mosaic_error = patchMosaic()
    local list_ok, list_error = patchList()
    if not mosaic_ok or not list_ok then
        return false, table.concat({
            mosaic_error or "",
            list_error or "",
        }, " ")
    end

    Module.applied = true
    logger.info(
        burrow_debug.logprefix,
        "Unified physical-folder and automatic-series cover styling loaded"
    )
    return true
end

return Module

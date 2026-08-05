local MODULE_KEY = "burrow.internal.2__stretched_rounded_covers"
local existing_module = package.loaded[MODULE_KEY]
if existing_module then return existing_module end
local Module = { key = MODULE_KEY, phase = "instance", filename = "2--stretched-rounded-covers.lua" }
package.loaded[MODULE_KEY] = Module

--[[
    Burrow cover-grid patch

    - Keeps book covers at a consistent 2:3 aspect ratio
    - Adds rounded corners to books and virtual series-folder covers
    - Shows the title beneath every book cover
    - Shows the series name beneath virtual series-folder covers
    - Marks virtual series folders with a small stacked-books icon
--]]

local BD = require("ui/bidi")
local Blitbuffer = require("ffi/blitbuffer")
local Font = require("ui/font")
local IconWidget = require("ui/widget/iconwidget")
local Screen = require("device").screen
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local logger = require("logger")
local userpatch = require("userpatch")

-- stylua: ignore start
--========================== [[Edit your preferences here]] ======================
local aspect_ratio = 2 / 3
local stretch_limit = 50
local Fill = false

local caption_font_size = 12
local caption_height = Screen:scaleBySize(18)
local caption_gap = Screen:scaleBySize(3)
local caption_side_margin = Screen:scaleBySize(4)

local series_marker_size = Screen:scaleBySize(26)
local series_marker_inset = Screen:scaleBySize(6)
local cover_corner_radius = math.max(6, Screen:scaleBySize(8))
--================================================================================
-- stylua: ignore end

-- Burrow centers each cover vertically. Reserving the caption height on
-- both sides leaves one full caption line beneath the centered cover.
local caption_vertical_reserve = 2 * (caption_height + caption_gap)

local function patchAspectRatioWithRoundedCorners(plugin)
    local MosaicMenu = require("mosaicmenu")
    local MosaicMenuItem = userpatch.getUpValue(MosaicMenu._updateItemsBuildUI, "MosaicMenuItem")

    if not MosaicMenuItem then
        logger.warn("Failed to find MosaicMenuItem")
        return
    end

    -- bookinfomanager belongs to Burrow, so it must be retrieved only
    -- after the Burrow plugin has loaded. Requiring it at patch-file load
    -- time causes KOReader's generic "Error applying patch" warning.
    local BookInfoManager = userpatch.getUpValue(MosaicMenuItem.update, "BookInfoManager")
    if not BookInfoManager then
        local ok, module = pcall(require, "bookinfomanager")
        if ok then
            BookInfoManager = module
        end
    end
    if not BookInfoManager then
        logger.warn("Could not find Burrow BookInfoManager")
        return
    end

    if MosaicMenuItem.patched_stretched_rounded_corners_with_titles then
        return
    end
    MosaicMenuItem.patched_stretched_rounded_corners_with_titles = true

    logger.info(string.format(
        "Loading cover titles, series marker, aspect ratio %.2f, and rounded corners",
        aspect_ratio
    ))

    local function isSeriesGroup(menu_item)
        local entry = menu_item.entry
        if entry and entry.is_series_group then
            return true
        end

        local cache = MosaicMenuItem._automatic_series_items_cache
        local filepath = (entry and entry.path) or menu_item.filepath
        return cache and filepath and cache[filepath] ~= nil
    end

    local function isBook(menu_item)
        local entry = menu_item.entry
        return entry and (entry.is_file or entry.file) and true or false
    end

    local function cleanFilename(text)
        if not text or text == "" then
            return ""
        end
        text = text:gsub("/$", "")
        text = text:match("([^/]+)$") or text
        return text:gsub("%.[^%.]+$", "")
    end

    local function getDisplayTitle(menu_item, series_group)
        if series_group then
            return (menu_item.entry and menu_item.entry.text) or menu_item.text or ""
        end

        local title
        if menu_item.filepath then
            local bookinfo = BookInfoManager:getBookInfo(menu_item.filepath, false)
            if bookinfo and not bookinfo.ignore_meta then
                title = bookinfo.title
            end
        end

        if not title or title == "" then
            title = cleanFilename(menu_item.text or menu_item.filepath)
        end
        return title or ""
    end

    local function getCoverTarget(menu_item, series_group)
        if not menu_item[1] or not menu_item[1][1] then
            return nil
        end

        if not series_group then
            return menu_item[1][1][1]
        end

        -- Burrow virtual-series directory widget:
        -- Underline -> outer frame -> overlap -> center -> cover frame
        local outer = menu_item[1][1]
        local overlap = outer and outer[1]
        local center = overlap and overlap[1]
        return center and center[1]
    end

    local function getWidgetSize(widget)
        if not widget then
            return nil, nil
        end
        if widget.getSize then
            local size = widget:getSize()
            if size then
                return size.w, size.h
            end
        end
        if widget.dimen then
            return widget.dimen.w, widget.dimen.h
        end
        return widget.width, widget.height
    end

    local series_marker_widget = IconWidget:new {
        icon = "series.folder",
        alpha = true,
        width = series_marker_size,
        height = series_marker_size,
    }

    local function paintSeriesMarker(bb, x, y)
        series_marker_widget:paintTo(bb, math.floor(x), math.floor(y))
    end

    -- Cut away only the pixels outside a small quarter-circle. Unlike the
    -- rounded.corner SVG assets, this adds no separate curved outline.
    local function paintCleanRoundedCorners(bb, x, y, w, h)
        local radius = math.min(cover_corner_radius, math.floor(w / 2), math.floor(h / 2))
        if radius < 2 then
            return
        end

        for row = 0, radius - 1 do
            local vertical = radius - row
            local inside = math.sqrt(math.max(0, radius * radius - vertical * vertical))
            local cut = math.max(0, math.ceil(radius - inside))
            if cut > 0 then
                bb:paintRect(x, y + row, cut, 1, Blitbuffer.COLOR_WHITE)
                bb:paintRect(x + w - cut, y + row, cut, 1, Blitbuffer.COLOR_WHITE)
                bb:paintRect(x, y + h - row - 1, cut, 1, Blitbuffer.COLOR_WHITE)
                bb:paintRect(x + w - cut, y + h - row - 1, cut, 1, Blitbuffer.COLOR_WHITE)
            end
        end
    end

    -- Replace Burrow's local ImageWidget only while normal book covers are
    -- being built. Real directories keep their existing sizing. Virtual series
    -- folders are sized independently by 2-automatic-book-series.lua.
    if not MosaicMenuItem.patched_aspect_ratio_with_caption_space then
        MosaicMenuItem.patched_aspect_ratio_with_caption_space = true

        local original_update = MosaicMenuItem.update
        local local_ImageWidget
        local imagewidget_upvalue_index
        local n = 1
        while true do
            local name, value = debug.getupvalue(original_update, n)
            if not name then
                break
            end
            if name == "ImageWidget" then
                local_ImageWidget = value
                imagewidget_upvalue_index = n
                break
            end
            n = n + 1
        end

        if not local_ImageWidget then
            logger.warn("Could not find ImageWidget in MosaicMenuItem.update closure")
        else
            local active_item
            local StretchingImageWidget = local_ImageWidget:extend({})

            function StretchingImageWidget:init()
                if local_ImageWidget.init then
                    local_ImageWidget.init(self)
                end

                local item = active_item
                if not item or not isBook(item) or not item.width or not item.height then
                    return
                end

                local border_size = Size.border.thin
                local max_img_w = math.max(1, item.width - 2 * border_size)
                local max_img_h = math.max(
                    Screen:scaleBySize(40),
                    item.height - 2 * border_size - caption_vertical_reserve
                )

                self.scale_factor = nil
                self.stretch_limit_percentage = stretch_limit

                local ratio = Fill and (max_img_w / max_img_h) or aspect_ratio
                if max_img_w / max_img_h > ratio then
                    self.height = max_img_h
                    self.width = math.floor(max_img_h * ratio)
                else
                    self.width = max_img_w
                    self.height = math.floor(max_img_w / ratio)
                end
            end

            debug.setupvalue(original_update, imagewidget_upvalue_index, StretchingImageWidget)

            function MosaicMenuItem:update(...)
                -- Keep BookInfoManager as a named upvalue. The automatic-series
                -- patch retrieves it from MosaicMenuItem.update at load time.
                if BookInfoManager == nil then
                    return original_update(self, ...)
                end

                active_item = self
                local ok, result = pcall(original_update, self, ...)
                active_item = nil
                if not ok then
                    error(result)
                end
                return result
            end

            logger.info("Aspect ratio and caption space applied successfully")
        end
    end

    if not MosaicMenuItem.patched_rounded_corners_and_titles then
        MosaicMenuItem.patched_rounded_corners_and_titles = true

        local original_paint = MosaicMenuItem.paintTo
        local original_free = MosaicMenuItem.free

        function MosaicMenuItem:paintTo(bb, x, y)
            if original_paint then
                original_paint(self, bb, x, y)
            end

            local series_group = isSeriesGroup(self)
            local book = isBook(self)
            if self.file_deleted or (not book and not series_group) then
                return
            end

            local target = getCoverTarget(self, series_group)
            local cover_w, cover_h = getWidgetSize(target)
            if not target or not cover_w or not cover_h then
                return
            end

            local cover_x = x + math.floor((self.width - cover_w) / 2)
            local cover_y = y + math.floor((self.height - cover_h) / 2)

            -- Rounded corners without the heavy curved outline from the SVG masks.
            paintCleanRoundedCorners(bb, cover_x, cover_y, cover_w, cover_h)

            if series_group then
                paintSeriesMarker(
                    bb,
                    cover_x + series_marker_inset,
                    cover_y + series_marker_inset
                )
            end

            local title = getDisplayTitle(self, series_group)
            if title == "" then
                return
            end

            local caption_width = math.max(1, self.width - 2 * caption_side_margin)
            local caption_key = title .. "\0" .. tostring(caption_width) .. "\0" .. tostring(series_group)
            if self._cover_caption_key ~= caption_key then
                if self._cover_caption then
                    self._cover_caption:free(true)
                end
                self._cover_caption = TextWidget:new {
                    text = BD.auto(title),
                    face = Font:getFace("cfont", caption_font_size),
                    bold = series_group,
                    max_width = caption_width,
                    alignment = "center",
                    padding = 0,
                    forced_height = caption_height,
                }
                self._cover_caption_key = caption_key
            end

            local caption_size = self._cover_caption:getSize()
            local caption_x = x + math.floor((self.width - caption_size.w) / 2)
            local caption_y = cover_y + cover_h + caption_gap
            local lowest_y = y + self.height - caption_size.h
            if caption_y > lowest_y then
                caption_y = lowest_y
            end
            self._cover_caption:paintTo(bb, caption_x, caption_y)
        end

        if original_free then
            function MosaicMenuItem:free()
                if self._cover_caption then
                    self._cover_caption:free(true)
                    self._cover_caption = nil
                    self._cover_caption_key = nil
                end
                return original_free(self)
            end
        end

        logger.info("Rounded corners, cover titles, and series-folder marker applied successfully")
    end
end

Module.apply = patchAspectRatioWithRoundedCorners
return Module

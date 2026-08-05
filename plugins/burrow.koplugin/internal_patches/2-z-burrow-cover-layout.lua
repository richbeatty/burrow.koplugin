local MODULE_KEY = "burrow.internal.2_z_burrow_cover_layout"
local existing_module = package.loaded[MODULE_KEY]
if existing_module then return existing_module end
local Module = { key = MODULE_KEY, phase = "instance", filename = "2-z-burrow-cover-layout.lua" }
package.loaded[MODULE_KEY] = Module

--[[
    Burrow Cover Gap and Size Controls v2

    Adds two independent settings under Burrow display settings:

      Cover gap reduction
        Moves complete tiles inward without changing the grid or touch targets.

      Cover size
        Resizes the primary cover inside book, real-folder, and virtual-series
        tiles. Book and series captions are deferred and repainted beneath the
        resized cover so an enlarged cover cannot paint over its title.

    The size setting is applied after Burrow and the other cover patches
    have finished building a tile. It therefore works with normal covers,
    custom folder covers, stock folder art, and automatic series folders.

    Restart KOReader after changing either setting. Remove older gap, spacing,
    or cover-size patches before installing this file.
--]]

local logger = require("logger")
local userpatch = require("userpatch")

local function patchBurrowCoverControls(plugin)
    local BookInfoManager = require("bookinfomanager")
    local MosaicMenu = require("mosaicmenu")
    local RenderImage = require("ui/renderimage")
    local Screen = require("device").screen
    local TextWidget = require("ui/widget/textwidget")
    local UIManager = require("ui/uimanager")
    local _ = require("l10n.gettext")
    local T = require("ffi/util").template

    local MosaicMenuItem = userpatch.getUpValue(MosaicMenu._updateItemsBuildUI, "MosaicMenuItem")
    if not MosaicMenuItem then
        logger.warn("Burrow cover controls: could not find MosaicMenuItem")
        return
    end

    local GAP_SETTING_KEY = "burrow_cover_gap_reduction"
    local SIZE_SETTING_KEY = "burrow_cover_size_percent"

    local DEFAULT_GAP = 0
    local MIN_GAP = 0
    local MAX_GAP = 30

    local DEFAULT_SIZE = 100
    local MIN_SIZE = 50
    local MAX_SIZE = 130

    -- Must match the caption geometry used by the current rounded-cover patch.
    local CAPTION_HEIGHT = Screen:scaleBySize(18)
    local CAPTION_GAP = Screen:scaleBySize(3)
    local CAPTION_BLOCK = CAPTION_HEIGHT + CAPTION_GAP

    local function round(value)
        if value >= 0 then
            return math.floor(value + 0.5)
        end
        return math.ceil(value - 0.5)
    end

    local function normalizeGap(value)
        value = tonumber(value) or DEFAULT_GAP
        value = math.floor(value + 0.5)
        if value < MIN_GAP then value = MIN_GAP end
        if value > MAX_GAP then value = MAX_GAP end
        return value
    end

    local function normalizeSize(value)
        value = tonumber(value) or DEFAULT_SIZE
        value = math.floor(value + 0.5)
        if value < MIN_SIZE then value = MIN_SIZE end
        if value > MAX_SIZE then value = MAX_SIZE end
        return value
    end

    local function getGap()
        return normalizeGap(BookInfoManager:getSetting(GAP_SETTING_KEY))
    end

    local function getCoverSize()
        return normalizeSize(BookInfoManager:getSetting(SIZE_SETTING_KEY))
    end

    local function isBook(item)
        local entry = item and item.entry
        return entry and (entry.is_file or entry.file) and true or false
    end

    local function isSeriesGroup(item)
        local entry = item and item.entry
        if entry and entry.is_series_group then
            return true
        end
        local cache = MosaicMenuItem._automatic_series_items_cache
        local filepath = item and ((entry and entry.path) or item.filepath)
        return cache and filepath and cache[filepath] ~= nil or false
    end

    local function hasExternalCaption(item)
        return isBook(item) or isSeriesGroup(item)
    end

    local function isImageWidget(widget)
        return type(widget) == "table"
            and type(widget._render) == "function"
            and type(widget.getOriginalWidth) == "function"
            and type(widget.getSize) == "function"
    end

    local function getFrameChrome(frame)
        if not frame then return 0, 0 end
        local margin = tonumber(frame.margin) or 0
        local border = tonumber(frame.bordersize) or 0
        local padding = tonumber(frame.padding) or 0
        local padding_left = tonumber(frame.padding_left) or padding
        local padding_right = tonumber(frame.padding_right) or padding
        local padding_top = tonumber(frame.padding_top) or padding
        local padding_bottom = tonumber(frame.padding_bottom) or padding

        return 2 * (margin + border) + padding_left + padding_right,
               2 * (margin + border) + padding_top + padding_bottom
    end

    local function walkWidgets(widget, parent, seen, candidates)
        if type(widget) ~= "table" or seen[widget] then
            return
        end
        seen[widget] = true

        if isImageWidget(widget) then
            local ok, size = pcall(widget.getSize, widget)
            if ok and size and size.w and size.h and size.w > 0 and size.h > 0 then
                candidates[#candidates + 1] = {
                    image = widget,
                    parent = parent,
                    area = size.w * size.h,
                    width = size.w,
                    height = size.h,
                }
            end
        end

        local count = #widget
        for i = 1, count do
            walkWidgets(widget[i], widget, seen, candidates)
        end
    end

    local function findPrimaryCover(item)
        local root = item and item[1]
        if not root then return end

        local candidates = {}
        walkWidgets(root, nil, {}, candidates)
        if #candidates == 0 then return end

        table.sort(candidates, function(a, b)
            return a.area > b.area
        end)

        local candidate = candidates[1]
        local frame = candidate.parent or candidate.image

        -- The immediate parent is normally the cover FrameContainer. If an
        -- intermediary container is present, the image itself can still be
        -- resized; frame chrome simply remains zero.
        return candidate.image, frame, root, candidate.width, candidate.height
    end

    local function updateMatchingDimensions(widget, old_w, old_h, new_w, new_h, seen)
        if type(widget) ~= "table" then return end
        seen = seen or {}
        if seen[widget] then return end
        seen[widget] = true

        if widget.dimen and widget.dimen.w and widget.dimen.h then
            if math.abs(widget.dimen.w - old_w) <= 1 and math.abs(widget.dimen.h - old_h) <= 1 then
                widget.dimen.w = new_w
                widget.dimen.h = new_h
            end
        end

        local count = #widget
        for i = 1, count do
            updateMatchingDimensions(widget[i], old_w, old_h, new_w, new_h, seen)
        end
    end

    local function replaceRenderedBuffer(image, new_w, new_h)
        if not image._bb then
            return false
        end

        local ok, scaled = pcall(RenderImage.scaleBlitBuffer, RenderImage, image._bb, new_w, new_h, false)
        if not ok or not scaled then
            logger.warn("Burrow cover size: could not resize rendered cover buffer")
            return false
        end

        image._bb = scaled
        image._bb_disposable = true
        image._bb_w = new_w
        image._bb_h = new_h
        image._offset_x = 0
        image._offset_y = 0
        image._max_off_center_x_ratio = 0
        image._max_off_center_y_ratio = 0
        image.width = new_w
        image.height = new_h
        image.scale_factor = 1
        return true
    end

    local function resizePrimaryCover(item)
        if not item or item._burrow_cover_size_applied == getCoverSize() then
            return
        end

        local image, frame, root, image_w, image_h = findPrimaryCover(item)
        if not image or not image_w or not image_h then
            return
        end

        local frame_size
        if frame and frame.getSize then
            local ok, value = pcall(frame.getSize, frame)
            if ok then frame_size = value end
        end

        local frame_w = frame_size and frame_size.w or image_w
        local frame_h = frame_size and frame_size.h or image_h
        local chrome_w, chrome_h = getFrameChrome(frame)

        image._burrow_cover_size_base_width = image._burrow_cover_size_base_width or image_w
        image._burrow_cover_size_base_height = image._burrow_cover_size_base_height or image_h
        if image._burrow_cover_size_base_scale_factor == nil then
            image._burrow_cover_size_base_scale_factor = image.scale_factor
            image._burrow_cover_size_base_scale_factor_was_nil = image.scale_factor == nil
        end

        frame._burrow_cover_size_base_width = frame._burrow_cover_size_base_width or frame_w
        frame._burrow_cover_size_base_height = frame._burrow_cover_size_base_height or frame_h

        local factor = getCoverSize() / 100
        local base_image_w = image._burrow_cover_size_base_width
        local base_image_h = image._burrow_cover_size_base_height
        local base_frame_h = frame._burrow_cover_size_base_height

        -- Apply the requested scale directly. Values above 100 intentionally
        -- let the visual cover use the surrounding grid space instead of being
        -- silently capped by the original tile dimensions. The touch target and
        -- grid remain unchanged, and book/series covers grow upward so the
        -- caption can stay visible beneath them.
        local effective_factor = math.max(0.01, factor)

        local new_image_w = math.max(1, round(base_image_w * effective_factor))
        local new_image_h = math.max(1, round(base_image_h * effective_factor))
        local new_frame_w = new_image_w + chrome_w
        local new_frame_h = new_image_h + chrome_h

        if image._bb then
            replaceRenderedBuffer(image, new_image_w, new_image_h)
        else
            image.width = new_image_w
            image.height = new_image_h

            if image._burrow_cover_size_base_scale_factor_was_nil then
                image.scale_factor = nil
            elseif type(image._burrow_cover_size_base_scale_factor) == "number" then
                if image._burrow_cover_size_base_scale_factor == 0 then
                    image.scale_factor = 0
                else
                    image.scale_factor = image._burrow_cover_size_base_scale_factor * effective_factor
                end
            end
        end

        if frame then
            frame.width = new_frame_w
            frame.height = new_frame_h
            if frame.dimen then
                frame.dimen.w = new_frame_w
                frame.dimen.h = new_frame_h
            end
        end

        -- Folder-name and item-count overlays use the original cover dimensions.
        -- Resize matching overlay containers so they remain attached to the
        -- resized folder face instead of floating over the old area.
        if not isBook(item) then
            updateMatchingDimensions(root, frame_w, frame_h, new_frame_w, new_frame_h)
        end

        item._burrow_primary_cover_frame = frame
        item._burrow_cover_base_height = base_frame_h
        item._burrow_cover_current_height = new_frame_h
        item._burrow_cover_vertical_shift = hasExternalCaption(item)
            and math.max(0, round((new_frame_h - base_frame_h) / 2))
            or 0
        item._burrow_cover_size_applied = getCoverSize()
    end

    if not MosaicMenuItem._burrow_cover_size_patched_v2 then
        MosaicMenuItem._burrow_cover_size_patched_v2 = true

        local original_update = MosaicMenuItem.update
        function MosaicMenuItem:update(...)
            local result = original_update(self, ...)
            resizePrimaryCover(self)
            return result
        end

        logger.info("Burrow book and folder cover size control loaded", getCoverSize())
    end

    -- The rounded-cover title patch paints captions from inside its own paint
    -- wrapper. Defer only that specific caption while a grid item is painting,
    -- then repaint it below the actual resized cover after every other cover
    -- layer has finished.
    local active_caption_item
    local original_text_paint = TextWidget.paintTo

    if not TextWidget._burrow_cover_caption_defer_patched then
        TextWidget._burrow_cover_caption_defer_patched = true
        TextWidget._burrow_cover_caption_original_paint = original_text_paint

        function TextWidget:paintTo(bb, x, y)
            local item = active_caption_item
            if item and item._cover_caption == self then
                item._burrow_cover_caption_deferred = true
                return
            end
            return TextWidget._burrow_cover_caption_original_paint(self, bb, x, y)
        end
    else
        original_text_paint = TextWidget._burrow_cover_caption_original_paint or original_text_paint
    end

    if not MosaicMenuItem._burrow_cover_gap_reduction_patched_v2 then
        MosaicMenuItem._burrow_cover_gap_reduction_patched_v2 = true

        local original_paint = MosaicMenuItem.paintTo
        function MosaicMenuItem:paintTo(bb, x, y)
            local original_y = y
            local reduction = getGap()
            local menu = self.menu
            local columns = menu and tonumber(menu.nb_cols)
            local index = self.entry and tonumber(self.entry.idx)

            if reduction > 0 and columns and columns > 1 and index then
                local column = ((index - 1) % columns) + 1
                local center_column = (columns + 1) / 2
                local step = Screen:scaleBySize(reduction)
                x = x + round((center_column - column) * step)
            end

            local vertical_shift = tonumber(self._burrow_cover_vertical_shift) or 0
            active_caption_item = self
            self._burrow_cover_caption_deferred = nil

            local ok, result = pcall(original_paint, self, bb, x, y - vertical_shift)
            active_caption_item = nil
            if not ok then
                error(result)
            end

            if self._burrow_cover_caption_deferred and self._cover_caption then
                local caption = self._cover_caption
                local caption_size = caption:getSize()
                local caption_x = x + math.floor(((tonumber(self.width) or caption_size.w) - caption_size.w) / 2)

                local frame = self._burrow_primary_cover_frame
                local cover_bottom
                if frame and frame.dimen and frame.dimen.y and frame.dimen.h then
                    cover_bottom = frame.dimen.y + frame.dimen.h
                else
                    local current_h = tonumber(self._burrow_cover_current_height) or 0
                    cover_bottom = y - vertical_shift
                        + math.floor(((tonumber(self.height) or current_h) - current_h) / 2)
                        + current_h
                end

                local caption_y = cover_bottom + CAPTION_GAP
                local lowest_y = original_y + (tonumber(self.height) or caption_size.h) - caption_size.h
                if caption_y > lowest_y then
                    caption_y = lowest_y
                end

                original_text_paint(caption, bb, caption_x, caption_y)
            end

            return result
        end

        logger.info("Burrow cover gap and safe caption placement loaded", getGap())
    end

    if plugin._burrow_cover_controls_menu_patched_v2 then
        return
    end
    plugin._burrow_cover_controls_menu_patched_v2 = true

    local original_add_to_main_menu = plugin.addToMainMenu

    function plugin:addToMainMenu(menu_items)
        original_add_to_main_menu(self, menu_items)

        local root = menu_items.filemanager_display_mode
        local items = root and root.sub_item_table
        if not items then return end

        local gap_item = {
            text_func = function()
                return T(_("Cover gap reduction: %1"), getGap())
            end,
            callback = function()
                local SpinWidget = require("ui/widget/spinwidget")
                UIManager:show(SpinWidget:new {
                    title_text = _("Cover gap reduction"),
                    info_text = _("0 keeps normal placement. Higher values move complete book and folder tiles inward without changing their touch areas. Restart KOReader after saving."),
                    value = getGap(),
                    default_value = DEFAULT_GAP,
                    value_min = MIN_GAP,
                    value_max = MAX_GAP,
                    value_step = 2,
                    value_hold_step = 5,
                    ok_text = _("Save"),
                    callback = function(spin)
                        BookInfoManager:saveSetting(GAP_SETTING_KEY, normalizeGap(spin.value))
                        local InfoMessage = require("ui/widget/infomessage")
                        UIManager:show(InfoMessage:new {
                            text = _("Cover gap reduction saved. Restart KOReader to apply it."),
                            timeout = 3,
                        })
                    end,
                })
            end,
        }

        local size_item = {
            text_func = function()
                return T(_("Cover size: %1%"), getCoverSize())
            end,
            callback = function()
                local SpinWidget = require("ui/widget/spinwidget")
                UIManager:show(SpinWidget:new {
                    title_text = _("Cover size"),
                    info_text = _("Resizes book covers, real folder covers, and virtual series covers. Values above 100% deliberately use the surrounding grid space so covers become visibly larger. Enlarged book and series covers move upward so their titles remain visible underneath. Restart KOReader after saving."),
                    value = getCoverSize(),
                    default_value = DEFAULT_SIZE,
                    value_min = MIN_SIZE,
                    value_max = MAX_SIZE,
                    value_step = 5,
                    value_hold_step = 10,
                    unit = "%",
                    ok_text = _("Save"),
                    callback = function(spin)
                        BookInfoManager:saveSetting(SIZE_SETTING_KEY, normalizeSize(spin.value))
                        local InfoMessage = require("ui/widget/infomessage")
                        UIManager:show(InfoMessage:new {
                            text = _("Cover size saved. Restart KOReader to apply it."),
                            timeout = 3,
                        })
                    end,
                })
            end,
        }

        local insert_at = #items + 1
        for i, item in ipairs(items) do
            if item.text == _("Advanced settings") then
                insert_at = i
                break
            end
        end

        table.insert(items, insert_at, gap_item)
        table.insert(items, insert_at + 1, size_item)
    end
end

Module.apply = patchBurrowCoverControls
return Module

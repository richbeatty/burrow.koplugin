local MODULE_KEY = "burrow.internal.2_series_badge_numbered"
local existing_module = package.loaded[MODULE_KEY]
if existing_module then return existing_module end
local Module = { key = MODULE_KEY, phase = "instance", filename = "2-series-badge-numbered.lua" }
package.loaded[MODULE_KEY] = Module

--[[
    Adds a compact numbered series badge inside the bottom-right corner of covers.

    The circle sizes itself around the text instead of using a large fixed size.
    Install series.number.badge.svg in KOReader's icons folder.
--]]

local Blitbuffer = require("ffi/blitbuffer")
local Font = require("ui/font")
local IconWidget = require("ui/widget/iconwidget")
local Screen = require("device").screen
local TextWidget = require("ui/widget/textwidget")
local userpatch = require("userpatch")

--========================== Preferences =============================
local font_size = 11
local text_color = Blitbuffer.colorFromString("#444444")
local badge_padding = Screen:scaleBySize(3)
local minimum_diameter = Screen:scaleBySize(21)
local badge_inset = Screen:scaleBySize(4)
--====================================================================

local function formatSeriesIndex(value)
    local text = tostring(value)
    return text:gsub("%.0$", "")
end

local function patchAddSeriesIndicator(plugin)
    local MosaicMenu = require("mosaicmenu")
    local MosaicMenuItem = userpatch.getUpValue(MosaicMenu._updateItemsBuildUI, "MosaicMenuItem")
    local BookInfoManager = require("bookinfomanager")

    if not MosaicMenuItem or MosaicMenuItem.patched_series_badge then
        return
    end
    MosaicMenuItem.patched_series_badge = true

    local original_init = MosaicMenuItem.init
    local original_paint = MosaicMenuItem.paintTo
    local original_free = MosaicMenuItem.free

    function MosaicMenuItem:init()
        original_init(self)

        if self.is_directory or self.file_deleted then
            return
        end

        local bookinfo = BookInfoManager:getBookInfo(self.filepath, false)
        if not bookinfo or not bookinfo.series or not bookinfo.series_index then
            return
        end

        self.series_index = bookinfo.series_index
        self._series_text = TextWidget:new {
            text = "#" .. formatSeriesIndex(self.series_index),
            face = Font:getFace("cfont", font_size),
            bold = true,
            fgcolor = text_color,
            padding = 0,
        }

        local text_dimensions = self._series_text:getSize()
        self._series_badge_diameter = math.max(
            minimum_diameter,
            math.max(text_dimensions.w, text_dimensions.h) + 2 * badge_padding
        )

        self._series_badge_background = IconWidget:new {
            icon = "series.number.badge",
            alpha = true,
            width = self._series_badge_diameter,
            height = self._series_badge_diameter,
        }
        self.has_series_badge = true
    end

    function MosaicMenuItem:paintTo(bb, x, y)
        original_paint(self, bb, x, y)

        if not self.has_series_badge
            or not self._series_badge_background
            or not self._series_text
            or not self._series_badge_diameter
        then
            return
        end

        local target = self[1] and self[1][1] and self[1][1][1]
        if not target or not target.dimen then
            return
        end

        local diameter = self._series_badge_diameter
        local badge_x = target.dimen.x + target.dimen.w - diameter - badge_inset
        local badge_y = target.dimen.y + target.dimen.h - diameter - badge_inset
        badge_x = math.floor(badge_x)
        badge_y = math.floor(badge_y)

        self._series_badge_background:paintTo(bb, badge_x, badge_y)

        local text_dimensions = self._series_text:getSize()
        local text_x = badge_x + math.floor((diameter - text_dimensions.w) / 2)
        local text_y = badge_y + math.floor((diameter - text_dimensions.h) / 2)
        self._series_text:paintTo(bb, text_x, text_y)
    end

    if original_free then
        function MosaicMenuItem:free()
            if self._series_badge_background then
                self._series_badge_background:free(true)
                self._series_badge_background = nil
            end
            if self._series_text then
                self._series_text:free(true)
                self._series_text = nil
            end
            self._series_badge_diameter = nil
            self.series_index = nil
            self.has_series_badge = nil
            original_free(self)
        end
    end
end

Module.apply = patchAddSeriesIndicator
return Module

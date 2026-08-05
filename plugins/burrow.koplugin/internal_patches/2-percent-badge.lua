local MODULE_KEY = "burrow.internal.2_percent_badge"
local existing_module = package.loaded[MODULE_KEY]
if existing_module then return existing_module end
local Module = { key = MODULE_KEY, phase = "instance", filename = "2-percent-badge.lua" }
package.loaded[MODULE_KEY] = Module

--[[
    Adds a compact bookmark-ribbon progress badge to the top-right corner
    of book covers.

    The ribbon sits flush with the cover's top edge. Percentage text is
    automatically reduced as needed so both 75% and 100% keep side spacing.
    Install percent.badge.svg in KOReader's icons folder.
--]]

local Blitbuffer = require("ffi/blitbuffer")
local Font = require("ui/font")
local IconWidget = require("ui/widget/iconwidget")
local Screen = require("device").screen
local TextWidget = require("ui/widget/textwidget")
local userpatch = require("userpatch")

--========================== Preferences =============================
local text_size = 0.35
local four_character_text_size = 0.30
local text_color = Blitbuffer.colorFromString("#444444")
local inset_x = Screen:scaleBySize(4)
local badge_width = Screen:scaleBySize(31)
local badge_height = Screen:scaleBySize(36)
local notch_height = Screen:scaleBySize(9)
local side_padding = Screen:scaleBySize(5)
local text_nudge_up = Screen:scaleBySize(1)
--====================================================================

local function makePercentWidget(text, font_size)
    return TextWidget:new {
        text = text,
        face = Font:getFace("cfont", font_size),
        bold = true,
        fgcolor = text_color,
        alignment = "center",
        padding = 0,
    }
end

local function patchCoverBrowserProgressPercent(plugin)
    local MosaicMenu = require("mosaicmenu")
    local MosaicMenuItem = userpatch.getUpValue(MosaicMenu._updateItemsBuildUI, "MosaicMenuItem")

    if not MosaicMenuItem or MosaicMenuItem.patched_percent_badge then
        return
    end
    MosaicMenuItem.patched_percent_badge = true

    local original_paint = MosaicMenuItem.paintTo

    function MosaicMenuItem:paintTo(bb, x, y)
        original_paint(self, bb, x, y)

        if self.is_directory or self.status == "complete" or not self.percent_finished then
            return
        end

        if not ((self.do_hint_opened and self.been_opened)
            or self.menu.name == "history"
            or self.menu.name == "collections")
        then
            return
        end

        local target = self[1] and self[1][1] and self[1][1][1]
        if not target or not target.dimen then
            return
        end

        local percent_text = string.format("%d%%", math.floor(self.percent_finished * 100))
        local corner_mark_size = Screen:scaleBySize(20)
        local scale = #percent_text >= 4 and four_character_text_size or text_size
        local font_size = math.max(7, math.floor(corner_mark_size * scale))
        local max_text_width = math.max(1, badge_width - 2 * side_padding)

        local percent_widget = makePercentWidget(percent_text, font_size)
        local text_dimensions = percent_widget:getSize()

        -- Keep reducing the font until the percentage has real side breathing room.
        while text_dimensions.w > max_text_width and font_size > 7 do
            percent_widget:free(true)
            font_size = font_size - 1
            percent_widget = makePercentWidget(percent_text, font_size)
            text_dimensions = percent_widget:getSize()
        end

        local badge_widget = IconWidget:new {
            icon = "percent.badge",
            alpha = true,
            width = badge_width,
            height = badge_height,
        }

        local badge_x = math.floor(target.dimen.x + target.dimen.w - badge_width - inset_x)
        -- No vertical inset: the ribbon begins exactly at the cover's top edge.
        local badge_y = math.floor(target.dimen.y)

        badge_widget:paintTo(bb, badge_x, badge_y)

        local usable_height = badge_height - notch_height
        local text_x = badge_x + math.floor((badge_width - text_dimensions.w) / 2)
        local text_y = badge_y
            + math.floor((usable_height - text_dimensions.h) / 2)
            - text_nudge_up
        percent_widget:paintTo(bb, text_x, text_y)

        badge_widget:free(true)
        percent_widget:free(true)
    end
end

Module.apply = patchCoverBrowserProgressPercent
return Module

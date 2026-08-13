local MODULE_KEY = "burrow.internal.2_quick_settings_swipe_guard"
local existing_module = package.loaded[MODULE_KEY]
if existing_module then return existing_module end

local Math = require("optmath")
local TouchMenu = require("ui/widget/touchmenu")

local Module = {
    key = MODULE_KEY,
    phase = "early",
    filename = "2-quick-settings-swipe-guard.lua",
}
package.loaded[MODULE_KEY] = Module

local function handleSliderGesture(touch_menu, ges)
    local refs = touch_menu._rounded_qs_refs
    if not refs or not ges or not ges.pos then return false end

    for _, slider in ipairs(refs.sliders or {}) do
        if slider.widget.dimen and ges.pos:intersectWith(slider.widget.dimen) then
            local percentage = slider.widget:getPercentageFromPosition(ges.pos)
            if percentage then
                local state = slider.state
                slider.setValue(Math.round(state.min + percentage * (state.max - state.min)))
                return true
            end
        end
    end

    return false
end

function Module.apply()
    if Module.applied then return true end
    if TouchMenu._burrow_quick_settings_swipe_guard then
        Module.applied = true
        return true
    end
    TouchMenu._burrow_quick_settings_swipe_guard = true

    -- 2-quick-settings.lua has already wrapped TouchMenu:onSwipe at this point.
    -- Keep that implementation for normal KOReader tabs, but intercept Burrow's
    -- custom Quick Settings panel first. A swipe must never act like a button tap.
    local original_onSwipe = TouchMenu.onSwipe
    function TouchMenu:onSwipe(arg, ges_ev)
        if self._rounded_qs_refs and self.item_table and self.item_table.panel then
            -- Slider dragging remains useful. Every other swipe in Quick Settings
            -- is consumed so it cannot trigger an action tile or propagate into
            -- TouchMenu while the gesture is still being processed.
            handleSliderGesture(self, ges_ev)
            return true
        end
        if original_onSwipe then
            return original_onSwipe(self, arg, ges_ev)
        end
    end

    Module.applied = true
    return true
end

return Module

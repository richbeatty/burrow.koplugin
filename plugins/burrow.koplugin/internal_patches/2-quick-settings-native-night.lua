local MODULE_KEY = "burrow.internal.2_quick_settings_native_night"
local existing_module = package.loaded[MODULE_KEY]
if existing_module then return existing_module end

local Module = {
    key = MODULE_KEY,
    phase = "early",
    filename = "2-quick-settings-native-night.lua",
}
package.loaded[MODULE_KEY] = Module

local function getUpValue(fn, wanted)
    if type(fn) ~= "function" then return nil end
    for index = 1, 100 do
        local name, value = debug.getupvalue(fn, index)
        if not name then break end
        if name == wanted then return value end
    end
end

function Module.apply()
    if Module.applied then return true end

    local quick = package.loaded["burrow.internal.2_quick_settings"]
    if type(quick) ~= "table" or type(quick.getSettingsMenu) ~= "function" then
        return false, "Quick Settings module is unavailable"
    end

    -- buildSettingsMenu -> makeButtonSettings -> button_defs. Patch only the
    -- Night action instead of replacing or reloading the full Quick Settings
    -- module. This keeps the already-tested panel/layout code untouched.
    local makeButtonSettings = getUpValue(quick.getSettingsMenu, "makeButtonSettings")
    local button_defs = getUpValue(makeButtonSettings, "button_defs")
    if type(button_defs) ~= "table"
        or type(button_defs.night) ~= "table"
    then
        return false, "Could not locate Quick Settings Night action"
    end

    local Event = require("ui/event")
    local UIManager = require("ui/uimanager")

    button_defs.night.callback = function(touch_menu)
        -- Use KOReader's native DeviceListener path. It handles screen
        -- inversion, CRengine cache reset, highlight refresh, persistence and
        -- the repaint as one coordinated Night Mode transition.
        UIManager:broadcastEvent(Event:new("ToggleNightMode"))

        UIManager:nextTick(function()
            if touch_menu
                and touch_menu.item_table
                and touch_menu.item_table.panel
            then
                touch_menu:updateItems(1)
            end
        end)
    end

    Module.applied = true
    return true
end

return Module

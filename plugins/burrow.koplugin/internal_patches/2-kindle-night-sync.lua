local MODULE_KEY = "burrow.internal.2_kindle_night_sync"
local existing_module = package.loaded[MODULE_KEY]
if existing_module then return existing_module end

local Module = {
    key = MODULE_KEY,
    phase = "early",
    filename = "2-kindle-night-sync.lua",
}
package.loaded[MODULE_KEY] = Module

function Module.sync()
    local Device = require("device")

    -- Kindle uses the framebuffer's hardware inversion flag for Night Mode.
    -- KOReader keeps its own logical Screen.night_mode state separately. Keep
    -- these synchronized without ever changing the user's saved Night Mode
    -- preference or Device.orig_hw_nightmode. This is safe to call repeatedly,
    -- including immediately before/after Burrow reloads an ornament shadow.
    if not Device:isKindle()
        or not Device:canHWInvert()
        or not Device:canModifyFBInfo()
    then
        return true
    end

    local Screen = Device.screen
    if type(Screen) ~= "table"
        or type(Screen.getHWNightmode) ~= "function"
        or type(Screen.setHWNightmode) ~= "function"
    then
        return false, "Kindle hardware Night Mode API is unavailable"
    end

    local ok_hw, hw_night = pcall(Screen.getHWNightmode, Screen)
    if not ok_hw then
        return false, "Could not read Kindle hardware Night Mode: " .. tostring(hw_night)
    end

    local logical_night = Screen.night_mode == true
    hw_night = hw_night == true

    if hw_night ~= logical_night then
        local ok_set, set_error = pcall(
            Screen.setHWNightmode,
            Screen,
            logical_night
        )
        if not ok_set then
            return false, "Could not synchronize Kindle hardware Night Mode: "
                .. tostring(set_error)
        end

        local ok_verify, verified_hw = pcall(Screen.getHWNightmode, Screen)
        if not ok_verify or (verified_hw == true) ~= logical_night then
            return false, "Kindle hardware Night Mode did not accept the requested state"
        end

        local UIManager = require("ui/uimanager")
        UIManager:setDirty("all", "full")

        local logger = require("logger")
        logger.info(
            "[Burrow] Synchronized Kindle hardware Night Mode with KOReader state",
            logical_night
        )
    end

    return true
end

function Module.apply()
    if Module.applied then return true end

    local ok, err = Module.sync()
    if not ok then return false, err end

    Module.applied = true
    return true
end

return Module

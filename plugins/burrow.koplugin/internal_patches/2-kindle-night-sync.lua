local MODULE_KEY = "burrow.internal.2_kindle_night_sync"
local existing_module = package.loaded[MODULE_KEY]
if existing_module then return existing_module end

local Module = {
    key = MODULE_KEY,
    phase = "early",
    filename = "2-kindle-night-sync.lua",
}
package.loaded[MODULE_KEY] = Module

function Module.apply()
    if Module.applied then return true end

    local Device = require("device")

    -- Kindle uses the framebuffer's hardware inversion flag for Night Mode.
    -- KOReader keeps its own logical Screen.night_mode state separately. A
    -- restart can therefore inherit a stale hardware flag even while KOReader's
    -- saved/logical Night Mode is off. Android does not use this path.
    if not Device:isKindle()
        or not Device:canHWInvert()
        or not Device:canModifyFBInfo()
    then
        Module.applied = true
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

        -- Do not change G_reader_settings or Device.orig_hw_nightmode. KOReader
        -- still owns the user's Night Mode setting and will restore the Kindle's
        -- pre-KOReader hardware state when it finally exits. We only make the
        -- hardware match KOReader's current logical state while Burrow is open.
        local UIManager = require("ui/uimanager")
        UIManager:setDirty("all", "full")

        local logger = require("logger")
        logger.info(
            "[Burrow] Synchronized Kindle hardware Night Mode with KOReader state",
            logical_night
        )
    end

    Module.applied = true
    return true
end

return Module

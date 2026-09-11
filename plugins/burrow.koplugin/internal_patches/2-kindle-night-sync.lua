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

local function patchDirectory()
    local source = debug.getinfo(1, "S").source
    return source:match("^@(.+)/[^/]+$")
end

local function applyFastEinkPageTurns()
    -- Fast page turns are e-ink-wide, not Kindle-specific. Load them from this
    -- always-present early module to preserve Burrow's established module order.
    -- The implementation itself returns immediately on non-e-ink screens.
    local directory = patchDirectory()
    if not directory then return end

    local ok_load, fast_turns = pcall(dofile, directory .. "/2-fast-dark-page-turns.lua")
    if not ok_load or type(fast_turns) ~= "table" or type(fast_turns.apply) ~= "function" then
        local logger = require("logger")
        logger.warn("[Burrow] Fast e-ink page turns unavailable", fast_turns)
        return
    end

    local ok_apply, result, apply_error = pcall(fast_turns.apply)
    if not ok_apply or result == false then
        local logger = require("logger")
        logger.warn("[Burrow] Fast e-ink page turns failed; continuing with KOReader defaults", ok_apply and apply_error or result)
    end
end

local function applyKindleWifiRecovery()
    -- Keep the Wi-Fi recovery implementation in its own file and guard it here.
    -- A networking compatibility failure must never disable Kindle Night Mode
    -- synchronization or any larger Burrow subsystem.
    local directory = patchDirectory()
    if not directory then return end

    local ok_load, recovery = pcall(dofile, directory .. "/2-kindle-wifi-recovery.lua")
    if not ok_load or type(recovery) ~= "table" or type(recovery.apply) ~= "function" then
        local logger = require("logger")
        logger.warn("[Burrow] Kindle Wi-Fi recovery unavailable", recovery)
        return
    end

    local ok_apply, result, apply_error = pcall(recovery.apply)
    if not ok_apply or result == false then
        local logger = require("logger")
        logger.warn("[Burrow] Kindle Wi-Fi recovery failed; continuing without it", ok_apply and apply_error or result)
    end
end

function Module.apply()
    if Module.applied then return true end

    local ok, err = Module.sync()
    if not ok then return false, err end

    applyFastEinkPageTurns()
    applyKindleWifiRecovery()

    Module.applied = true
    return true
end

return Module

local Event = require("ui/event")
local Device = require("device")
local UIManager = require("ui/uimanager")
local logger = require("logger")

local RotationFix = {}

function RotationFix.apply()
    if UIManager._burrow_quick_rotation_v2 then
        return true
    end
    UIManager._burrow_quick_rotation_v2 = true

    local Screen = Device.screen
    local original_broadcast = UIManager.broadcastEvent

    local function calledFromBurrowQuickSettings()
        local info = debug.getinfo(3, "S")
        local source = info and tostring(info.source or "") or ""
        return source:find("2-quick-settings.lua", 1, true) ~= nil
    end

    function UIManager:broadcastEvent(event, ...)
        local burrow_rotate = event
            and event.handler == "onSwapRotation"
            and calledFromBurrowQuickSettings()

        if burrow_rotate then
            event = Event:new("IterateRotation")
            G_reader_settings:makeTrue("lock_rotation")
        end

        local result = original_broadcast(self, event, ...)

        if burrow_rotate then
            G_reader_settings:saveSetting("fm_rotation_mode", Screen:getRotationMode())
            logger.dbg("[Burrow] Saved Quick Settings rotation", Screen:getRotationMode())
        end

        return result
    end

    return true
end

return RotationFix

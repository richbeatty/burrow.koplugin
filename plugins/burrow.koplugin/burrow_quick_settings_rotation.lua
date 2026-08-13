local Event = require("ui/event")
local Device = require("device")
local UIManager = require("ui/uimanager")
local logger = require("logger")

local RotationFix = {}

function RotationFix.apply()
    if UIManager._burrow_quick_rotation_v3 then
        return true
    end
    UIManager._burrow_quick_rotation_v3 = true

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
            -- Cycle through all four physical orientations instead of KOReader's
            -- paired portrait/landscape SwapRotation behavior.
            event = Event:new("IterateRotation")

            -- Keep this orientation when moving between File Manager and Reader.
            G_reader_settings:makeTrue("lock_rotation")
        end

        local result = original_broadcast(self, event, ...)

        if burrow_rotate then
            -- Persist the actual post-rotation mode as Burrow's startup rotation.
            -- KOReader normally skips fm_rotation_mode at startup when
            -- lock_rotation is enabled, so Burrow also restores this value below.
            local mode = Screen:getRotationMode()
            G_reader_settings:saveSetting("fm_rotation_mode", mode)
            if type(G_reader_settings.flush) == "function" then
                G_reader_settings:flush()
            end
            logger.dbg("[Burrow] Saved Quick Settings rotation", mode)
        end

        return result
    end

    -- KOReader's FileManager:setRotationMode() intentionally does nothing when
    -- lock_rotation is true. That is correct while switching views, but on a
    -- fresh KOReader process it means the saved fm_rotation_mode is never
    -- reapplied. Restore it once after Burrow starts so a full KOReader restart
    -- comes back on the same physical side chosen from Quick Settings.
    local saved_mode = tonumber(G_reader_settings:readSetting("fm_rotation_mode"))
    if G_reader_settings:isTrue("lock_rotation") and saved_mode ~= nil then
        saved_mode = saved_mode % 4
        UIManager:nextTick(function()
            if Screen:getRotationMode() ~= saved_mode then
                original_broadcast(UIManager, Event:new("SetRotationMode", saved_mode))
                logger.dbg("[Burrow] Restored saved startup rotation", saved_mode)
            end
        end)
    end

    return true
end

return RotationFix

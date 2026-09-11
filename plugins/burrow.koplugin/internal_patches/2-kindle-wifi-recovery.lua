local MODULE_KEY = "burrow.internal.2_kindle_wifi_recovery"
local existing_module = package.loaded[MODULE_KEY]
if existing_module then return existing_module end

local Module = {
    key = MODULE_KEY,
    phase = "early",
    filename = "2-kindle-wifi-recovery.lua",
}
package.loaded[MODULE_KEY] = Module

--[[
    Burrow Kindle Wi-Fi recovery

    KOReader's Kindle background restore path only asks Amazon's wifid service
    to enable Wi-Fi and then waits for connectivity. On some Kindles, especially
    after the device has moved out of range and back again, that is not enough
    to trigger a fresh association with a saved network. The normal interactive
    Wi-Fi path works because it performs an active scan and explicitly asks the
    Kindle backend to authenticate a known network.

    This patch keeps KOReader's normal background restore intact, then performs
    one silent Kindle-only scan shortly afterward if the device is still not
    connected. If a saved network is visible, Burrow asks the existing Kindle
    backend to authenticate it. There are deliberately no dialogs, toasts, or
    failure messages in this automatic path.

    Important behavior:
    - Kindle only. Other devices are untouched.
    - Manual Wi-Fi actions remain KOReader's normal visible/interactive path.
    - A failed automatic restore does not erase the user's prior "Wi-Fi was on"
      intent, so a later resume can try again when a known network is available.
    - Explicit/manual Wi-Fi off still clears that intent through KOReader.
    - Only one silent scan is scheduled per restore call, with a short cooldown
      to avoid duplicate work during rapid lifecycle events.
--]]

function Module.apply()
    if Module.applied then return true end

    local Device = require("device")
    if not Device:isKindle() then
        Module.applied = true
        return true
    end

    local NetworkMgr = require("ui/network/manager")
    local UIManager = require("ui/uimanager")
    local logger = require("logger")

    if NetworkMgr._burrow_kindle_wifi_recovery_v1 then
        Module.applied = true
        return true
    end

    local original_restore = NetworkMgr.restoreWifiAsync
    local original_abort = NetworkMgr._abortWifiConnection
    local original_connectivity_check = NetworkMgr.connectivityCheck
    local original_enable = NetworkMgr.enableWifi
    local original_disable = NetworkMgr.disableWifi
    local original_toggle_on = NetworkMgr.toggleWifiOn
    local original_toggle_off = NetworkMgr.toggleWifiOff

    if type(original_restore) ~= "function"
        or type(original_abort) ~= "function"
        or type(original_connectivity_check) ~= "function"
        or type(original_enable) ~= "function"
        or type(original_disable) ~= "function"
        or type(original_toggle_on) ~= "function"
        or type(original_toggle_off) ~= "function"
        or type(NetworkMgr.getNetworkList) ~= "function"
        or type(NetworkMgr.authenticateNetwork) ~= "function"
    then
        logger.warn("Burrow Kindle Wi-Fi recovery: required KOReader network hooks are unavailable")
        Module.applied = true
        return true
    end

    local RECOVERY_DELAY_SECONDS = 2
    local RECOVERY_COOLDOWN_SECONDS = 30

    local function cancelScheduledRecovery(self)
        if self._burrow_kindle_wifi_recovery_callback then
            UIManager:unschedule(self._burrow_kindle_wifi_recovery_callback)
        end
        self._burrow_kindle_wifi_recovery_pending = false
    end

    local function clearAutomaticRestore(self)
        cancelScheduledRecovery(self)
        self._burrow_kindle_auto_restore_active = false
    end

    local function silentRecover(self)
        self._burrow_kindle_wifi_recovery_pending = false

        if not self._burrow_kindle_auto_restore_active then
            return
        end
        if not G_reader_settings:isTrue("auto_restore_wifi") or not self.wifi_was_on then
            clearAutomaticRestore(self)
            return
        end

        self:queryNetworkState()
        if self.is_wifi_on and self.is_connected then
            logger.dbg("Burrow Kindle Wi-Fi recovery: normal background restore already connected")
            clearAutomaticRestore(self)
            return
        end

        local now = os.time()
        local last_attempt = tonumber(self._burrow_kindle_wifi_recovery_last_attempt) or 0
        if now - last_attempt < RECOVERY_COOLDOWN_SECONDS then
            logger.dbg("Burrow Kindle Wi-Fi recovery: skipping duplicate recovery scan")
            return
        end
        self._burrow_kindle_wifi_recovery_last_attempt = now

        -- getNetworkList uses KOReader's existing Kindle backend. It triggers the
        -- same real Kindle scan used by the manual Wi-Fi path, but we deliberately
        -- do not call reconnectOrShowNetworkMenu because that function owns the
        -- visible "Scanning" / "Connecting" / failure messages.
        local ok, network_list, scan_error = pcall(self.getNetworkList, self)
        if not ok then
            logger.warn("Burrow Kindle Wi-Fi recovery: silent scan failed", network_list)
            return
        end
        if type(network_list) ~= "table" then
            logger.dbg("Burrow Kindle Wi-Fi recovery: no scan results", tostring(scan_error))
            return
        end
        if #network_list == 0 then
            logger.dbg("Burrow Kindle Wi-Fi recovery: no networks in range")
            return
        end

        table.sort(network_list, function(left, right)
            return (tonumber(left.signal_quality) or 0) > (tonumber(right.signal_quality) or 0)
        end)

        -- Amazon's backend may already have associated while the scan was in
        -- progress. If so, leave the normal KOReader connectivity check to finish
        -- the lifecycle and emit NetworkConnected.
        for _, network in ipairs(network_list) do
            if network.connected then
                logger.dbg("Burrow Kindle Wi-Fi recovery: Kindle backend already associated", tostring(network.ssid))
                return
            end
        end

        -- Match KOReader's native reconnect policy: saved Kindle profiles expose
        -- their PSK as network.password. Try the strongest saved network first.
        for _, network in ipairs(network_list) do
            if network.password and network.ssid then
                logger.dbg("Burrow Kindle Wi-Fi recovery: silently reconnecting to saved network", tostring(network.ssid))
                local auth_ok, success, auth_error = pcall(self.authenticateNetwork, self, network)
                if not auth_ok then
                    logger.warn("Burrow Kindle Wi-Fi recovery: authentication request failed", success)
                    return
                end
                if success ~= false then
                    return
                end
                logger.dbg("Burrow Kindle Wi-Fi recovery: saved-network authentication declined", tostring(auth_error))
            end
        end

        logger.dbg("Burrow Kindle Wi-Fi recovery: no saved network is currently available")
    end

    local recovery_callback = function()
        silentRecover(NetworkMgr)
    end
    NetworkMgr._burrow_kindle_wifi_recovery_callback = recovery_callback

    local function scheduleSilentRecovery(self)
        cancelScheduledRecovery(self)
        self._burrow_kindle_wifi_recovery_pending = true
        UIManager:scheduleIn(RECOVERY_DELAY_SECONDS, recovery_callback)
    end

    function NetworkMgr:restoreWifiAsync(...)
        -- This method is used by KOReader's automatic startup/resume restoration,
        -- not by the user's explicit Wi-Fi toggle. Mark that narrow lifecycle so
        -- an eventual timeout can preserve the user's prior Wi-Fi intent.
        self._burrow_kindle_auto_restore_active = true

        local result = original_restore(self, ...)
        scheduleSilentRecovery(self)
        return result
    end

    function NetworkMgr:_abortWifiConnection(...)
        local preserve_auto_restore_intent = self._burrow_kindle_auto_restore_active == true
            and self.wifi_was_on == true
            and G_reader_settings:isTrue("auto_restore_wifi")

        cancelScheduledRecovery(self)
        local result = original_abort(self, ...)

        if preserve_auto_restore_intent then
            -- KOReader normally clears wifi_was_on after any failed connection.
            -- For an automatic Kindle resume attempt, being temporarily out of
            -- range should not be treated like an explicit request to keep Wi-Fi
            -- off forever. Preserve only the intent flag; all other native abort
            -- behavior remains unchanged.
            self.wifi_was_on = true
            G_reader_settings:makeTrue("wifi_was_on")
            logger.dbg("Burrow Kindle Wi-Fi recovery: automatic failure preserved Wi-Fi restore intent")
        end

        self._burrow_kindle_auto_restore_active = false
        return result
    end

    function NetworkMgr:connectivityCheck(iter, callback, widget)
        local result = original_connectivity_check(self, iter, callback, widget)

        if self._burrow_kindle_auto_restore_active and self.is_wifi_on and self.is_connected then
            clearAutomaticRestore(self)
        end

        return result
    end

    function NetworkMgr:enableWifi(wifi_cb, interactive)
        if interactive then
            -- A direct user action supersedes any background restore attempt.
            clearAutomaticRestore(self)
        end
        return original_enable(self, wifi_cb, interactive)
    end

    function NetworkMgr:disableWifi(cb, interactive)
        if interactive then
            -- Explicit Wi-Fi off must remain explicit. KOReader's native
            -- disableWifi will clear wifi_was_on when interactive == true.
            clearAutomaticRestore(self)
        end
        return original_disable(self, cb, interactive)
    end

    -- Burrow's Quick Settings button historically called toggleWifiOn/Off
    -- without KOReader's interactive flag. Those functions are user-facing
    -- toggles, and KOReader's own callers are also explicit user actions, so on
    -- Kindle treat an omitted flag as interactive while preserving any caller
    -- that deliberately passes false.
    function NetworkMgr:toggleWifiOn(complete_callback, long_press, interactive)
        if interactive == nil then interactive = true end
        return original_toggle_on(self, complete_callback, long_press, interactive)
    end

    function NetworkMgr:toggleWifiOff(complete_callback, interactive)
        if interactive == nil then interactive = true end
        return original_toggle_off(self, complete_callback, interactive)
    end

    -- NetworkMgr is initialized before Burrow's early modules are applied. If
    -- KOReader already began an automatic startup restore, join that in-flight
    -- attempt so the first launch after updating receives the same silent scan
    -- and intent-preservation behavior as later resume events.
    self = NetworkMgr
    self:queryNetworkState()
    if G_reader_settings:isTrue("auto_restore_wifi")
        and self.wifi_was_on == true
        and not (self.is_wifi_on and self.is_connected)
    then
        self._burrow_kindle_auto_restore_active = true
        scheduleSilentRecovery(self)
        logger.dbg("Burrow Kindle Wi-Fi recovery: joined startup background restore")
    end

    NetworkMgr._burrow_kindle_wifi_recovery_v1 = true
    Module.applied = true
    logger.info("Burrow Kindle silent Wi-Fi recovery loaded")
    return true
end

return Module

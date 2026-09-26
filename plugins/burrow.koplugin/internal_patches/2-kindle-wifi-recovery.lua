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

    This patch keeps KOReader's normal background restore intact, then starts
    one silent Kindle-only scan shortly afterward if the device is still not
    connected. The scan is triggered once and its state is polled through short
    UIManager callbacks. It never calls Kindle getNetworkList(), whose native
    implementation blocks the UI thread while waiting for scan completion.
    If a saved network is visible, Burrow asks the existing Kindle backend to
    authenticate it. There are deliberately no dialogs, toasts, or failure
    messages in this automatic path.

    KOReader Progress Sync has a separate suspend path which deliberately calls
    updateProgress with ensure_networking=true. When a Kindle is out of range,
    that path calls willRerunWhenOnline(), which invokes the full Kindle Wi-Fi
    connection flow and shows the "Scanning for networks" UI. Burrow detects only
    that KOSync-on-suspend call and lets the progress request proceed offline;
    KOSync then uses its existing retry queue and drains it on NetworkConnected.

    Important behavior:
    - Kindle only. Other devices are untouched.
    - Manual Wi-Fi actions remain KOReader's normal visible/interactive path.
    - A failed automatic restore does not erase the user's prior "Wi-Fi was on"
      intent, so a later resume can try again when a known network is available.
    - A direct user Wi-Fi ON action also preserves that intent even when the
      Kindle is temporarily away from every saved network.
    - Explicit/manual Wi-Fi off still clears that intent through KOReader.
    - Only one silent scan is scheduled per restore call, with a short cooldown
      to avoid duplicate work during rapid lifecycle events.
    - KOSync suspend never forces a visible connection attempt while offline;
      its own retry queue preserves the progress update for later.
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

    if NetworkMgr._burrow_kindle_wifi_recovery_v4 then
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
    local original_will_rerun_when_online = NetworkMgr.willRerunWhenOnline

    if type(original_restore) ~= "function"
        or type(original_abort) ~= "function"
        or type(original_connectivity_check) ~= "function"
        or type(original_enable) ~= "function"
        or type(original_disable) ~= "function"
        or type(original_toggle_on) ~= "function"
        or type(original_toggle_off) ~= "function"
        or type(original_will_rerun_when_online) ~= "function"
        or type(NetworkMgr.authenticateNetwork) ~= "function"
    then
        logger.warn("Burrow Kindle Wi-Fi recovery: required KOReader network hooks are unavailable")
        Module.applied = true
        return true
    end

    local RECOVERY_DELAY_SECONDS = 2
    local RECOVERY_COOLDOWN_SECONDS = 30
    local RECOVERY_POLL_SECONDS = 0.25
    local RECOVERY_MAX_POLLS = 80

    local function cancelScheduledRecovery(self)
        if self._burrow_kindle_wifi_recovery_callback then
            UIManager:unschedule(self._burrow_kindle_wifi_recovery_callback)
        end
        if self._burrow_kindle_wifi_recovery_poll_callback then
            UIManager:unschedule(self._burrow_kindle_wifi_recovery_poll_callback)
        end
        self._burrow_kindle_wifi_recovery_pending = false
        self._burrow_kindle_wifi_recovery_polling = false
        self._burrow_kindle_wifi_recovery_poll_count = 0
        self._burrow_kindle_wifi_recovery_saw_scan = false
    end

    local function clearAutomaticRestore(self)
        cancelScheduledRecovery(self)
        self._burrow_kindle_auto_restore_active = false
    end

    local function isKOSyncSuspendNetworkingCall()
        -- The exact stack depth between KOSync:updateProgress and this helper can
        -- change when another narrowly-scoped wrapper is added. Scan only a small
        -- bounded section of the stack and still require both the KOSync source
        -- file and its named on_suspend=true local. This keeps the exception
        -- limited to suspend autosync while leaving manual Push/Pull, Store,
        -- updater, and every other network-required action on KOReader's native
        -- path.
        for level = 3, 8 do
            local info = debug.getinfo(level, "S")
            if not info then break end
            local source = info.source or ""
            if source:find("plugins/kosync%.koplugin/main%.lua", 1, false) then
                local index = 1
                while true do
                    local name, value = debug.getlocal(level, index)
                    if not name then break end
                    if name == "on_suspend" then
                        return value == true
                    end
                    index = index + 1
                end
            end
        end

        return false
    end

    local function withLipcHandle(callback)
        local ok_lipc, lipc = pcall(require, "liblipclua")
        if not ok_lipc or not lipc then return false, "liblipclua unavailable" end

        local handle = lipc.init("com.github.koreader.burrow.wifirecovery")
        if not handle then return false, "could not open LIPC handle" end

        local ok, a, b = pcall(callback, handle)
        pcall(handle.close, handle)
        if not ok then return false, a end
        return true, a, b
    end

    local function triggerNonBlockingScan()
        return withLipcHandle(function(handle)
            -- This property returns immediately. Unlike KOReader's Kindle
            -- getNetworkList(), we never wait in a usleep loop on the UI thread.
            handle:set_string_property("com.lab126.wifid", "scan", "")
            return true
        end)
    end

    local function readScanState()
        local ok, state = withLipcHandle(function(handle)
            return handle:get_string_property("com.lab126.wifid", "scanState")
        end)
        if not ok then return nil, state end
        return state
    end

    local function readScanList()
        local ok_lipc, lipc = pcall(require, "libopenlipclua")
        if not ok_lipc or not lipc then
            return nil, "libopenlipclua unavailable"
        end

        local handle = lipc.open_no_name()
        if not handle then return nil, "could not open scan-list LIPC handle" end

        local input = handle:new_hasharray()
        local ok, result = pcall(function()
            return handle:access_hash_property(
                "com.lab126.wifid",
                "scanList",
                input
            )
        end)

        local list
        if ok and result then
            list = result:to_table()
            pcall(result.destroy, result)
        end
        pcall(input.destroy, input)
        pcall(handle.close, handle)

        if not ok then return nil, result end
        return list or {}
    end

    local function strongestKnownNetwork(scan_list)
        local best
        local best_signal = -math.huge

        for _, network in ipairs(scan_list or {}) do
            local ssid = network.essid
            if network.known == "yes" and ssid and ssid ~= "" then
                local signal = tonumber(network.signal) or 0
                local signal_max = tonumber(network.signal_max) or 0
                local quality = signal_max > 0 and signal / signal_max or signal
                if not best or quality > best_signal then
                    best = { ssid = ssid }
                    best_signal = quality
                end
            end
        end

        return best
    end

    local pollSilentRecovery

    local function finishSilentScan(self)
        self._burrow_kindle_wifi_recovery_polling = false
        self._burrow_kindle_wifi_recovery_pending = false

        if not self._burrow_kindle_auto_restore_active then return end

        self:queryNetworkState()
        if self.is_wifi_on and self.is_connected then
            logger.dbg(
                "Burrow Kindle Wi-Fi recovery: scan completed and backend associated"
            )
            clearAutomaticRestore(self)
            return
        end

        local scan_list, scan_error = readScanList()
        if type(scan_list) ~= "table" then
            logger.dbg(
                "Burrow Kindle Wi-Fi recovery: could not read completed scan",
                tostring(scan_error)
            )
            return
        end

        local network = strongestKnownNetwork(scan_list)
        if not network then
            logger.dbg(
                "Burrow Kindle Wi-Fi recovery: no saved network is currently available"
            )
            return
        end

        logger.dbg(
            "Burrow Kindle Wi-Fi recovery: silently reconnecting to saved network",
            tostring(network.ssid)
        )
        local auth_ok, success, auth_error = pcall(
            self.authenticateNetwork,
            self,
            network
        )
        if not auth_ok then
            logger.warn(
                "Burrow Kindle Wi-Fi recovery: authentication request failed",
                success
            )
            return
        end
        if success == false then
            logger.dbg(
                "Burrow Kindle Wi-Fi recovery: saved-network authentication declined",
                tostring(auth_error)
            )
        end
    end

    pollSilentRecovery = function(self)
        if not self._burrow_kindle_wifi_recovery_polling then return end
        if not self._burrow_kindle_auto_restore_active then
            cancelScheduledRecovery(self)
            return
        end

        self:queryNetworkState()
        if self.is_wifi_on and self.is_connected then
            logger.dbg(
                "Burrow Kindle Wi-Fi recovery: connected while async scan was running"
            )
            clearAutomaticRestore(self)
            return
        end

        self._burrow_kindle_wifi_recovery_poll_count =
            (tonumber(self._burrow_kindle_wifi_recovery_poll_count) or 0) + 1

        local state, state_error = readScanState()
        if not state then
            logger.dbg(
                "Burrow Kindle Wi-Fi recovery: scan-state poll failed",
                tostring(state_error)
            )
            cancelScheduledRecovery(self)
            return
        end

        if state ~= "idle" then
            self._burrow_kindle_wifi_recovery_saw_scan = true
        elseif self._burrow_kindle_wifi_recovery_saw_scan
            or self._burrow_kindle_wifi_recovery_poll_count >= 2
        then
            finishSilentScan(self)
            return
        end

        if self._burrow_kindle_wifi_recovery_poll_count >= RECOVERY_MAX_POLLS then
            logger.dbg(
                "Burrow Kindle Wi-Fi recovery: asynchronous scan timed out without blocking input"
            )
            cancelScheduledRecovery(self)
            return
        end

        UIManager:scheduleIn(
            RECOVERY_POLL_SECONDS,
            self._burrow_kindle_wifi_recovery_poll_callback
        )
    end

    local function silentRecover(self)
        self._burrow_kindle_wifi_recovery_pending = false

        if not self._burrow_kindle_auto_restore_active then return end
        if not G_reader_settings:isTrue("auto_restore_wifi") or not self.wifi_was_on then
            clearAutomaticRestore(self)
            return
        end

        self:queryNetworkState()
        if self.is_wifi_on and self.is_connected then
            logger.dbg(
                "Burrow Kindle Wi-Fi recovery: normal background restore already connected"
            )
            clearAutomaticRestore(self)
            return
        end

        local now = os.time()
        local last_attempt = tonumber(
            self._burrow_kindle_wifi_recovery_last_attempt
        ) or 0
        if now - last_attempt < RECOVERY_COOLDOWN_SECONDS then
            logger.dbg(
                "Burrow Kindle Wi-Fi recovery: skipping duplicate recovery scan"
            )
            return
        end
        self._burrow_kindle_wifi_recovery_last_attempt = now

        local ok, scan_error = triggerNonBlockingScan()
        if not ok then
            logger.dbg(
                "Burrow Kindle Wi-Fi recovery: could not start asynchronous scan",
                tostring(scan_error)
            )
            return
        end

        self._burrow_kindle_wifi_recovery_polling = true
        self._burrow_kindle_wifi_recovery_poll_count = 0
        self._burrow_kindle_wifi_recovery_saw_scan = false
        UIManager:scheduleIn(
            RECOVERY_POLL_SECONDS,
            self._burrow_kindle_wifi_recovery_poll_callback
        )
    end

    local recovery_callback = function()
        silentRecover(NetworkMgr)
    end
    local recovery_poll_callback = function()
        pollSilentRecovery(NetworkMgr)
    end
    NetworkMgr._burrow_kindle_wifi_recovery_callback = recovery_callback
    NetworkMgr._burrow_kindle_wifi_recovery_poll_callback =
        recovery_poll_callback

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
        local preserve_user_on_intent = self._burrow_kindle_user_wifi_on_intent == true

        cancelScheduledRecovery(self)
        local result = original_abort(self, ...)

        if preserve_auto_restore_intent or preserve_user_on_intent then
            -- KOReader normally clears wifi_was_on after a failed connection.
            -- That is correct for an abandoned background attempt, but it should
            -- not turn a temporary out-of-range condition into a permanent Wi-Fi
            -- OFF preference after either automatic restore or an explicit user
            -- Wi-Fi ON action.
            self.wifi_was_on = true
            G_reader_settings:makeTrue("wifi_was_on")
            if preserve_user_on_intent then
                logger.dbg("Burrow Kindle Wi-Fi recovery: failed user Wi-Fi ON preserved reconnect intent")
            else
                logger.dbg("Burrow Kindle Wi-Fi recovery: automatic failure preserved Wi-Fi restore intent")
            end
        end

        self._burrow_kindle_user_wifi_on_intent = false
        self._burrow_kindle_auto_restore_active = false
        return result
    end

    function NetworkMgr:connectivityCheck(iter, callback, widget)
        local result = original_connectivity_check(self, iter, callback, widget)

        if self.is_wifi_on and self.is_connected then
            self._burrow_kindle_user_wifi_on_intent = false
            if self._burrow_kindle_auto_restore_active then
                clearAutomaticRestore(self)
            end
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
            self._burrow_kindle_user_wifi_on_intent = false
        end
        return original_disable(self, cb, interactive)
    end

    -- Burrow's Quick Settings button historically called toggleWifiOn/Off
    -- without KOReader's interactive flag. Those functions are user-facing
    -- toggles, and KOReader's own callers are also explicit user actions, so on
    -- Kindle treat an omitted flag as interactive while preserving any caller
    -- that deliberately passes false. A direct Wi-Fi ON also records the user's
    -- intent before the scan begins so an out-of-range failure cannot erase it.
    function NetworkMgr:toggleWifiOn(complete_callback, long_press, interactive)
        if interactive == nil then
            self._burrow_kindle_user_wifi_on_intent = true
            self.wifi_was_on = true
            G_reader_settings:makeTrue("wifi_was_on")
            interactive = true
        end
        return original_toggle_on(self, complete_callback, long_press, interactive)
    end

    function NetworkMgr:toggleWifiOff(complete_callback, interactive)
        if interactive == nil then interactive = true end
        return original_toggle_off(self, complete_callback, interactive)
    end

    function NetworkMgr:willRerunWhenOnline(callback)
        if isKOSyncSuspendNetworkingCall() and not self:isOnline() then
            -- Returning false tells KOSync to continue its non-interactive
            -- updateProgress call without bringing Wi-Fi up. The network request
            -- will naturally fail as unreachable and KOSync will queue that
            -- progress update for its existing NetworkConnected drain path.
            logger.dbg("Burrow Kindle Wi-Fi recovery: KOSync suspend is offline; queueing progress without Wi-Fi scan")
            return false
        end
        return original_will_rerun_when_online(self, callback)
    end

    -- NetworkMgr is initialized before Burrow's early modules are applied. If
    -- KOReader already began an automatic startup restore, join that in-flight
    -- attempt so the first launch after updating receives the same silent scan
    -- and intent-preservation behavior as later resume events.
    local manager = NetworkMgr
    manager:queryNetworkState()
    if G_reader_settings:isTrue("auto_restore_wifi")
        and manager.wifi_was_on == true
        and not (manager.is_wifi_on and manager.is_connected)
    then
        manager._burrow_kindle_auto_restore_active = true
        scheduleSilentRecovery(manager)
        logger.dbg("Burrow Kindle Wi-Fi recovery: joined startup background restore")
    end

    NetworkMgr._burrow_kindle_wifi_recovery_v1 = true
    NetworkMgr._burrow_kindle_wifi_recovery_v2 = true
    NetworkMgr._burrow_kindle_wifi_recovery_v3 = true
    NetworkMgr._burrow_kindle_wifi_recovery_v4 = true
    Module.applied = true
    logger.info("Burrow Kindle nonblocking Wi-Fi recovery loaded")
    return true
end

return Module

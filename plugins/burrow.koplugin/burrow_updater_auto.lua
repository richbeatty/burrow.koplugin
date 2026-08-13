local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local _ = require("l10n.gettext")

local AutoUpdater = {}

local AUTO_SETTING = "burrow_auto_update_check"
local LAST_CHECK_SETTING = "burrow_update_last_check"
local RETRY_INTERVAL = 60 * 60

function AutoUpdater.apply(Updater)
    if not Updater or Updater._burrow_auto_scheduler_v2 then
        return Updater
    end
    Updater._burrow_auto_scheduler_v2 = true

    local original_about_menu_item = Updater.aboutMenuItem
    local original_check = Updater._checkForUpdates
    local original_startup = Updater.startup

    local function autoEnabled()
        return G_reader_settings:isTrue(AUTO_SETTING)
    end

    local function cancelTimer(self)
        if self._auto_timer_callback and type(UIManager.unschedule) == "function" then
            UIManager:unschedule(self._auto_timer_callback)
        end
        self._auto_timer_scheduled = false
    end

    local function dueDelay(self, force)
        if force or self._auto_force_when_online then
            return 3
        end

        local now = os.time()
        local last_check = tonumber(G_reader_settings:readSetting(LAST_CHECK_SETTING)) or 0
        local due_at = last_check + (self.AUTO_CHECK_INTERVAL or (24 * 60 * 60))
        if self._auto_retry_not_before and self._auto_retry_not_before > due_at then
            due_at = self._auto_retry_not_before
        end
        return math.max(3, due_at - now)
    end

    local function timerCallback()
        local self = Updater
        self._auto_timer_scheduled = false
        if not autoEnabled() then
            self._auto_force_when_online = false
            return
        end
        if not NetworkMgr:isOnline() then
            self._auto_waiting_for_network = true
            return
        end

        self._auto_waiting_for_network = false
        self._auto_force_when_online = false
        self:checkForUpdates(false)
    end

    Updater._auto_timer_callback = timerCallback

    function Updater:_scheduleAutomaticCheck(force)
        cancelTimer(self)

        if not autoEnabled() then
            self._auto_waiting_for_network = false
            self._auto_force_when_online = false
            return
        end

        if force then
            self._auto_force_when_online = true
        end

        if not NetworkMgr:isOnline() then
            self._auto_waiting_for_network = true
            return
        end

        self._auto_waiting_for_network = false
        local delay = dueDelay(self, force)
        self._auto_timer_scheduled = true
        UIManager:scheduleIn(delay, self._auto_timer_callback)
        logger.dbg("[Burrow updater] Automatic check scheduled in", delay, "seconds")
    end

    function Updater:_checkForUpdates(interactive)
        local result = original_check(self, interactive)

        if autoEnabled() then
            -- Always enforce a one-hour floor after an attempted automatic check.
            -- On success, burrow_update_last_check moves the normal due time out
            -- by 24 hours, so that later deadline wins. On failure, this prevents
            -- an overdue check from immediately rescheduling itself every few
            -- seconds while still allowing a reasonable retry.
            self._auto_retry_not_before = os.time() + RETRY_INTERVAL
            self:_scheduleAutomaticCheck(false)
        end

        return result
    end

    function Updater:aboutMenuItem()
        local root = original_about_menu_item(self)
        for index, item in ipairs((root and root.sub_item_table) or {}) do
            if item.text == _("Automatic update checks") and type(item.callback) == "function" then
                local original_callback = item.callback
                item.callback = function()
                    local was_enabled = autoEnabled()
                    original_callback()
                    local is_enabled = autoEnabled()

                    if is_enabled and not was_enabled then
                        -- Turning the feature on is an explicit request to begin
                        -- automatic checking, so do one check right away instead
                        -- of making the user wait up to 24 hours.
                        self._auto_retry_not_before = nil
                        self:_scheduleAutomaticCheck(true)
                    elseif not is_enabled then
                        self:_scheduleAutomaticCheck(false)
                    else
                        self:_scheduleAutomaticCheck(false)
                    end
                end
                break
            end
        end
        return root
    end

    function Updater:startup(plugin)
        local result = original_startup(self, plugin)

        if plugin and not plugin._burrow_updater_network_connected_hook then
            plugin._burrow_updater_network_connected_hook = true
            local original_network_connected = plugin.onNetworkConnected

            function plugin:onNetworkConnected(...)
                local original_result
                if type(original_network_connected) == "function" then
                    original_result = original_network_connected(self, ...)
                end

                -- If startup happened before Wi-Fi was ready, this event is the
                -- missing trigger that lets an overdue automatic check actually run.
                Updater:_scheduleAutomaticCheck(Updater._auto_force_when_online == true)
                return original_result
            end
        end

        -- original_startup calls _scheduleAutomaticCheck dynamically, so the
        -- scheduler above already handles normal startup. Calling it once more is
        -- harmless and also covers plugin reloads where the network hook changed.
        self:_scheduleAutomaticCheck(false)
        return result
    end

    return Updater
end

return AutoUpdater

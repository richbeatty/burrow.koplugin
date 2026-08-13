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

    return Updater
end

return AutoUpdater

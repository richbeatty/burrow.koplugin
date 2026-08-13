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
    return Updater
end

return AutoUpdater

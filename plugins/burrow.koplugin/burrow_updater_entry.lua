local Updater = require("burrow_updater_prepare_fix")
Updater = require("burrow_updater_auto").apply(Updater)

-- Restore Burrow's original four-way, persistent Quick Settings rotation
-- behavior without changing KOReader's native SwapRotation action globally.
local rotation_ok, RotationFix = pcall(require, "burrow_quick_settings_rotation")
if rotation_ok and RotationFix and type(RotationFix.apply) == "function" then
    pcall(RotationFix.apply)
end

-- Apply Burrow's Home-style page dots to KOReader's paginated Menu and
-- KeyValuePage widgets. This remains a separate guarded module so the tested
-- pager implementation can be updated without replacing KOReader's widgets.
local source = debug.getinfo(1, "S").source
local plugin_root = source:match("^@(.+)/[^/]+$") or "."
local pager_ok, Pager = pcall(dofile, plugin_root .. "/internal_patches/2-dialog-pager-icons.lua")
if pager_ok and Pager and type(Pager.apply) == "function" then
    pcall(Pager.apply)
end

-- Quick Settings is attached later by Burrow's loader. Once startup finishes,
-- layer the swipe guard over that finished TouchMenu wrapper. This preserves
-- slider dragging but prevents a swipe from being interpreted as a button tap.
local UIManager = require("ui/uimanager")
UIManager:nextTick(function()
    local QuickSettings = package.loaded["burrow.internal.2_quick_settings"]
    if not (QuickSettings and QuickSettings.applied) then return end

    local guard_ok, Guard = pcall(
        dofile,
        plugin_root .. "/internal_patches/2-quick-settings-swipe-guard.lua"
    )
    if guard_ok and Guard and type(Guard.apply) == "function" then
        pcall(Guard.apply)
    end
end)

local function cleanError(err)
    return tostring(err or "unknown error"):gsub("^.-:%d+:%s*", "")
end

-- This is the final updater entrypoint. Resolve _prepareRelease at call time so
-- later preparation implementations cannot be bypassed by a cached function
-- reference from an earlier compatibility layer.
function Updater:_performUpdate(release)
    local prepared, prepare_err = pcall(self._prepareRelease, self, release)
    if not prepared then
        error("Preparation failed: " .. cleanError(prepare_err), 0)
    end

    local installed, install_err = pcall(self._swapInPreparedRelease, self, release)
    if not installed then
        error("Installation failed: " .. cleanError(install_err), 0)
    end
end

Updater._burrow_dynamic_prepare_dispatch = true

return Updater

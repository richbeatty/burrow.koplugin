local Updater = require("burrow_updater_prepare_fix")
Updater = require("burrow_updater_auto").apply(Updater)

local rotation_ok, RotationFix = pcall(require, "burrow_quick_settings_rotation")
if rotation_ok and RotationFix and type(RotationFix.apply) == "function" then
    pcall(RotationFix.apply)
end

local source = debug.getinfo(1, "S").source
local plugin_root = source:match("^@(.+)/[^/]+$") or "."
local pager_ok, Pager = pcall(dofile, plugin_root .. "/internal_patches/2-dialog-pager-icons.lua")
if pager_ok and Pager and type(Pager.apply) == "function" then
    pcall(Pager.apply)

    -- beta.10 reached Table of Contents by wrapping every Menu. Recover the
    -- stock Menu functions and the tested pager helpers from that wrapper, then
    -- keep the Menu dots only on Table of Contents. KeyValuePage remains as-is.
    local Menu = require("ui/widget/menu")
    local _ = require("gettext")
    local function upvalue(fn, wanted)
        if type(fn) ~= "function" then return nil end
        for index = 1, 64 do
            local name, value = debug.getupvalue(fn, index)
            if not name then break end
            if name == wanted then return value end
        end
    end

    local wrapped_init = Menu.init
    local wrapped_update = Menu.updateItems
    local original_init = upvalue(wrapped_init, "original_init")
    local original_update = upvalue(wrapped_update, "original_update_items")
    local primePager = upvalue(wrapped_init, "primePager")
    local refreshMenuDots = upvalue(wrapped_init, "refreshMenuDots")
        or upvalue(wrapped_update, "refreshMenuDots")
    local toc_title = _("Table of contents")

    if original_init and original_update and primePager and refreshMenuDots then
        function Menu:init(...)
            local title = type(self.title) == "string" and self.title or ""
            local use_dots = title:sub(1, #toc_title) == toc_title
            if use_dots then primePager(self) end
            local result = original_init(self, ...)
            if use_dots then refreshMenuDots(self) end
            return result
        end

        function Menu:updateItems(...)
            local result = original_update(self, ...)
            if self._burrow_page_dots then refreshMenuDots(self) end
            return result
        end
    end
end

-- Quick Settings is attached later by Burrow's loader. Once startup finishes,
-- layer the swipe guard over that finished TouchMenu wrapper. Slider dragging
-- remains available; other Quick Settings swipes are consumed safely.
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

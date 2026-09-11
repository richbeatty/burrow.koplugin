local MODULE_KEY = "burrow.internal.2_fast_dark_page_turns"
local existing_module = package.loaded[MODULE_KEY]
if existing_module then return existing_module end

local Module = {
    key = MODULE_KEY,
    phase = "early",
    filename = "2-fast-dark-page-turns.lua",
}
package.loaded[MODULE_KEY] = Module

local SETTING = "burrow_fast_dark_page_turns"
local CLEANUP_INTERVAL = 6

local function settingEnabled()
    local value = G_reader_settings:readSetting(SETTING)
    if value == nil then return true end
    return value == true
end

local function applyFastEinkPageTurns()
    local Device = require("device")
    local Screen = Device.screen

    local eink_ok, is_eink = pcall(Device.hasEinkScreen, Device)
    if not eink_ok or not is_eink then
        return true
    end

    if not Screen or type(Screen.refreshFast) ~= "function" then
        return true
    end

    local ReaderView = require("apps/reader/modules/readerview")
    if ReaderView._burrow_fast_dark_page_turns_v1 then
        return true
    end

    local original_on_page_update = ReaderView.onPageUpdate
    if type(original_on_page_update) ~= "function" then
        return false, "ReaderView.onPageUpdate is unavailable"
    end

    ReaderView._burrow_fast_dark_page_turns_v1 = true

    ReaderView.onPageUpdate = function(self, ...)
        local use_fast = settingEnabled()
            and self.ui ~= nil
            and self.ui.rolling ~= nil
            and self.view_mode == "page"
            and self.currently_scrolling ~= true

        if not use_fast then
            self._burrow_fast_eink_turn_count = 0
            return original_on_page_update(self, ...)
        end

        local turn_count = (self._burrow_fast_eink_turn_count or 0) + 1
        self._burrow_fast_eink_turn_count = turn_count

        -- Fast refreshes do not advance KOReader's normal partial-refresh
        -- promotion counter. Keep a regular higher-fidelity refresh periodically
        -- so low-fidelity page turns cannot accumulate residue indefinitely.
        if turn_count % CLEANUP_INTERVAL == 0 then
            return original_on_page_update(self, ...)
        end

        -- ReaderView:recalculate() already requests "fast" whenever its
        -- currently_scrolling flag is true. Borrow that native path only for
        -- this PageUpdate call instead of patching UIManager or any framebuffer
        -- backend. Each e-ink device therefore keeps its own fast waveform.
        local previous_scrolling = self.currently_scrolling
        self.currently_scrolling = true
        local results = { pcall(original_on_page_update, self, ...) }
        self.currently_scrolling = previous_scrolling

        if not results[1] then
            error(results[2], 0)
        end
        return unpack(results, 2)
    end

    return true
end

Module.apply = applyFastEinkPageTurns
return Module

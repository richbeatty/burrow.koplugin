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
local MENU_KEY = "burrow_fast_dark_page_turns"

local function settingEnabled()
    return G_reader_settings:isTrue(SETTING)
end

local function addReaderMenuEntry(Screen)
    local _ = require("gettext")
    local ReaderRolling = require("apps/reader/modules/readerrolling")
    local menu_order = require("ui/elements/reader_menu_order")

    if not ReaderRolling._burrow_fast_dark_page_turns_menu_v1 then
        ReaderRolling._burrow_fast_dark_page_turns_menu_v1 = true
        local original_add_to_main_menu = ReaderRolling.addToMainMenu

        ReaderRolling.addToMainMenu = function(self, menu_items)
            original_add_to_main_menu(self, menu_items)
            menu_items[MENU_KEY] = {
                text = _("Fast dark-mode page turns"),
                help_text = _("On e-ink screens, use KOReader's native fast refresh for most reflowable page turns in Night Mode. Every sixth turn keeps the normal Night Mode refresh to limit residue. Light mode, scrolling, PDFs, comics, and menus are unchanged."),
                checked_func = settingEnabled,
                callback = function()
                    G_reader_settings:saveSetting(SETTING, not settingEnabled())
                end,
            }
        end
    end

    local document_order = type(menu_order) == "table" and menu_order.document or nil
    if type(document_order) == "table" then
        local found = false
        for _, key in ipairs(document_order) do
            if key == MENU_KEY then
                found = true
                break
            end
        end
        if not found then
            local insert_at = #document_order + 1
            for index, key in ipairs(document_order) do
                if key == "partial_rerendering" then
                    insert_at = index + 1
                    break
                end
            end
            table.insert(document_order, insert_at, MENU_KEY)
        end
    end
end

local function applyFastDarkPageTurns()
    local Device = require("device")
    local Screen = Device.screen

    local eink_ok, is_eink = pcall(Device.hasEinkScreen, Device)
    if not eink_ok or not is_eink then
        return true
    end

    if not Screen or type(Screen.refreshFast) ~= "function" then
        return true
    end

    addReaderMenuEntry(Screen)

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
            and Screen.night_mode == true
            and self.ui ~= nil
            and self.ui.rolling ~= nil
            and self.view_mode == "page"
            and self.currently_scrolling ~= true

        if not use_fast then
            self._burrow_fast_dark_turn_count = 0
            return original_on_page_update(self, ...)
        end

        local turn_count = (self._burrow_fast_dark_turn_count or 0) + 1
        self._burrow_fast_dark_turn_count = turn_count

        -- Fast refreshes do not advance KOReader's normal partial-refresh
        -- promotion counter. Keep a regular Night Mode refresh periodically so
        -- the experiment cannot run indefinitely on low-fidelity updates.
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

Module.apply = applyFastDarkPageTurns
return Module

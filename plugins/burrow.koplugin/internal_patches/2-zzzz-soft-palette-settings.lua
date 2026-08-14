local MODULE_KEY = "burrow.internal.2_zzzz_soft_palette_settings"
local existing_module = package.loaded[MODULE_KEY]
if existing_module then return existing_module end

local Module = {
    key = MODULE_KEY,
    phase = "instance",
    filename = "2-zzzz-soft-palette-settings.lua",
}
package.loaded[MODULE_KEY] = Module

function Module.apply(plugin)
    if Module.applied then return true end
    if not plugin or plugin._burrow_soft_palette_settings_patched then
        Module.applied = true
        return true
    end
    plugin._burrow_soft_palette_settings_patched = true

    local BurrowLoader = require("burrow_loader")
    local BurrowSettings = require("burrow_settings")
    local Device = require("device")
    local SpinWidget = require("ui/widget/spinwidget")
    local UIManager = require("ui/uimanager")
    local _ = require("l10n.gettext")
    local T = require("ffi/util").template

    local ORNAMENT_SETTING = "burrow_soft_palette_recolor_ornaments"
    local SLEEP_COVER_CROP_SETTING = "burrow_screensaver_crop_cover_to_fill"

    -- Mark the real reader CreDocument before CRengine loads it. The soft
    -- palette EPUB shadow loader checks this marker so file-browser cover and
    -- metadata probes are never redirected through a transformed copy. Keep
    -- this wrapper composable with Bionic Reading and the other Burrow hooks.
    if not plugin._burrow_soft_palette_reader_context_hook then
        plugin._burrow_soft_palette_reader_context_hook = true
        local originalDocSettingsLoad = plugin.onDocSettingsLoad
        function plugin:onDocSettingsLoad(docSettings, document)
            local result
            if originalDocSettingsLoad then
                result = originalDocSettingsLoad(self, docSettings, document)
            end
            local doc = document or self.document or (self.ui and self.ui.document)
            if doc and doc.provider == "crengine" then
                doc._burrow_soft_palette_reader_context = true
            end
            return result
        end
    end

    -- This is an experimental test overlay. Turn the new ornament treatment on
    -- for first-time testers so reopening an EPUB immediately exercises it.
    -- The setting remains independently switchable in Burrow Settings.
    if G_reader_settings:readSetting(ORNAMENT_SETTING) == nil then
        G_reader_settings:saveSetting(ORNAMENT_SETTING, true)
    end

    -- Clean duplicate Quick Settings button IDs left behind by older test
    -- overlays. LuaSettings returns tables by reference, so mutating these
    -- arrays in place also updates the already-loaded Quick Settings module.
    local function dedupeOrderInPlace(order)
        if type(order) ~= "table" then return false end
        local seen = {}
        local write_index = 1
        local changed = false
        for read_index = 1, #order do
            local id = order[read_index]
            if not seen[id] then
                seen[id] = true
                order[write_index] = id
                write_index = write_index + 1
            else
                changed = true
            end
        end
        for index = #order, write_index, -1 do
            order[index] = nil
        end
        return changed
    end

    local function cleanQuickSettingsDuplicates()
        local config = G_reader_settings:readSetting("rounded_quick_settings_panel")
        if type(config) ~= "table" then return end
        local changed = dedupeOrderInPlace(config.reader_order)
        changed = dedupeOrderInPlace(config.filemanager_order) or changed
        if changed then
            G_reader_settings:saveSetting("rounded_quick_settings_panel", config)
        end
    end
    cleanQuickSettingsDuplicates()

    -- KOReader dims disabled icon buttons by lightening the entire icon
    -- rectangle. That is invisible on pure white, but Burrow's softer white
    -- makes the first/last-page chevron appear inside a pale square. Hide only
    -- the inactive boundary chevron instead, preserving the enabled chevron and
    -- every other TouchMenu button exactly as KOReader draws them.
    if BurrowSettings:isFeatureEnabled("soft_palette") then
        local TouchMenu = require("ui/widget/touchmenu")
        if not TouchMenu._burrow_soft_palette_pager_boundary_fix then
            TouchMenu._burrow_soft_palette_pager_boundary_fix = true
            local original_touchmenu_update_items = TouchMenu.updateItems
            function TouchMenu:updateItems(...)
                local result = original_touchmenu_update_items(self, ...)
                if self.item_table and self.item_table.panel then
                    return result
                end
                if self.page_num and self.page_num > 1 and self.page then
                    if self.page_info_left_chev then
                        if self.page <= 1 then
                            self.page_info_left_chev:hide()
                        else
                            self.page_info_left_chev:show()
                        end
                    end
                    if self.page_info_right_chev then
                        if self.page >= self.page_num then
                            self.page_info_right_chev:hide()
                        else
                            self.page_info_right_chev:show()
                        end
                    end
                end
                return result
            end
        end
    end

    local SPLIT_FOOTER_ENABLED = "burrow_reading_progress_footer_enabled"
    local SPLIT_FOOTER_LEFT = "burrow_reading_progress_footer_left"
    local SPLIT_FOOTER_RIGHT = "burrow_reading_progress_footer_right"
    local SPLIT_FOOTER_BOTTOM_INSET = "burrow_reading_progress_footer_bottom_inset"
    local SPLIT_FOOTER_HORIZONTAL_INSET = "burrow_reading_progress_footer_horizontal_inset"

    local DEFAULT_SPLIT_LEFT = "book_time"
    local DEFAULT_SPLIT_RIGHT = "percentage"
    local DEFAULT_BOTTOM_INSET = 6
    local DEFAULT_HORIZONTAL_INSET = 8

    local LEFT_CHOICES = { "book_time", "chapter_time", "page", "hidden" }
    local RIGHT_CHOICES = { "percentage", "page", "clock", "battery", "hidden" }
    local CHOICE_LABELS = {
        book_time = _("Time left in book"),
        chapter_time = _("Time left in chapter"),
        page = _("Page in book"),
        percentage = _("Percentage"),
        clock = _("Clock"),
        battery = _("Battery"),
        hidden = _("Hidden"),
    }

    local function splitEnabled()
        local value = G_reader_settings:readSetting(SPLIT_FOOTER_ENABLED)
        if value == nil then return true end
        return value == true
    end

    local function readChoice(key, default)
        local value = G_reader_settings:readSetting(key)
        if type(value) ~= "string" or value == "" then return default end
        return value
    end

    local function readInteger(key, default, minimum, maximum)
        local value = tonumber(G_reader_settings:readSetting(key)) or default
        value = math.floor(value + 0.5)
        return math.max(minimum, math.min(maximum, value))
    end

    local function liveFooter()
        local ok, ReaderUI = pcall(require, "apps/reader/readerui")
        local reader = ok and ReaderUI.instance or nil
        return reader and reader.footer or nil
    end

    local function refreshLiveFooter(rebuild)
        local footer = liveFooter()
        if not footer then return end
        if rebuild then
            if type(footer.applyFooterMode) == "function" then footer:applyFooterMode() end
            if type(footer.updateFooterContainer) == "function" then footer:updateFooterContainer() end
            if type(footer.resetLayout) == "function" then footer:resetLayout(true) end
        end
        if type(footer.refreshFooter) == "function" then
            footer:refreshFooter(true, true)
        elseif type(footer.onUpdateFooter) == "function" then
            footer:onUpdateFooter(true, true)
        end
    end

    local function choiceItems(setting_key, choices, default)
        local result = {}
        for _, choice in ipairs(choices) do
            if choice ~= "battery" or Device:hasBattery() then
                local value = choice
                result[#result + 1] = {
                    text = CHOICE_LABELS[value],
                    radio = true,
                    checked_func = function()
                        return readChoice(setting_key, default) == value
                    end,
                    callback = function()
                        G_reader_settings:saveSetting(setting_key, value)
                        refreshLiveFooter(false)
                    end,
                }
            end
        end
        return result
    end

    local function fallbackReadingProgressMenu()
        return {
            text = _("Reading progress footer"),
            sub_item_table = {
                {
                    text = _("Use Reading progress footer"),
                    checked_func = splitEnabled,
                    callback = function()
                        G_reader_settings:saveSetting(
                            SPLIT_FOOTER_ENABLED,
                            not splitEnabled()
                        )
                        refreshLiveFooter(true)
                    end,
                },
                {
                    text_func = function()
                        local value = readChoice(SPLIT_FOOTER_LEFT, DEFAULT_SPLIT_LEFT)
                        return T(_("Left side: %1"), CHOICE_LABELS[value] or value)
                    end,
                    enabled_func = splitEnabled,
                    sub_item_table_func = function()
                        return choiceItems(SPLIT_FOOTER_LEFT, LEFT_CHOICES, DEFAULT_SPLIT_LEFT)
                    end,
                },
                {
                    text_func = function()
                        local value = readChoice(SPLIT_FOOTER_RIGHT, DEFAULT_SPLIT_RIGHT)
                        return T(_("Right side: %1"), CHOICE_LABELS[value] or value)
                    end,
                    enabled_func = splitEnabled,
                    sub_item_table_func = function()
                        return choiceItems(SPLIT_FOOTER_RIGHT, RIGHT_CHOICES, DEFAULT_SPLIT_RIGHT)
                    end,
                },
                {
                    text_func = function()
                        return T(
                            _("Footer position: %1"),
                            readInteger(SPLIT_FOOTER_BOTTOM_INSET, DEFAULT_BOTTOM_INSET, 0, 48)
                        )
                    end,
                    help_text = _("Moves the Reading progress footer upward from the bottom edge."),
                    enabled_func = splitEnabled,
                    keep_menu_open = true,
                    callback = function(touchmenu_instance)
                        UIManager:show(SpinWidget:new{
                            title_text = _("Reading progress footer position"),
                            value = readInteger(SPLIT_FOOTER_BOTTOM_INSET, DEFAULT_BOTTOM_INSET, 0, 48),
                            value_min = 0,
                            value_max = 48,
                            value_step = 1,
                            value_hold_step = 5,
                            default_value = DEFAULT_BOTTOM_INSET,
                            keep_shown_on_apply = true,
                            callback = function(spin)
                                G_reader_settings:saveSetting(SPLIT_FOOTER_BOTTOM_INSET, spin.value)
                                refreshLiveFooter(true)
                                if touchmenu_instance then touchmenu_instance:updateItems() end
                            end,
                        })
                    end,
                },
                {
                    text_func = function()
                        return T(
                            _("Horizontal inset: %1"),
                            readInteger(SPLIT_FOOTER_HORIZONTAL_INSET, DEFAULT_HORIZONTAL_INSET, 0, 80)
                        )
                    end,
                    help_text = _("Moves both footer items inward from the left and right screen edges."),
                    enabled_func = splitEnabled,
                    keep_menu_open = true,
                    callback = function(touchmenu_instance)
                        UIManager:show(SpinWidget:new{
                            title_text = _("Reading progress footer horizontal inset"),
                            value = readInteger(SPLIT_FOOTER_HORIZONTAL_INSET, DEFAULT_HORIZONTAL_INSET, 0, 80),
                            value_min = 0,
                            value_max = 80,
                            value_step = 1,
                            value_hold_step = 5,
                            default_value = DEFAULT_HORIZONTAL_INSET,
                            keep_shown_on_apply = true,
                            callback = function(spin)
                                G_reader_settings:saveSetting(SPLIT_FOOTER_HORIZONTAL_INSET, spin.value)
                                refreshLiveFooter(true)
                                if touchmenu_instance then touchmenu_instance:updateItems() end
                            end,
                        })
                    end,
                },
            },
        }
    end

    local original_add_to_main_menu = plugin.addToMainMenu
    function plugin:addToMainMenu(menu_items)
        original_add_to_main_menu(self, menu_items)

        local root = menu_items and menu_items.filemanager_display_mode
        local items = root and root.sub_item_table
        if type(items) ~= "table" then return end

        local appearance
        local has_reading = false
        for _, item in ipairs(items) do
            if type(item) == "table"
                and (item._burrow_soft_palette_appearance or item.text == _("Appearance"))
            then
                appearance = item
            end
            if item._burrow_reading_settings then
                has_reading = true
            end
        end

        local function enabled()
            return BurrowSettings:isFeatureEnabled("soft_palette")
        end

        if not appearance then
            appearance = {
                text = _("Appearance"),
                _burrow_soft_palette_appearance = true,
                sub_item_table = {
                    {
                        text = _("Use softer black and white"),
                        help_text = _("Use Burrow's softer neutral white and black instead of KOReader's pure white and black. Night mode uses KOReader's native inversion. Restart required."),
                        checked_func = enabled,
                        callback = function()
                            local new_enabled = not enabled()
                            BurrowSettings:setFeatureEnabled("soft_palette", new_enabled)
                            if new_enabled then
                                BurrowLoader:clearQuarantine("soft_palette")
                            end
                            UIManager:askForRestart()
                        end,
                    },
                    {
                        text = _("Recolor decorative book elements"),
                        help_text = _("For EPUB books, recolor only small monochrome images and simple SVG ornaments to match Burrow's soft page colors. Covers, large images, and colored artwork are left unchanged. Reopen the book after changing this setting."),
                        checked_func = function()
                            return G_reader_settings:isTrue(ORNAMENT_SETTING)
                        end,
                        enabled_func = enabled,
                        callback = function()
                            G_reader_settings:saveSetting(
                                ORNAMENT_SETTING,
                                not G_reader_settings:isTrue(ORNAMENT_SETTING)
                            )
                            if type(G_reader_settings.flush) == "function" then
                                G_reader_settings:flush()
                            end
                        end,
                    },
                },
            }
            table.insert(items, math.min(2, #items + 1), appearance)
        end

        -- The crop setting is deliberately ensured after Appearance exists,
        -- rather than only when Appearance is created. This makes it resilient
        -- to other Burrow wrappers reusing or pre-creating the Appearance menu.
        local appearance_items = appearance.sub_item_table
        if type(appearance_items) ~= "table" then
            appearance_items = {}
            appearance.sub_item_table = appearance_items
        end

        local has_crop = false
        for _, item in ipairs(appearance_items) do
            if type(item) == "table" and item._burrow_sleep_cover_crop_setting then
                has_crop = true
                break
            end
        end

        if not has_crop then
            table.insert(appearance_items, {
                text = _("Crop sleep-screen book cover to fill"),
                help_text = _("Scale the current book cover proportionally until the sleep screen is completely filled, then crop the excess from the edges. This avoids stretching or distorting the cover."),
                _burrow_sleep_cover_crop_setting = true,
                checked_func = function()
                    return G_reader_settings:isTrue(SLEEP_COVER_CROP_SETTING)
                end,
                callback = function()
                    G_reader_settings:saveSetting(
                        SLEEP_COVER_CROP_SETTING,
                        not G_reader_settings:isTrue(SLEEP_COVER_CROP_SETTING)
                    )
                    if type(G_reader_settings.flush) == "function" then
                        G_reader_settings:flush()
                    end
                end,
            })
        end

        if not has_reading then
            local reading_progress
            local status_module = package.loaded[
                "burrow.internal.2_statusbar_margins_presets"
            ]
            if status_module
                and type(status_module.getReadingProgressSettingsMenu) == "function"
            then
                reading_progress = status_module.getReadingProgressSettingsMenu()
            end
            -- The Reading section should never silently disappear just because
            -- another module was not discoverable at menu-build time.
            reading_progress = reading_progress or fallbackReadingProgressMenu()

            local reading = {
                text = _("Reading"),
                _burrow_reading_settings = true,
                sub_item_table = { reading_progress },
            }

            local insert_at = #items + 1
            for index, item in ipairs(items) do
                if item.text == _("Quick settings") then
                    insert_at = index + 1
                    break
                elseif item.text == _("Store")
                    or item.text == _("Store unavailable")
                    or item.text == _("Advanced")
                then
                    insert_at = index
                    break
                end
            end
            table.insert(items, insert_at, reading)
        end
    end

    Module.applied = true
    return true
end

return Module

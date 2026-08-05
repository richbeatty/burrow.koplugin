local MODULE_KEY = "burrow.internal.2_statusbar_margins_presets"
local existing_module = package.loaded[MODULE_KEY]
if existing_module then return existing_module end
local Module = { key = MODULE_KEY, phase = "early", filename = "2-statusbar-margins-presets.lua" }
package.loaded[MODULE_KEY] = Module

function Module.apply()
    if Module.applied then return true end


-- Adjustable status-bar side margins and tap-to-cycle footer presets.
-- Keeps KOReader's native ReaderFooter content, presets, gestures and settings.

local ReaderFooter = require("apps/reader/modules/readerfooter")
local HorizontalSpan = require("ui/widget/horizontalspan")
local Screen = require("device").screen
local SpinWidget = require("ui/widget/spinwidget")
local UIManager = require("ui/uimanager")
local util = require("util")
local _ = require("gettext")
local T = require("ffi/util").template

local DEFAULT_SIDE_MARGIN = 10
local CURRENT_PRESET_SETTING = "footer_current_preset"

-- These are stored with the rest of the native footer settings, so they are
-- automatically included when a KOReader status-bar preset is saved.
ReaderFooter.default_settings.statusbar_left_margin =
    ReaderFooter.default_settings.statusbar_left_margin or DEFAULT_SIDE_MARGIN
ReaderFooter.default_settings.statusbar_right_margin =
    ReaderFooter.default_settings.statusbar_right_margin or DEFAULT_SIDE_MARGIN
if ReaderFooter.default_settings.statusbar_cycle_presets == nil then
    ReaderFooter.default_settings.statusbar_cycle_presets = true
end

local function getMarginValue(footer, key)
    local value = footer.settings and tonumber(footer.settings[key])
    if value == nil then
        value = ReaderFooter.default_settings[key] or DEFAULT_SIDE_MARGIN
    end
    return math.max(0, math.floor(value + 0.5))
end

local function getScaledMargins(footer)
    local left = Screen:scaleBySize(getMarginValue(footer, "statusbar_left_margin"))
    local right = Screen:scaleBySize(getMarginValue(footer, "statusbar_right_margin"))
    return left, right
end

local function applyMarginRuntimeValues(footer)
    local left, right = getScaledMargins(footer)
    footer._custom_statusbar_left_margin = left
    footer._custom_statusbar_right_margin = right

    -- Native ReaderFooter uses one horizontal_margin value for text fitting,
    -- separators and alongside spacing. Using the larger side keeps all native
    -- fitting calculations conservative while the actual edge spans remain
    -- independently adjustable.
    footer.horizontal_margin = math.max(left, right)
    return left, right
end

-- Let KOReader build its normal footer, then replace only the two edge spans.
-- No footer content, progress calculations or callbacks are replaced.
local original_updateFooterContainer = ReaderFooter.updateFooterContainer
function ReaderFooter:updateFooterContainer()
    local left, right = applyMarginRuntimeValues(self)
    original_updateFooterContainer(self)

    if self.horizontal_group then
        local count = #self.horizontal_group
        if count >= 2 then
            self.horizontal_group[1] = HorizontalSpan:new{ width = left }
            self.horizontal_group[count] = HorizontalSpan:new{ width = right }
            self.horizontal_group:resetLayout()
        end
    end
end

local function getPresetNames()
    return ReaderFooter.getPresets() or {}
end

function ReaderFooter:cycleNamedStatusBarPreset()
    local presets = getPresetNames()
    if #presets < 2 then
        return false
    end

    local current = G_reader_settings:readSetting(CURRENT_PRESET_SETTING)
    local current_index = util.arrayContains(presets, current) or 0
    local next_name = presets[(current_index % #presets) + 1]

    G_reader_settings:saveSetting(CURRENT_PRESET_SETTING, next_name)
    self:onLoadFooterPreset(next_name)
    return true
end

-- Remember presets loaded from KOReader's normal preset menu or Dispatcher.
local original_onLoadFooterPreset = ReaderFooter.onLoadFooterPreset
function ReaderFooter:onLoadFooterPreset(preset_name)
    if preset_name then
        G_reader_settings:saveSetting(CURRENT_PRESET_SETTING, preset_name)
    end
    return original_onLoadFooterPreset(self, preset_name)
end

-- A normal footer tap rotates through named presets when enabled. When fewer
-- than two presets exist, KOReader's original mode-cycling behavior is retained.
local original_onToggleFooterMode = ReaderFooter.onToggleFooterMode
function ReaderFooter:onToggleFooterMode()
    local enabled = not self.settings or self.settings.statusbar_cycle_presets ~= false
    if enabled and self:cycleNamedStatusBarPreset() then
        return true
    end
    return original_onToggleFooterMode(self)
end

local function showMarginSpin(footer, touchmenu_instance, key, title, update_both)
    local spin_widget = SpinWidget:new{
        title_text = title,
        value = getMarginValue(footer, key),
        value_min = 0,
        value_max = 140,
        value_step = 1,
        value_hold_step = 5,
        default_value = ReaderFooter.default_settings[key] or DEFAULT_SIDE_MARGIN,
        keep_shown_on_apply = true,
        callback = function(spin)
            footer.settings[key] = spin.value
            if update_both then
                footer.settings.statusbar_left_margin = spin.value
                footer.settings.statusbar_right_margin = spin.value
            end
            footer:refreshFooter(true, true)
            if touchmenu_instance then
                touchmenu_instance:updateItems()
            end
        end,
    }
    UIManager:show(spin_widget)
end

local function marginsMenuItem(footer)
    return {
        text_func = function()
            local left = getMarginValue(footer, "statusbar_left_margin")
            local right = getMarginValue(footer, "statusbar_right_margin")
            return T(_("Side margins: left %1, right %2"), left, right)
        end,
        sub_item_table = {
            {
                text_func = function()
                    local left = getMarginValue(footer, "statusbar_left_margin")
                    local right = getMarginValue(footer, "statusbar_right_margin")
                    if left == right then
                        return T(_("Both margins: %1"), left)
                    end
                    return _("Both margins: mixed")
                end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    showMarginSpin(
                        footer,
                        touchmenu_instance,
                        "statusbar_left_margin",
                        _("Status bar side margins"),
                        true
                    )
                end,
            },
            {
                text_func = function()
                    return T(_("Left margin: %1"),
                        getMarginValue(footer, "statusbar_left_margin"))
                end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    showMarginSpin(
                        footer,
                        touchmenu_instance,
                        "statusbar_left_margin",
                        _("Status bar left margin"),
                        false
                    )
                end,
            },
            {
                text_func = function()
                    return T(_("Right margin: %1"),
                        getMarginValue(footer, "statusbar_right_margin"))
                end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    showMarginSpin(
                        footer,
                        touchmenu_instance,
                        "statusbar_right_margin",
                        _("Status bar right margin"),
                        false
                    )
                end,
            },
        },
    }
end

local function presetCycleMenuItems(footer)
    return {
        {
            text = _("Tap status bar to cycle presets"),
            help_text = _("A tap loads the next named status-bar preset. With fewer than two presets, the normal KOReader status-bar tap behavior is used."),
            checked_func = function()
                return footer.settings.statusbar_cycle_presets ~= false
            end,
            callback = function()
                footer.settings.statusbar_cycle_presets =
                    footer.settings.statusbar_cycle_presets == false
            end,
        },
        {
            text = _("Next status bar preset"),
            enabled_func = function()
                return #getPresetNames() > 1
            end,
            callback = function()
                footer:cycleNamedStatusBarPreset()
            end,
        },
    }
end

local original_addToMainMenu = ReaderFooter.addToMainMenu
function ReaderFooter:addToMainMenu(menu_items)
    original_addToMainMenu(self, menu_items)

    local status_bar = menu_items.status_bar
    local sub_items = status_bar and status_bar.sub_item_table
    if not sub_items then
        return
    end

    table.insert(sub_items, marginsMenuItem(self))
    for _, item in ipairs(presetCycleMenuItems(self)) do
        table.insert(sub_items, item)
    end
end

    Module.applied = true
    return true
end

return Module

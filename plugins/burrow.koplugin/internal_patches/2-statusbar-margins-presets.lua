local MODULE_KEY = "burrow.internal.2_statusbar_margins_presets"
local existing_module = package.loaded[MODULE_KEY]
if existing_module then return existing_module end
local Module = { key = MODULE_KEY, phase = "early", filename = "2-statusbar-margins-presets.lua" }
package.loaded[MODULE_KEY] = Module

function Module.apply()
    if Module.applied then return true end

-- Adjustable status-bar side margins and tap-to-cycle footer presets.
-- Also provides Burrow's optional two-sided Reading progress footer.
-- Keeps KOReader's native ReaderFooter lifecycle, page/progress calculations,
-- settings, and existing footer touch zone.

local BD = require("ui/bidi")
local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Event = require("ui/event")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local LeftContainer = require("ui/widget/container/leftcontainer")
local ReaderFooter = require("apps/reader/modules/readerfooter")
local RightContainer = require("ui/widget/container/rightcontainer")
local Screen = require("device").screen
local SpinWidget = require("ui/widget/spinwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local Widget = require("ui/widget/widget")
local datetime = require("datetime")
local util = require("util")
local _ = require("gettext")
local T = require("ffi/util").template

local DEFAULT_SIDE_MARGIN = 10
local CURRENT_PRESET_SETTING = "footer_current_preset"

local SPLIT_FOOTER_ENABLED = "burrow_reading_progress_footer_enabled"
local SPLIT_FOOTER_LEFT = "burrow_reading_progress_footer_left"
local SPLIT_FOOTER_RIGHT = "burrow_reading_progress_footer_right"
local SPLIT_FOOTER_BOTTOM_INSET = "burrow_reading_progress_footer_bottom_inset"
local SPLIT_FOOTER_HORIZONTAL_INSET = "burrow_reading_progress_footer_horizontal_inset"
local DEFAULT_SPLIT_LEFT = "book_time"
local DEFAULT_SPLIT_RIGHT = "percentage"
local DEFAULT_BOTTOM_INSET = 6
local MIN_BOTTOM_INSET = 0
local MAX_BOTTOM_INSET = 48
local DEFAULT_HORIZONTAL_INSET = 8
local MIN_HORIZONTAL_INSET = 0
local MAX_HORIZONTAL_INSET = 80

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

local function splitFooterEnabled()
    local value = G_reader_settings:readSetting(SPLIT_FOOTER_ENABLED)
    if value == nil then return true end
    return value == true
end

local function getSplitChoice(key, default)
    local value = G_reader_settings:readSetting(key)
    if type(value) ~= "string" or value == "" then return default end
    return value
end

local function getBottomInset()
    local value = tonumber(G_reader_settings:readSetting(SPLIT_FOOTER_BOTTOM_INSET))
    if value == nil then value = DEFAULT_BOTTOM_INSET end
    return math.max(MIN_BOTTOM_INSET, math.min(MAX_BOTTOM_INSET, math.floor(value + 0.5)))
end

local function getHorizontalInset()
    local value = tonumber(G_reader_settings:readSetting(SPLIT_FOOTER_HORIZONTAL_INSET))
    if value == nil then value = DEFAULT_HORIZONTAL_INSET end
    return math.max(
        MIN_HORIZONTAL_INSET,
        math.min(MAX_HORIZONTAL_INSET, math.floor(value + 0.5))
    )
end

local function saveSplitChoice(key, value)
    G_reader_settings:saveSetting(key, value)
end

local function resolveLiveFooter(footer)
    if footer then return footer end
    local ok, ReaderUI = pcall(require, "apps/reader/readerui")
    local reader = ok and ReaderUI.instance or nil
    return reader and reader.footer or nil
end

local function humanizeTimeLeft(value)
    if type(value) ~= "string" then return value end

    -- KOReader's classic statistics duration is hours:minutes (for example,
    -- "00:01"). Only rewrite that exact shape. If KOReader returns another
    -- duration format now or in the future, keep it untouched.
    local hours_text, minutes_text = value:match("^(%d+):(%d%d)$")
    local hours = tonumber(hours_text)
    local minutes = tonumber(minutes_text)
    if hours == nil or minutes == nil or minutes > 59 then
        return value
    end

    local total_minutes = hours * 60 + minutes
    if total_minutes < 1 then
        return _("<1 min")
    elseif total_minutes < 60 then
        return T(_("%1 min"), total_minutes)
    end

    local whole_hours = math.floor(total_minutes / 60)
    local remaining_minutes = total_minutes % 60
    if remaining_minutes == 0 then
        return T(_("%1 hr"), whole_hours)
    end
    return T(_("%1 hr %2 min"), whole_hours, remaining_minutes)
end

local function timeForPages(footer, pages)
    if not footer.ui or not footer.ui.statistics or type(pages) ~= "number" then
        return nil
    end
    local ok, value = pcall(footer.ui.statistics.getTimeForPages, footer.ui.statistics, pages)
    if not ok or not value or value == "" or value == _("N/A") then return nil end
    return humanizeTimeLeft(value)
end

local function pageText(footer)
    if type(footer.pageno) ~= "number" or not footer.pages then return nil end
    if footer.ui and footer.ui.pagemap and footer.ui.pagemap:wantsPageLabels() then
        local ok1, current = pcall(footer.ui.pagemap.getCurrentPageLabel, footer.ui.pagemap, true)
        local ok2, last = pcall(footer.ui.pagemap.getLastPageLabel, footer.ui.pagemap, true)
        if ok1 and ok2 and current and last then
            return T(_("Page %1 of %2"), current, last)
        end
    end
    return T(_("Page %1 of %2"), footer.pageno, footer.pages)
end

local function splitValue(footer, choice)
    if choice == "hidden" then
        return ""
    elseif choice == "book_time" then
        if not footer.ui or not footer.ui.document or type(footer.pageno) ~= "number" then return nil end
        local ok, pages = pcall(footer.ui.document.getTotalPagesLeft, footer.ui.document, footer.pageno)
        if not ok then return nil end
        local value = timeForPages(footer, pages)
        return value and T(_("%1 left in book"), value) or nil
    elseif choice == "chapter_time" then
        if not footer.ui or not footer.ui.document or type(footer.pageno) ~= "number" then return nil end
        local pages
        if footer.ui.toc and type(footer.ui.toc.getChapterPagesLeft) == "function" then
            local ok, result = pcall(footer.ui.toc.getChapterPagesLeft, footer.ui.toc, footer.pageno, true)
            if ok then pages = result end
        end
        if pages == nil then
            local ok, result = pcall(footer.ui.document.getTotalPagesLeft, footer.ui.document, footer.pageno)
            if ok then pages = result end
        end
        local value = timeForPages(footer, pages)
        return value and T(_("%1 left in chapter"), value) or nil
    elseif choice == "page" then
        return pageText(footer)
    elseif choice == "percentage" then
        local pct = tonumber(footer.percent_finished)
        if not pct then return nil end
        return string.format("%d%%", math.floor(pct * 100 + 0.5))
    elseif choice == "clock" then
        return datetime.secondsToHour(os.time(), G_reader_settings:isTrue("twelve_hour_clock"))
    elseif choice == "battery" then
        if not Device:hasBattery() then return nil end
        local powerd = Device:getPowerDevice()
        local ok, capacity = pcall(powerd.getCapacity, powerd)
        if not ok or capacity == nil then return nil end
        return tostring(capacity) .. "%"
    end
    return nil
end

local LEFT_CYCLE = { "book_time", "chapter_time", "page", "hidden" }
local RIGHT_CYCLE = { "percentage", "page", "clock", "battery", "hidden" }

local CHOICE_LABELS = {
    book_time = _("Time left in book"),
    chapter_time = _("Time left in chapter"),
    page = _("Page in book"),
    percentage = _("Percentage"),
    clock = _("Clock"),
    battery = _("Battery"),
    hidden = _("Hidden"),
}

local function choiceAvailable(footer, choice)
    if choice == "hidden" then return true end
    if choice == "battery" then return Device:hasBattery() end
    return splitValue(footer, choice) ~= nil
end

local function nextChoice(footer, key, cycle, default)
    local current = getSplitChoice(key, default)
    local index = util.arrayContains(cycle, current) or 0
    for step = 1, #cycle do
        local next_index = ((index - 1 + step) % #cycle) + 1
        local candidate = cycle[next_index]
        if choiceAvailable(footer, candidate) then
            saveSplitChoice(key, candidate)
            return candidate
        end
    end
    return current
end

local function freeSplitWidgets(footer)
    for _, name in ipairs({ "_burrow_left_text", "_burrow_right_text" }) do
        local widget = footer[name]
        if widget and widget.free then
            pcall(widget.free, widget)
        end
        footer[name] = nil
    end
end

local function makeSplitTextWidget(footer, text, max_width)
    return TextWidget:new{
        text = text or "",
        face = footer.footer_text_face or Font:getFace("smallinfofont", 14),
        bold = footer.settings and footer.settings.text_font_bold or false,
        max_width = math.max(1, max_width),
    }
end

local function buildSplitFooterContainer(footer)
    if not splitFooterEnabled() then return false end

    local left_margin, right_margin = getScaledMargins(footer)
    local horizontal_inset = Screen:scaleBySize(getHorizontalInset())
    left_margin = left_margin + horizontal_inset
    right_margin = right_margin + horizontal_inset

    local screen_w = Screen:getWidth()
    local usable_w = math.max(2, screen_w - left_margin - right_margin)
    local left_w = math.floor(usable_w / 2)
    local right_w = usable_w - left_w
    local row_h = math.max(1, footer.height or Screen:scaleBySize(24))
    local text_pad = Screen:scaleBySize(3)

    freeSplitWidgets(footer)
    footer._burrow_left_text = makeSplitTextWidget(footer, "", left_w - 2 * text_pad)
    footer._burrow_right_text = makeSplitTextWidget(footer, "", right_w - 2 * text_pad)

    local left_cell = LeftContainer:new{
        dimen = Geom:new{ w = left_w, h = row_h },
        footer._burrow_left_text,
    }
    local right_cell = RightContainer:new{
        dimen = Geom:new{ w = right_w, h = row_h },
        footer._burrow_right_text,
    }

    footer.horizontal_group = HorizontalGroup:new{
        HorizontalSpan:new{ width = left_margin },
        left_cell,
        right_cell,
        HorizontalSpan:new{ width = right_margin },
    }

    footer.footer_container = LeftContainer:new{
        dimen = Geom:new{ w = screen_w, h = row_h },
        footer.horizontal_group,
    }

    footer.vertical_frame = VerticalGroup:new{
        footer.footer_container,
    }

    footer.footer_content = FrameContainer:new{
        footer.vertical_frame,
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0,
        padding = 0,
        padding_bottom = (footer.bottom_padding or 0) + Screen:scaleBySize(getBottomInset()),
    }

    local BottomContainer = require("ui/widget/container/bottomcontainer")
    footer.footer_positioner = BottomContainer:new{
        dimen = Geom:new{ w = screen_w, h = Screen:getHeight() },
        footer.footer_content,
    }
    footer[1] = footer.footer_positioner
    footer._burrow_split_built = true
    return true
end

local function updateSplitFooterText(footer)
    if not splitFooterEnabled() or not footer._burrow_split_built then return end
    local left_choice = getSplitChoice(SPLIT_FOOTER_LEFT, DEFAULT_SPLIT_LEFT)
    local right_choice = getSplitChoice(SPLIT_FOOTER_RIGHT, DEFAULT_SPLIT_RIGHT)
    local left = splitValue(footer, left_choice) or ""
    local right = splitValue(footer, right_choice) or ""
    if footer._burrow_left_text then footer._burrow_left_text:setText(BD.auto(left)) end
    if footer._burrow_right_text then footer._burrow_right_text:setText(BD.auto(right)) end
    if footer.horizontal_group and footer.horizontal_group.resetLayout then
        footer.horizontal_group:resetLayout()
    end
end

local function ensureSplitFooterReady(footer, notify_reader)
    if not splitFooterEnabled() then return false end

    local was_visible = footer.view and footer.view.footer_visible
    if footer.view then footer.view.footer_visible = true end
    buildSplitFooterContainer(footer)

    if footer.resetLayout then footer:resetLayout(true) end
    updateSplitFooterText(footer)

    if was_visible == false then footer.visibility_change = true end
    if notify_reader and footer.ui and footer.ui.handleEvent then
        footer.ui:handleEvent(Event:new("ReaderFooterVisibilityChange"))
    end
    return true
end

-- Let KOReader build its normal footer, then replace only the two edge spans,
-- or the whole footer row when Reading progress footer is enabled.
local original_updateFooterContainer = ReaderFooter.updateFooterContainer
function ReaderFooter:updateFooterContainer()
    local left, right = applyMarginRuntimeValues(self)
    original_updateFooterContainer(self)

    if splitFooterEnabled() then
        buildSplitFooterContainer(self)
        return
    end

    self._burrow_split_built = nil
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
    if splitFooterEnabled() then
        return true
    end
    local enabled = not self.settings or self.settings.statusbar_cycle_presets ~= false
    if enabled and self:cycleNamedStatusBarPreset() then
        return true
    end
    return original_onToggleFooterMode(self)
end

-- Reading progress footer uses KOReader's existing footer tap zone. No new
-- touch zones are registered. Left and right halves cycle independently.
local original_TapFooter = ReaderFooter.TapFooter
function ReaderFooter:TapFooter(ges)
    if splitFooterEnabled() and not self.view.flipping_visible and ges and ges.pos then
        if self.settings and self.settings.lock_tap then return end
        if ges.pos.x < Screen:getWidth() / 2 then
            nextChoice(self, SPLIT_FOOTER_LEFT, LEFT_CYCLE, DEFAULT_SPLIT_LEFT)
        else
            nextChoice(self, SPLIT_FOOTER_RIGHT, RIGHT_CYCLE, DEFAULT_SPLIT_RIGHT)
        end
        updateSplitFooterText(self)
        self:onUpdateFooter(true)
        return true
    end
    return original_TapFooter(self, ges)
end

-- Keep both side values current whenever KOReader updates its native footer.
local original_onUpdateFooter = ReaderFooter.onUpdateFooter
function ReaderFooter:onUpdateFooter(force_repaint, full_repaint)
    updateSplitFooterText(self)
    return original_onUpdateFooter(self, force_repaint, full_repaint)
end

-- KOReader initializes ReaderFooter before the document is fully ready. v1.1
-- could therefore force footer_visible but still leave the custom row unbuilt
-- until the setting was toggled. Re-apply the Burrow row after KOReader's own
-- ReaderReady lifecycle has finished and screen/document dimensions are valid.
local original_onReaderReady = ReaderFooter.onReaderReady
function ReaderFooter:onReaderReady(...)
    local result = original_onReaderReady(self, ...)
    if splitFooterEnabled() then
        ensureSplitFooterReady(self, true)
        -- updateFooterText is now live after native onReaderReady.
        self:onUpdateFooter(true, true)
    end
    return result
end

-- KOReader's native footer mode can be "off" even while Burrow's Reading
-- progress footer is enabled. Let KOReader do normal bookkeeping first, then
-- keep only Burrow's custom footer visible. Disabling Burrow immediately
-- restores KOReader's native footer visibility logic.
local original_applyFooterMode = ReaderFooter.applyFooterMode
function ReaderFooter:applyFooterMode(mode)
    local result = original_applyFooterMode(self, mode)
    if splitFooterEnabled() then
        if self.view then self.view.footer_visible = true end
        if not self._burrow_split_built then
            buildSplitFooterContainer(self)
        end
    end
    return result
end

-- Rebuild custom widgets when the native footer font is changed.
local original_updateFooterFont = ReaderFooter.updateFooterFont
function ReaderFooter:updateFooterFont(...)
    local result = original_updateFooterFont(self, ...)
    if splitFooterEnabled() then
        buildSplitFooterContainer(self)
        if self.resetLayout then self:resetLayout(true) end
        updateSplitFooterText(self)
    end
    return result
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
            footer:updateFooterContainer()
            footer:resetLayout(true)
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

local function choiceMenuItems(footer, setting_key, choices, default)
    local items = {}
    for _, choice in ipairs(choices) do
        if choice ~= "battery" or Device:hasBattery() then
            local value = choice
            table.insert(items, {
                text = CHOICE_LABELS[value],
                radio = true,
                checked_func = function()
                    return getSplitChoice(setting_key, default) == value
                end,
                callback = function()
                    saveSplitChoice(setting_key, value)
                    local live_footer = resolveLiveFooter(footer)
                    if live_footer then
                        updateSplitFooterText(live_footer)
                        live_footer:onUpdateFooter(true)
                    end
                end,
            })
        end
    end
    return items
end

local function splitFooterMenuItem(footer)
    return {
        text = _("Reading progress footer"),
        sub_item_table = {
            {
                text = _("Use Reading progress footer"),
                checked_func = splitFooterEnabled,
                callback = function()
                    local enabled = not splitFooterEnabled()
                    G_reader_settings:saveSetting(SPLIT_FOOTER_ENABLED, enabled)

                    -- Burrow Settings may be opened from the File Manager, where
                    -- no live ReaderFooter exists. Save the same global setting
                    -- either way, and refresh immediately only when a reader is live.
                    local live_footer = resolveLiveFooter(footer)
                    if not live_footer then return end

                    live_footer:applyFooterMode()
                    live_footer:updateFooterContainer()
                    live_footer:resetLayout(true)
                    if enabled then
                        ensureSplitFooterReady(live_footer, true)
                    else
                        live_footer._burrow_split_built = nil
                        live_footer:applyFooterMode()
                        if live_footer.ui and live_footer.ui.handleEvent then
                            live_footer.ui:handleEvent(Event:new("ReaderFooterVisibilityChange"))
                        end
                    end
                    live_footer:refreshFooter(true, true)
                end,
            },
            {
                text_func = function()
                    local value = getSplitChoice(SPLIT_FOOTER_LEFT, DEFAULT_SPLIT_LEFT)
                    return T(_("Left side: %1"), CHOICE_LABELS[value] or value)
                end,
                enabled_func = splitFooterEnabled,
                sub_item_table_func = function()
                    return choiceMenuItems(footer, SPLIT_FOOTER_LEFT, LEFT_CYCLE, DEFAULT_SPLIT_LEFT)
                end,
            },
            {
                text_func = function()
                    local value = getSplitChoice(SPLIT_FOOTER_RIGHT, DEFAULT_SPLIT_RIGHT)
                    return T(_("Right side: %1"), CHOICE_LABELS[value] or value)
                end,
                enabled_func = splitFooterEnabled,
                sub_item_table_func = function()
                    return choiceMenuItems(footer, SPLIT_FOOTER_RIGHT, RIGHT_CYCLE, DEFAULT_SPLIT_RIGHT)
                end,
            },
            {
                text_func = function()
                    return T(_("Footer position: %1"), getBottomInset())
                end,
                help_text = _("Moves the Reading progress footer upward from the bottom edge. Increase this if the footer is too low or clipped by the screen edge."),
                enabled_func = splitFooterEnabled,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    UIManager:show(SpinWidget:new{
                        title_text = _("Reading progress footer position"),
                        info_text = _("Higher values move the footer farther up from the bottom edge."),
                        value = getBottomInset(),
                        value_min = MIN_BOTTOM_INSET,
                        value_max = MAX_BOTTOM_INSET,
                        value_step = 1,
                        value_hold_step = 5,
                        default_value = DEFAULT_BOTTOM_INSET,
                        keep_shown_on_apply = true,
                        callback = function(spin)
                            G_reader_settings:saveSetting(SPLIT_FOOTER_BOTTOM_INSET, spin.value)
                            local live_footer = resolveLiveFooter(footer)
                            if live_footer then
                                ensureSplitFooterReady(live_footer, true)
                                live_footer:refreshFooter(true, true)
                            end
                            if touchmenu_instance then touchmenu_instance:updateItems() end
                        end,
                    })
                end,
            },
            {
                text_func = function()
                    return T(_("Horizontal inset: %1"), getHorizontalInset())
                end,
                help_text = _("Moves both sides of the Reading progress footer inward from the left and right screen edges without changing the normal KOReader status-bar margins."),
                enabled_func = splitFooterEnabled,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    UIManager:show(SpinWidget:new{
                        title_text = _("Reading progress footer horizontal inset"),
                        info_text = _("Higher values move the left and right footer items farther inward from the screen edges."),
                        value = getHorizontalInset(),
                        value_min = MIN_HORIZONTAL_INSET,
                        value_max = MAX_HORIZONTAL_INSET,
                        value_step = 1,
                        value_hold_step = 5,
                        default_value = DEFAULT_HORIZONTAL_INSET,
                        keep_shown_on_apply = true,
                        callback = function(spin)
                            G_reader_settings:saveSetting(
                                SPLIT_FOOTER_HORIZONTAL_INSET,
                                spin.value
                            )
                            local live_footer = resolveLiveFooter(footer)
                            if live_footer then
                                ensureSplitFooterReady(live_footer, true)
                                live_footer:refreshFooter(true, true)
                            end
                            if touchmenu_instance then touchmenu_instance:updateItems() end
                        end,
                    })
                end,
            },
        },
    }
end

-- Expose the exact same settings tree to Burrow Settings. Keeping one
-- menu factory means the Status bar path and Burrow Settings always edit the
-- same keys with the same labels, ranges, and behavior.
function Module.getReadingProgressSettingsMenu()
    return splitFooterMenuItem(nil)
end

local function presetCycleMenuItems(footer)
    return {
        {
            text = _("Tap status bar to cycle presets"),
            help_text = _("A tap loads the next named status-bar preset. With fewer than two presets, the normal KOReader status-bar tap behavior is used."),
            checked_func = function()
                return footer.settings.statusbar_cycle_presets ~= false
            end,
            enabled_func = function()
                return not splitFooterEnabled()
            end,
            callback = function()
                footer.settings.statusbar_cycle_presets =
                    footer.settings.statusbar_cycle_presets == false
            end,
        },
        {
            text = _("Next status bar preset"),
            enabled_func = function()
                return not splitFooterEnabled() and #getPresetNames() > 1
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

    table.insert(sub_items, splitFooterMenuItem(self))
    table.insert(sub_items, marginsMenuItem(self))
    for _, item in ipairs(presetCycleMenuItems(self)) do
        table.insert(sub_items, item)
    end
end

    Module.applied = true
    return true
end

return Module

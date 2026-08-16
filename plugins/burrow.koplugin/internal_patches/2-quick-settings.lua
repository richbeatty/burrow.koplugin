local MODULE_KEY = "burrow.internal.2_quick_settings"
local existing_module = package.loaded[MODULE_KEY]
if existing_module then return existing_module end
local Module = { key = MODULE_KEY, phase = "early", filename = "2-quick-settings.lua" }
package.loaded[MODULE_KEY] = Module

function Module.apply()
    if Module.applied then return true end


-- Rounded Quick Settings for KOReader
--
-- Based on qewer33's 2-quick-settings.lua:
-- https://github.com/qewer33/koreader-patches
--
-- This version adds a reader-focused quick panel, KoSync push/pull actions,
-- rounded tab highlights, and a rounded bottom footer.
-- Remove any other copy of 2-quick-settings.lua before installing this file.

local logger = require("logger")
local BionicReading
do
    local ok, module_or_error = pcall(require, "burrow_bionic_reading")
    if ok and type(module_or_error) == "table" then
        local apply_ok, apply_result = pcall(module_or_error.apply)
        if apply_ok and apply_result ~= false then
            BionicReading = module_or_error
        else
            logger.warn("[Burrow] Bionic Reading disabled; initialization failed", apply_result)
        end
    else
        logger.warn("[Burrow] Bionic Reading disabled; module failed to load", module_or_error)
    end
end
local BD = require("ui/bidi")
local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local CenterContainer = require("ui/widget/container/centercontainer")
local ConfirmBox = require("ui/widget/confirmbox")
local Device = require("device")
local Event = require("ui/event")
local FocusManager = require("ui/widget/focusmanager")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local IconWidget = require("ui/widget/iconwidget")
local Math = require("optmath")
local NetworkMgr = require("ui/network/manager")
local ProgressWidget = require("ui/widget/progresswidget")
local Screen = Device.screen
local Size = require("ui/size")
local SortWidget = require("ui/widget/sortwidget")
local TextWidget = require("ui/widget/textwidget")
local TouchMenu = require("ui/widget/touchmenu")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local datetime = require("datetime")
local _ = require("gettext")



-- Local slider renderer used only by this patch. KOReader's stock ProgressWidget
-- paints its fill as a square rectangle even when the track is rounded. That
-- square can protrude into the curved left edge. This subclass keeps the stock
-- sizing, percentage, and touch handling, but paints both the track and fill as
-- rounded shapes.
local RoundedSlider = ProgressWidget:extend{}

function RoundedSlider:paintTo(bb, x, y)
    local size = self:getSize()
    if not self.dimen then
        self.dimen = Geom:new{ x = x, y = y, w = size.w, h = size.h }
    else
        self.dimen.x = x
        self.dimen.y = y
        self.dimen.w = size.w
        self.dimen.h = size.h
    end
    if size.w <= 0 or size.h <= 0 then return end

    local radius = math.min(self.radius or 0, math.floor(size.h / 2))
    bb:paintRoundedRect(x, y, size.w, size.h, self.bgcolor, radius)
    if (self.bordersize or 0) > 0 then
        bb:paintBorder(
            math.floor(x), math.floor(y), size.w, size.h,
            self.bordersize, self.bordercolor, radius,
            G_reader_settings:nilOrTrue("anti_alias_ui")
        )
    end

    local inset = math.max(self.bordersize or 0, 0)
    local inner_x = x + inset
    local inner_y = y + inset
    local inner_w = math.max(0, size.w - inset * 2)
    local inner_h = math.max(0, size.h - inset * 2)
    local percentage = math.max(0, math.min(1, self.percentage or 0))
    local fill_w = math.floor(inner_w * percentage + 0.5)

    if fill_w > 0 and inner_h > 0 then
        local mirrored = BD.mirroredUILayout()
        if self.invert_direction then mirrored = not mirrored end
        local from_right = self.fill_from_right or (mirrored and not self.fill_from_right)
        local fill_x = from_right and (inner_x + inner_w - fill_w) or inner_x
        local fill_radius = math.min(
            math.max(0, radius - inset),
            math.floor(inner_h / 2),
            math.floor(fill_w / 2)
        )
        bb:paintRoundedRect(fill_x, inner_y, fill_w, inner_h, self.fillcolor, fill_radius)
    end
end

local CONFIG_KEY = "rounded_quick_settings_panel"

local function deepCopy(value)
    if type(value) ~= "table" then return value end
    local copy = {}
    for key, item in pairs(value) do
        copy[key] = deepCopy(item)
    end
    return copy
end

local config_default = {
    reader_order = {
        "toc", "search_book", "bookmarks", "text",
        "book_info", "kosync_push", "kosync_pull", "library",
        "night", "rotate", "wifi", "sleep", "restart", "exit",
    },
    filemanager_order = {
        "file_search", "wifi", "night", "rotate", "sleep", "restart", "exit",
    },
    reader_buttons = {
        toc = true,
        search_book = true,
        bookmarks = true,
        text = true,
        book_info = true,
        kosync_push = true,
        kosync_pull = true,
        library = true,
        night = true,
        rotate = true,
        wifi = false,
        sleep = false,
        restart = false,
        exit = false,
    },
    filemanager_buttons = {
        file_search = true,
        wifi = true,
        night = true,
        rotate = true,
        sleep = true,
        restart = false,
        exit = false,
    },
    show_frontlight = true,
    show_warmth = true,
    open_on_start = true,
    rounded_tabs = false, -- deprecated; native KOReader top tabs are retained
    columns = 4,
}

local function mergeDefaults(target, defaults)
    for key, value in pairs(defaults) do
        if target[key] == nil then
            target[key] = deepCopy(value)
        elseif type(value) == "table" and type(target[key]) == "table" then
            mergeDefaults(target[key], value)
        end
    end
end

local config = G_reader_settings:readSetting(CONFIG_KEY)
if type(config) ~= "table" then
    config = deepCopy(config_default)
else
    mergeDefaults(config, config_default)
end

local function ensureOrderContains(order, defaults)
    local known = {}
    for _, id in ipairs(order) do known[id] = true end
    for _, id in ipairs(defaults) do
        if not known[id] then table.insert(order, id) end
    end
end

local function insertBeforeIfMissing(order, id, before_id)
    for _, existing in ipairs(order) do
        if existing == id then return end
    end
    local insert_at = #order + 1
    for index, existing in ipairs(order) do
        if existing == before_id then
            insert_at = index
            break
        end
    end
    table.insert(order, insert_at, id)
end

-- Place the new sync pair together for users upgrading from the earlier patch.
insertBeforeIfMissing(config.reader_order, "kosync_push", "library")
insertBeforeIfMissing(config.reader_order, "kosync_pull", "library")
ensureOrderContains(config.reader_order, config_default.reader_order)
ensureOrderContains(config.filemanager_order, config_default.filemanager_order)

local function saveConfig()
    G_reader_settings:saveSetting(CONFIG_KEY, config)
end

-- Bionic Reading is a fixed Reader Controls action, not a configurable
-- Reader button. Remove configuration residue from earlier test overlays.
local removed_legacy_bionic = false
for index = #config.reader_order, 1, -1 do
    if config.reader_order[index] == "bionic" then
        table.remove(config.reader_order, index)
        removed_legacy_bionic = true
    end
end
if config.reader_buttons and config.reader_buttons.bionic ~= nil then
    config.reader_buttons.bionic = nil
    removed_legacy_bionic = true
end
if removed_legacy_bionic then saveConfig() end

local function isReaderContext()
    local ok, ReaderUI = pcall(require, "apps/reader/readerui")
    return ok and ReaderUI.instance ~= nil
end

local function closeAndBroadcast(touch_menu, event_name)
    UIManager:close(touch_menu)
    UIManager:nextTick(function()
        UIManager:broadcastEvent(Event:new(event_name))
    end)
end

local button_defs = {
    toc = {
        icon = "quick_toc",
        label = _("Contents"),
        reader = true,
        callback = function(menu) closeAndBroadcast(menu, "ShowToc") end,
    },
    search_book = {
        icon = "quick_search",
        label = _("Search"),
        reader = true,
        callback = function(menu) closeAndBroadcast(menu, "ShowFulltextSearchInput") end,
    },
    bookmarks = {
        icon = "quick_bookmark",
        label = _("Bookmarks"),
        reader = true,
        callback = function(menu) closeAndBroadcast(menu, "ShowBookmark") end,
    },
    text = {
        icon = "quick_text",
        label = _("Text"),
        reader = true,
        callback = function(menu) closeAndBroadcast(menu, "ShowConfigMenu") end,
    },
    bionic = {
        icon = "quick_bionic",
        label = _("Bionic"),
        reader = true,
        active_func = function()
            return BionicReading and BionicReading.isEnabled() or false
        end,
        callback = function(touch_menu)
            if BionicReading then
                BionicReading.toggleFromQuickSettings(touch_menu)
            end
        end,
    },
    book_info = {
        icon = "quick_info",
        label = _("Book info"),
        reader = true,
        callback = function(menu) closeAndBroadcast(menu, "ShowBookInfo") end,
    },
    kosync_push = {
        icon = "quick_push",
        label = _("Push sync"),
        reader = true,
        callback = function(menu) closeAndBroadcast(menu, "KOSyncPushProgress") end,
    },
    kosync_pull = {
        icon = "quick_pull",
        label = _("Pull sync"),
        reader = true,
        callback = function(menu) closeAndBroadcast(menu, "KOSyncPullProgress") end,
    },
    library = {
        icon = "quick_library",
        label = _("Library"),
        reader = true,
        callback = function(menu) closeAndBroadcast(menu, "Home") end,
    },
    file_search = {
        icon = "quick_search",
        label = _("Search"),
        filemanager = true,
        callback = function(menu) closeAndBroadcast(menu, "ShowFileSearch") end,
    },
    wifi = {
        icon = "quick_wifi",
        label = _("Wi-Fi"),
        active_func = function() return NetworkMgr:isWifiOn() end,
        callback = function(touch_menu)
            if NetworkMgr:isWifiOn() then
                NetworkMgr:toggleWifiOff()
            else
                NetworkMgr:toggleWifiOn()
            end
            UIManager:scheduleIn(1, function()
                if touch_menu.item_table and touch_menu.item_table.panel then
                    touch_menu:updateItems(1)
                end
            end)
        end,
    },
    night = {
        icon = "quick_nightmode",
        label = _("Night"),
        active_func = function() return G_reader_settings:isTrue("night_mode") end,
        callback = function(touch_menu)
            local night_mode = G_reader_settings:isTrue("night_mode")
            Screen:toggleNightMode()
            UIManager:ToggleNightMode(not night_mode)
            G_reader_settings:saveSetting("night_mode", not night_mode)
            touch_menu:updateItems(1)
            UIManager:setDirty("all", "full")
        end,
    },
    rotate = {
        icon = "quick_rotate",
        label = _("Rotate"),
        callback = function(menu) closeAndBroadcast(menu, "SwapRotation") end,
    },
    sleep = {
        icon = "quick_sleep",
        label = _("Sleep"),
        callback = function(menu)
            UIManager:close(menu)
            UIManager:nextTick(function()
                if Device:canSuspend() then
                    UIManager:broadcastEvent(Event:new("RequestSuspend"))
                elseif Device:canPowerOff() then
                    UIManager:broadcastEvent(Event:new("RequestPowerOff"))
                end
            end)
        end,
    },
    restart = {
        icon = "quick_restart",
        label = _("Restart"),
        callback = function()
            UIManager:show(ConfirmBox:new{
                text = _("Restart KOReader?"),
                ok_text = _("Restart"),
                ok_callback = function()
                    UIManager:broadcastEvent(Event:new("Restart"))
                end,
            })
        end,
    },
    exit = {
        icon = "quick_exit",
        label = _("Exit"),
        callback = function()
            UIManager:show(ConfirmBox:new{
                text = _("Exit KOReader?"),
                ok_text = _("Exit"),
                ok_callback = function()
                    UIManager:broadcastEvent(Event:new("Exit"))
                end,
            })
        end,
    },
}

local button_display_names = {
    toc = _("Table of contents"),
    search_book = _("Search in book"),
    bookmarks = _("Bookmarks"),
    text = _("Text controls"),
    book_info = _("Book information"),
    kosync_push = _("Push progress to KoSync"),
    kosync_pull = _("Pull progress from KoSync"),
    library = _("Return to library"),
    file_search = _("File search"),
    wifi = _("Wi-Fi"),
    night = _("Night mode"),
    rotate = _("Rotate"),
    sleep = _("Sleep"),
    restart = _("Restart"),
    exit = _("Exit"),
}

local function visibleButtonEntries()
    local reader = isReaderContext()
    local order = reader and config.reader_order or config.filemanager_order
    local enabled = reader and config.reader_buttons or config.filemanager_buttons
    local entries = {}
    local bionic_inserted = false

    for _, id in ipairs(order) do
        local def = button_defs[id]
        local context_ok = def and not ((def.reader and not reader) or (def.filemanager and reader))
        if def and context_ok and enabled[id] then
            table.insert(entries, { id = id, def = def })
        end

        if reader and BionicReading and id == "text" and not bionic_inserted then
            table.insert(entries, { id = "bionic", def = button_defs.bionic })
            bionic_inserted = true
        end
    end

    if reader and BionicReading and not bionic_inserted then
        table.insert(entries, { id = "bionic", def = button_defs.bionic })
    end
    return entries
end

local function makeRoundedButton(text, width, callback)
    return Button:new{
        text = text,
        width = width,
        height = Screen:scaleBySize(36),
        radius = Screen:scaleBySize(11),
        bordersize = Size.border.thin,
        padding = Screen:scaleBySize(2),
        text_font_size = 20,
        show_parent = nil,
        callback = callback,
    }
end

local function createQuickSettingsPanel(touch_menu)
    local panel_width = touch_menu.item_width
    local outer_margin = Screen:scaleBySize(12)
    local card_width = panel_width - 2 * outer_margin
    local card_padding = Screen:scaleBySize(12)
    local inner_width = card_width - 2 * card_padding - 2 * Size.border.thin
    local action_gap = Screen:scaleBySize(8)
    local row_gap = Screen:scaleBySize(8)
    local columns = math.max(3, math.min(4, tonumber(config.columns) or 4))
    local action_width = math.floor((inner_width - (columns - 1) * action_gap) / columns)
    local action_height = Screen:scaleBySize(72)
    local icon_size = Screen:scaleBySize(29)
    local action_radius = Screen:scaleBySize(12)
    local powerd = Device:getPowerDevice()
    local refs = { buttons = {}, sliders = {} }

    local panel_content = VerticalGroup:new{ align = "center" }
    table.insert(panel_content, TextWidget:new{
        text = isReaderContext() and _("Reading Controls") or _("Quick Settings"),
        face = Font:getFace("smallinfofont", 20),
        bold = true,
        max_width = inner_width,
    })
    table.insert(panel_content, VerticalSpan:new{ width = Screen:scaleBySize(10) })

    local entries = visibleButtonEntries()
    for row_start = 1, #entries, columns do
        local row = HorizontalGroup:new{ align = "center" }
        local row_end = math.min(row_start + columns - 1, #entries)
        for index = row_start, row_end do
            local entry = entries[index]
            local def = entry.def
            local active = def.active_func and def.active_func() or false
            local icon = IconWidget:new{
                icon = def.icon,
                width = icon_size,
                height = icon_size,
                alpha = true,
            }
            local label = TextWidget:new{
                text = def.label,
                face = Font:getFace("smallinfofont", 15),
                bold = false,
                max_width = action_width - Screen:scaleBySize(8),
            }
            local action_content = VerticalGroup:new{
                align = "center",
                icon,
                VerticalSpan:new{ width = Screen:scaleBySize(3) },
                label,
            }
            local action_card = FrameContainer:new{
                width = action_width,
                height = action_height,
                radius = action_radius,
                bordersize = Size.border.thin,
                padding = 0,
                margin = 0,
                background = active and Blitbuffer.COLOR_LIGHT_GRAY or Blitbuffer.COLOR_WHITE,
                CenterContainer:new{
                    dimen = Geom:new{ w = action_width, h = action_height },
                    action_content,
                },
            }
            table.insert(refs.buttons, {
                widget = action_card,
                callback = function() def.callback(touch_menu) end,
            })
            table.insert(row, action_card)
            if index < row_end then
                table.insert(row, HorizontalSpan:new{ width = action_gap })
            end
        end
        table.insert(panel_content, CenterContainer:new{
            dimen = Geom:new{ w = inner_width, h = action_height },
            row,
        })
        if row_end < #entries then
            table.insert(panel_content, VerticalSpan:new{ width = row_gap })
        end
    end

    local function addSliderCard(label_text, minimum, maximum, current, setter)
        if maximum <= minimum then return end
        table.insert(panel_content, VerticalSpan:new{ width = Screen:scaleBySize(12) })

        local slider_padding = Screen:scaleBySize(10)
        local control_gap = Screen:scaleBySize(7)
        local button_width = Screen:scaleBySize(42)
        local slider_width = inner_width - 2 * slider_padding - 2 * button_width - 2 * control_gap
        local control_height = Screen:scaleBySize(36)
        local state = { min = minimum, max = maximum, cur = current }

        local value_label = TextWidget:new{
            text = label_text .. ": " .. tostring(current),
            face = Font:getFace("smallinfofont", 17),
            max_width = inner_width - 2 * slider_padding,
        }

        local progress = RoundedSlider:new{
            width = slider_width,
            height = Screen:scaleBySize(18),
            radius = Screen:scaleBySize(8),
            bordersize = Size.border.thin,
            bordercolor = Blitbuffer.COLOR_GRAY_3,
            bgcolor = Blitbuffer.COLOR_GRAY_E,
            fillcolor = Blitbuffer.COLOR_DARK_GRAY,
            margin_h = 0,
            margin_v = 0,
            percentage = (current - minimum) / (maximum - minimum),
        }

        local function setValue(value)
            value = math.max(minimum, math.min(maximum, value))
            setter(value)
            state.cur = value
            progress:setPercentage((value - minimum) / (maximum - minimum))
            value_label:setText(label_text .. ": " .. tostring(value))
            UIManager:setDirty(touch_menu.show_parent, "ui")
        end

        local minus = makeRoundedButton("-", button_width, function() setValue(state.cur - 1) end)
        local plus = makeRoundedButton("+", button_width, function() setValue(state.cur + 1) end)
        minus.show_parent = touch_menu.show_parent
        plus.show_parent = touch_menu.show_parent

        local controls = HorizontalGroup:new{
            align = "center",
            minus,
            HorizontalSpan:new{ width = control_gap },
            CenterContainer:new{
                dimen = Geom:new{ w = slider_width, h = control_height },
                progress,
            },
            HorizontalSpan:new{ width = control_gap },
            plus,
        }

        local slider_content = VerticalGroup:new{
            align = "center",
            value_label,
            VerticalSpan:new{ width = Screen:scaleBySize(7) },
            controls,
        }
        local slider_card = FrameContainer:new{
            width = inner_width,
            radius = Screen:scaleBySize(13),
            bordersize = Size.border.thin,
            padding = slider_padding,
            margin = 0,
            background = Blitbuffer.COLOR_WHITE,
            slider_content,
        }
        table.insert(panel_content, slider_card)
        table.insert(refs.sliders, {
            widget = progress,
            state = state,
            setValue = setValue,
        })
    end

    if config.show_frontlight and Device:hasFrontlight() then
        local fl_min = powerd.fl_min or 0
        local fl_max = powerd.fl_max or 100
        local fl_cur = powerd:frontlightIntensity()
        addSliderCard(_("Frontlight"), fl_min, fl_max, fl_cur, function(value)
            powerd:setIntensity(value)
        end)
    end

    if config.show_warmth and Device:hasNaturalLight() then
        local warmth_min = powerd.fl_warmth_min or 0
        local warmth_max = powerd.fl_warmth_max or 100
        local warmth_cur = powerd:toNativeWarmth(powerd:frontlightWarmth())
        addSliderCard(_("Warmth"), warmth_min, warmth_max, warmth_cur, function(value)
            powerd:setWarmth(powerd:fromNativeWarmth(value))
        end)
    end

    local outer_card = FrameContainer:new{
        width = card_width,
        radius = Screen:scaleBySize(18),
        bordersize = Size.border.thin,
        padding = card_padding,
        margin = 0,
        background = Blitbuffer.COLOR_WHITE,
        panel_content,
    }

    local panel = VerticalGroup:new{
        align = "center",
        VerticalSpan:new{ width = Screen:scaleBySize(10) },
        CenterContainer:new{
            dimen = Geom:new{ w = panel_width, h = outer_card:getSize().h },
            outer_card,
        },
        VerticalSpan:new{ width = Screen:scaleBySize(8) },
    }

    touch_menu._rounded_qs_refs = refs
    return panel
end

local function handlePanelGesture(touch_menu, ges)
    local refs = touch_menu._rounded_qs_refs
    if not refs or not ges or not ges.pos then return false end

    for _, slider in ipairs(refs.sliders) do
        if slider.widget.dimen and ges.pos:intersectWith(slider.widget.dimen) then
            local percentage = slider.widget:getPercentageFromPosition(ges.pos)
            if percentage then
                local state = slider.state
                slider.setValue(Math.round(state.min + percentage * (state.max - state.min)))
                return true
            end
        end
    end

    for _, button in ipairs(refs.buttons) do
        if button.widget.dimen and ges.pos:intersectWith(button.widget.dimen) then
            button.callback()
            return true
        end
    end

    return false
end

-- Render the quick tab as a custom panel.
local original_updateItems = TouchMenu.updateItems
function TouchMenu:updateItems(target_page, target_item_id)
    if not self.item_table or not self.item_table.panel then
        self._rounded_qs_refs = nil
        if self.menu_frame then
            self.menu_frame.color = Blitbuffer.COLOR_BLACK
            self.menu_frame.radius = 0
        end
        return original_updateItems(self, target_page, target_item_id)
    end

    -- The stock TouchMenu frame draws a straight black bottom edge.
    -- Hide that frame only for this custom tab; the content and footer
    -- provide their own rounded borders instead.
    if self.menu_frame then
        self.menu_frame.color = Blitbuffer.COLOR_WHITE
        self.menu_frame.radius = 0
    end

    self.item_group:clear()
    self.layout = {}
    table.insert(self.item_group, self.bar)
    table.insert(self.layout, self.bar.icon_widgets)

    local panel_source = self.item_table.panel
    local panel = type(panel_source) == "function" and panel_source(self) or panel_source
    table.insert(self.item_group, panel)

    table.insert(self.item_group, self.footer_top_margin)
    local footer_cap = FrameContainer:new{
        radius = Screen:scaleBySize(15),
        bordersize = Size.border.thin,
        padding = 0,
        margin = 0,
        background = Blitbuffer.COLOR_WHITE,
        self.footer,
    }
    table.insert(self.item_group, footer_cap)
    table.insert(self.item_group, VerticalSpan:new{ width = Screen:scaleBySize(6) })
    self.page_info_text:setText("")
    self.page_info_left_chev:showHide(false)
    self.page_info_right_chev:showHide(false)

    local time_info = datetime.secondsToHour(os.time(), G_reader_settings:isTrue("twelve_hour_clock"))
    local powerd = Device:getPowerDevice()
    if Device:hasBattery() then
        local level = powerd:getCapacity()
        local symbol = powerd:getBatterySymbol(powerd:isCharged(), powerd:isCharging(), level)
        time_info = BD.wrap(time_info) .. " " .. BD.wrap("|") .. " " .. BD.wrap(symbol) .. BD.wrap(level .. "%")
    end
    self.time_info:setText(time_info)

    local old_dimen = self.dimen:copy()
    self.dimen.w = self.width
    self.dimen.h = self.item_group:getSize().h + self.bordersize * 2 + self.padding
    self:moveFocusTo(self.cur_tab, 1, FocusManager.NOT_FOCUS)

    local keep_background = old_dimen and self.dimen.h >= old_dimen.h
    UIManager:setDirty((self.is_fresh or keep_background) and self.show_parent or "all", function()
        local refresh_dimen = old_dimen and old_dimen:combine(self.dimen) or self.dimen
        local refresh_type = "ui"
        if self.is_fresh then
            refresh_type = "flashui"
            self.is_fresh = false
        end
        return refresh_type, refresh_dimen
    end)
end

local original_onTapCloseAllMenus = TouchMenu.onTapCloseAllMenus
function TouchMenu:onTapCloseAllMenus(arg, ges_ev)
    if self._rounded_qs_refs and self.item_table and self.item_table.panel then
        if handlePanelGesture(self, ges_ev) then return true end
    end
    return original_onTapCloseAllMenus(self, arg, ges_ev)
end

local original_onSwipe = TouchMenu.onSwipe
function TouchMenu:onSwipe(arg, ges_ev)
    if self._rounded_qs_refs and self.item_table and self.item_table.panel then
        if handlePanelGesture(self, ges_ev) then return true end
    end
    if original_onSwipe then return original_onSwipe(self, arg, ges_ev) end
end

-- Keep KOReader's native TouchMenuBar intact. Earlier Burrow alpha builds
-- replaced live IconButton children to draw rounded tab frames. That left the
-- IconButton's internal widget references inconsistent and could crash when a
-- tab was opened. KOReader's stock tab icons are already transparent and
-- theme-aware, so Burrow now styles only its Quick Settings content panel.

-- TouchMenu:init() chooses its opening tab before switchMenuTab() runs.
-- Set the opening index first so menus opened through Burrow's
-- top-right bird land on Quick Settings immediately, not one opening later.
local original_touchmenu_init = TouchMenu.init
function TouchMenu:init(...)
    if config.open_on_start then
        self.last_index = 1
    end
    return original_touchmenu_init(self, ...)
end

local quick_settings_tab = {
    icon = "quicksettings",
    remember = false,
    panel = createQuickSettingsPanel,
    _rounded_quick_settings = true,
}

local function makeArrangeItem(title, order, enabled)
    return {
        text = title,
        keep_menu_open = true,
        callback = function()
            local sort_items = {}
            for _, id in ipairs(order) do
                if button_defs[id] then
                    table.insert(sort_items, {
                        text = button_display_names[id],
                        orig_item = id,
                        dim = not enabled[id],
                    })
                end
            end
            UIManager:show(SortWidget:new{
                title = title,
                item_table = sort_items,
                callback = function()
                    for index, item in ipairs(sort_items) do
                        order[index] = item.orig_item
                    end
                    saveConfig()
                end,
            })
        end,
    }
end

local function makeButtonSettings(title, order, enabled)
    local items = { makeArrangeItem(_("Arrange buttons"), order, enabled) }
    items[1].separator = true
    for _, id in ipairs(order) do
        local button_id = id
        if button_defs[button_id] then
            table.insert(items, {
                text = button_display_names[button_id],
                checked_func = function() return enabled[button_id] end,
                callback = function()
                    enabled[button_id] = not enabled[button_id]
                    saveConfig()
                end,
            })
        end
    end
    return {
        text = title,
        sub_item_table = items,
    }
end

local function buildSettingsMenu()
    return {
        text = _("Rounded top menu and quick settings"),
        sub_item_table = {
            makeButtonSettings(_("Reader buttons"), config.reader_order, config.reader_buttons),
            makeButtonSettings(_("File browser buttons"), config.filemanager_order, config.filemanager_buttons),
            {
                text = _("Show frontlight slider"),
                checked_func = function() return config.show_frontlight end,
                callback = function()
                    config.show_frontlight = not config.show_frontlight
                    saveConfig()
                end,
            },
            {
                text = _("Show warmth slider"),
                checked_func = function() return config.show_warmth end,
                callback = function()
                    config.show_warmth = not config.show_warmth
                    saveConfig()
                end,
                separator = true,
            },
            {
                text = _("Always open on quick settings"),
                checked_func = function() return config.open_on_start end,
                callback = function()
                    config.open_on_start = not config.open_on_start
                    saveConfig()
                end,
            },
        },
    }
end

-- Expose the configuration menu to Burrow's consolidated Settings screen.
Module.getSettingsMenu = buildSettingsMenu

local function addTabOnce(tab_table)
    for _, tab in ipairs(tab_table or {}) do
        if tab._rounded_quick_settings then return end
    end
    table.insert(tab_table, 1, quick_settings_tab)
end

local FileManagerMenu = require("apps/filemanager/filemanagermenu")
local ReaderMenu = require("apps/reader/modules/readermenu")

local original_fm_setUpdateItemTable = FileManagerMenu.setUpdateItemTable
function FileManagerMenu:setUpdateItemTable()
    original_fm_setUpdateItemTable(self)
    if self.tab_item_table then addTabOnce(self.tab_item_table) end
end

-- Keep Burrow's reader-toolbar glyphs scoped to the Reader menu instead of
-- overwriting KOReader's global appbar icon names. Reuse the same light,
-- rounded 1.8-stroke family as Reader Controls so a fresh Burrow install
-- has one coherent visual language while unrelated KOReader screens keep
-- their own theme/user icons.
local reader_tab_icon_map = {
    ["appbar.navigation"] = "quick_toc",
    ["appbar.typeset"] = "quick_text",
    ["appbar.settings"] = "burrow.reader.settings",
    ["appbar.tools"] = "burrow.reader.tools",
    ["appbar.search"] = "quick_search",
    ["appbar.filebrowser"] = "quick_library",
    ["appbar.menu"] = "quick_more",
}

local function applyReaderTabIcons(tab_table)
    for _, tab in ipairs(tab_table or {}) do
        local replacement = reader_tab_icon_map[tab.icon]
        if replacement then tab.icon = replacement end
    end
end

local original_reader_setUpdateItemTable = ReaderMenu.setUpdateItemTable
function ReaderMenu:setUpdateItemTable()
    original_reader_setUpdateItemTable(self)
    if self.tab_item_table then
        applyReaderTabIcons(self.tab_item_table)
        addTabOnce(self.tab_item_table)
    end
end

    Module.applied = true
    return true
end

return Module

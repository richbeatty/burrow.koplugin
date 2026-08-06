local MODULE_KEY = "burrow.internal.2_a_burrow_simple_topbar"
local existing_module = package.loaded[MODULE_KEY]
if existing_module then return existing_module end
local Module = { key = MODULE_KEY, phase = "instance", filename = "2-a-burrow-simple-topbar.lua" }
package.loaded[MODULE_KEY] = Module

--[[
    Burrow Flexible Top Bar

    Adds settings at:
        Burrow settings > Top bar

    Every toolbar element can be shown or hidden independently:
        Home, Favorites, History, Burrow logo,
        Last document, Up folder, Menu

    A dedicated logo-only mode places the Burrow bird in the
    top-right corner and lowers it slightly for better visual balance.

    The complete icon row can also be reduced from 100% to 50% size.
    When every element is hidden, the top bar collapses to zero height.

    Keep this filename beginning with "2-a-" so it loads before the
    Burrow Hero Card patch.
--]]

local logger = require("logger")

local function patchBurrowTopBar(plugin)
    local BookInfoManager = require("bookinfomanager")
    local CenterContainer = require("ui/widget/container/centercontainer")
    local CoverMenu = require("covermenu")
    local Device = require("device")
    local Geom = require("ui/geometry")
    local HorizontalGroup = require("ui/widget/horizontalgroup")
    local HorizontalSpan = require("ui/widget/horizontalspan")
    local IconButton = require("ui/widget/iconbutton")
    local LeftContainer = require("ui/widget/container/leftcontainer")
    local OverlapGroup = require("ui/widget/overlapgroup")
    local Widget = require("ui/widget/widget")
    local Screen = Device.screen
    local UIManager = require("ui/uimanager")
    local _ = require("l10n.gettext")
    local T = require("ffi/util").template

    local SETTING_HOME = "burrow_topbar_show_home"
    local SETTING_FAVORITES = "burrow_topbar_show_favorites"
    local SETTING_HISTORY = "burrow_topbar_show_history"
    local SETTING_LOGO = "burrow_topbar_show_logo"
    local SETTING_LAST_DOCUMENT = "burrow_topbar_show_last_document"
    local SETTING_UP = "burrow_topbar_show_up"
    local SETTING_MENU = "burrow_topbar_show_menu"
    local SETTING_SIZE = "burrow_topbar_size_percent"
    local SETTING_LOGO_ONLY_RIGHT = "burrow_topbar_logo_only_right"

    local DEFAULT_SIZE = 100
    local MIN_SIZE = 50
    local MAX_SIZE = 100

    local defaults = {
        [SETTING_HOME] = true,
        [SETTING_FAVORITES] = false,
        [SETTING_HISTORY] = true,
        [SETTING_LOGO] = true,
        [SETTING_LAST_DOCUMENT] = false,
        [SETTING_UP] = true,
        [SETTING_MENU] = true,
        [SETTING_LOGO_ONLY_RIGHT] = false,
    }

    local function enabled(key)
        local value = BookInfoManager:getSetting(key)
        if value == nil then return defaults[key] end
        return tonumber(value) == 1
    end

    local function saveEnabled(key, value)
        BookInfoManager:saveSetting(key, value and 1 or 0)
    end

    local function normalizeSize(value)
        value = tonumber(value) or DEFAULT_SIZE
        value = math.floor(value + 0.5)
        if value < MIN_SIZE then value = MIN_SIZE end
        if value > MAX_SIZE then value = MAX_SIZE end
        return value
    end

    local function getSizePercent()
        return normalizeSize(BookInfoManager:getSetting(SETTING_SIZE))
    end

    local function findUpvalueIndex(func, wanted_name)
        local index = 1
        while true do
            local name = debug.getupvalue(func, index)
            if not name then return nil end
            if name == wanted_name then return index end
            index = index + 1
        end
    end

    if not CoverMenu._flexible_topbar_patch_applied then
        local titlebar_index = findUpvalueIndex(CoverMenu.setupLayout, "TitleBar")

        if titlebar_index then
            local DGENERIC_ICON_SIZE = G_defaults:readSetting("DGENERIC_ICON_SIZE") or 44

            local FlexibleTitleBar = OverlapGroup:extend {
                left1_icon = nil,
                left1_icon_tap_callback = function() end,
                left1_icon_hold_callback = function() end,
                left2_icon = nil,
                left2_icon_tap_callback = function() end,
                left2_icon_hold_callback = function() end,
                left3_icon = nil,
                left3_icon_tap_callback = function() end,
                left3_icon_hold_callback = function() end,
                center_icon = nil,
                center_icon_tap_callback = function() end,
                center_icon_hold_callback = function() end,
                right3_icon = nil,
                right3_icon_tap_callback = function() end,
                right3_icon_hold_callback = function() end,
                right2_icon = nil,
                right2_icon_tap_callback = function() end,
                right2_icon_hold_callback = function() end,
                right1_icon = nil,
                right1_icon_tap_callback = function() end,
                right1_icon_hold_callback = function() end,
                show_parent = nil,
                title = "",
                subtitle = "",
                fullscreen = "true",
                align = "center",
            }

            local function makeButton(self, icon, tap_callback, hold_callback, size, center)
                return IconButton:new {
                    icon = icon,
                    width = size,
                    height = size,
                    padding = 0,
                    padding_top = center and 0 or self.icon_padding_top,
                    padding_bottom = center and 0 or self.icon_padding_bottom,
                    overlap_align = center and "center" or nil,
                    callback = tap_callback,
                    hold_callback = hold_callback,
                    show_parent = self.show_parent,
                }
            end

            local function placeAtSide(self, button, from_left, slot)
                local offset = self.outer_margin
                    + (slot - 1) * (self.icon_size + self.icon_gap)
                local before
                local after
                if from_left then
                    before = offset
                    after = self.width - offset - button:getSize().w
                else
                    before = self.width - offset - button:getSize().w
                    after = offset
                end
                return LeftContainer:new {
                    dimen = self.dimen,
                    HorizontalGroup:new {
                        HorizontalSpan:new { width = math.max(0, before) },
                        button,
                        HorizontalSpan:new { width = math.max(0, after) },
                    },
                }
            end

            local function add(container, child)
                if child then table.insert(container, child) end
            end

            function FlexibleTitleBar:init()
                self.width = Screen:getWidth()

                local size_percent = getSizePercent()
                local size_scale = size_percent / 100
                local function scaledBase(value)
                    return Screen:scaleBySize(math.max(0, math.floor(value * size_scale + 0.5)))
                end

                self.icon_size = scaledBase(DGENERIC_ICON_SIZE)
                self.center_icon_size_ratio = 1.12
                self.icon_padding_top = scaledBase(4)
                self.icon_padding_bottom = scaledBase(4)
                self.icon_gap = scaledBase(27)
                self.outer_margin = scaledBase(18)

                local logo_only_right = enabled(SETTING_LOGO_ONLY_RIGHT)
                local show_home = not logo_only_right and enabled(SETTING_HOME)
                local show_favorites = not logo_only_right and enabled(SETTING_FAVORITES)
                local show_history = not logo_only_right and enabled(SETTING_HISTORY)
                local show_logo = logo_only_right or enabled(SETTING_LOGO)
                local show_last_document = not logo_only_right and enabled(SETTING_LAST_DOCUMENT)
                local show_up = not logo_only_right and enabled(SETTING_UP)
                local show_menu = not logo_only_right and enabled(SETTING_MENU)
                local has_any_button = show_home or show_favorites or show_history
                    or show_logo or show_last_document or show_up or show_menu
                local logo_bottom_clearance = logo_only_right and scaledBase(12) or 0

                self.titlebar_height = has_any_button
                    and (self.icon_size + self.icon_padding_top + self.icon_padding_bottom
                        + logo_bottom_clearance)
                    or 0
                self.dimen = Geom:new {
                    x = 0,
                    y = 0,
                    w = self.width,
                    h = self.titlebar_height,
                }

                if not has_any_button then
                    table.insert(self, Widget:new { dimen = self.dimen })
                    OverlapGroup.init(self)
                    return
                end

                local left_slot = 1
                if show_home and self.left1_icon then
                    self.left1_button = makeButton(self,
                        self.left1_icon,
                        self.left1_icon_tap_callback,
                        self.left1_icon_hold_callback,
                        self.icon_size,
                        false)
                    self.left1_button_container = placeAtSide(self, self.left1_button, true, left_slot)
                    left_slot = left_slot + 1
                end

                if show_favorites and self.left2_icon then
                    self.left2_button = makeButton(self,
                        self.left2_icon,
                        self.left2_icon_tap_callback,
                        self.left2_icon_hold_callback,
                        self.icon_size,
                        false)
                    self.left2_button_container = placeAtSide(self, self.left2_button, true, left_slot)
                    left_slot = left_slot + 1
                end

                if show_history and self.left3_icon then
                    self.left3_button = makeButton(self,
                        self.left3_icon,
                        self.left3_icon_tap_callback,
                        self.left3_icon_hold_callback,
                        self.icon_size,
                        false)
                    self.left3_button_container = placeAtSide(self, self.left3_button, true, left_slot)
                end

                if show_logo and self.center_icon then
                    self.center_icon_size = math.ceil(self.icon_size * self.center_icon_size_ratio)
                    self.center_button = makeButton(self,
                        self.center_icon,
                        self.center_icon_tap_callback,
                        self.center_icon_hold_callback,
                        self.center_icon_size,
                        true)

                    if logo_only_right then
                        -- Dedicated minimal mode: only the badger remains. Keep
                        -- the icon in the upper portion of the bar and reserve
                        -- clear space below it before the first row of covers.
                        local logo_right_margin = scaledBase(10)
                        local before = math.max(0,
                            self.width - logo_right_margin - self.center_button:getSize().w)
                        local after = math.max(0, logo_right_margin)
                        local logo_area = Geom:new {
                            x = 0,
                            y = 0,
                            w = self.width,
                            h = math.max(1, self.titlebar_height - logo_bottom_clearance),
                        }
                        self.center_button_container = LeftContainer:new {
                            dimen = logo_area,
                            HorizontalGroup:new {
                                HorizontalSpan:new { width = before },
                                self.center_button,
                                HorizontalSpan:new { width = after },
                            },
                        }
                        self.center_button_container.overlap_offset = { 0, scaledBase(2) }
                    else
                        -- Keep the bird vertically centered when used as the
                        -- normal middle button, including reduced bar sizes.
                        self.center_button_container = CenterContainer:new {
                            dimen = self.dimen,
                            self.center_button,
                        }
                    end
                end

                local right_slot = 1
                if show_menu and self.right1_icon then
                    self.right1_button = makeButton(self,
                        self.right1_icon,
                        self.right1_icon_tap_callback,
                        self.right1_icon_hold_callback,
                        self.icon_size,
                        false)
                    self.right1_button_container = placeAtSide(self, self.right1_button, false, right_slot)
                    right_slot = right_slot + 1
                end

                if show_up and self.right2_icon then
                    self.right2_button = makeButton(self,
                        self.right2_icon,
                        self.right2_icon_tap_callback,
                        self.right2_icon_hold_callback,
                        self.icon_size,
                        false)
                    self.right2_button_container = placeAtSide(self, self.right2_button, false, right_slot)
                    right_slot = right_slot + 1
                end

                if show_last_document and self.right3_icon then
                    self.right3_button = makeButton(self,
                        self.right3_icon,
                        self.right3_icon_tap_callback,
                        self.right3_icon_hold_callback,
                        self.icon_size,
                        false)
                    self.right3_button_container = placeAtSide(self, self.right3_button, false, right_slot)
                end

                add(self, self.center_button_container)
                add(self, self.left1_button_container)
                add(self, self.left2_button_container)
                add(self, self.left3_button_container)
                add(self, self.right3_button_container)
                add(self, self.right2_button_container)
                add(self, self.right1_button_container)

                self.left_button = self.left1_button or self.left2_button or self.left3_button
                if logo_only_right then
                    self.right_button = self.center_button
                else
                    self.right_button = self.right1_button or self.right2_button or self.right3_button
                end

                OverlapGroup.init(self)
            end

            function FlexibleTitleBar:paintTo(bb, x, y)
                self.dimen.x = x
                self.dimen.y = y
                OverlapGroup.paintTo(self, bb, x, y)
            end

            function FlexibleTitleBar:getHeight()
                return self.titlebar_height
            end

            function FlexibleTitleBar:setTitle(title, no_refresh)
                self.title = ""
            end

            function FlexibleTitleBar:setSubTitle(subtitle, no_refresh)
                self.subtitle = ""
            end

            function FlexibleTitleBar:setLeftIcon(icon)
                -- Keep Burrow's fixed icon assignments.
            end

            function FlexibleTitleBar:setRightIcon(icon)
                -- Keep Burrow's fixed icon assignments.
            end

            function FlexibleTitleBar:generateHorizontalLayout()
                local row = {}
                add(row, self.left1_button)
                add(row, self.left2_button)
                add(row, self.left3_button)
                add(row, self.center_button)
                add(row, self.right3_button)
                add(row, self.right2_button)
                add(row, self.right1_button)
                return #row > 0 and { row } or {}
            end

            function FlexibleTitleBar:generateVerticalLayout()
                local layout = {}
                local function addRow(button)
                    if button then table.insert(layout, { button }) end
                end
                addRow(self.left1_button)
                addRow(self.left2_button)
                addRow(self.left3_button)
                addRow(self.center_button)
                addRow(self.right3_button)
                addRow(self.right2_button)
                addRow(self.right1_button)
                return layout
            end

            debug.setupvalue(CoverMenu.setupLayout, titlebar_index, FlexibleTitleBar)
            -- Expose the exact configured class so embedded Burrow screens can
            -- use the same icon visibility, sizing, and logo-only mode.
            CoverMenu._burrow_flexible_titlebar_class = FlexibleTitleBar
            plugin._burrow_flexible_titlebar_class = FlexibleTitleBar
            CoverMenu._flexible_topbar_patch_applied = true
            logger.info("Burrow flexible top bar installed")
        else
            logger.warn("Burrow flexible top bar: TitleBar upvalue not found")
        end
    end

    if plugin._flexible_topbar_menu_patched then return end
    plugin._flexible_topbar_menu_patched = true

    local original_add_to_main_menu = plugin.addToMainMenu

    function plugin:addToMainMenu(menu_items)
        original_add_to_main_menu(self, menu_items)

        local root = menu_items.filemanager_display_mode
        local items = root and root.sub_item_table
        if not items then return end

        local function toggleItem(text, key, normal_mode_only)
            return {
                text = text,
                checked_func = function() return enabled(key) end,
                enabled_func = normal_mode_only and function()
                    return not enabled(SETTING_LOGO_ONLY_RIGHT)
                end or nil,
                callback = function()
                    saveEnabled(key, not enabled(key))
                    UIManager:askForRestart()
                end,
            }
        end

        local size_item = {
            text_func = function()
                return T(_("Top bar size: %1"), getSizePercent()) .. "%"
            end,
            callback = function()
                local SpinWidget = require("ui/widget/spinwidget")
                UIManager:show(SpinWidget:new {
                    value = getSizePercent(),
                    default_value = DEFAULT_SIZE,
                    value_min = MIN_SIZE,
                    value_max = MAX_SIZE,
                    value_step = 5,
                    value_hold_step = 10,
                    title_text = _("Top bar size"),
                    info_text = _("Scales the icons, spacing, padding, and total height of the Burrow top bar."),
                    ok_text = _("Set size"),
                    extra_text = _("Reset"),
                    extra_callback = function()
                        BookInfoManager:saveSetting(SETTING_SIZE, DEFAULT_SIZE)
                        UIManager:askForRestart()
                    end,
                    callback = function(spin)
                        BookInfoManager:saveSetting(SETTING_SIZE, normalizeSize(spin.value))
                        UIManager:askForRestart()
                    end,
                })
            end,
        }

        local reset_item = {
            text = _("Restore default top bar"),
            callback = function()
                for key, value in pairs(defaults) do
                    saveEnabled(key, value)
                end
                BookInfoManager:saveSetting(SETTING_SIZE, DEFAULT_SIZE)
                UIManager:askForRestart()
            end,
        }

        local logo_only_item = {
            text = _("Logo only in top-right corner"),
            checked_func = function() return enabled(SETTING_LOGO_ONLY_RIGHT) end,
            callback = function()
                saveEnabled(SETTING_LOGO_ONLY_RIGHT,
                    not enabled(SETTING_LOGO_ONLY_RIGHT))
                UIManager:askForRestart()
            end,
            separator = true,
        }

        local section = {
            text = _("Top bar"),
            sub_item_table = {
                size_item,
                logo_only_item,
                toggleItem(_("Show Home"), SETTING_HOME, true),
                toggleItem(_("Show Favorites"), SETTING_FAVORITES, true),
                toggleItem(_("Show History"), SETTING_HISTORY, true),
                toggleItem(_("Show Burrow logo"), SETTING_LOGO, true),
                toggleItem(_("Show Last document"), SETTING_LAST_DOCUMENT, true),
                toggleItem(_("Show Up folder"), SETTING_UP, true),
                toggleItem(_("Show Menu"), SETTING_MENU, true),
                reset_item,
            },
        }

        local insert_at = #items + 1
        for i, item in ipairs(items) do
            if item.text == _("Advanced settings") then
                insert_at = i
                break
            end
        end
        table.insert(items, insert_at, section)
    end
end

Module.apply = patchBurrowTopBar
return Module

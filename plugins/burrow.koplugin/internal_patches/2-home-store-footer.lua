local MODULE_KEY = "burrow.internal.2_home_store_footer"
local existing_module = package.loaded[MODULE_KEY]
if existing_module then return existing_module end
local Module = { key = MODULE_KEY, phase = "instance", filename = "2-home-store-footer.lua" }
package.loaded[MODULE_KEY] = Module

--[[
    Burrow Home / Store navigation

    Adds a simple text-only Home and Store navigation bar with page indicators.
    two-tab navigation bar on the Burrow HOME folder:

      Home  - the existing Burrow HOME folder
      Store - the selected Store catalog

    The normal first / previous / next / last arrows and page text are replaced
    by page indicators above a divider line. The current page is shown as a wider
    pill, while the remaining pages stay as small dots. Horizontal page swiping
    remains handled by KOReader / Burrow.

    Tap Store to open the saved catalog. Hold Store to choose another Burrow Store
    catalog. Existing selections are migrated automatically.

    The Home and Store label size is adjustable from the Burrow display
    settings. The original Burrow footer is restored automatically outside the HOME
    folder. This patch never attaches the same widget to two live container trees.
--]]


local SETTINGS_URL = "burrow_store_catalog_url"
local SETTINGS_TITLE = "burrow_store_catalog_title"
local SETTINGS_LABEL_SIZE = "burrow_home_store_label_size_percent"
local SETTINGS_SHOW_LABELS = "burrow_home_store_show_labels"
local SETTINGS_AUTO_HIDE_LABELS = "burrow_home_store_auto_hide_without_catalogs"

local DEFAULT_LABEL_SIZE = 100
local MIN_LABEL_SIZE = 10
local MAX_LABEL_SIZE = 100
local DEFAULT_SHOW_LABELS = true
local DEFAULT_AUTO_HIDE_LABELS = false

local function patchBurrowFooter(plugin)
    local Blitbuffer = require("ffi/blitbuffer")
    local ButtonDialog = require("ui/widget/buttondialog")
    local CenterContainer = require("ui/widget/container/centercontainer")
    local Font = require("ui/font")
    local FrameContainer = require("ui/widget/container/framecontainer")
    local Geom = require("ui/geometry")
    local GestureRange = require("ui/gesturerange")
    local HorizontalGroup = require("ui/widget/horizontalgroup")
    local HorizontalSpan = require("ui/widget/horizontalspan")
    local InfoMessage = require("ui/widget/infomessage")
    local LineWidget = require("ui/widget/linewidget")
    local InputContainer = require("ui/widget/container/inputcontainer")
    local Menu = require("ui/widget/menu")
    local PluginLoader = require("pluginloader")
    local Screen = require("device").screen
    local TextWidget = require("ui/widget/textwidget")
    local UIManager = require("ui/uimanager")
    local VerticalGroup = require("ui/widget/verticalgroup")
    local VerticalSpan = require("ui/widget/verticalspan")
    local Widget = require("ui/widget/widget")
    local CoverMenu = require("covermenu")

    if CoverMenu._home_store_tabs_patched then
        return
    end
    CoverMenu._home_store_tabs_patched = true

    local function normalizeLabelSize(value)
        value = tonumber(value) or DEFAULT_LABEL_SIZE
        value = math.floor(value + 0.5)
        return math.max(MIN_LABEL_SIZE, math.min(MAX_LABEL_SIZE, value))
    end

    local function getLabelSize()
        return normalizeLabelSize(G_reader_settings:readSetting(SETTINGS_LABEL_SIZE, DEFAULT_LABEL_SIZE))
    end

    local function getShowLabels()
        local value = G_reader_settings:readSetting(SETTINGS_SHOW_LABELS)
        if value == nil then
            return DEFAULT_SHOW_LABELS
        end
        return value == true
    end

    local function getAutoHideLabels()
        local value = G_reader_settings:readSetting(SETTINGS_AUTO_HIDE_LABELS)
        if value == nil then
            return DEFAULT_AUTO_HIDE_LABELS
        end
        return value == true
    end

    if not plugin._home_store_label_size_menu_patched then
        plugin._home_store_label_size_menu_patched = true
        local original_add_to_main_menu = plugin.addToMainMenu

        function plugin:addToMainMenu(menu_items)
            original_add_to_main_menu(self, menu_items)

            local root = menu_items.filemanager_display_mode
            local items = root and root.sub_item_table
            if not items then
                return
            end

            local _ = require("gettext")
            local T = require("ffi/util").template
            local setting_items = {
                {
                    text = _("Show Home and Store labels"),
                    help_text = _("When disabled, Burrow keeps the page indicators but removes the Home and Store labels from the home-folder footer."),
                    checked_func = getShowLabels,
                    callback = function()
                        G_reader_settings:saveSetting(SETTINGS_SHOW_LABELS, not getShowLabels())
                        UIManager:askForRestart()
                    end,
                },
                {
                    text = _("Hide labels when no Store catalogs are configured"),
                    help_text = _("Automatically leaves only the page indicators when the embedded Store has no catalogs."),
                    enabled_func = getShowLabels,
                    checked_func = getAutoHideLabels,
                    callback = function()
                        G_reader_settings:saveSetting(SETTINGS_AUTO_HIDE_LABELS, not getAutoHideLabels())
                        UIManager:askForRestart()
                    end,
                },
                {
                    text_func = function()
                        return T(_("Home and Store label size: %1"), getLabelSize()) .. "%"
                    end,
                    enabled_func = getShowLabels,
                    callback = function()
                        local SpinWidget = require("ui/widget/spinwidget")
                        UIManager:show(SpinWidget:new {
                            title_text = _("Home and Store label size"),
                            info_text = _("Adjusts the text size of the Home and Store tabs in the Burrow home-folder footer. Restart KOReader after saving."),
                            value = getLabelSize(),
                            default_value = DEFAULT_LABEL_SIZE,
                            value_min = MIN_LABEL_SIZE,
                            value_max = MAX_LABEL_SIZE,
                            value_step = 5,
                            value_hold_step = 10,
                            unit = "%",
                            ok_text = _("Save"),
                            callback = function(spin)
                                G_reader_settings:saveSetting(SETTINGS_LABEL_SIZE, normalizeLabelSize(spin.value))
                                UIManager:askForRestart()
                            end,
                        })
                    end,
                },
            }

            local insert_at = #items + 1
            for index, item in ipairs(items) do
                if item.text == _("Advanced settings") then
                    insert_at = index
                    break
                end
            end
            for offset, setting_item in ipairs(setting_items) do
                table.insert(items, insert_at + offset - 1, setting_item)
            end
        end
    end

    local original_menu_init = CoverMenu.menuInit
    local original_update_page_info = CoverMenu.updatePageInfo
    local menu_was_using_covermenu_init = Menu.init == original_menu_init
    local menu_was_using_covermenu_update = Menu.updatePageInfo == original_update_page_info

    local function normalizePath(path)
        if type(path) ~= "string" then
            return nil
        end
        path = path:gsub("/+$", "")
        return path ~= "" and path or "/"
    end

    local function isHomeFolder(menu)
        if not menu or not menu.path_items then
            return false
        end
        local home = normalizePath(G_reader_settings:readSetting("home_dir"))
        local current = normalizePath(menu.path)
        return home ~= nil and current == home
    end

    local function getBurrowStore()
        local instance = PluginLoader:getPluginInstance("burrow")
        if instance and instance.store then
            return instance.store
        end

        if plugin and plugin._burrow_instance and plugin._burrow_instance.store then
            return plugin._burrow_instance.store
        end

        return nil
    end

    local function getCatalogs()
        local store = getBurrowStore()
        if not store then
            return nil, nil
        end
        return store, store.servers or {}
    end

    local function shouldShowNavigationLabels()
        if not getShowLabels() then
            return false
        end
        if getAutoHideLabels() then
            local _, servers = getCatalogs()
            return servers ~= nil and #servers > 0
        end
        return true
    end

    local function findSelectedCatalog(servers)
        local saved_url = G_reader_settings:readSetting(SETTINGS_URL)
        local saved_title = G_reader_settings:readSetting(SETTINGS_TITLE)

        for index, server in ipairs(servers) do
            if saved_url and server.url == saved_url then
                return index, server
            end
        end
        for index, server in ipairs(servers) do
            if saved_title and server.title == saved_title then
                return index, server
            end
        end
        return nil, nil
    end

    local function saveSelectedCatalog(server)
        G_reader_settings:saveSetting(SETTINGS_URL, server.url)
        G_reader_settings:saveSetting(SETTINGS_TITLE, server.title)
    end

    local function clearSelectedCatalog()
        G_reader_settings:delSetting(SETTINGS_URL)
        G_reader_settings:delSetting(SETTINGS_TITLE)
    end

    local function showPluginUnavailable()
        UIManager:show(InfoMessage:new {
            text = "Burrow Store is unavailable.",
        })
    end

    local function findBrowserCatalogItem(browser, server, server_index)
        if not browser or not browser.item_table then
            return nil
        end

        for _, item in ipairs(browser.item_table) do
            if server.url and item.url == server.url then
                return item
            end
        end
        for _, item in ipairs(browser.item_table) do
            if server.title and item.text == server.title then
                return item
            end
        end
        return browser.item_table[server_index + 1]
    end

    local function openCatalog(menu, server_index, server)
        local store, servers = getCatalogs()
        if not store then
            showPluginUnavailable()
            return
        end

        if not server then
            server_index, server = findSelectedCatalog(servers)
        end
        if not server then
            clearSelectedCatalog()
            if menu and menu._show_home_store_catalog_chooser then
                menu:_show_home_store_catalog_chooser()
            end
            return
        end

        saveSelectedCatalog(server)
        store:onShowOPDSCatalog()

        UIManager:nextTick(function()
            local browser = store.opds_browser
            local item = findBrowserCatalogItem(browser, server, server_index)
            if not item then
                return
            end
            item.idx = item.idx or server_index + 1
            browser:onMenuSelect(item)
        end)
    end

    local function makeCatalogChooser(menu)
        local store, servers = getCatalogs()
        if not store then
            showPluginUnavailable()
            return
        end
        if #servers == 0 then
            UIManager:show(InfoMessage:new {
                text = "No Store catalogs are configured.",
            })
            return
        end

        local dialog
        local rows = {}
        for index, server in ipairs(servers) do
            local catalog_index = index
            local catalog = server
            table.insert(rows, {
                {
                    text = catalog.title or catalog.url or "Store catalog",
                    callback = function()
                        UIManager:close(dialog)
                        saveSelectedCatalog(catalog)
                        openCatalog(menu, catalog_index, catalog)
                    end,
                },
            })
        end

        dialog = ButtonDialog:new {
            title = "Choose Store catalog",
            title_align = "center",
            buttons = rows,
        }
        UIManager:show(dialog)
    end

    local TabIndicator = Widget:extend {
        width = nil,
        height = nil,
        active = false,
    }

    function TabIndicator:getSize()
        return Geom:new {
            w = self.width,
            h = self.height,
        }
    end

    function TabIndicator:paintTo(bb, x, y)
        local size = self:getSize()
        if not self.dimen then
            self.dimen = Geom:new {
                x = x,
                y = y,
                w = size.w,
                h = size.h,
            }
        else
            self.dimen.x = x
            self.dimen.y = y
            self.dimen.w = size.w
            self.dimen.h = size.h
        end

        if self.active then
            bb:paintRoundedRect(
                x,
                y,
                self.width,
                self.height,
                Blitbuffer.COLOR_BLACK,
                math.floor(self.height / 2)
            )
        end
    end

    local NavTab = InputContainer:extend {
        width = nil,
        height = nil,
        label = nil,
        active = false,
        callback = nil,
        hold_callback = nil,
    }

    function NavTab:init()
        local indicator_height = math.max(2, Screen:scaleBySize(2))
        local indicator_width = math.max(
            Screen:scaleBySize(30),
            math.floor(self.width * 0.24)
        )
        local base_label_size = math.max(14, math.floor(self.height * 0.42))
        local label_size = math.max(8, math.floor(base_label_size * getLabelSize() / 100 + 0.5))
        local label_gap = math.max(2, math.floor(self.height * 0.08))

        local label = TextWidget:new {
            text = self.label,
            face = Font:getFace("smallinfofont", label_size),
            bold = false,
        }
        local indicator = TabIndicator:new {
            width = indicator_width,
            height = indicator_height,
            active = self.active,
        }
        local contents = VerticalGroup:new {
            align = "center",
            label,
            VerticalSpan:new { width = label_gap },
            indicator,
        }

        self[1] = CenterContainer:new {
            dimen = Geom:new {
                w = self.width,
                h = self.height,
            },
            contents,
        }
        self.dimen = self[1]:getSize()
        self.ges_events = {
            TapHomeStoreTab = {
                GestureRange:new {
                    ges = "tap",
                    range = self.dimen,
                },
            },
            HoldHomeStoreTab = {
                GestureRange:new {
                    ges = "hold",
                    range = self.dimen,
                },
            },
        }
    end

    function NavTab:onTapHomeStoreTab()
        if self.callback then
            self.callback()
        end
        return true
    end

    function NavTab:onHoldHomeStoreTab()
        if self.hold_callback then
            self.hold_callback()
            return true
        end
        return false
    end

    local PageDots = Widget:extend {
        page = 1,
        page_num = 1,
        dot_size = nil,
        active_width = nil,
        gap = nil,
        height = nil,
        max_visible = 9,
    }

    function PageDots:_visiblePages()
        local total = math.max(1, tonumber(self.page_num) or 1)
        local current = math.max(1, math.min(total, tonumber(self.page) or 1))
        local count = math.min(total, self.max_visible)
        local first = 1
        if total > count then
            first = math.max(1, math.min(current - math.floor(count / 2), total - count + 1))
        end
        local pages = {}
        for value = first, first + count - 1 do
            table.insert(pages, value)
        end
        return pages, current
    end

    function PageDots:getSize()
        local pages, current = self:_visiblePages()
        local width = 0
        for index, page in ipairs(pages) do
            width = width + (page == current and self.active_width or self.dot_size)
            if index < #pages then
                width = width + self.gap
            end
        end
        return Geom:new {
            w = math.max(1, width),
            h = self.height,
        }
    end

    function PageDots:setPage(page, page_num)
        self.page = page or 1
        self.page_num = page_num or 1
        self.dimen = nil
    end

    function PageDots:paintTo(bb, x, y)
        local size = self:getSize()
        if not self.dimen then
            self.dimen = Geom:new {
                x = x,
                y = y,
                w = size.w,
                h = size.h,
            }
        else
            self.dimen.x = x
            self.dimen.y = y
            self.dimen.w = size.w
            self.dimen.h = size.h
        end

        local pages, current = self:_visiblePages()
        local offset = 0
        local dot_y = y + math.floor((self.height - self.dot_size) / 2)
        for index, page in ipairs(pages) do
            local width = page == current and self.active_width or self.dot_size
            local color = page == current
                and Blitbuffer.COLOR_BLACK
                or Blitbuffer.COLOR_LIGHT_GRAY
            bb:paintRoundedRect(
                x + offset,
                dot_y,
                width,
                self.dot_size,
                color,
                math.floor(self.dot_size / 2)
            )
            offset = offset + width
            if index < #pages then
                offset = offset + self.gap
            end
        end
    end

    local function buildHomeFooter(menu, footer_height)
        local show_labels = shouldShowNavigationLabels()
        local line_height = math.max(1, Screen:scaleBySize(1))
        local dots_height = show_labels
            and math.max(6, math.floor(footer_height * 0.22))
            or footer_height
        local gap_above_line = math.max(1, math.floor(footer_height * 0.03))
        local gap_below_line = math.max(1, math.floor(footer_height * 0.04))
        local nav_height = math.max(
            20,
            footer_height - dots_height - line_height - gap_above_line - gap_below_line
        )

        local dot_size = show_labels
            and math.max(3, math.floor(dots_height * 0.42))
            or math.max(3, math.floor(footer_height * 0.18))
        local dots = PageDots:new {
            page = menu.page or 1,
            page_num = menu.page_num or 1,
            dot_size = dot_size,
            active_width = math.max(dot_size * 2, math.floor(dot_size * 2.5)),
            gap = math.max(5, math.floor(dot_size * 1.6)),
            height = dots_height,
        }

        if not show_labels then
            local root = VerticalGroup:new {
                align = "center",
                dots,
            }
            return root, dots
        end

        local nav_width = math.floor(menu.screen_w * 0.88)
        local tab_width = math.max(1, math.floor(nav_width / 2))

        local home_tab = NavTab:new {
            width = tab_width,
            height = nav_height,
            label = "Home",
            active = true,
            callback = function()
                if menu.onHome then
                    menu:onHome()
                end
            end,
        }

        local store_tab = NavTab:new {
            width = tab_width,
            height = nav_height,
            label = "Store",
            active = false,
            callback = function()
                local _, servers = getCatalogs()
                if not servers then
                    showPluginUnavailable()
                    return
                end
                local index, server = findSelectedCatalog(servers)
                if server then
                    openCatalog(menu, index, server)
                else
                    makeCatalogChooser(menu)
                end
            end,
            hold_callback = function()
                makeCatalogChooser(menu)
            end,
        }

        local nav = HorizontalGroup:new {
            home_tab,
            store_tab,
        }

        local divider = LineWidget:new {
            background = Blitbuffer.COLOR_LIGHT_GRAY,
            dimen = Geom:new {
                w = math.floor(menu.screen_w * 0.94),
                h = line_height,
            },
        }

        local root = VerticalGroup:new {
            align = "center",
            dots,
            VerticalSpan:new { width = gap_above_line },
            divider,
            VerticalSpan:new { width = gap_below_line },
            nav,
        }

        return root, dots
    end

    local function activateHomeFooter(menu)
        if menu._home_store_active then
            return
        end
        local state = menu._home_store_state
        if not state then
            return
        end

        state.page_controls[1] = state.custom_container
        state.footer[5] = state.empty_footer_line
        menu.page_info = state.custom_root
        menu._home_store_active = true

        if menu.cur_folder_text then
            menu.cur_folder_text:setText("")
            menu.cur_folder_text:setMaxWidth(0)
        end
        if state.page_controls.resetLayout then
            state.page_controls:resetLayout()
        end
        if menu.page_info.resetLayout then
            menu.page_info:resetLayout()
        end
    end

    local function restoreOriginalFooter(menu)
        if not menu._home_store_active then
            return
        end
        local state = menu._home_store_state
        if not state then
            return
        end

        state.page_controls[1] = state.original_page_controls_child
        state.footer[5] = state.original_footer_line
        menu.page_info = state.original_page_info
        menu._home_store_active = false

        if state.page_controls.resetLayout then
            state.page_controls:resetLayout()
        end
        if menu.page_info.resetLayout then
            menu.page_info:resetLayout()
        end
    end

    function CoverMenu:menuInit(...)
        original_menu_init(self, ...)

        if not self.path_items then
            return
        end

        local footer_frame = self[1]
        local footer = footer_frame and footer_frame[1]
        local page_controls = footer and footer[4]
        if not page_controls or not self.page_info then
            return
        end

        self._show_home_store_catalog_chooser = makeCatalogChooser

        local original_page_info = self.page_info
        local original_page_controls_child = page_controls[1]
        local original_footer_line = footer[5]
        local footer_height = original_page_info:getSize().h
        local custom_root, dots = buildHomeFooter(self, footer_height)
        local custom_container = CenterContainer:new {
            dimen = Geom:new {
                w = self.inner_dimen.w,
                h = footer_height,
            },
            custom_root,
        }

        self._home_store_state = {
            footer = footer,
            page_controls = page_controls,
            original_page_info = original_page_info,
            original_page_controls_child = original_page_controls_child,
            original_footer_line = original_footer_line,
            custom_root = custom_root,
            custom_container = custom_container,
            dots = dots,
            empty_footer_line = HorizontalSpan:new { width = 0 },
        }

        if isHomeFolder(self) then
            activateHomeFooter(self)
        end
    end

    function CoverMenu:updatePageInfo(select_number)
        if self._home_store_state then
            if isHomeFolder(self) then
                activateHomeFooter(self)
            else
                restoreOriginalFooter(self)
            end
        end

        original_update_page_info(self, select_number)

        if self._home_store_active then
            local state = self._home_store_state
            state.dots:setPage(self.page or 1, self.page_num or 1)
            if self.cur_folder_text then
                self.cur_folder_text:setText("")
                self.cur_folder_text:setMaxWidth(0)
            end
        end
    end

    if menu_was_using_covermenu_init then
        Menu.init = CoverMenu.menuInit
    end
    if menu_was_using_covermenu_update then
        Menu.updatePageInfo = CoverMenu.updatePageInfo
    end
end

Module.apply = patchBurrowFooter
return Module

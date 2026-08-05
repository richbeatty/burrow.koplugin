-- Burrow core library runtime.
--
-- This module owns Burrow's guarded library hooks. It is required once per
-- KOReader process, keeps the original KOReader methods in one runtime, and can
-- attach the same method set to a newly sourced Burrow plugin class without
-- wrapping KOReader a second time.

local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local logger = require("logger")
local BurrowVersion = require("burrow_version")
local _ = require("l10n.gettext")
local T = require("ffi/util").template
local burrow_util = require("burrow_util")
local util = require("util")
local burrow_debug = require("burrow_debug")
local BurrowSettings = require("burrow_settings")
local BurrowMigration = require("burrow_migration")
local BurrowLoader = require("burrow_loader")

local LibraryCore = {
    id = "library_core",
    phase = "core",
    critical = true,
}
local Methods = {}
local BurrowClass

local BookStatusWidget = require("ui/widget/bookstatuswidget")
local AltBookStatusWidget = require("altbookstatuswidget")
local BookInfoManager = require("bookinfomanager")
BurrowMigration.migrateSettings(BookInfoManager)
BurrowSettings:applyFirstRunDefaults(BookInfoManager)
local BookList = require("ui/widget/booklist")
local FileChooser = require("ui/widget/filechooser")
local FileManager = require("apps/filemanager/filemanager")
local FileManagerHistory = require("apps/filemanager/filemanagerhistory")
local FileManagerCollection = require("apps/filemanager/filemanagercollection")
local FileManagerFileSearcher = require("apps/filemanager/filemanagerfilesearcher")
local Menu = require("ui/widget/menu")
local Dispatcher = require("dispatcher")
local Trapper = require("ui/trapper")
local FFIUtil = require("ffi/util")
local store_load_error
local EmbeddedStore
local StoreSettingsMenu
local store_ok, store_or_error = pcall(require, "burrow_store.main")
if store_ok then
    EmbeddedStore = store_or_error
    local menu_ok, menu_or_error = pcall(require, "burrow_store.config.settings_menu")
    if menu_ok then
        StoreSettingsMenu = menu_or_error
    else
        store_load_error = tostring(menu_or_error)
        logger.warn(burrow_debug.logprefix, "Burrow Store settings failed to load", store_load_error)
    end
else
    store_load_error = tostring(store_or_error)
    logger.warn(burrow_debug.logprefix, "Burrow Store failed to load", store_load_error)
end

-- Keep Burrow's library modules in package.loaded after PluginLoader restores
-- the normal package path. Plugin-owned instance modules applied at the end of
-- this file may need them regardless of the selected display mode.
local BurrowCoverMenu = require("covermenu")
local BurrowMosaicMenu = require("mosaicmenu")
local BurrowTitleBar = require("titlebar")

-- https://github.com/koreader/koreader/commits/master/frontend/ui/widget/filechooser.lua
local _FileChooser__recalculateDimen_orig = FileChooser._recalculateDimen
local _FileChooser_updateItems_orig = FileChooser.updateItems
local _FileChooser_onCloseWidget_orig = FileChooser.onCloseWidget
local _FileChooser_genItemTable_orig = FileChooser.genItemTable         -- not in Cover Browser

-- https://github.com/koreader/koreader/commits/master/frontend/apps/filemanager/filemanager.lua
local _FileManager_setupLayout_orig = FileManager.setupLayout           -- not in Cover Browser

-- https://github.com/koreader/koreader/commits/master/frontend/ui/widget/menu.lua
local _Menu_init_orig = Menu.init                                       -- not in Cover Browser
local _Menu_updatePageInfo_orig = Menu.updatePageInfo                   -- not in Cover Browser

local _modified_widgets = {
    filemanager  = FileManager,
    history      = FileManagerHistory,
    collections  = FileManagerCollection,
    filesearcher = FileManagerFileSearcher,
}
local _updateItemTable_orig_funcs = {
    history      = FileManagerHistory.updateItemTable,
    collections  = FileManagerCollection.updateItemTable,
    filesearcher = FileManagerFileSearcher.updateItemTable,
}

-- Available display modes
local DISPLAY_MODES = {
    -- nil or ""            -- classic : filename only
    mosaic_image    = true, -- 3x3 grid covers with images
    list_image_meta = true, -- image with metadata (title/authors)
    list_only_meta  = true, -- metadata with no image
    list_no_meta    = true, -- filename only
}
local display_mode_db_names = {
    filemanager = "filemanager_display_mode",
    history     = "history_display_mode",
    collections = "collection_display_mode",
}
-- Store some states as locals, to be permanent across instantiations
local init_done = false
local curr_display_modes = {
    filemanager = false, -- not initialized yet
    history     = false, -- not initialized yet
    collections = false, -- not initialized yet
}
local series_mode = nil  -- defaults to not display series


function Methods:onDispatcherRegisterActions()
    Dispatcher:registerAction("dec_items_pp", {
        category = "none",
        event = "DecreaseItemsPerPage",
        title = _("Burrow") .. " - " .. _("Decrease Items Per Page"),
        filemanager = true,
        separator = false,
    })
    Dispatcher:registerAction("inc_items_pp", {
        category = "none",
        event = "IncreaseItemsPerPage",
        title = _("Burrow") .. " - " .. _("Increase Items Per Page"),
        filemanager = true,
        separator = false,
    })
    Dispatcher:registerAction("switch_grid", {
        category = "none",
        event = "SwitchToCoverGrid",
        title = _("Burrow") .. " - " .. _("Cover Grid"),
        filemanager = true,
        separator = false,
    })
    Dispatcher:registerAction("switch_list", {
        category = "none",
        event = "SwitchToCoverList",
        title = _("Burrow") .. " - " .. _("Cover List"),
        filemanager = true,
        separator = false,
    })
    Dispatcher:registerAction("burrow_show_store", {
        category = "none",
        event = "ShowBurrowStore",
        title = _("Burrow Store"),
        filemanager = true,
        separator = false,
    })
    Dispatcher:registerAction("burrow_sync_store", {
        category = "none",
        event = "SyncBurrowStore",
        title = _("Burrow Store") .. " - " .. _("Sync all catalogs"),
        filemanager = true,
        separator = false,
    })
end

function Methods:init()
    if not self.ui.document then -- FileManager menu only
        if EmbeddedStore then
            local ok, store_or_error = pcall(function()
                return EmbeddedStore:new {
                    ui = self.ui,
                    embedded = true,
                    brand_title = _("Burrow Store"),
                }
            end)
            if ok then
                self.store = self.store or store_or_error
            else
                store_load_error = tostring(store_or_error)
                logger.warn(burrow_debug.logprefix, "Burrow Store initialization failed", store_load_error)
            end
        end
        BurrowClass._burrow_instance = self
        self.ui.menu:registerToMainMenu(self)

        if not BurrowClass._startup_notice_checked then
            BurrowClass._startup_notice_checked = true
            local notices = {}
            if BurrowClass._compatibility_notice then
                local warning_key = "burrow_compatibility_warning_"
                    .. tostring(BurrowClass._compatibility and BurrowClass._compatibility.current or "unknown")
                    .. "_" .. BurrowVersion.VERSION:gsub("[^%w]", "_")
                if not G_reader_settings:isTrue(warning_key) then
                    notices[#notices + 1] = BurrowClass._compatibility_notice
                    G_reader_settings:makeTrue(warning_key)
                end
            end
            for _, loader_notice in ipairs(BurrowLoader:getUserNotices()) do
                notices[#notices + 1] = loader_notice
            end
            if #notices > 0 then
                UIManager:nextTick(function()
                    UIManager:show(InfoMessage:new {
                        text = table.concat(notices, "\n\n"),
                        show_icon = false,
                        alignment = "center",
                        timeout = 30,
                    })
                end)
            end
        end
    end

    if init_done then -- things already patched according to current modes
        return
    end

    -- impersonate coverbrowser to support calls from KOReader core
    self.coverbrowser = self
    self.ui.coverbrowser = self

    -- on first ever run and occasionally afterward it will be necessary to create
    -- new settings keys in the 'config' table and some of them require restarting
    -- koreader to fully apply.
    local restart_needed = false
    local initial_setup_key = BurrowMigration.initialSetupKey()
    if not G_reader_settings:isTrue(initial_setup_key) then
        logger.info(burrow_debug.logprefix, "Initalizing settings")
        -- Set up default display modes on first launch
        -- but only if no display mode has been set yet
        if not BookInfoManager:getSetting("filemanager_display_mode")
            and not BookInfoManager:getSetting("history_display_mode") then
            BookInfoManager:saveSetting("filemanager_display_mode", "list_image_meta")
            BookInfoManager:saveSetting("history_display_mode", "list_image_meta")
            BookInfoManager:saveSetting("collection_display_mode", "list_image_meta")
        end
        -- initalize settings with their defaults
        BookInfoManager:saveSetting("config_version", "1")
        BookInfoManager:saveSetting("series_mode", "series_in_separate_line")
        BookInfoManager:saveSetting("hide_file_info", true)
        BookInfoManager:saveSetting("unified_display_mode", true)
        BookInfoManager:saveSetting("show_progress_in_mosaic", true)
        BookInfoManager:saveSetting("autoscan_on_eject", false)
        G_reader_settings:makeTrue(initial_setup_key)
        restart_needed = true
    end

    -- initalize additional settings with their defaults
    if BookInfoManager:getSetting("config_version") == nil then
        -- catch installs done before setting versioning
        logger.info(burrow_debug.logprefix, "Migrating settings to version 1")
        BookInfoManager:saveSetting("config_version", "1")
    end
    if BookInfoManager:getSetting("config_version") == 1 then
        logger.info(burrow_debug.logprefix, "Migrating settings to version 2")
        BookInfoManager:saveSetting("disable_auto_foldercovers", false)
        BookInfoManager:saveSetting("force_max_progressbars", false)
        BookInfoManager:saveSetting("opened_at_top_of_library", true)
        BookInfoManager:saveSetting("reverse_footer", false)
        BookInfoManager:saveSetting("use_custom_bookstatus", true)
        BookInfoManager:saveSetting("replace_footer_text", false)
        BookInfoManager:saveSetting("show_name_grid_folders", true)
        BookInfoManager:saveSetting("config_version", "2")
        restart_needed = true
    end
    if BookInfoManager:getSetting("config_version") == 2 then
        logger.info(burrow_debug.logprefix, "Migrating settings to version 3")
        BookInfoManager:saveSetting("force_no_progressbars", false)
        BookInfoManager:saveSetting("config_version", "3")
    end
    if BookInfoManager:getSetting("config_version") == 3 then
        logger.info(burrow_debug.logprefix, "Migrating settings to version 4")
        BookInfoManager:saveSetting("force_focus_indicator", false)
        BookInfoManager:saveSetting("use_stacked_foldercovers", false)
        BookInfoManager:saveSetting("config_version", "4")
    end
    if BookInfoManager:getSetting("config_version") == 4 then
        logger.info(burrow_debug.logprefix, "Migrating settings to version 5")
        BookInfoManager:saveSetting("show_tags", false)
        BookInfoManager:saveSetting("config_version", "5")
    end
    if BookInfoManager:getSetting("config_version") == 5 then
        logger.info(burrow_debug.logprefix, "Migrating settings to version 6")
        BookInfoManager:saveSetting("use_custom_sorts", true)
        BookInfoManager:saveSetting("config_version", "6")
    end

    -- restart if needed
    if restart_needed then
        logger.info(burrow_debug.logprefix, "Restarting KOReader to apply settings")
        UIManager:restartKOReader()
        FFIUtil.sleep(2)
    end

    self:setupFileManagerDisplayMode(BookInfoManager:getSetting("filemanager_display_mode"))
    BurrowClass.setupWidgetDisplayMode("history", true)
    BurrowClass.setupWidgetDisplayMode("collections", true)
    series_mode = BookInfoManager:getSetting("series_mode")
    self:onDispatcherRegisterActions()

    if BookInfoManager:getSetting("use_custom_sorts") then
        BurrowClass.addSortMethods()
    end

    if BookInfoManager:getSetting("use_custom_bookstatus") then
        BookStatusWidget.genHeader = AltBookStatusWidget.genHeader
        BookStatusWidget.getStatusContent = AltBookStatusWidget.getStatusContent
        BookStatusWidget.genBookInfoGroup = AltBookStatusWidget.genBookInfoGroup
        BookStatusWidget.genSummaryGroup = AltBookStatusWidget.genSummaryGroup
        BookStatusWidget.genStatisticsGroup = AltBookStatusWidget.genStatisticsGroup
    end

    local home_dir = G_reader_settings:readSetting("home_dir")
    if home_dir then logger.info(burrow_debug.logprefix, "Home directory is set to: ", home_dir) end
    if home_dir and util.pathExists(home_dir) and BookInfoManager:getSetting("autoscan_on_eject") then
        local cover_specs = { max_cover_w = 1, max_cover_h = 1, }
        UIManager:tickAfterNext(function()
            Trapper:wrap(function()
                BookInfoManager:extractBooksInDirectory(home_dir, cover_specs, true)
            end)
        end)
    end

    init_done = true
    BookInfoManager:closeDbConnection() -- will be re-opened if needed
end

function Methods:onShowBurrowStore()
    if self.store then
        self.store:onShowOPDSCatalog()
        return true
    end
end

function Methods:onSyncBurrowStore()
    if self.store then
        self.store:_startSyncFromDispatcher(false)
        return true
    end
end

function Methods:stopPlugin()
    logger.info(burrow_debug.logprefix, "Disabling plugin per user request")
end

function Methods:deletePluginSettings()
    logger.info(burrow_debug.logprefix, "Removing settings and cache database per user request")

    -- Tear down Burrow and restore the stock file-manager view.
    local fc = self.ui.file_chooser
    BurrowClass.removeFileDialogButtons("filesearcher")
    _modified_widgets["filesearcher"].updateItemTable = _updateItemTable_orig_funcs["filesearcher"]
    FileChooser.updateItems = _FileChooser_updateItems_orig
    FileChooser.onCloseWidget = _FileChooser_onCloseWidget_orig
    FileChooser._recalculateDimen = _FileChooser__recalculateDimen_orig
    BurrowClass.removeFileDialogButtons("filemanager")
    FileChooser.genItemTable = _FileChooser_genItemTable_orig
    FileManager.setupLayout = _FileManager_setupLayout_orig
    Menu.init = _Menu_init_orig
    Menu.updatePageInfo = _Menu_updatePageInfo_orig
    FileChooser._updateItemsBuildUI = nil
    FileChooser._do_cover_images = nil
    FileChooser._do_filename_only = nil
    FileChooser._do_hint_opened = nil
    FileChooser._do_center_partial_rows = nil
    if fc then
        fc:_recalculateDimen()
        fc:switchItemTable(nil, nil, fc.prev_itemnumber, { dummy = "" }) -- dummy itemmatch to draw focus
    end
    BookInfoManager:closeDbConnection()

    -- Delete Burrow-owned settings and cache files. Legacy source files are retained as backups.
    BurrowMigration.removeBurrowData()
    BurrowSettings:removeAllSettings()

    -- delete installed icons
    local icons_path = burrow_util.koreader_dir .. "/icons"
    local icons_list = {
        "favorites",
        "go_up",
        "history",
        "last_document",
        "plus",
    }
    local icons_checksum_list = {
        "546928404910d90cbdcaf4b1c207683c",
        "5536bb523b1f11a6ef48ec71bb7ddc55",
        "e26a48a6e9f6dc4086bcd32222349752",
        "9408835d5c1aa69d8ad9c2701e22e33a",
        "515a084140c4931607bc066b6819d34e",
    }
    for i, icon in ipairs(icons_list) do
        local icon_file = icons_path .. "/" .. icon .. ".svg"
        if icons_checksum_list[i] == util.partialMD5(icon_file) then
            os.remove(icon_file)
        end
    end
    -- These names belong only to Burrow, so they can be removed directly.
    local burrow_owned_icons = {
        "burrow.hero",
        "percent.badge",
        "quick_bookmark",
        "quick_exit",
        "quick_info",
        "quick_library",
        "quick_more",
        "quick_nightmode",
        "quick_pull",
        "quick_push",
        "quick_restart",
        "quick_rotate",
        "quick_search",
        "quick_sleep",
        "quick_text",
        "quick_toc",
        "quick_wifi",
        "quicksettings",
        "return.library",
        "rounded.corner.bl",
        "rounded.corner.br",
        "rounded.corner.tl",
        "rounded.corner.tr",
        "series.folder",
        "series.number.badge",
    }
    for _, icon in ipairs(burrow_owned_icons) do
        os.remove(icons_path .. "/" .. icon .. ".svg")
    end
end

function Methods:addToMainMenu(menu_items)
    local sub_item_table, history_sub_item_table, collection_sub_item_table = {}, {}, {}
    local fc = self.ui.file_chooser
    for i, v in ipairs(self.modes) do
        local text, mode = unpack(v)
        sub_item_table[i] = {
            text = text,
            checked_func = function()
                return mode == curr_display_modes["filemanager"]
            end,
            callback = function()
                self:setDisplayMode(mode)
            end,
        }
        history_sub_item_table[i] = {
            text = text,
            checked_func = function()
                return mode == curr_display_modes["history"]
            end,
            callback = function()
                BurrowClass.setupWidgetDisplayMode("history", mode)
            end,
        }
        collection_sub_item_table[i] = {
            text = text,
            checked_func = function()
                return mode == curr_display_modes["collections"]
            end,
            callback = function()
                BurrowClass.setupWidgetDisplayMode("collections", mode)
            end,
        }
    end
    sub_item_table[#self.modes].separator = true
    table.insert(sub_item_table, {
        text = _("Use this mode everywhere"),
        checked_func = function()
            return BookInfoManager:getSetting("unified_display_mode")
        end,
        callback = function()
            if BookInfoManager:toggleSetting("unified_display_mode") then
                BurrowClass.setupWidgetDisplayMode("history", curr_display_modes["filemanager"])
                BurrowClass.setupWidgetDisplayMode("collections", curr_display_modes["filemanager"])
            end
        end,
    })
    table.insert(sub_item_table, {
        text = _("History display mode"),
        enabled_func = function()
            return not BookInfoManager:getSetting("unified_display_mode")
        end,
        sub_item_table = history_sub_item_table,
    })
    table.insert(sub_item_table, {
        text = _("Collections display mode"),
        separator = true,
        enabled_func = function()
            return not BookInfoManager:getSetting("unified_display_mode")
        end,
        sub_item_table = collection_sub_item_table,
    })
    table.insert(sub_item_table, {
        text = _("Items per page"),
        sub_item_table = {
            {
                text_func = function()
                    return _("Portrait cover grid mode") .. T(_(": %1 × %2"), fc.nb_cols_portrait, fc.nb_rows_portrait)
                end,
                -- Best to not "keep_menu_open = true", to see how this apply on the full view
                callback = function()
                    local nb_cols = fc.nb_cols_portrait
                    local nb_rows = fc.nb_rows_portrait
                    local DoubleSpinWidget = require("/ui/widget/doublespinwidget")
                    local widget = DoubleSpinWidget:new {
                        title_text = _("Portrait cover grid mode"),
                        width_factor = 0.6,
                        left_text = _("Columns"),
                        left_value = nb_cols,
                        left_min = burrow_util.grid_defaults.min_cols,
                        left_max = burrow_util.grid_defaults.max_cols,
                        left_default = burrow_util.grid_defaults.default_cols,
                        left_precision = "%01d",
                        right_text = _("Rows"),
                        right_value = nb_rows,
                        right_min = burrow_util.grid_defaults.min_rows,
                        right_max = burrow_util.grid_defaults.max_rows,
                        right_default = burrow_util.grid_defaults.default_rows,
                        right_precision = "%01d",
                        keep_shown_on_apply = true,
                        callback = function(left_value, right_value)
                            fc.nb_cols_portrait = left_value
                            fc.nb_rows_portrait = right_value
                            if fc.display_mode_type == "mosaic" and fc.portrait_mode then
                                fc.no_refresh_covers = true
                                fc:updateItems()
                            end
                        end,
                        close_callback = function()
                            if fc.nb_cols_portrait ~= nb_cols or fc.nb_rows_portrait ~= nb_rows then
                                BookInfoManager:saveSetting("nb_cols_portrait", fc.nb_cols_portrait)
                                BookInfoManager:saveSetting("nb_rows_portrait", fc.nb_rows_portrait)
                                FileChooser.nb_cols_portrait = fc.nb_cols_portrait
                                FileChooser.nb_rows_portrait = fc.nb_rows_portrait
                                if fc.display_mode_type == "mosaic" and fc.portrait_mode then
                                    fc.no_refresh_covers = nil
                                    fc:updateItems()
                                end
                            end
                        end,
                    }
                    UIManager:show(widget)
                end,
            },
            {
                text_func = function()
                    return _("Landscape cover grid mode") .. T(_(": %1 × %2"), fc.nb_cols_landscape, fc.nb_rows_landscape)
                end,
                callback = function()
                    local nb_cols = fc.nb_cols_landscape
                    local nb_rows = fc.nb_rows_landscape
                    local DoubleSpinWidget = require("/ui/widget/doublespinwidget")
                    local widget = DoubleSpinWidget:new {
                        title_text = _("Landscape cover grid mode"),
                        width_factor = 0.6,
                        left_text = _("Columns"),
                        left_value = nb_cols,
                        left_min = burrow_util.grid_defaults.min_cols,
                        left_max = burrow_util.grid_defaults.max_cols,
                        left_default = burrow_util.grid_defaults.default_cols,
                        left_precision = "%01d",
                        right_text = _("Rows"),
                        right_value = nb_rows,
                        right_min = burrow_util.grid_defaults.min_rows,
                        right_max = burrow_util.grid_defaults.max_rows,
                        right_default = burrow_util.grid_defaults.default_rows,
                        right_precision = "%01d",
                        keep_shown_on_apply = true,
                        callback = function(left_value, right_value)
                            fc.nb_cols_landscape = left_value
                            fc.nb_rows_landscape = right_value
                            if fc.display_mode_type == "mosaic" and not fc.portrait_mode then
                                fc.no_refresh_covers = true
                                fc:updateItems()
                            end
                        end,
                        close_callback = function()
                            if fc.nb_cols_landscape ~= nb_cols or fc.nb_rows_landscape ~= nb_rows then
                                BookInfoManager:saveSetting("nb_cols_landscape", fc.nb_cols_landscape)
                                BookInfoManager:saveSetting("nb_rows_landscape", fc.nb_rows_landscape)
                                FileChooser.nb_cols_landscape = fc.nb_cols_landscape
                                FileChooser.nb_rows_landscape = fc.nb_rows_landscape
                                if fc.display_mode_type == "mosaic" and not fc.portrait_mode then
                                    fc.no_refresh_covers = nil
                                    fc:updateItems()
                                end
                            end
                        end,
                    }
                    UIManager:show(widget)
                end,
            },
            {
                text_func = function()
                    -- default files_per_page should be calculated by ListMenu on the first drawing,
                    -- use 7 if ListMenu has not been drawn yet
                    return _("List modes") .. T(_(": %1"),
                        fc.files_per_page or burrow_util.list_defaults.default_items_per_page)
                end,
                callback = function()
                    local files_per_page = fc.files_per_page or burrow_util.list_defaults.default_items_per_page
                    local SpinWidget = require("ui/widget/spinwidget")
                    local widget = SpinWidget:new {
                        title_text = _("List modes"),
                        value = files_per_page,
                        value_min = burrow_util.list_defaults.min_items_per_page,
                        value_max = burrow_util.list_defaults.max_items_per_page,
                        default_value = burrow_util.list_defaults.default_items_per_page,
                        keep_shown_on_apply = true,
                        callback = function(spin)
                            fc.files_per_page = spin.value
                            if fc.display_mode_type == "list" then
                                fc.no_refresh_covers = true
                                fc:updateItems()
                            end
                        end,
                        close_callback = function()
                            if fc.files_per_page ~= files_per_page then
                                BookInfoManager:saveSetting("files_per_page", fc.files_per_page)
                                FileChooser.files_per_page = fc.files_per_page
                                if fc.display_mode_type == "list" then
                                    fc.no_refresh_covers = nil
                                    fc:updateItems()
                                end
                            end
                        end,
                    }
                    UIManager:show(widget)
                end,
            },
        },
    })
    table.insert(sub_item_table, {
        text = _("Advanced settings"),
        sub_item_table = {
            {
                text = _("Folder display"),
                sub_item_table = {
                    {
                        text = _("Auto-generate cover images from books"),
                        checked_func = function()
                            return not BookInfoManager:getSetting("disable_auto_foldercovers")
                        end,
                        callback = function()
                            BookInfoManager:toggleSetting("disable_auto_foldercovers")
                            fc:updateItems()
                        end,
                    },
                    {
                        text = _("Show auto-generated cover images as a stack"),
                        enabled_func = function()
                            return not (BookInfoManager:getSetting("disable_auto_foldercovers"))
                        end,
                        checked_func = function() return BookInfoManager:getSetting("use_stacked_foldercovers") end,
                        callback = function()
                            BookInfoManager:toggleSetting("use_stacked_foldercovers")
                            fc:updateItems(1, true)
                        end,
                    },
                    {
                        text = _("Overlay name and details in cover grid"),
                        checked_func = function() return BookInfoManager:getSetting("show_name_grid_folders") end,
                        callback = function()
                            BookInfoManager:toggleSetting("show_name_grid_folders")
                            fc:updateItems(1, true)
                        end,
                    },
                    {
                        text = _("Use custom sort methods"),
                        checked_func = function() return BookInfoManager:getSetting("use_custom_sorts") end,
                        callback = function()
                            BookInfoManager:toggleSetting("use_custom_sorts")
                            UIManager:askForRestart()
                        end,
                    },
                },
            },
            {
                text = _("Book display"),
                sub_item_table = {
                    {
                        text = _("Show file info instead of pages or progress %"),
                        checked_func = function() return not BookInfoManager:getSetting("hide_file_info") end,
                        callback = function()
                            BookInfoManager:toggleSetting("hide_file_info")
                            fc:updateItems(1, true)
                        end,
                    },
                    {
                        text = _("Show pages read instead of progress %"),
                        enabled_func = function()
                            return not (
                                    not BookInfoManager:getSetting("hide_file_info")
                                )
                        end,
                        checked_func = function() return BookInfoManager:getSetting("show_pages_read_as_progress") end,
                        callback = function()
                            BookInfoManager:toggleSetting("show_pages_read_as_progress")
                            fc:updateItems(1, true)
                        end,
                    },
                    {
                        text = _("Show progress % instead of progress bars"),
                        enabled_func = function()
                            return not (
                                    BookInfoManager:getSetting("show_pages_read_as_progress") or
                                    not BookInfoManager:getSetting("hide_file_info")
                                )
                        end,
                        checked_func = function() return BookInfoManager:getSetting("force_no_progressbars") end,
                        callback = function()
                            BookInfoManager:toggleSetting("force_no_progressbars")
                            fc:updateItems(1, true)
                        end,
                    },
                    {
                        text = _("Always show maximum length progress bars"),
                        separator = true,
                        enabled_func = function()
                            return not (
                                    BookInfoManager:getSetting("force_no_progressbars") or
                                    BookInfoManager:getSetting("show_pages_read_as_progress") or
                                    not BookInfoManager:getSetting("hide_file_info")
                                )
                        end,
                        checked_func = function() return BookInfoManager:getSetting("force_max_progressbars") end,
                        callback = function()
                            BookInfoManager:toggleSetting("force_max_progressbars")
                            fc:updateItems(1, true)
                        end,
                    },
                    {
                        text = _("Show series"),
                        checked_func = function() return series_mode == "series_in_separate_line" end,
                        callback = function()
                            if series_mode == "series_in_separate_line" then
                                series_mode = nil
                            else
                                series_mode = "series_in_separate_line"
                            end
                            BookInfoManager:saveSetting("series_mode", series_mode)
                            fc:updateItems(1, true)
                        end,
                    },
                    {
                        text = _("Show calibre tags/keywords"),
                        separator = true,
                        checked_func = function() return BookInfoManager:getSetting("show_tags") end,
                        callback = function()
                            BookInfoManager:toggleSetting("show_tags")
                            fc:updateItems(1, true)
                        end,
                    },
                    {
                        text = _("Use custom book status screen"),
                        checked_func = function() return BookInfoManager:getSetting("use_custom_bookstatus") end,
                        callback = function()
                            BookInfoManager:toggleSetting("use_custom_bookstatus")
                            UIManager:askForRestart()
                        end,
                    },
                },
            },
            {
                text = _("Footer"),
                sub_item_table = {
                    {
                        text = _("Replace folder name with device info"),
                        checked_func = function() return BookInfoManager:getSetting("replace_footer_text") end,
                        callback = function()
                            BookInfoManager:toggleSetting("replace_footer_text")
                            UIManager:askForRestart()
                        end,
                    },
                    {
                        text = _("Show page controls in left corner"),
                        checked_func = function() return BookInfoManager:getSetting("reverse_footer") end,
                        callback = function()
                            BookInfoManager:toggleSetting("reverse_footer")
                            UIManager:askForRestart()
                        end,
                    },
                },
            },
            {
                text = _("Library mode"),
                sub_item_table = {
                    {
                        text = _("Show opened books first"),
                        checked_func = function()
                            return BookInfoManager:getSetting("opened_at_top_of_library")
                        end,
                        callback = function()
                            BookInfoManager:toggleSetting("opened_at_top_of_library")
                            -- can't figure out how to refresh the item table from here
                            -- but a restart gets the job done
                            UIManager:askForRestart()
                        end,
                    },
                },
            },
            {
                text = _("Cache database"),
                sub_item_table = {
                    {
                        text = _("Scan home folder for new books automatically"),
                        checked_func = function() return BookInfoManager:getSetting("autoscan_on_eject") end,
                        callback = function()
                            BookInfoManager:toggleSetting("autoscan_on_eject")
                            UIManager:askForRestart()
                        end,
                    },
                    {
                        text = _("Prune cache"),
                        keep_menu_open = false,
                        callback = function()
                            local ConfirmBox = require("ui/widget/confirmbox")
                            UIManager:close(self.file_dialog)
                            UIManager:show(ConfirmBox:new {
                                -- Checking file existences is quite fast, but deleting entries is slow.
                                text = _("Are you sure that you want to prune cache of removed books?\n(This may take a while.)"),
                                ok_text = _("Prune cache"),
                                ok_callback = function()
                                    local InfoMessage = require("ui/widget/infomessage")
                                    local msg = InfoMessage:new { text = _("Pruning cache of removed books…") }
                                    UIManager:show(msg)
                                    UIManager:nextTick(function()
                                        local summary = BookInfoManager:removeNonExistantEntries()
                                        BookInfoManager:compactDb() -- compact
                                        UIManager:close(msg)
                                        UIManager:show(InfoMessage:new { text = summary })
                                    end)
                                end
                            })
                        end,
                    },
                    {
                        text = _("Empty cache"),
                        keep_menu_open = false,
                        callback = function()
                            local ConfirmBox = require("ui/widget/confirmbox")
                            UIManager:close(self.file_dialog)
                            UIManager:show(ConfirmBox:new {
                                text = _("Are you sure that you want to delete cover and metadata cache?"),
                                ok_text = _("Empty cache"),
                                ok_callback = function()
                                    BookInfoManager:deleteDb()
                                    BookInfoManager:compactDb() -- compact
                                    local InfoMessage = require("ui/widget/infomessage")
                                    UIManager:show(InfoMessage:new { text = _("Cache emptied.") })
                                end
                            })
                        end,
                        separator = true,
                    },
                    {
                        text_func = function() -- add current db size to menu text
                            local sstr = BookInfoManager:getDbSize()
                            return _("Cache size") .. ": " .. sstr
                        end,
                        keep_menu_open = true,
                        callback = function() end, -- no callback, only for information
                    },
                },
            },
            {
                text = _("Show last item indicator on touchscreen devices"),
                checked_func = function() return BookInfoManager:getSetting("force_focus_indicator") end,
                callback = function()
                    BookInfoManager:toggleSetting("force_focus_indicator")
                end,
            },
        },
    })
    if self.store and StoreSettingsMenu then
        table.insert(sub_item_table, {
            text = _("Store"),
            sub_item_table = StoreSettingsMenu.create(self.store),
            separator = true,
        })
    elseif store_load_error then
        table.insert(sub_item_table, {
            text = _("Store unavailable"),
            keep_menu_open = true,
            callback = function()
                UIManager:show(InfoMessage:new {
                    text = _("The Burrow library loaded, but the Store engine did not.") .. "\n\n" .. store_load_error,
                    show_icon = false,
                })
            end,
            separator = true,
        })
    end
    local feature_items = BurrowSettings:featureMenuItems(UIManager)
    local degraded_features = BurrowLoader:getDegradedFeatures()
    if next(degraded_features) then
        table.insert(feature_items, {
            text = _("Retry disabled features after restart"),
            separator = true,
            callback = function()
                BurrowLoader:clearQuarantine()
                UIManager:askForRestart()
            end,
        })
        table.insert(feature_items, {
            text = _("Show module status"),
            keep_menu_open = true,
            callback = function()
                local lines = {}
                for id, status in pairs(BurrowLoader:getStatuses()) do
                    lines[#lines + 1] = id .. ": " .. tostring(status.state)
                end
                table.sort(lines)
                UIManager:show(InfoMessage:new {
                    text = table.concat(lines, "\n"),
                    show_icon = false,
                })
            end,
        })
    end
    table.insert(sub_item_table, {
        text = _("Features"),
        sub_item_table = feature_items,
    })
    table.insert(sub_item_table, {
        text = _("About Burrow"),
        help_text = _("Version, license, and acknowledgements."),
        keep_menu_open = true,
        callback = function()
            UIManager:show(InfoMessage:new {
                text = T(_("Burrow %1\n\nA unified library, Store, and reader interface for KOReader.\n\nInspired by ProjectTitle, OPDS Plus, and the wider KOReader community.\n\nLicensed under GNU AGPL v3."), BurrowVersion.DISPLAY_VERSION),
                show_icon = false,
            })
        end,
    })

    menu_items.filemanager_display_mode = {
        text = _("Burrow settings"),
        sub_item_table = sub_item_table,
        separator = true,
    }
end

function Methods:genExtractBookInfoButton(close_dialog_callback) -- for the extended File Manager dialog
    return curr_display_modes["filemanager"] and {
        {
            text = _("Extract and cache book information"),
            callback = function()
                close_dialog_callback()
                local fc = self.ui.file_chooser
                local Trapper = require("ui/trapper")
                Trapper:wrap(function()
                    BookInfoManager:extractBooksInDirectory(fc.path, fc.cover_specs)
                end)
            end,
        },
    }
end

function Methods:genMultipleRefreshBookInfoButton(close_dialog_toggle_select_mode_callback, button_disabled)
    return curr_display_modes["filemanager"] and {
        {
            text = _("Refresh cached book information"),
            enabled = not button_disabled,
            callback = function()
                for file in pairs(self.ui.selected_files) do
                    BookInfoManager:deleteBookInfo(file)
                    self.ui.file_chooser.resetBookInfoCache(file)
                end
                close_dialog_toggle_select_mode_callback()
            end,
        },
    }
end

function Methods.initGrid(menu, display_mode)
    if menu == nil then return end
    if menu.nb_cols_portrait == nil then
        menu.nb_cols_portrait  = BookInfoManager:getSetting("nb_cols_portrait") or burrow_util.grid_defaults.default_cols
        menu.nb_rows_portrait  = BookInfoManager:getSetting("nb_rows_portrait") or burrow_util.grid_defaults.default_rows
        menu.nb_cols_landscape = BookInfoManager:getSetting("nb_cols_landscape") or burrow_util.grid_defaults.default_cols
        menu.nb_rows_landscape = BookInfoManager:getSetting("nb_rows_landscape") or burrow_util.grid_defaults.default_rows
        -- initial List mode files_per_page will be calculated and saved by ListMenu on the first drawing
        menu.files_per_page    = BookInfoManager:getSetting("files_per_page")
    end
    menu.display_mode_type = display_mode and display_mode:gsub("_.*", "") -- "mosaic" or "list"
end

function Methods.addFileDialogButtons(widget_id)
    local widget = _modified_widgets[widget_id]
    FileManager.addFileDialogButtons(widget, "burrow_1", function(file, is_file, bookinfo)
        if is_file then
            return bookinfo and {
                { -- Allow user to ignore some offending cover image
                    text = bookinfo.ignore_cover and _("Unignore cover") or _("Ignore cover"),
                    enabled = bookinfo.has_cover and true or false,
                    callback = function()
                        BookInfoManager:setBookInfoProperties(file, {
                            ["ignore_cover"] = not bookinfo.ignore_cover and 'Y' or false,
                        })
                        widget.files_updated = true
                        local menu = widget.getMenuInstance()
                        UIManager:close(menu.file_dialog)
                        menu:updateItems(1, true)
                    end,
                },
                { -- Allow user to ignore some bad metadata (filename will be used instead)
                    text = bookinfo.ignore_meta and _("Unignore metadata") or _("Ignore metadata"),
                    enabled = bookinfo.has_meta and true or false,
                    callback = function()
                        BookInfoManager:setBookInfoProperties(file, {
                            ["ignore_meta"] = not bookinfo.ignore_meta and 'Y' or false,
                        })
                        widget.files_updated = true
                        local menu = widget.getMenuInstance()
                        UIManager:close(menu.file_dialog)
                        menu:updateItems(1, true)
                    end,
                },
            }
        end
    end)
    FileManager.addFileDialogButtons(widget, "burrow_2", function(file, is_file, bookinfo)
        if is_file then
            return bookinfo and {
                { -- Allow a new extraction (multiple interruptions, book replaced)...
                    text = _("Refresh cached book information"),
                    callback = function()
                        BookInfoManager:deleteBookInfo(file)
                        widget.files_updated = true
                        local menu = widget.getMenuInstance()
                        menu.resetBookInfoCache(file)
                        UIManager:close(menu.file_dialog)
                        menu:updateItems(1, true)
                    end,
                },
            }
        end
    end)
end

function Methods.removeFileDialogButtons(widget_id)
    local widget = _modified_widgets[widget_id]
    FileManager.removeFileDialogButtons(widget, "burrow_2")
    FileManager.removeFileDialogButtons(widget, "burrow_1")
end

function Methods:refreshFileManagerInstance()
    local fc = self.ui.file_chooser
    if fc then
        fc:_recalculateDimen()
        fc:switchItemTable(nil, nil, fc.prev_itemnumber, { dummy = "" }) -- dummy itemmatch to draw focus
    end
end

function Methods:setDisplayMode(display_mode)
    self:setupFileManagerDisplayMode(display_mode)
    if BookInfoManager:getSetting("unified_display_mode") then
        BurrowClass.setupWidgetDisplayMode("history", display_mode)
        BurrowClass.setupWidgetDisplayMode("collections", display_mode)
    end
end

function Methods:setupFileManagerDisplayMode(display_mode)
    if not DISPLAY_MODES[display_mode] then
        display_mode = nil                                                  -- unknown mode, fallback to classic
    end
    if init_done and display_mode == curr_display_modes["filemanager"] then -- no change
        return
    end
    if init_done then -- save new mode in db
        BookInfoManager:saveSetting(display_mode_db_names["filemanager"], display_mode)
    end
    -- remember current mode in module variable
    curr_display_modes["filemanager"] = display_mode
    logger.dbg(burrow_debug.logprefix, "Setting FileManager display mode to:", display_mode or "classic")

    -- init Mosaic and List grid dimensions (in Classic mode used in the settings menu)
    BurrowClass.initGrid(FileChooser, display_mode)

    if not init_done and not display_mode then
        return -- starting in classic mode, nothing to patch
    end

    if not display_mode then -- classic mode
        BurrowClass.removeFileDialogButtons("filesearcher")
        _modified_widgets["filesearcher"].updateItemTable = _updateItemTable_orig_funcs["filesearcher"]
        -- Put back original methods
        FileChooser.updateItems = _FileChooser_updateItems_orig
        FileChooser.onCloseWidget = _FileChooser_onCloseWidget_orig
        FileChooser._recalculateDimen = _FileChooser__recalculateDimen_orig
        BurrowClass.removeFileDialogButtons("filemanager")
        FileChooser.genItemTable = _FileChooser_genItemTable_orig
        FileManager.setupLayout = _FileManager_setupLayout_orig
        Menu.init = _Menu_init_orig
        Menu.updatePageInfo = _Menu_updatePageInfo_orig
        -- Also clean-up what we added, even if it does not bother original code
        FileChooser._updateItemsBuildUI = nil
        FileChooser._do_cover_images = nil
        FileChooser._do_filename_only = nil
        FileChooser._do_hint_opened = nil
        FileChooser._do_center_partial_rows = nil
        self:refreshFileManagerInstance()
        return
    end

    BurrowClass.addFileDialogButtons("filesearcher")
    _modified_widgets["filesearcher"].updateItemTable = BurrowClass.getUpdateItemTableFunc(display_mode)
    -- In both mosaic and list modes, replace original methods with those from
    -- our generic CoverMenu
    local CoverMenu = require("covermenu")
    FileChooser.updateItems = CoverMenu.updateItems
    FileChooser.onCloseWidget = CoverMenu.onCloseWidget
    BurrowClass.addFileDialogButtons("filemanager")
    if FileChooser.display_mode_type == "mosaic" then
        -- Replace some other original methods with those from our MosaicMenu
        local MosaicMenu = require("mosaicmenu")
        FileChooser._recalculateDimen = MosaicMenu._recalculateDimen
        FileChooser._updateItemsBuildUI = MosaicMenu._updateItemsBuildUI
        -- Set MosaicMenu behaviour:
        FileChooser._do_cover_images = display_mode ~= "mosaic_text"
        FileChooser._do_hint_opened = true -- dogear at bottom
        -- Don't have "../" centered in empty directories
        FileChooser._do_center_partial_rows = false
    elseif FileChooser.display_mode_type == "list" then
        -- Replace some other original methods with those from our ListMenu
        local ListMenu = require("listmenu")
        FileChooser._recalculateDimen = ListMenu._recalculateDimen
        FileChooser._updateItemsBuildUI = ListMenu._updateItemsBuildUI
        -- Set ListMenu behaviour:
        if (display_mode == "list_only_meta") or (display_mode == "list_no_meta") then
            FileChooser._do_cover_images = false
        else
            FileChooser._do_cover_images = true
        end
        -- booklist_menu._do_cover_images = display_mode ~= "list_only_meta"
        FileChooser._do_filename_only = display_mode == "list_no_meta"
        FileChooser._do_hint_opened = true -- dogear at bottom
    end

    CoverMenu._FileChooser_genItemTable_orig = _FileChooser_genItemTable_orig
    FileChooser.genItemTable = CoverMenu.genItemTable

    CoverMenu._FileManager_setupLayout_orig = _FileManager_setupLayout_orig
    FileManager.setupLayout = CoverMenu.setupLayout

    CoverMenu._Menu_init_orig = _Menu_init_orig
    CoverMenu._Menu_updatePageInfo_orig = _Menu_updatePageInfo_orig

    Menu.init = CoverMenu.menuInit
    Menu.updatePageInfo = CoverMenu.updatePageInfo

    if init_done then
        self:refreshFileManagerInstance()
    else
        -- If KOReader has started directly to FileManager, the FileManager
        -- instance is being init()'ed and there is no FileManager.instance yet,
        -- but there'll be one at next tick.
        UIManager:nextTick(function()
            self:refreshFileManagerInstance()
        end)
    end
end

function Methods.setupWidgetDisplayMode(widget_id, display_mode)
    if display_mode == true then -- init
        display_mode = BookInfoManager:getSetting(display_mode_db_names[widget_id])
    end
    if not DISPLAY_MODES[display_mode] then
        display_mode = nil                                              -- unknown mode, fallback to classic
    end
    if init_done and display_mode == curr_display_modes[widget_id] then -- no change
        return
    end
    if init_done then -- save new mode in db
        BookInfoManager:saveSetting(display_mode_db_names[widget_id], display_mode)
    end
    -- remember current mode in module variable
    curr_display_modes[widget_id] = display_mode
    logger.dbg(burrow_debug.logprefix, "Setting display mode:", widget_id, display_mode or "classic")

    if not init_done and not display_mode then
        return -- starting in classic mode, nothing to patch
    end

    -- We only need to replace one method
    local widget = _modified_widgets[widget_id]
    if display_mode then
        BurrowClass.addFileDialogButtons(widget_id)
        widget.updateItemTable = BurrowClass.getUpdateItemTableFunc(display_mode)
    else -- classic mode
        BurrowClass.removeFileDialogButtons(widget_id)
        widget.updateItemTable = _updateItemTable_orig_funcs[widget_id]
    end
end

function Methods.getUpdateItemTableFunc(display_mode)
    return function(this, ...)
        -- 'this' here is the single widget instance
        -- The widget has just created a new instance of BookList as 'booklist_menu'
        -- at each display of the widget. Soon after instantiation, this method
        -- is called. The first time it is called, we replace some methods.
        local booklist_menu = this.booklist_menu
        local widget_id = booklist_menu.name

        if not booklist_menu._burrow_overridden then
            booklist_menu._burrow_overridden = true

            -- In both mosaic and list modes, replace original methods with those from
            -- our generic CoverMenu
            local CoverMenu = require("covermenu")
            booklist_menu.updateItems = CoverMenu.updateItems
            booklist_menu.onCloseWidget = CoverMenu.onCloseWidget

            BurrowClass.initGrid(booklist_menu, display_mode)
            if booklist_menu.display_mode_type == "mosaic" then
                -- Replace some other original methods with those from our MosaicMenu
                local MosaicMenu = require("mosaicmenu")
                booklist_menu._recalculateDimen = MosaicMenu._recalculateDimen
                booklist_menu._updateItemsBuildUI = MosaicMenu._updateItemsBuildUI
                -- Set MosaicMenu behaviour:
                booklist_menu._do_cover_images = display_mode ~= "mosaic_text"
                booklist_menu._do_center_partial_rows = false -- nicer looking when few elements
            elseif booklist_menu.display_mode_type == "list" then
                -- Replace some other original methods with those from our ListMenu
                local ListMenu = require("listmenu")
                booklist_menu._recalculateDimen = ListMenu._recalculateDimen
                booklist_menu._updateItemsBuildUI = ListMenu._updateItemsBuildUI
                -- Set ListMenu behaviour:
                if (display_mode == "list_only_meta") or (display_mode == "list_no_meta") then
                    booklist_menu._do_cover_images = false
                else
                    booklist_menu._do_cover_images = true
                end
                -- booklist_menu._do_cover_images = display_mode ~= "list_only_meta"
                booklist_menu._do_filename_only = display_mode == "list_no_meta"
            end

            if widget_id == "history" then
                booklist_menu._do_hint_opened = BookInfoManager:getSetting("history_hint_opened")
            elseif widget_id == "collections" then
                booklist_menu._do_hint_opened = BookInfoManager:getSetting("collections_hint_opened")
            else -- "filesearcher"
                booklist_menu._do_hint_opened = true
            end
        end

        -- And do now what the original does
        _updateItemTable_orig_funcs[widget_id](this, ...)
    end
end

function Methods:getBookInfo(file)
    return BookInfoManager:getBookInfo(file)
end

function Methods.getDocProps(file)
    return BookInfoManager:getDocProps(file)
end

function Methods:onInvalidateMetadataCache(file)
    BookInfoManager:deleteBookInfo(file)
    return true
end

function Methods:extractBooksInDirectory(path)
    local Trapper = require("ui/trapper")
    Trapper:wrap(function()
        BookInfoManager:extractBooksInDirectory(path)
    end)
end

-- Gesturable: Increase items per page (makes items smaller)
function Methods:onIncreaseItemsPerPage()
    local fc = self.ui.file_chooser
    local display_mode = BookInfoManager:getSetting("filemanager_display_mode")
    -- list modes
    if display_mode == "list_image_meta" or display_mode == "list_only_meta" or display_mode == "list_no_meta" then
        local files_per_page = fc.files_per_page or burrow_util.list_defaults.default_items_per_page
        files_per_page = math.min(files_per_page + 1, burrow_util.list_defaults.max_items_per_page)
        BookInfoManager:saveSetting("files_per_page", files_per_page)
        FileChooser.files_per_page = files_per_page
        -- grid mode
    elseif display_mode == "mosaic_image" then
        local Device = require("device")
        local Screen = Device.screen
        local portrait_mode = Screen:getWidth() <= Screen:getHeight()
        if portrait_mode then
            local portrait_cols = BookInfoManager:getSetting("nb_cols_portrait") or burrow_util.grid_defaults.default_cols
            local portrait_rows = BookInfoManager:getSetting("nb_rows_portrait") or burrow_util.list_defaults.default_rows
            if portrait_cols == portrait_rows then
                fc.nb_cols_portrait = math.min(portrait_cols + 1, burrow_util.grid_defaults.max_cols)
                fc.nb_rows_portrait = math.min(portrait_rows + 1, burrow_util.grid_defaults.max_rows)
                BookInfoManager:saveSetting("nb_cols_portrait", fc.nb_cols_portrait)
                BookInfoManager:saveSetting("nb_rows_portrait", fc.nb_rows_portrait)
                FileChooser.nb_cols_portrait = fc.nb_cols_portrait
                FileChooser.nb_rows_portrait = fc.nb_rows_portrait
            end
        end
        if not portrait_mode then
            local landscape_cols = BookInfoManager:getSetting("nb_cols_landscape") or burrow_util.grid_defaults.default_cols
            local landscape_rows = BookInfoManager:getSetting("nb_rows_landscape") or burrow_util.list_defaults.default_rows
            if landscape_cols == landscape_rows then
                fc.nb_cols_landscape = math.min(landscape_cols + 1, burrow_util.grid_defaults.max_cols)
                fc.nb_rows_landscape = math.min(landscape_rows + 1, burrow_util.grid_defaults.max_rows)
                BookInfoManager:saveSetting("nb_cols_landscape", fc.nb_cols_landscape)
                BookInfoManager:saveSetting("nb_rows_landscape", fc.nb_rows_landscape)
                FileChooser.nb_cols_landscape = fc.nb_cols_landscape
                FileChooser.nb_rows_landscape = fc.nb_rows_landscape
            end
        end
    end
    fc.no_refresh_covers = nil
    fc:updateItems()
end

-- Gesturable: Decrease items per page (makes items bigger)
function Methods:onDecreaseItemsPerPage()
    local fc = self.ui.file_chooser
    local display_mode = BookInfoManager:getSetting("filemanager_display_mode")
    -- list modes
    if display_mode == "list_image_meta" or display_mode == "list_only_meta" or display_mode == "list_no_meta" then
        local files_per_page = fc.files_per_page or burrow_util.list_defaults.default_items_per_page
        files_per_page = math.max(files_per_page - 1, burrow_util.list_defaults.min_items_per_page)
        BookInfoManager:saveSetting("files_per_page", files_per_page)
        FileChooser.files_per_page = files_per_page
        -- grid mode
    elseif display_mode == "mosaic_image" then
        local Device = require("device")
        local Screen = Device.screen
        local portrait_mode = Screen:getWidth() <= Screen:getHeight()
        if portrait_mode then
            local portrait_cols = BookInfoManager:getSetting("nb_cols_portrait") or burrow_util.grid_defaults.default_cols
            local portrait_rows = BookInfoManager:getSetting("nb_rows_portrait") or burrow_util.list_defaults.default_rows
            if portrait_cols == portrait_rows then
                fc.nb_cols_portrait = math.max(portrait_cols - 1, burrow_util.grid_defaults.min_cols)
                fc.nb_rows_portrait = math.max(portrait_rows - 1, burrow_util.grid_defaults.min_rows)
                BookInfoManager:saveSetting("nb_cols_portrait", fc.nb_cols_portrait)
                BookInfoManager:saveSetting("nb_rows_portrait", fc.nb_rows_portrait)
                FileChooser.nb_cols_portrait = fc.nb_cols_portrait
                FileChooser.nb_rows_portrait = fc.nb_rows_portrait
            end
        end
        if not portrait_mode then
            local landscape_cols = BookInfoManager:getSetting("nb_cols_landscape") or burrow_util.grid_defaults.default_cols
            local landscape_rows = BookInfoManager:getSetting("nb_rows_landscape") or burrow_util.list_defaults.default_rows
            if landscape_cols == landscape_rows then
                fc.nb_cols_landscape = math.max(landscape_cols - 1, burrow_util.grid_defaults.min_cols)
                fc.nb_rows_landscape = math.max(landscape_rows - 1, burrow_util.grid_defaults.min_rows)
                BookInfoManager:saveSetting("nb_cols_landscape", fc.nb_cols_landscape)
                BookInfoManager:saveSetting("nb_rows_landscape", fc.nb_rows_landscape)
                FileChooser.nb_cols_landscape = fc.nb_cols_landscape
                FileChooser.nb_rows_landscape = fc.nb_rows_landscape
            end
        end
    end
    fc.no_refresh_covers = nil
    fc:updateItems()
end

-- Gesturable: Switch to Cover Grid display mode
function Methods:onSwitchToCoverGrid()
    self:setDisplayMode("mosaic_image")
end

-- Gesturable: Switch to Cover List display mode
function Methods:onSwitchToCoverList()
    self:setDisplayMode("list_image_meta")
end

function Methods.addSortMethods()
    BookList.collates.title = {
        text = _("Burrow") .. " - " .. _("Title"),
        menu_order = 401,
        item_func = function(item, ui)
            local file = item.path or item.file
            item.title = burrow_util.getTitle(file) or "\u{FFFF}"
        end,
        init_sort_func = function()
            return function(a, b)
                return FFIUtil.strcoll(a.title, b.title)
            end
        end,
    }
    BookList.collates.authors = {
        text = _("Burrow") .. " - " .. _("Author first name"),
        menu_order = 402,
        item_func = function(item, ui)
            local file = item.path or item.file
            item.author = burrow_util.getAuthor(file, false, nil) or "\u{FFFF}"
        end,
        init_sort_func = function()
            return function(a, b)
                if a.author ~= b.author then
                    return FFIUtil.strcoll(a.author, b.author)
                end
                return FFIUtil.strcoll((a.path or a.file), (b.path or b.file))
            end
        end,
    }
    BookList.collates.authorsswap = {
        text = _("Burrow") .. " - " .. _("Author last name"),
        menu_order = 403,
        item_func = function(item, ui)
            local file = item.path or item.file
            item.author = burrow_util.getAuthor(file, true, nil) or "\u{FFFF}"
        end,
        init_sort_func = function()
            return function(a, b)
                if a.author ~= b.author then
                    return FFIUtil.strcoll(a.author, b.author)
                end
                return FFIUtil.strcoll((a.path or a.file), (b.path or b.file))
            end
        end,
    }
    BookList.collates.series = {
        text = _("Burrow") .. " - " .. _("Series"),
        menu_order = 404,
        item_func = function(item, ui)
            local file = item.path or item.file
            item.series = burrow_util.getSeries(file) or "\u{FFFF}"
        end,
        init_sort_func = function()
            return function(a, b)
                if a.series ~= b.series then
                    return FFIUtil.strcoll(a.series, b.series)
                end
                return FFIUtil.strcoll((a.path or a.file), (b.path or b.file))
            end
        end,
    }
    BookList.collates.keywords = {
        text = _("Burrow") .. " - " .. _("Keywords"),
        menu_order = 405,
        item_func = function(item, ui)
            local file = item.path or item.file
            item.keywords = burrow_util.getKeyword(file) or "\u{FFFF}"
        end,
        init_sort_func = function()
            return function(a, b)
                if a.keywords ~= b.keywords then
                    return FFIUtil.strcoll(a.keywords, b.keywords)
                end
                return FFIUtil.strcoll((a.path or a.file), (b.path or b.file))
            end
        end,
    }
    BookList.collates.pages = {
        text = _("Burrow") .. " - " .. _("Total pages"),
        menu_order = 411,
        item_func = function(item, ui)
            local file = item.path or item.file
            item.pages = burrow_util.getPageCount(file) or 999999
        end,
        init_sort_func = function()
            return function(a, b)
                if a.pages ~= b.pages then
                    return a.pages < b.pages
                end
                return FFIUtil.strcoll((a.path or a.file), (b.path or b.file))
            end
        end,
        mandatory_func = function(item)
            return item.pages
        end,
    }
    BookList.collates.fullmeta = {
        text = _("Burrow") .. " - " .. _("Author first name") ..", ".. _("Series") ..", ".. _("Title"),
        menu_order = 421,
        item_func = function(item, ui)
            local file = item.path or item.file
            item.fullmeta = burrow_util.getMetaSummary(file, false) or ""
        end,
        init_sort_func = function()
            return function(a, b)
                if a.fullmeta ~= b.fullmeta then
                    return a.fullmeta < b.fullmeta
                end
                return FFIUtil.strcoll((a.path or a.file), (b.path or b.file))
            end
        end,
        mandatory_func = function(item)
            return item.fullmeta
        end,
    }
    BookList.collates.fullmetaswap = {
        text = _("Burrow") .. " - " .. _("Author last name") ..", ".. _("Series") ..", ".. _("Title"),
        menu_order = 422,
        item_func = function(item, ui)
            local file = item.path or item.file
            item.fullmeta = burrow_util.getMetaSummary(file, true) or ""
        end,
        init_sort_func = function()
            return function(a, b)
                if a.fullmeta ~= b.fullmeta then
                    return a.fullmeta < b.fullmeta
                end
                return FFIUtil.strcoll((a.path or a.file), (b.path or b.file))
            end
        end,
        mandatory_func = function(item)
            return item.fullmeta
        end,
    }
end

function LibraryCore.apply(Burrow)
    if type(Burrow) ~= "table" then
        return nil, "Burrow class was not provided"
    end
    if rawget(Burrow, "_burrow_library_core_attached") then
        BurrowClass = Burrow
        return true
    end

    BurrowClass = Burrow
    Burrow.modes = {
        { _("Cover List"),     "list_image_meta" },
        { _("Cover Grid"),     "mosaic_image" },
        { _("Details List"),   "list_only_meta" },
        { _("Filenames List"), "list_no_meta" },
    }
    for name, value in pairs(Methods) do
        Burrow[name] = value
    end
    Burrow._burrow_library_core_attached = true
    return true
end

function LibraryCore.isInitialized()
    return init_done
end

return LibraryCore

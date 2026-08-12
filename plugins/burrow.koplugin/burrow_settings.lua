local _ = require("gettext")

local BurrowSettings = {}

BurrowSettings.features = {
    {
        id = "library_visuals",
        text = _("Burrow library styling"),
        help_text = _("Rounded covers, folder styling, captions, badges, the top bar, hero card, and the expanded cover grid."),
        default = true,
    },
    {
        id = "home_store",
        text = _("Home and Store footer"),
        help_text = _("Show Home and Store navigation in the configured home folder."),
        default = true,
    },
    {
        id = "quick_settings",
        text = _("Rounded quick settings"),
        help_text = _("Add Burrow's rounded quick-settings panel while retaining KOReader's native top-menu tabs."),
        default = true,
    },
    {
        id = "statusbar",
        text = _("Status-bar margins and preset cycling"),
        help_text = _("Add separate left and right margins and allow taps to rotate saved status-bar presets."),
        default = true,
    },
    {
        id = "reading_location",
        text = _("Reading-location return button"),
        help_text = _("Remember the furthest reading location and provide a configurable return button."),
        default = true,
    },
    {
        id = "reader_bottom_menu",
        text = _("Rounded menu sheets"),
        help_text = _("Remove the hard outer rules and safely round the exposed edge of KOReader's native top and reader-bottom menus without replacing their widgets."),
        default = true,
    },
}

local function featureKey(id)
    return "burrow_feature_" .. id
end

function BurrowSettings:isFeatureEnabled(id)
    local value = G_reader_settings:readSetting(featureKey(id))
    if value ~= nil then
        return value == true
    end
    for _, feature in ipairs(self.features) do
        if feature.id == id then
            return feature.default
        end
    end
    return false
end

function BurrowSettings:setFeatureEnabled(id, enabled)
    G_reader_settings:saveSetting(featureKey(id), enabled and true or false)
end

function BurrowSettings:getModuleManifest()
    local modules = {}
    local function add(id, source, phase, options)
        options = options or {}
        modules[#modules + 1] = {
            id = id,
            filename = options.filename,
            module_name = options.module_name,
            source = source,
            phase = phase,
            feature = options.feature or id,
            critical = options.critical == true,
            depends = options.depends or {},
        }
    end

    -- The core library runtime is a guarded plugin module, not an internal
    -- userpatch. It must attach successfully before the optional visual modules.
    add("library_core", "burrow_library", "core", {
        module_name = "burrow_library",
        feature = "library_core",
        critical = true,
    })

    local function automaticSeries()
        add("automatic_series", "2-automatic-book-series.lua", "instance", {
            filename = "2-automatic-book-series.lua",
            feature = "library_navigation",
            depends = { "library_core" },
        })
    end

    if self:isFeatureEnabled("library_visuals") then
        local function visual(id, filename, depends)
            add(id, filename, "instance", {
                filename = filename,
                feature = "library_visuals",
                depends = depends or { "library_core" },
            })
        end

        visual("disable_widgets", "2--disable-burrow-widgets.lua")

        -- IMPORTANT LOAD ORDER:
        -- rounded_covers must wrap Burrow's original MosaicMenuItem:update before
        -- automatic_series wraps it. rounded_covers retrieves the ImageWidget
        -- upvalue from that original closure to establish the shared 2:3 cover
        -- geometry and caption reserve.
        visual("rounded_covers", "2--stretched-rounded-covers.lua")
        automaticSeries()

        visual("simple_topbar", "2-a-burrow-simple-topbar.lua")
        visual("percent_badge", "2-percent-badge.lua", { "library_core", "rounded_covers" })
        visual("grid_8x8", "2-burrow-grid-8x8.lua")
        visual("hero_card", "2-burrow-hero-card.lua", { "library_core", "simple_topbar" })
        visual("hide_grid_lines", "2-burrow-hide-grid-lines.lua")
        visual("disable_fake_covers", "2-burrow-disable-fake-covers.lua")
        visual("rounded_folder_covers", "2-rounded-folder-covers.lua")
        visual("series_badge", "2-series-badge-numbered.lua", {
            "library_core", "rounded_covers", "automatic_series",
        })

        -- The physical-folder consistency layer used to be applied from main.lua
        -- after every instance module. That meant it rebuilt physical folders
        -- after cover_layout had already resized them. Pre-apply it here instead;
        -- main.lua's later call becomes a harmless no-op because Module.applied is
        -- already true.
        add("folder_consistency", "burrow_list_folder_covers", "instance", {
            module_name = "burrow_list_folder_covers",
            feature = "library_visuals",
            depends = { "library_core", "rounded_covers", "automatic_series" },
        })

        -- This is deliberately the last cover-rendering wrapper. It receives the
        -- finished book, series, or physical-folder widget and applies one shared
        -- size, spacing, and caption-placement policy.
        visual("cover_layout", "2-z-burrow-cover-layout.lua", {
            "library_core", "rounded_covers", "folder_consistency",
        })
    else
        -- Series grouping and Return to Library remain available without Burrow's
        -- visual styling, but when styling is enabled they must load after the
        -- rounded-cover geometry hook above.
        automaticSeries()
    end
    if self:isFeatureEnabled("home_store") then
        add("home_store_footer", "2-home-store-footer.lua", "instance", {
            filename = "2-home-store-footer.lua",
            feature = "home_store",
            depends = { "library_core" },
        })
    end
    if self:isFeatureEnabled("quick_settings") then
        add("quick_settings", "2-quick-settings.lua", "early", {
            filename = "2-quick-settings.lua",
            feature = "quick_settings",
        })
    end
    if self:isFeatureEnabled("statusbar") then
        add("statusbar", "2-statusbar-margins-presets.lua", "early", {
            filename = "2-statusbar-margins-presets.lua",
            feature = "statusbar",
        })
    end
    if self:isFeatureEnabled("reading_location") then
        add("reading_location", "2-track-reading-location.lua", "early", {
            filename = "2-track-reading-location.lua",
            feature = "reading_location",
        })
    end
    if self:isFeatureEnabled("reader_bottom_menu") then
        add("rounded_menu_sheets", "2-rounded-reader-bottom-menu.lua", "early", {
            filename = "2-rounded-reader-bottom-menu.lua",
            feature = "reader_bottom_menu",
        })
    end

    -- Apply last so it can collect settings inserted by the other Burrow
    -- modules and present one consistent Burrow Settings hierarchy.
    add("settings_menu_cleanup", "2-zz-burrow-settings-menu.lua", "instance", {
        filename = "2-zz-burrow-settings-menu.lua",
        feature = "settings_menu",
        depends = { "library_core" },
    })

    return modules
end

local function saveIfMissing(settings, key, value)
    if settings:getSetting(key) == nil then
        settings:saveSetting(key, value)
    end
end

local function mergeMissing(target, defaults)
    target = type(target) == "table" and target or {}
    for key, value in pairs(defaults) do
        if target[key] == nil then
            if type(value) == "table" then
                local copy = {}
                for nested_key, nested_value in pairs(value) do
                    copy[nested_key] = nested_value
                end
                target[key] = copy
            else
                target[key] = value
            end
        end
    end
    return target
end

function BurrowSettings:applyFirstRunDefaults(BookInfoManager)
    -- Small versioned migrations run even for an existing Burrow installation.
    if not G_reader_settings:isTrue("burrow_defaults_applied_v2") then
        if G_reader_settings:readSetting("burrow_home_store_show_labels") == nil then
            G_reader_settings:saveSetting("burrow_home_store_show_labels", true)
        end
        if G_reader_settings:readSetting("burrow_home_store_auto_hide_without_catalogs") == nil then
            G_reader_settings:saveSetting("burrow_home_store_auto_hide_without_catalogs", false)
        end
        G_reader_settings:makeTrue("burrow_defaults_applied_v2")
    end

    if G_reader_settings:isTrue("burrow_defaults_applied_v1") then
        return
    end

    -- Burrow-compatible library settings. Existing values are preserved.
    saveIfMissing(BookInfoManager, "filemanager_display_mode", "mosaic_image")
    saveIfMissing(BookInfoManager, "history_display_mode", "mosaic_image")
    saveIfMissing(BookInfoManager, "collection_display_mode", "mosaic_image")
    saveIfMissing(BookInfoManager, "nb_cols_portrait", 3)
    saveIfMissing(BookInfoManager, "nb_rows_portrait", 3)
    saveIfMissing(BookInfoManager, "nb_cols_landscape", 3)
    saveIfMissing(BookInfoManager, "nb_rows_landscape", 3)
    saveIfMissing(BookInfoManager, "automatic_series_grouping_enabled", true)
    saveIfMissing(BookInfoManager, "hide_file_info", true)
    saveIfMissing(BookInfoManager, "show_pages_read_as_progress", false)
    saveIfMissing(BookInfoManager, "show_name_grid_folders", false)
    saveIfMissing(BookInfoManager, "opened_at_top_of_library", true)
    saveIfMissing(BookInfoManager, "use_custom_bookstatus", true)
    saveIfMissing(BookInfoManager, "use_custom_sorts", true)
    saveIfMissing(BookInfoManager, "burrow_cover_gap_reduction", 0)
    saveIfMissing(BookInfoManager, "burrow_cover_size_percent", 100)
    saveIfMissing(BookInfoManager, "burrow_show_book_titles", "Y")
    saveIfMissing(BookInfoManager, "burrow_show_folder_titles", "Y")
    saveIfMissing(BookInfoManager, "burrow_show_series_titles", "Y")

    saveIfMissing(BookInfoManager, "burrow_topbar_show_home", true)
    saveIfMissing(BookInfoManager, "burrow_topbar_show_favorites", false)
    saveIfMissing(BookInfoManager, "burrow_topbar_show_history", true)
    saveIfMissing(BookInfoManager, "burrow_topbar_show_logo", true)
    saveIfMissing(BookInfoManager, "burrow_topbar_show_last_document", false)
    saveIfMissing(BookInfoManager, "burrow_topbar_show_up", true)
    saveIfMissing(BookInfoManager, "burrow_topbar_show_menu", true)
    saveIfMissing(BookInfoManager, "burrow_topbar_size_percent", 85)
    saveIfMissing(BookInfoManager, "burrow_topbar_logo_only_right", true)

    if G_reader_settings:readSetting("burrow_home_store_label_size_percent") == nil then
        G_reader_settings:saveSetting("burrow_home_store_label_size_percent", 100)
    end

    local quick_defaults = {
        columns = 4,
        open_on_start = true,
        rounded_tabs = false, -- deprecated; native KOReader top tabs are retained
        show_frontlight = true,
        show_warmth = true,
        filemanager_buttons = {
            file_search = true,
            wifi = true,
            night = true,
            rotate = true,
            sleep = false,
            restart = true,
            exit = true,
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
        reader_order = {
            "toc", "search_book", "bookmarks", "text", "book_info",
            "kosync_push", "kosync_pull", "library", "night", "rotate",
            "wifi", "sleep", "restart", "exit",
        },
    }
    if G_reader_settings:readSetting("rounded_quick_settings_panel") == nil then
        G_reader_settings:saveSetting("rounded_quick_settings_panel", quick_defaults)
    end

    -- Only establish the full Burrow status bar when no footer setting exists.
    -- Existing KOReader status-bar choices are never replaced.
    if G_reader_settings:readSetting("footer") == nil then
        local ReaderFooter = require("apps/reader/modules/readerfooter")
        local util = require("util")
        local footer = util.tableDeepCopy(ReaderFooter.default_settings)
        local overrides = {
            align = "center",
            all_at_once = true,
            auto_refresh_time = true,
            battery = false,
            book_author = false,
            book_chapter = false,
            book_time_to_read = false,
            book_title = false,
            bookmark_count = false,
            bottom_horizontal_separator = false,
            chapter_progress = false,
            chapter_progress_bar = false,
            chapter_time_to_read = true,
            container_bottom_padding = 3,
            container_height = 14,
            disable_progress_bar = true,
            dynamic_filler = true,
            frontlight = false,
            hide_empty_generators = true,
            item_prefix = "compact_items",
            items_separator = "none",
            lock_tap = false,
            mem_usage = false,
            page_progress = true,
            pages_left = false,
            pages_left_book = false,
            percentage = false,
            progress_bar_position = "alongside",
            progress_margin = false,
            progress_margin_width = 55,
            reclaim_height = false,
            skim_widget_on_hold = false,
            statusbar_cycle_presets = true,
            statusbar_left_margin = 40,
            statusbar_right_margin = 40,
            text_font_bold = false,
            text_font_size = 14,
            time = false,
            toc_markers = true,
            toc_markers_width = 1,
            wifi_status = false,
        }
        for key, value in pairs(overrides) do
            footer[key] = value
        end
        G_reader_settings:saveSetting("footer", footer)
        G_reader_settings:saveSetting("reader_footer_mode", 2)
    else
        local footer = G_reader_settings:readSetting("footer")
        footer = mergeMissing(footer, {
            statusbar_cycle_presets = true,
            statusbar_left_margin = 40,
            statusbar_right_margin = 40,
        })
        G_reader_settings:saveSetting("footer", footer)
    end

    G_reader_settings:makeTrue("burrow_defaults_applied_v1")
end

function BurrowSettings:removeAllSettings()
    for _, feature in ipairs(self.features) do
        G_reader_settings:delSetting(featureKey(feature.id))
    end
    local keys = {
        "burrow_defaults_applied_v1",
        "burrow_defaults_applied_v2",
        "burrow_home_store_show_labels",
        "burrow_home_store_auto_hide_without_catalogs",
        "burrow_home_store_label_size_percent",
        "burrow_store_catalog_url",
        "burrow_store_catalog_title",
    }
    for _, key in ipairs(keys) do
        G_reader_settings:delSetting(key)
    end
end

function BurrowSettings:featureMenuItems(UIManager)
    local items = {}
    for _, feature in ipairs(self.features) do
        local current = feature
        items[#items + 1] = {
            text = current.text,
            help_text = current.help_text,
            checked_func = function()
                return BurrowSettings:isFeatureEnabled(current.id)
            end,
            callback = function()
                BurrowSettings:setFeatureEnabled(
                    current.id,
                    not BurrowSettings:isFeatureEnabled(current.id)
                )
                UIManager:askForRestart()
            end,
        }
    end
    return items
end

return BurrowSettings

local MODULE_KEY = "burrow.internal.2_zz_burrow_settings_menu"
local existing_module = package.loaded[MODULE_KEY]
if existing_module then return existing_module end
local Module = { key = MODULE_KEY, phase = "instance", filename = "2-zz-burrow-settings-menu.lua" }
package.loaded[MODULE_KEY] = Module

-- Burrow settings cleanup v2.
-- Rebuild the user-facing menu around normal tasks instead of exposing the
-- structure inherited from Cover Browser and individual Burrow patches.

local function applySettingsCleanup(plugin)
    if not plugin or plugin._burrow_settings_cleanup_v2_patched then
        return true
    end
    plugin._burrow_settings_cleanup_v2_patched = true

    local BookInfoManager = require("bookinfomanager")
    local BurrowLoader = require("burrow_loader")
    local BurrowSettings = require("burrow_settings")
    local UIManager = require("ui/uimanager")
    local _ = require("l10n.gettext")
    local T = require("ffi/util").template

    local SERIES_SETTING = "automatic_series_grouping_enabled"
    local COVER_SIZE_SETTING = "burrow_cover_size_percent"
    local COVER_GAP_SETTING = "burrow_cover_gap_reduction"
    local SHOW_BOOK_TITLES_SETTING = "burrow_show_book_titles"
    local SHOW_FOLDER_TITLES_SETTING = "burrow_show_folder_titles"
    local SHOW_SERIES_TITLES_SETTING = "burrow_show_series_titles"

    local DEFAULT_COVER_SIZE = 100
    local MIN_COVER_SIZE = 50
    local MAX_COVER_SIZE = 130
    local DEFAULT_COVER_GAP = 0
    local MIN_COVER_GAP = 0
    local MAX_COVER_GAP = 30
    local RETURN_TILE_SETTING = "burrow_return_to_library_enabled"

    local function textOf(item)
        if not item then return nil end
        if item.text then return item.text end
        if item.text_func then
            local ok, value = pcall(item.text_func)
            if ok then return value end
        end
        return nil
    end

    local function startsWith(value, prefix)
        return type(value) == "string"
            and type(prefix) == "string"
            and value:sub(1, #prefix) == prefix
    end

    local function append(target, item)
        if item then target[#target + 1] = item end
    end

    local function findItem(items, wanted_text)
        for _, item in ipairs(items or {}) do
            if textOf(item) == wanted_text then
                return item
            end
        end
        return nil
    end

    local function findByPrefix(items, prefix)
        for _, item in ipairs(items or {}) do
            if startsWith(textOf(item), prefix) then
                return item
            end
        end
        return nil
    end

    local function featureToggle(id, text, help_text)
        return {
            text = text,
            help_text = help_text,
            checked_func = function()
                return BurrowSettings:isFeatureEnabled(id)
            end,
            callback = function()
                BurrowSettings:setFeatureEnabled(
                    id,
                    not BurrowSettings:isFeatureEnabled(id)
                )
                UIManager:askForRestart()
            end,
        }
    end

    local function seriesGroupingItem(instance)
        local function enabled()
            return BookInfoManager:getSetting(SERIES_SETTING) ~= "N"
        end
        return {
            text = _("Group books into series folders"),
            help_text = _("Create virtual folders for books that share series metadata. Physical folders and files are not changed."),
            checked_func = enabled,
            callback = function()
                BookInfoManager:saveSetting(SERIES_SETTING, enabled() and "N" or "Y")
                if instance.ui and instance.ui.file_chooser then
                    instance.ui.file_chooser:refreshPath()
                end
            end,
        }
    end

    local function titleVisibilityItem(instance, setting_name, text, help_text)
        local function enabled()
            local value = BookInfoManager:getSetting(setting_name)
            return value ~= "N" and value ~= false
        end
        return {
            text = text,
            help_text = help_text,
            checked_func = enabled,
            callback = function()
                BookInfoManager:saveSetting(setting_name, enabled() and "N" or "Y")
                if instance.ui and instance.ui.file_chooser then
                    instance.ui.file_chooser:refreshPath()
                end
            end,
        }
    end

    local function titlesUnderCoversMenu(instance)
        return {
            text = _("Titles under covers"),
            help_text = _("Choose which labels appear beneath covers in the Cover Grid."),
            sub_item_table = {
                titleVisibilityItem(
                    instance,
                    SHOW_BOOK_TITLES_SETTING,
                    _("Show book titles"),
                    _("Show each book title beneath its cover in the Cover Grid.")
                ),
                titleVisibilityItem(
                    instance,
                    SHOW_FOLDER_TITLES_SETTING,
                    _("Show folder titles"),
                    _("Show physical folder names beneath their covers in the Cover Grid.")
                ),
                titleVisibilityItem(
                    instance,
                    SHOW_SERIES_TITLES_SETTING,
                    _("Show series titles"),
                    _("Show automatic series-folder names beneath their covers in the Cover Grid.")
                ),
            },
        }
    end

    local function returnTileItem(instance)
        local function enabled()
            local value = G_reader_settings:readSetting(RETURN_TILE_SETTING)
            return value == nil or value == true
        end
        return {
            text = _("Show Return to Library tile"),
            help_text = _("Show a final Return to Library tile inside book folders and Burrow series folders."),
            checked_func = enabled,
            callback = function()
                G_reader_settings:saveSetting(RETURN_TILE_SETTING, not enabled())
                if instance.ui and instance.ui.file_chooser then
                    instance.ui.file_chooser:refreshPath()
                end
            end,
        }
    end


    local function clampInteger(value, default_value, minimum, maximum)
        value = tonumber(value) or default_value
        value = math.floor(value + 0.5)
        return math.max(minimum, math.min(maximum, value))
    end

    local function getCoverSize()
        return clampInteger(
            BookInfoManager:getSetting(COVER_SIZE_SETTING),
            DEFAULT_COVER_SIZE,
            MIN_COVER_SIZE,
            MAX_COVER_SIZE
        )
    end

    local function getCoverGapReduction()
        return clampInteger(
            BookInfoManager:getSetting(COVER_GAP_SETTING),
            DEFAULT_COVER_GAP,
            MIN_COVER_GAP,
            MAX_COVER_GAP
        )
    end

    local function coverSizeItem()
        return {
            text_func = function()
                return T(_("Cover size: %1%"), getCoverSize())
            end,
            help_text = _("Changes the size of book covers, physical folder covers, and automatic series-folder covers together."),
            callback = function()
                local SpinWidget = require("ui/widget/spinwidget")
                UIManager:show(SpinWidget:new {
                    title_text = _("Cover size"),
                    info_text = _("Adjusts every library cover together so books, physical folders, and automatic series folders stay the same size. Restart KOReader after saving."),
                    value = getCoverSize(),
                    default_value = DEFAULT_COVER_SIZE,
                    value_min = MIN_COVER_SIZE,
                    value_max = MAX_COVER_SIZE,
                    value_step = 5,
                    value_hold_step = 10,
                    unit = "%",
                    ok_text = _("Save"),
                    callback = function(spin)
                        BookInfoManager:saveSetting(
                            COVER_SIZE_SETTING,
                            clampInteger(spin.value, DEFAULT_COVER_SIZE, MIN_COVER_SIZE, MAX_COVER_SIZE)
                        )
                        UIManager:askForRestart()
                    end,
                })
            end,
        }
    end

    local function coverSpacingItem()
        return {
            text_func = function()
                return T(_("Space between covers: %1"), getCoverGapReduction())
            end,
            help_text = _("0 keeps the normal spacing. Higher values pull neighboring covers closer together without changing their touch targets."),
            callback = function()
                local SpinWidget = require("ui/widget/spinwidget")
                UIManager:show(SpinWidget:new {
                    title_text = _("Space between covers"),
                    info_text = _("0 keeps the normal spacing. Increase the value to reduce the visible space between books and folders. Restart KOReader after saving."),
                    value = getCoverGapReduction(),
                    default_value = DEFAULT_COVER_GAP,
                    value_min = MIN_COVER_GAP,
                    value_max = MAX_COVER_GAP,
                    value_step = 2,
                    value_hold_step = 5,
                    ok_text = _("Save"),
                    callback = function(spin)
                        BookInfoManager:saveSetting(
                            COVER_GAP_SETTING,
                            clampInteger(spin.value, DEFAULT_COVER_GAP, MIN_COVER_GAP, MAX_COVER_GAP)
                        )
                        UIManager:askForRestart()
                    end,
                })
            end,
        }
    end

    local function troubleshootingMenu()
        local degraded = BurrowLoader:getDegradedFeatures()
        if not next(degraded) then
            return nil
        end

        return {
            text = _("Troubleshooting"),
            sub_item_table = {
                {
                    text = _("Retry disabled components after restart"),
                    callback = function()
                        BurrowLoader:clearQuarantine()
                        UIManager:askForRestart()
                    end,
                },
                {
                    text = _("Show component status"),
                    keep_menu_open = true,
                    callback = function()
                        local InfoMessage = require("ui/widget/infomessage")
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
                },
            },
        }
    end

    local original_add_to_main_menu = plugin.addToMainMenu

    function plugin:addToMainMenu(menu_items)
        original_add_to_main_menu(self, menu_items)

        local root = menu_items.filemanager_display_mode
        local old_items = root and root.sub_item_table
        if not old_items then return end

        -- Remove the old series toggle from KOReader's File Browser settings.
        local filebrowser = menu_items.filebrowser_settings
        if filebrowser and filebrowser.sub_item_table then
            for index = #filebrowser.sub_item_table, 1, -1 do
                local item = filebrowser.sub_item_table[index]
                if item._automatic_series_menu_item
                    or textOf(item) == _("Group book series into folders")
                then
                    table.remove(filebrowser.sub_item_table, index)
                end
            end
        end

        local advanced_old = findItem(old_items, _("Advanced settings"))
        local advanced_sub = advanced_old and advanced_old.sub_item_table or {}
        local folder_old = findItem(advanced_sub, _("Folder display"))
        local folder_sub = folder_old and folder_old.sub_item_table or {}
        local book_old = findItem(advanced_sub, _("Book display"))
        local book_sub = book_old and book_old.sub_item_table or {}
        local footer_old = findItem(advanced_sub, _("Footer"))
        local library_mode_old = findItem(advanced_sub, _("Library mode"))
        local cache_old = findItem(advanced_sub, _("Cache database"))

        -- Library > View
        local view_items = {}
        append(view_items, findItem(old_items, _("Cover Grid")))
        append(view_items, findItem(old_items, _("Cover List")))
        append(view_items, findItem(old_items, _("Details List")))
        append(view_items, findItem(old_items, _("Filenames List")))
        local unified = findItem(old_items, _("Use this mode everywhere"))
        if unified then
            unified.text = _("Use the same view for Library, History, and Collections")
            unified.separator = true
            append(view_items, unified)
        end
        append(view_items, findItem(old_items, _("History display mode")))
        append(view_items, findItem(old_items, _("Collections display mode")))
        -- Cover geometry belongs with the normal Library view controls.
        -- Build these entries directly so the cleanup menu does not depend on
        -- finding the older dynamically-labelled patch entries.
        append(view_items, coverSizeItem())
        append(view_items, coverSpacingItem())
        append(view_items, titlesUnderCoversMenu(self))

        local items_per_page = findItem(old_items, _("Items per page"))
        if items_per_page then
            items_per_page.text = _("Grid and list size")
            items_per_page.separator = true
            append(view_items, items_per_page)
        end

        -- Library > Series
        local series_items = { seriesGroupingItem(self) }
        local show_series = findItem(book_sub, _("Show series"))
        if show_series then
            show_series.text = _("Show series name with books")
            append(series_items, show_series)
        end

        -- Library > Folder covers
        local folder_cover_items = {}
        local generate_folder_covers = findItem(folder_sub, _("Auto-generate cover images from books"))
        if generate_folder_covers then
            generate_folder_covers.text = _("Generate folder covers from books")
            append(folder_cover_items, generate_folder_covers)
        end
        local show_folder_names = findItem(folder_sub, _("Overlay name and details in cover grid"))
        if show_folder_names then
            show_folder_names.text = _("Show folder names and details on covers")
            append(folder_cover_items, show_folder_names)
        end

        -- Library > Book details
        local book_detail_items = {}
        local file_info = findItem(book_sub, _("Show file info instead of pages or progress %"))
        if file_info then
            file_info.text = _("Show file details instead of reading progress")
            append(book_detail_items, file_info)
        end
        local pages_read = findItem(book_sub, _("Show pages read instead of progress %"))
        if pages_read then
            pages_read.text = _("Show pages read instead of percentage")
            append(book_detail_items, pages_read)
        end
        local progress_percent = findItem(book_sub, _("Show progress % instead of progress bars"))
        if progress_percent then
            progress_percent.text = _("Show progress percentage instead of bars")
            append(book_detail_items, progress_percent)
        end
        local tags = findItem(book_sub, _("Show calibre tags/keywords"))
        if tags then
            tags.text = _("Show tags and keywords")
            tags.separator = true
            append(book_detail_items, tags)
        end

        -- Library > Sorting
        local sorting_items = {}
        local opened_first = library_mode_old
            and findItem(library_mode_old.sub_item_table, _("Show opened books first"))
        append(sorting_items, opened_first)

        local library_items = {
            { text = _("View"), sub_item_table = view_items },
            { text = _("Series"), sub_item_table = series_items },
            { text = _("Folder covers"), sub_item_table = folder_cover_items },
            { text = _("Book details"), sub_item_table = book_detail_items },
        }
        if #sorting_items > 0 then
            append(library_items, { text = _("Sorting"), sub_item_table = sorting_items })
        end

        -- Navigation. Reuse the mature top-bar/footer controls, but present
        -- them only here rather than mixed with the library display menu.
        local navigation_items = { returnTileItem(self) }
        local top_bar = findItem(old_items, _("Top bar"))
        append(navigation_items, top_bar)

        local home_store_settings = {}
        append(home_store_settings, findItem(old_items, _("Show Home and Store labels")))
        append(home_store_settings, findItem(old_items, _("Hide labels when no Store catalogs are configured")))
        append(home_store_settings, findByPrefix(old_items, _("Home and Store label size")))
        if #home_store_settings > 0 then
            append(navigation_items, {
                text = _("Home and Store footer"),
                sub_item_table = home_store_settings,
            })
        end

        -- Quick Settings gets its own obvious section instead of being hidden
        -- in KOReader's general Settings tab.
        local quick_settings_items = {}
        local quick_module = package.loaded["burrow.internal.2_quick_settings"]
        if quick_module and type(quick_module.getSettingsMenu) == "function" then
            local quick_menu = quick_module.getSettingsMenu()
            for _, item in ipairs((quick_menu and quick_menu.sub_item_table) or {}) do
                append(quick_settings_items, item)
            end
        end

        -- Advanced contains things normal Burrow users should rarely need.
        local legacy_visual_items = {}
        local stacked = findItem(folder_sub, _("Show auto-generated cover images as a stack"))
        if stacked then
            stacked.text = _("Use stacked folder covers")
            append(legacy_visual_items, stacked)
        end
        append(legacy_visual_items, findItem(book_sub, _("Always show maximum length progress bars")))
        append(legacy_visual_items, findItem(book_sub, _("Use custom book status screen")))
        append(legacy_visual_items, findItem(folder_sub, _("Use custom sort methods")))
        if footer_old then
            footer_old.text = _("Legacy file browser footer")
            append(legacy_visual_items, footer_old)
        end
        append(legacy_visual_items,
            findItem(advanced_sub, _("Show last item indicator on touchscreen devices")))

        local component_items = {
            featureToggle(
                "library_visuals",
                _("Burrow library styling"),
                _("Rounded covers, folder styling, badges, top bar, hero card, and expanded grid. Restart required.")
            ),
            featureToggle(
                "home_store",
                _("Home and Store footer"),
                _("Enable Burrow's Home and Store footer. Restart required.")
            ),
            featureToggle(
                "quick_settings",
                _("Quick Settings"),
                _("Enable Burrow's Quick Settings panel. Restart required.")
            ),
            featureToggle(
                "reading_location",
                _("Reading-location return button"),
                _("Enable Burrow's furthest-reading-location tracking and return button. Restart required.")
            ),
            featureToggle(
                "statusbar",
                _("Status-bar extensions"),
                _("Enable Burrow's side margins and preset cycling additions. Restart required.")
            ),
            featureToggle(
                "reader_bottom_menu",
                _("Rounded menu sheets"),
                _("Round the exposed edges of KOReader's native top and reader-bottom menus. Restart required.")
            ),
        }

        local advanced_items = {
            { text = _("Components"), sub_item_table = component_items },
        }
        if cache_old then
            cache_old.text = _("Library cache")
            append(advanced_items, cache_old)
        end
        if #legacy_visual_items > 0 then
            append(advanced_items, {
                text = _("Legacy and compatibility options"),
                sub_item_table = legacy_visual_items,
            })
        end
        append(advanced_items, troubleshootingMenu())

        local clean_items = {
            { text = _("Library"), sub_item_table = library_items },
            { text = _("Navigation"), sub_item_table = navigation_items },
        }

        if #quick_settings_items > 0 then
            append(clean_items, {
                text = _("Quick settings"),
                sub_item_table = quick_settings_items,
            })
        end

        local store = findItem(old_items, _("Store")) or findItem(old_items, _("Store unavailable"))
        append(clean_items, store)
        append(clean_items, { text = _("Advanced"), sub_item_table = advanced_items })
        append(clean_items, findItem(old_items, _("About Burrow")))

        root.sub_item_table = clean_items
    end

    return true
end

Module.apply = applySettingsCleanup
return Module

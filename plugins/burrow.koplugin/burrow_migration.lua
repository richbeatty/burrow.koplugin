-- Burrow legacy migration helpers.
--
-- Exact names from earlier standalone components are intentionally isolated in
-- this file so existing settings and caches can be imported without keeping
-- those namespaces throughout the active Burrow codebase.

local DataStorage = require("datastorage")
local FFIUtil = require("ffi/util")
local logger = require("logger")
local util = require("util")

local BurrowMigration = {}

local settings_dir = DataStorage:getSettingsDir()
local data_dir = DataStorage:getDataDir()

local LEGACY_LIBRARY_DB = settings_dir .. "/PT_bookinfo_cache.sqlite3"
local BURROW_LIBRARY_DB = settings_dir .. "/burrow_library.sqlite3"
local LEGACY_STORE_SETTINGS = settings_dir .. "/opdsplus.lua"
local BURROW_STORE_SETTINGS = settings_dir .. "/burrow_store.lua"
local LEGACY_VERSION_BYPASS = data_dir .. "/settings/pt-skipversioncheck.txt"
local BURROW_VERSION_BYPASS = data_dir .. "/settings/burrow-skipversioncheck.txt"
local LEGACY_INITIAL_SETUP = "aaaProjectTitle_initial_default_setup_done2"
local BURROW_INITIAL_SETUP = "burrow_initial_default_setup_done_v1"

local function copyFile(source, destination)
    if util.fileExists(destination) or not util.fileExists(source) then
        return false
    end
    local ok, result = pcall(FFIUtil.copyFile, source, destination)
    if not ok or result == false then
        logger.warn("Burrow migration: could not copy", source, destination, result)
        return false
    end
    logger.info("Burrow migration: imported", source, "as", destination)
    return true
end

function BurrowMigration.libraryDatabasePath()
    if copyFile(LEGACY_LIBRARY_DB, BURROW_LIBRARY_DB) then
        -- Preserve pending SQLite writes when an older installation left a WAL
        -- or rollback journal. The shared-memory file is intentionally omitted;
        -- SQLite safely recreates it.
        copyFile(LEGACY_LIBRARY_DB .. "-wal", BURROW_LIBRARY_DB .. "-wal")
        copyFile(LEGACY_LIBRARY_DB .. "-journal", BURROW_LIBRARY_DB .. "-journal")
    end
    return BURROW_LIBRARY_DB
end

function BurrowMigration.storeSettingsPath()
    copyFile(LEGACY_STORE_SETTINGS, BURROW_STORE_SETTINGS)
    return BURROW_STORE_SETTINGS
end

function BurrowMigration.isVersionCheckSkipped()
    return util.fileExists(BURROW_VERSION_BYPASS) or util.fileExists(LEGACY_VERSION_BYPASS)
end

function BurrowMigration.initialSetupKey()
    if not G_reader_settings:isTrue(BURROW_INITIAL_SETUP)
            and G_reader_settings:isTrue(LEGACY_INITIAL_SETUP) then
        G_reader_settings:makeTrue(BURROW_INITIAL_SETUP)
    end
    return BURROW_INITIAL_SETUP
end

local library_setting_map = {
    pt_cover_gap_reduction = "burrow_cover_gap_reduction",
    pt_cover_size_percent = "burrow_cover_size_percent",
    pt_flexible_topbar_show_home = "burrow_topbar_show_home",
    pt_simple_topbar_show_favorites = "burrow_topbar_show_favorites",
    pt_simple_topbar_show_history = "burrow_topbar_show_history",
    pt_flexible_topbar_show_logo = "burrow_topbar_show_logo",
    pt_simple_topbar_show_last_document = "burrow_topbar_show_last_document",
    pt_flexible_topbar_show_up = "burrow_topbar_show_up",
    pt_flexible_topbar_show_menu = "burrow_topbar_show_menu",
    pt_flexible_topbar_size_percent = "burrow_topbar_size_percent",
    pt_flexible_topbar_logo_only_right = "burrow_topbar_logo_only_right",
}

local global_setting_map = {
    home_footer_tab_label_size_percent = "burrow_home_store_label_size_percent",
    home_footer_opdsplus_catalog_url = "burrow_store_catalog_url",
    home_footer_opdsplus_catalog_title = "burrow_store_catalog_title",
}

function BurrowMigration.migrateSettings(BookInfoManager)
    for legacy_key, burrow_key in pairs(library_setting_map) do
        if BookInfoManager:getSetting(burrow_key) == nil then
            local legacy_value = BookInfoManager:getSetting(legacy_key)
            if legacy_value ~= nil then
                BookInfoManager:saveSetting(burrow_key, legacy_value)
            end
        end
    end

    for legacy_key, burrow_key in pairs(global_setting_map) do
        if G_reader_settings:readSetting(burrow_key) == nil then
            local legacy_value = G_reader_settings:readSetting(legacy_key)
            if legacy_value ~= nil then
                G_reader_settings:saveSetting(burrow_key, legacy_value)
            end
        end
    end

    BurrowMigration.initialSetupKey()
    G_reader_settings:makeTrue("burrow_namespace_migration_v1")
end

function BurrowMigration.folderCoverPath(entry)
    if type(entry) ~= "table" then
        return nil
    end
    return entry.burrow_cover_path or entry.pt_cover_path
end

function BurrowMigration.removeBurrowData()
    os.remove(BURROW_LIBRARY_DB)
    os.remove(BURROW_LIBRARY_DB .. "-wal")
    os.remove(BURROW_LIBRARY_DB .. "-shm")
    os.remove(BURROW_LIBRARY_DB .. "-journal")
    os.remove(BURROW_STORE_SETTINGS)
    os.remove(BURROW_VERSION_BYPASS)
    G_reader_settings:delSetting(BURROW_INITIAL_SETUP)
    G_reader_settings:delSetting("burrow_namespace_migration_v1")
end

return BurrowMigration

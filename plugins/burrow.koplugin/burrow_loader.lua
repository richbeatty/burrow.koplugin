-- Burrow plugin-owned module loader.
--
-- Modules are loaded in three phases:
--   early    - KOReader class hooks needed before the library runtime
--   core     - the guarded Burrow library runtime
--   instance - optional class-level visual and navigation modules
--
-- A failed optional module disables its feature group instead of stopping the
-- whole plugin. Failures that happen before apply are cleanly skipped. Failures
-- during apply are quarantined for the next restart, so Burrow will not repeat
-- a partially applied feature until the plugin or KOReader version changes (or
-- the quarantine is manually cleared).

local DataStorage = require("datastorage")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local Version = require("version")
local BurrowSettings = require("burrow_settings")
local BurrowVersion = require("burrow_version")

local source = debug.getinfo(1, "S").source
local plugin_root = source:match("^@(.+)/[^/]+$") or "."
local module_root = plugin_root .. "/internal_patches"
local QUARANTINE_SETTING = "burrow_module_quarantine"

local Loader = {
    plugin_root = plugin_root,
    module_root = module_root,
    loaded_modules = {},
    statuses = {},
    errors = {},
    degraded_features = {},
    applied_to = setmetatable({}, { __mode = "k" }),
    restart_required = false,
    critical_failure = nil,
}

local function moduleKey(filename)
    local slug = filename:gsub("%.lua$", ""):gsub("[^%w_]", "_")
    return "burrow.internal." .. slug
end

local function currentKOReaderVersion()
    local current = Version:getNormalizedCurrentVersion()
    return current or 0
end

local function statusFor(entry)
    local status = Loader.statuses[entry.id]
    if not status then
        status = {
            id = entry.id,
            phase = entry.phase,
            feature = entry.feature,
            critical = entry.critical == true,
            state = "pending",
        }
        Loader.statuses[entry.id] = status
    end
    return status
end

local function setStatus(entry, state, err)
    local status = statusFor(entry)
    status.state = state
    status.error = err and tostring(err) or nil
    return status
end

local function rememberError(stage, entry, err)
    local label = entry and (entry.id or entry.filename or entry.module_name) or "loader"
    local message = string.format("%s: %s: %s", stage, tostring(label), tostring(err))
    Loader.errors[#Loader.errors + 1] = message
    logger.warn("Burrow loader:", message)
    if entry then
        setStatus(entry, "failed", err)
        Loader.degraded_features[entry.feature] = message
        if entry.critical then
            Loader.critical_failure = message
        end
    end
    return message
end

local function getQuarantine()
    local value = G_reader_settings:readSetting(QUARANTINE_SETTING)
    return type(value) == "table" and value or {}
end

local function saveQuarantine(value)
    G_reader_settings:saveSetting(QUARANTINE_SETTING, value)
end

function Loader:isFeatureQuarantined(feature)
    local record = getQuarantine()[feature]
    if type(record) ~= "table" then
        return false
    end
    if record.plugin_version ~= BurrowVersion.VERSION
        or record.koreader_version ~= currentKOReaderVersion()
    then
        return false
    end
    return true, record.error
end

function Loader:quarantineFeature(feature, err)
    if not feature or feature == "library_core" then
        return
    end
    local quarantine = getQuarantine()
    quarantine[feature] = {
        plugin_version = BurrowVersion.VERSION,
        koreader_version = currentKOReaderVersion(),
        error = tostring(err),
    }
    saveQuarantine(quarantine)
    self.restart_required = true
end

function Loader:clearQuarantine(feature)
    local quarantine = getQuarantine()
    if feature then
        quarantine[feature] = nil
    else
        quarantine = {}
    end
    saveQuarantine(quarantine)
end

local function dependencyFailure(entry, allow_loaded)
    for _, dependency in ipairs(entry.depends or {}) do
        local status = Loader.statuses[dependency]
        local state = status and status.state or "not loaded"
        local available = state == "applied" or (allow_loaded and state == "loaded")
        if not available then
            return dependency, state
        end
    end
end

local function loadModule(entry)
    local cached = Loader.loaded_modules[entry.id]
    if cached then
        return cached
    end

    local quarantined, quarantine_error = Loader:isFeatureQuarantined(entry.feature)
    if quarantined then
        setStatus(entry, "quarantined", quarantine_error)
        Loader.degraded_features[entry.feature] = quarantine_error
        logger.warn("Burrow loader: quarantined feature", entry.feature, quarantine_error)
        return nil
    end

    local ok, module_or_error
    if entry.module_name then
        ok, module_or_error = pcall(require, entry.module_name)
    else
        local path = Loader.module_root .. "/" .. tostring(entry.filename)
        if lfs.attributes(path, "mode") ~= "file" then
            rememberError("missing module", entry, path)
            return nil
        end
        ok, module_or_error = pcall(dofile, path)
        if not ok and entry.filename then
            package.loaded[moduleKey(entry.filename)] = nil
        end
    end

    if not ok then
        rememberError("load failed", entry, module_or_error)
        return nil
    end
    if type(module_or_error) ~= "table" then
        rememberError("invalid module", entry, "module did not return a table")
        return nil
    end
    if module_or_error.phase and module_or_error.phase ~= entry.phase then
        rememberError(
            "phase mismatch",
            entry,
            string.format("manifest=%s module=%s", tostring(entry.phase), tostring(module_or_error.phase))
        )
        return nil
    end

    Loader.loaded_modules[entry.id] = module_or_error
    setStatus(entry, "loaded")
    logger.info("Burrow loader: loaded", entry.phase, entry.id)
    return module_or_error
end

local function applyModule(entry, target)
    local dependency, state = dependencyFailure(entry)
    if dependency then
        local message = string.format("dependency %s is %s", dependency, state)
        setStatus(entry, "dependency_failed", message)
        Loader.degraded_features[entry.feature] = message
        logger.warn("Burrow loader: skipping", entry.id, message)
        return false, message
    end

    local module = Loader.loaded_modules[entry.id] or loadModule(entry)
    if not module then
        return false, statusFor(entry).error
    end

    if module.applied == true and type(module.apply) ~= "function" then
        setStatus(entry, "applied")
        return true
    end
    if type(module.apply) ~= "function" then
        local message = rememberError("invalid module", entry, "missing apply(target)")
        return false, message
    end

    local ok, result, apply_error = pcall(module.apply, target)
    if not ok then
        local message = rememberError("apply failed", entry, result)
        Loader:quarantineFeature(entry.feature, message)
        return false, message
    end
    if result == false then
        local message = rememberError("apply rejected", entry, apply_error or "module returned false")
        Loader:quarantineFeature(entry.feature, message)
        return false, message
    end

    module.applied = true
    setStatus(entry, "applied")
    logger.info("Burrow loader: applied", entry.id)
    return true
end

local function entriesForPhase(phase)
    local entries = {}
    for _, entry in ipairs(BurrowSettings:getModuleManifest()) do
        if entry.phase == phase then
            entries[#entries + 1] = entry
            statusFor(entry)
        end
    end
    return entries
end

function Loader:loadEarlyModules()
    for _, entry in ipairs(entriesForPhase("early")) do
        applyModule(entry)
    end
    return self.critical_failure == nil
end

function Loader:applyCoreModules(plugin_class)
    for _, entry in ipairs(entriesForPhase("core")) do
        local ok, err = applyModule(entry, plugin_class)
        if not ok and entry.critical then
            self.critical_failure = err or statusFor(entry).error or "critical module failed"
            return false, self.critical_failure
        end
    end
    return true
end

function Loader:applyInstanceModules(plugin_class)
    if not plugin_class or self.applied_to[plugin_class] then
        return self.critical_failure == nil
    end

    local entries = entriesForPhase("instance")
    local failed_features = {}

    -- Preflight every module before changing KOReader. A load or interface
    -- failure disables that feature group without applying any of its modules.
    for _, entry in ipairs(entries) do
        local quarantined = self:isFeatureQuarantined(entry.feature)
        if quarantined then
            failed_features[entry.feature] = true
            setStatus(entry, "quarantined", select(2, self:isFeatureQuarantined(entry.feature)))
        elseif not failed_features[entry.feature] then
            local dependency = dependencyFailure(entry, true)
            if dependency then
                failed_features[entry.feature] = true
                setStatus(entry, "dependency_failed", "dependency " .. dependency .. " is unavailable")
            else
                local module = loadModule(entry)
                if not module or type(module.apply) ~= "function" then
                    failed_features[entry.feature] = true
                    if module and type(module.apply) ~= "function" then
                        rememberError("invalid instance module", entry, "missing apply(plugin)")
                    end
                end
            end
        end
    end

    for _, entry in ipairs(entries) do
        if failed_features[entry.feature] then
            local status = statusFor(entry)
            if status.state == "pending" or status.state == "loaded" then
                setStatus(entry, "feature_skipped", "another module in this feature failed preflight")
            end
            self.degraded_features[entry.feature] = self.degraded_features[entry.feature]
                or "A module failed preflight; this feature was not applied."
        else
            local ok, err = applyModule(entry, plugin_class)
            if not ok then
                failed_features[entry.feature] = true
                self.degraded_features[entry.feature] = err
            end
        end
    end

    -- Mark entries after an apply-time failure as skipped. Earlier modules in
    -- the group may already have applied, so the feature is quarantined and a
    -- restart is requested for a clean next session.
    for _, entry in ipairs(entries) do
        if failed_features[entry.feature] then
            local status = statusFor(entry)
            if status.state == "loaded" or status.state == "pending" then
                setStatus(entry, "feature_skipped", "feature stopped after an apply failure")
            end
        end
    end

    self.applied_to[plugin_class] = true
    return self.critical_failure == nil
end

function Loader:getErrors()
    local copy = {}
    for i, value in ipairs(self.errors) do
        copy[i] = value
    end
    return copy
end

function Loader:getStatuses()
    local copy = {}
    for id, status in pairs(self.statuses) do
        local item = {}
        for key, value in pairs(status) do item[key] = value end
        copy[id] = item
    end
    return copy
end

function Loader:getDegradedFeatures()
    local copy = {}
    for feature, reason in pairs(self.degraded_features) do
        copy[feature] = reason
    end
    return copy
end

function Loader:getUserNotices()
    local notices = {}
    local labels = {
        library_visuals = "Library appearance",
        home_store = "Home and Store footer",
        quick_settings = "Quick Settings",
        statusbar = "Status bar",
        reading_location = "Reading-location button",
        reader_bottom_menu = "Rounded menu sheets",
    }
    for feature, reason in pairs(self.degraded_features) do
        notices[#notices + 1] = string.format(
            "%s was disabled for this session.\n%s",
            labels[feature] or feature,
            tostring(reason)
        )
    end
    if self.restart_required then
        notices[#notices + 1] = "A module failed while applying. Burrow quarantined that feature; restart KOReader for a clean session."
    end
    table.sort(notices)
    return notices
end

function Loader:hasErrors()
    return #self.errors > 0
end

function Loader:getCriticalFailure()
    return self.critical_failure
end

function Loader:getLegacyBootstrapPath()
    return DataStorage:getPatchesDir() .. "/2-burrow-bootstrap.lua"
end

function Loader:isLegacyBootstrapPresent()
    return lfs.attributes(self:getLegacyBootstrapPath(), "mode") == "file"
end

return Loader

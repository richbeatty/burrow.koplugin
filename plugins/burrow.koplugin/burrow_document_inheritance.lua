local logger = require("logger")

local MODULE_KEY = "burrow.document_inheritance"
local existing = package.loaded[MODULE_KEY]
if existing then return existing end

local Inheritance = {
    key = MODULE_KEY,
    PROFILE_KEY = "burrow_document_profiles",
    PROFILE_VERSION = 1,
}
package.loaded[MODULE_KEY] = Inheritance

local function clone(value, seen)
    if type(value) ~= "table" then
        return value
    end
    seen = seen or {}
    if seen[value] then
        return seen[value]
    end
    local copy = {}
    seen[value] = copy
    for key, item in pairs(value) do
        copy[clone(key, seen)] = clone(item, seen)
    end
    return copy
end

local function isSerializableConfigValue(value)
    local value_type = type(value)
    return value_type == "number"
        or value_type == "string"
        or value_type == "table"
end

local function currentPrefix(ui)
    local config = ui and ui.config
    local options = config and config.options
    local prefix = options and options.prefix
    if prefix == "copt" or prefix == "kopt" then
        return prefix
    end
end

local function loadProfiles()
    local profiles = G_reader_settings:readSetting(Inheritance.PROFILE_KEY)
    if type(profiles) ~= "table"
        or profiles.version ~= Inheritance.PROFILE_VERSION
    then
        profiles = { version = Inheritance.PROFILE_VERSION }
    end
    return profiles
end

local function saveProfiles(profiles)
    profiles.version = Inheritance.PROFILE_VERSION
    G_reader_settings:saveSetting(Inheritance.PROFILE_KEY, profiles)
    if type(G_reader_settings.flush) == "function" then
        G_reader_settings:flush()
    end
end

local function captureProfile(ui)
    local prefix = currentPrefix(ui)
    local configurable = ui and ui.config and ui.config.configurable
    if not prefix or type(configurable) ~= "table" then
        return false
    end

    local profile = { settings = {} }

    -- Mirror KOReader Configurable:saveSettings() from the live ReaderConfig
    -- object, so Burrow inherits the whole current copt/kopt option set without
    -- hard-coding individual document-setting names.
    for key, value in pairs(configurable) do
        if isSerializableConfigValue(value) then
            profile.settings[prefix .. "_" .. key] = clone(value)
        end
    end

    -- ReaderFont stores these separately from ReaderConfig.
    if prefix == "copt" and ui.font then
        if type(ui.font.font_face) == "string"
            and ui.font.font_face ~= ""
        then
            profile.settings.font_face = ui.font.font_face
        end
        if type(ui.font.font_family_fonts) == "table" then
            profile.settings.font_family_fonts = clone(ui.font.font_family_fonts)
        end
    end

    local profiles = loadProfiles()
    profiles[prefix] = profile
    saveProfiles(profiles)

    logger.dbg("[Burrow] Captured last-used document profile", prefix)
    return true
end

local function applyProfile(ui, doc_settings)
    if not doc_settings or type(doc_settings.saveSetting) ~= "function" then
        return false
    end

    local prefix = currentPrefix(ui)
    if not prefix then
        return false
    end

    local profiles = loadProfiles()
    local profile = profiles[prefix]
    if type(profile) ~= "table" or type(profile.settings) ~= "table" then
        return false
    end

    local applied = 0
    for key, value in pairs(profile.settings) do
        doc_settings:saveSetting(key, clone(value))
        applied = applied + 1
    end

    logger.dbg("[Burrow] Applied last-used document profile", prefix, applied)
    return applied > 0
end

function Inheritance.capture(ui)
    local ok, result = pcall(captureProfile, ui)
    if not ok then
        logger.warn("[Burrow] Could not capture last-used document settings", result)
        return false
    end
    return result == true
end

function Inheritance.applyToDocument(ui, doc_settings)
    local ok, result = pcall(applyProfile, ui, doc_settings)
    if not ok then
        logger.warn("[Burrow] Could not apply last-used document settings", result)
        return false
    end
    return result == true
end

function Inheritance.clearProfiles()
    G_reader_settings:delSetting(Inheritance.PROFILE_KEY)
    if type(G_reader_settings.flush) == "function" then
        G_reader_settings:flush()
    end
end

function Inheritance.attachPluginClass(Burrow)
    if type(Burrow) ~= "table"
        or Burrow._burrow_document_inheritance_hook
    then
        return false
    end
    Burrow._burrow_document_inheritance_hook = true

    -- This runs before ReaderConfig and ReaderFont read the new book's sidecar.
    -- Only the saved presentation-profile keys are replaced.
    local originalDocSettingsLoad = Burrow.onDocSettingsLoad
    function Burrow:onDocSettingsLoad(doc_settings, document)
        if originalDocSettingsLoad then
            local ok, err = pcall(
                originalDocSettingsLoad,
                self,
                doc_settings,
                document
            )
            if not ok then
                logger.warn("[Burrow] Earlier DocSettingsLoad hook failed", err)
            end
        end
        Inheritance.applyToDocument(self.ui, doc_settings)
    end

    -- Capture from live ReaderConfig/ReaderFont state, not from sidecar event
    -- ordering, whenever KOReader saves the current reader session.
    local originalSaveSettings = Burrow.onSaveSettings
    function Burrow:onSaveSettings(...)
        if originalSaveSettings then
            local ok, err = pcall(originalSaveSettings, self, ...)
            if not ok then
                logger.warn("[Burrow] Earlier SaveSettings hook failed", err)
            end
        end
        Inheritance.capture(self.ui)
    end

    return true
end

return Inheritance

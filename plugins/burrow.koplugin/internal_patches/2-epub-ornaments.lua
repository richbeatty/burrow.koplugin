local MODULE_KEY = "burrow.internal.2_epub_ornaments"
local existing_module = package.loaded[MODULE_KEY]
if existing_module then return existing_module end

local Module = {
    key = MODULE_KEY,
    phase = "early",
    filename = "2-epub-ornaments.lua",
}
package.loaded[MODULE_KEY] = Module

local ORNAMENT_SETTING = "burrow_soft_palette_recolor_ornaments"

local function isEpub(path)
    return type(path) == "string" and path:lower():match("%.epub$") ~= nil
end

local function hasUserReaderPalette()
    return G_reader_settings:has("cre_background_color")
        or G_reader_settings:has("cre_background_image")
end

local function softPaletteActive(Blitbuffer)
    return tonumber(Blitbuffer.COLOR_WHITE.a) == 0xF2
        and tonumber(Blitbuffer.COLOR_BLACK.a) == 0x20
end

local function desiredTone(document, Screen)
    -- If KOReader is preserving images in Night Mode (the normal/default
    -- behavior), use Burrow's explicit night-colored ornament copy. If the user
    -- deliberately disabled native image preservation, keep the light copy and
    -- allow KOReader's whole-page inversion to flip it naturally.
    if Screen.night_mode and document._nightmode_images ~= false then
        return "night"
    end
    return "light"
end

function Module.desiredTone(document)
    if type(document) ~= "table" then return nil end
    return desiredTone(document, require("device").screen)
end

local function syncKindleNightMode(logger)
    local sync = package.loaded["burrow.internal.2_kindle_night_sync"]
    if type(sync) ~= "table" or type(sync.sync) ~= "function" then
        return true
    end

    local call_ok, synced, sync_error = pcall(sync.sync)
    if not call_ok or synced == false then
        logger.warn(
            "[Burrow ornaments] Kindle Night Mode synchronization failed; ornament reload cancelled",
            call_ok and sync_error or synced
        )
        return false
    end
    return true
end

function Module.apply()
    if Module.applied then return true end

    local Blitbuffer = require("ffi/blitbuffer")
    local CreDocument = require("document/credocument")
    local OrnamentEpub = require("burrow_soft_palette_epub")
    local Screen = require("device").screen
    local logger = require("logger")

    -- Build a shadow EPUB using the exact palette required for the current
    -- reader state. Light and Night Mode are separate cached variants. We do
    -- not change KOReader's Night Mode or native image-preservation setting.
    if not CreDocument._burrow_epub_ornament_loader_v5 then
        CreDocument._burrow_epub_ornament_loader_v5 = true
        local originalLoadDocument = CreDocument.loadDocument

        function CreDocument:loadDocument(fullDocument)
            if self._loaded
                or fullDocument == false
                or (self._burrow_epub_ornament_reader_context ~= true
                    and self._burrow_bionic_reader_context ~= true)
                or not G_reader_settings:isTrue(ORNAMENT_SETTING)
                or hasUserReaderPalette()
                or not isEpub(self.file)
            then
                return originalLoadDocument(self, fullDocument)
            end

            local tone = desiredTone(self, Screen)
            local palette = (softPaletteActive(Blitbuffer) and "soft-" or "pure-")
                .. tone
            local originalFile = self.file
            local shadow, shadowErr, normalized = OrnamentEpub.ensureCache(
                originalFile,
                palette
            )

            -- Mixed books remain safe: ensureCache copies covers, photos,
            -- colored artwork and every non-qualifying image byte-for-byte.
            if not shadow then
                if shadowErr then
                    logger.warn(
                        "[Burrow ornaments] Falling back to original EPUB",
                        shadowErr
                    )
                end
                return originalLoadDocument(self, fullDocument)
            end

            self.file = shadow
            local ok, result = pcall(originalLoadDocument, self, fullDocument)
            self.file = originalFile
            if not ok then error(result) end

            if result then
                self._burrow_epub_ornaments_active = true
                self._burrow_epub_ornaments_image_count = tonumber(normalized) or 0
                self._burrow_epub_ornaments_shadow_file = shadow
                self._burrow_epub_ornaments_palette = palette
                self._burrow_epub_ornaments_tone = tone
                logger.info(
                    "[Burrow ornaments] Loaded explicit decorative EPUB palette",
                    palette,
                    self._burrow_epub_ornaments_image_count
                )
            end
            return result
        end
    end

    Module.applied = true
    return true
end

function Module.attachPluginClass(plugin_class)
    if type(plugin_class) ~= "table" then
        return false, "Burrow plugin class is unavailable"
    end
    if plugin_class._burrow_epub_ornament_post_night_v1 then return true end
    plugin_class._burrow_epub_ornament_post_night_v1 = true

    local UIManager = require("ui/uimanager")
    local Screen = require("device").screen
    local logger = require("logger")
    local reload_pending = false

    local function scheduleReload(plugin)
        if reload_pending then return end
        reload_pending = true

        -- Burrow plugins are registered after KOReader's DeviceListener. This
        -- handler therefore sees ToggleNightMode/SetNightMode only after native
        -- screen inversion and G_reader_settings have already been updated.
        -- Defer once more to the next UI tick so the event itself fully unwinds.
        UIManager:nextTick(function()
            reload_pending = false

            local reader = plugin and plugin.ui or nil
            local document = reader and reader.document or nil
            if not document
                or reader.tearing_down
                or document._burrow_epub_ornaments_active ~= true
                or type(reader.reloadDocument) ~= "function"
            then
                return
            end

            local wanted = desiredTone(document, Screen)
            if wanted == document._burrow_epub_ornaments_tone then return end

            -- Never reload while KOReader's saved and logical states disagree.
            -- Burrow must not repair that by changing the saved preference.
            local logical_night = Screen.night_mode == true
            if G_reader_settings:isTrue("night_mode") ~= logical_night then
                logger.warn(
                    "[Burrow ornaments] Night Mode state is not settled; ornament reload skipped"
                )
                return
            end

            -- Beta.3's Kindle hardware synchronization remains the authority.
            -- Verify it immediately before the reader reload. If the hardware
            -- state cannot be made consistent, do not risk the reload.
            if not syncKindleNightMode(logger) then return end

            local ok_reload, reload_error = pcall(
                reader.reloadDocument,
                reader,
                nil,
                true
            )
            if not ok_reload then
                logger.warn(
                    "[Burrow ornaments] Could not reload explicit night ornament palette",
                    reload_error
                )
                return
            end

            -- Reader reload should not alter Night Mode. Re-verify on the next
            -- tick anyway so a Kindle can never be left with a stale framebuffer
            -- inversion flag because of this cosmetic feature.
            UIManager:nextTick(function()
                syncKindleNightMode(logger)
            end)
        end)
    end

    local originalToggleNightMode = plugin_class.onToggleNightMode
    function plugin_class:onToggleNightMode(...)
        local result
        if originalToggleNightMode then
            result = originalToggleNightMode(self, ...)
        end
        scheduleReload(self)
        return result
    end

    local originalSetNightMode = plugin_class.onSetNightMode
    function plugin_class:onSetNightMode(...)
        local result
        if originalSetNightMode then
            result = originalSetNightMode(self, ...)
        end
        scheduleReload(self)
        return result
    end

    return true
end

return Module

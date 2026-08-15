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
    if Screen.night_mode and document._nightmode_images ~= false then
        return "night"
    end
    return "light"
end

function Module.desiredTone(document)
    if type(document) ~= "table" then return nil end
    local Screen = require("device").screen
    return desiredTone(document, Screen)
end

function Module.apply()
    if Module.applied then return true end

    local Blitbuffer = require("ffi/blitbuffer")
    local CreDocument = require("document/credocument")
    local DeviceListener = require("device/devicelistener")
    local OrnamentEpub = require("burrow_soft_palette_epub")
    local Screen = require("device").screen
    local UIManager = require("ui/uimanager")
    local logger = require("logger")

    local reload_pending = false

    local function scheduleReloadIfToneChanged()
        if reload_pending then return end
        reload_pending = true

        UIManager:tickAfterNext(function()
            reload_pending = false

            local ok_reader, ReaderUI = pcall(require, "apps/reader/readerui")
            local reader = ok_reader and ReaderUI.instance or nil
            local document = reader and reader.document or nil
            if not document
                or reader.tearing_down
                or document._burrow_epub_ornaments_active ~= true
            then
                return
            end

            local wanted = desiredTone(document, Screen)
            if wanted == document._burrow_epub_ornaments_tone
                or type(reader.reloadDocument) ~= "function"
            then
                return
            end

            local ok_reload, reload_error = pcall(
                reader.reloadDocument,
                reader,
                nil,
                true
            )
            if not ok_reload then
                logger.warn(
                    "[Burrow ornaments] Could not reload after image-mode change",
                    reload_error
                )
            end
        end)
    end

    -- DeviceListener owns the actual Night Mode state transition. Wrapping the
    -- state owner catches ToggleNightMode as well as SetNightMode, while leaving
    -- KOReader's inversion implementation untouched.
    if not DeviceListener._burrow_epub_ornament_night_hook_v1 then
        DeviceListener._burrow_epub_ornament_night_hook_v1 = true
        local originalToggleNightMode = DeviceListener.onToggleNightMode

        function DeviceListener:onToggleNightMode(...)
            local result = originalToggleNightMode(self, ...)
            scheduleReloadIfToneChanged()
            return result
        end
    end

    -- ReaderTypeset ultimately changes this CreDocument flag through
    -- setNightmodeImages(). Hook the state setter instead of listening for the
    -- ToggleNightmodeImages event, which ReaderTypeset consumes before plugins
    -- later in ReaderUI's child list can reliably see it.
    if not CreDocument._burrow_epub_ornament_image_mode_hook_v1 then
        CreDocument._burrow_epub_ornament_image_mode_hook_v1 = true
        local originalSetNightmodeImages = CreDocument.setNightmodeImages

        function CreDocument:setNightmodeImages(...)
            local result = originalSetNightmodeImages(self, ...)
            scheduleReloadIfToneChanged()
            return result
        end
    end

    if not CreDocument._burrow_epub_ornament_loader_v2 then
        CreDocument._burrow_epub_ornament_loader_v2 = true
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
            local palette = (softPaletteActive(Blitbuffer) and "soft-" or "pure-") .. tone
            local originalFile = self.file
            local shadow, shadowErr, recolored = OrnamentEpub.ensureCache(originalFile, palette)

            if recolored == 0 then
                return originalLoadDocument(self, fullDocument)
            end
            if not shadow then
                if shadowErr then
                    logger.warn("[Burrow ornaments] Falling back to original EPUB", shadowErr)
                end
                return originalLoadDocument(self, fullDocument)
            end

            self.file = shadow
            local ok, result = pcall(originalLoadDocument, self, fullDocument)
            self.file = originalFile
            if not ok then error(result) end

            if result then
                self._burrow_epub_ornaments_active = true
                self._burrow_epub_ornaments_shadow_file = shadow
                self._burrow_epub_ornaments_palette = palette
                self._burrow_epub_ornaments_tone = tone
                logger.info(
                    "[Burrow ornaments] Loaded decorative EPUB shadow",
                    palette,
                    recolored
                )
            end
            return result
        end
    end

    Module.applied = true
    return true
end

return Module

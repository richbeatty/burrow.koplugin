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

function Module.apply()
    if Module.applied then return true end

    local Blitbuffer = require("ffi/blitbuffer")
    local CreDocument = require("document/credocument")
    local OrnamentEpub = require("burrow_soft_palette_epub")
    local Screen = require("device").screen
    local logger = require("logger")

    -- Do not observe or alter KOReader's Night Mode transition. In particular,
    -- Kindle uses hardware framebuffer inversion, so a Burrow reload in the
    -- middle of that transition can leave the physical inversion and saved
    -- Night Mode state out of sync. Instead, classify the EPUB once when it is
    -- opened and let KOReader's existing screen inversion handle safe ornaments.
    if not CreDocument._burrow_epub_ornament_loader_v3 then
        CreDocument._burrow_epub_ornament_loader_v3 = true
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

            local originalFile = self.file
            local profile, inspectErr = OrnamentEpub.inspect(originalFile)
            if not profile or profile.all_eligible ~= true then
                if inspectErr then
                    logger.warn("[Burrow ornaments] Could not inspect EPUB", inspectErr)
                end
                return originalLoadDocument(self, fullDocument)
            end

            -- Pure black/white needs no shadow EPUB at all. When Burrow's soft
            -- palette is active, build one light-source copy so ornaments match
            -- the soft page. Night Mode will invert that same source naturally;
            -- there is never a separate night EPUB and never a day/night reload.
            local shadow
            if softPaletteActive(Blitbuffer) then
                local shadowErr, recolored
                shadow, shadowErr, recolored = OrnamentEpub.ensureCache(
                    originalFile,
                    "soft-light"
                )
                if not shadow or recolored ~= profile.image_count then
                    if shadowErr then
                        logger.warn(
                            "[Burrow ornaments] Falling back to native image handling",
                            shadowErr
                        )
                    elseif recolored ~= profile.image_count then
                        logger.warn(
                            "[Burrow ornaments] Soft cache did not contain every eligible image",
                            recolored,
                            profile.image_count
                        )
                    end
                    return originalLoadDocument(self, fullDocument)
                end
            end

            if shadow then self.file = shadow end
            local ok, result = pcall(originalLoadDocument, self, fullDocument)
            self.file = originalFile
            if not ok then error(result) end

            if result then
                self._burrow_epub_ornaments_active = true
                self._burrow_epub_ornaments_screen_invert = true
                self._burrow_epub_ornaments_image_count = profile.image_count
                self._burrow_epub_ornaments_shadow_file = shadow
                logger.info(
                    "[Burrow ornaments] Enabled native page inversion for decorative EPUB images",
                    profile.image_count,
                    shadow and "soft" or "pure"
                )
            end
            return result
        end
    end

    -- KOReader normally pre-inverts EPUB images in Night Mode so photographs
    -- retain their original appearance after the whole screen is inverted.
    -- For a book we have proven contains only our conservative ornament class,
    -- temporarily disable that pre-inversion for the draw call. The screen then
    -- inverts the ornament together with the page. This changes no saved native
    -- image setting and does not affect books that contain mixed/unknown images.
    if not CreDocument._burrow_epub_ornament_draw_v3 then
        CreDocument._burrow_epub_ornament_draw_v3 = true
        local originalDrawCurrentView = CreDocument.drawCurrentView

        function CreDocument:drawCurrentView(...)
            if self._burrow_epub_ornaments_screen_invert ~= true
                or not Screen.night_mode
            then
                return originalDrawCurrentView(self, ...)
            end

            local originalNightmodeImages = self._nightmode_images
            self._nightmode_images = false
            local results = { pcall(originalDrawCurrentView, self, ...) }
            self._nightmode_images = originalNightmodeImages

            local ok = table.remove(results, 1)
            if not ok then error(results[1]) end
            return unpack(results)
        end
    end

    Module.applied = true
    return true
end

return Module

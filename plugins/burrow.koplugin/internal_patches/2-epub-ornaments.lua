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
    local logger = require("logger")

    -- CRengine already has the night-mode behavior we need: when KOReader's
    -- native image-preservation option is enabled, CRengine pre-inverts only
    -- pixels whose RGB channels differ. Exact grayscale pixels are left alone
    -- and therefore follow the final page inversion naturally. Normalize only
    -- Burrow's conservative ornament class to exact grayscale once at open
    -- time, then leave Night Mode completely owned by KOReader.
    if not CreDocument._burrow_epub_ornament_loader_v4 then
        CreDocument._burrow_epub_ornament_loader_v4 = true
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
            local palette = softPaletteActive(Blitbuffer)
                and "soft-light"
                or "pure-light"
            local shadow, shadowErr, normalized = OrnamentEpub.ensureCache(
                originalFile,
                palette
            )

            -- No qualifying ornaments, or a cache-generation failure: use the
            -- original EPUB without changing KOReader's image behavior. Mixed
            -- books are safe because ensureCache copies every non-qualifying
            -- image byte-for-byte and changes only images that pass the narrow
            -- ornament detector.
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
                logger.info(
                    "[Burrow ornaments] Loaded grayscale-normalized EPUB shadow",
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

return Module

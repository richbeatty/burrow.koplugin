local MODULE_KEY = "burrow.internal.2_soft_palette"
local existing_module = package.loaded[MODULE_KEY]
if existing_module then return existing_module end

local Module = {
    key = MODULE_KEY,
    phase = "early",
    filename = "2-soft-palette.lua",
}
package.loaded[MODULE_KEY] = Module

function Module.apply()
    if Module.applied then return true end

    -- Preflight every dependency before mutating any shared KOReader object.
    -- If any of these fail, Burrow's guarded loader quarantines only the soft
    -- palette feature and the rest of Burrow continues unchanged.
    local Blitbuffer = require("ffi/blitbuffer")
    local CreDocument = require("document/credocument")
    local ImageWidget = require("ui/widget/imagewidget")
    local ReaderStyleTweak = require("apps/reader/modules/readerstyletweak")
    local logger = require("logger")
    local userpatch = require("userpatch")

    local WHITE_DEFAULT = 0xFF
    local BLACK_DEFAULT = 0x00
    local WHITE_SOFT = 0xF2
    local BLACK_SOFT = 0x20

    local current_white = tonumber(Blitbuffer.COLOR_WHITE.a)
    local current_black = tonumber(Blitbuffer.COLOR_BLACK.a)

    -- Do not silently fight another user patch/theme that has already changed
    -- KOReader's core named colors. Already-soft values are accepted so a
    -- harmless duplicate apply cannot break startup.
    local white_ok = current_white == WHITE_DEFAULT or current_white == WHITE_SOFT
    local black_ok = current_black == BLACK_DEFAULT or current_black == BLACK_SOFT
    if not white_ok or not black_ok then
        return false, string.format(
            "KOReader UI palette was already customized (white=%s, black=%s)",
            tostring(current_white), tostring(current_black)
        )
    end

    -- This is the central color swap. These are Color8 aggregate cdata objects,
    -- and KOReader widgets keep references to these shared named colors. Mutate
    -- the objects in place so already-loaded class defaults follow the palette
    -- without replacing any widget paint method.
    Blitbuffer.COLOR_WHITE.a = WHITE_SOFT
    Blitbuffer.COLOR_BLACK.a = BLACK_SOFT

    -- IconWidget normally flattens transparent SVG/PNG icons onto
    -- Blitbuffer.COLOR_WHITE before caching them. Clear that module-local cache
    -- through KOReader's supported userpatch helper so future icon instances
    -- are rebuilt against the new soft white instead of reusing old 255-white
    -- cached buffers. Cache failure is non-fatal; never take Burrow down for it.
    local cache_ok, cache_err = pcall(function()
        local image_cache = userpatch.getUpValue(ImageWidget._loadfile, "ImageCache")
        if image_cache and type(image_cache.clear) == "function" then
            image_cache:clear()
        end
    end)
    if not cache_ok then
        logger.warn("[Burrow] Soft palette could not clear ImageWidget cache", cache_err)
    end

    -- CRengine draws the book page itself, so it does not naturally use the UI
    -- COLOR_WHITE/COLOR_BLACK objects. Give reflowable documents the matching
    -- source palette, unless the user explicitly chose a CRE background/image.
    -- KOReader's native Night Mode inversion then creates #0D0D0F/#DFDFDF.
    local READER_BACKGROUND = 0xF2F2F0
    local READER_TEXT_CSS = [[
html,
body {
    color: #202020 !important;
}
]]

    local function hasUserReaderPalette()
        return G_reader_settings:has("cre_background_color")
            or G_reader_settings:has("cre_background_image")
    end

    if not CreDocument._burrow_soft_palette_v5 then
        CreDocument._burrow_soft_palette_v5 = true
        local original_setupDefaultView = CreDocument.setupDefaultView

        function CreDocument:setupDefaultView(...)
            local result = original_setupDefaultView(self, ...)
            if not hasUserReaderPalette() then
                self:setBackgroundColor(READER_BACKGROUND)
            end
            return result
        end
    end

    -- ReaderTypeset asks ReaderStyleTweak for its final CSS immediately before
    -- applying the document stylesheet. Append only an inherited body color;
    -- explicit descendant/publisher colors can still override the inheritance.
    if not ReaderStyleTweak._burrow_soft_palette_v5 then
        ReaderStyleTweak._burrow_soft_palette_v5 = true
        local original_getCssText = ReaderStyleTweak.getCssText

        function ReaderStyleTweak:getCssText()
            local css = original_getCssText(self)
            if hasUserReaderPalette() then
                return css
            end
            if css and css ~= "" then
                return css .. "\n" .. READER_TEXT_CSS
            end
            return READER_TEXT_CSS
        end
    end

    Module.applied = true
    return true
end

return Module

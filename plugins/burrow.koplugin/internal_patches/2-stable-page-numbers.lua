local MODULE_KEY = "burrow.internal.2_stable_page_numbers"
local existing_module = package.loaded[MODULE_KEY]
if existing_module then return existing_module end

local Module = {
    key = MODULE_KEY,
    phase = "early",
    filename = "2-stable-page-numbers.lua",
}
package.loaded[MODULE_KEY] = Module

function Module.apply()
    if Module.applied then return true end

    local ReaderPageMap = require("apps/reader/modules/readerpagemap")
    local logger = require("logger")
    if ReaderPageMap._burrow_stable_page_numbers_v5 then
        Module.applied = true
        return true
    end
    ReaderPageMap._burrow_stable_page_numbers_v1 = true
    ReaderPageMap._burrow_stable_page_numbers_v2 = true
    ReaderPageMap._burrow_stable_page_numbers_v3 = true
    ReaderPageMap._burrow_stable_page_numbers_v4 = true
    ReaderPageMap._burrow_stable_page_numbers_v5 = true

    local DEFAULT_CHARS_PER_PAGE = 1500
    local original_onReadSettings = ReaderPageMap.onReadSettings
    local original_postInit = ReaderPageMap._postInit

    local function getSyntheticChars(self)
        local chars = tonumber(
            self.ui.doc_settings:readSetting("pagemap_chars_per_synthetic_page")
            or G_reader_settings:readSetting("pagemap_chars_per_synthetic_page")
            or self.chars_per_synthetic_page
            or self.chars_per_synthetic_page_default
            or DEFAULT_CHARS_PER_PAGE
        ) or DEFAULT_CHARS_PER_PAGE

        if chars < 500 then chars = 500 end
        if chars > 3000 then chars = 3000 end
        return chars
    end

    local function isEpubDocument(document)
        local file = document and document.file
        if type(file) ~= "string" then
            return false
        end
        return file:lower():match("%.epub$") ~= nil
    end

    local function isSyntheticMap(document)
        if not document or type(document.isPageMapSynthetic) ~= "function" then
            return false
        end
        local ok, value = pcall(document.isPageMapSynthetic, document)
        return ok and value == true
    end

    local function getActiveSyntheticChars(document)
        if not document or type(document.getSyntheticPageMapCharsPerPage) ~= "function" then
            return 0
        end
        local ok, value = pcall(document.getSyntheticPageMapCharsPerPage, document)
        return ok and (tonumber(value) or 0) or 0
    end

    local function installSyntheticMap(self, document, chars, register_view)
        local ok, err = pcall(document.buildSyntheticPageMap, document, chars)
        if not ok then
            logger.warn("Burrow stable page numbers: synthetic page-map build failed", err)
            return false
        end

        if not isSyntheticMap(document) then
            logger.warn("Burrow stable page numbers: synthetic page-map build did not become active")
            return false
        end

        self.chars_per_synthetic_page = chars
        self.has_pagemap = true
        self.page_labels_cache = nil
        self:resetLayout()
        if register_view then
            self.view:registerViewModule("pagemap", self)
        end
        self.ui.doc_settings:saveSetting("pagemap_chars_per_synthetic_page", chars)
        self.ui.doc_settings:saveSetting(
            "pagemap_doc_pages",
            select(3, self:getCurrentPageLabel())
        )
        return true
    end

    -- Stable labels should be the normal Burrow presentation for reflowable
    -- documents. Do not touch fixed-layout readers (PDF/CBZ/DjVu/etc.).
    function ReaderPageMap:onReadSettings(config)
        local result = original_onReadSettings(self, config)
        if self.ui and self.ui.rolling then
            self.use_page_labels = true
            config:saveSetting("pagemap_use_page_labels", true)
        end
        return result
    end

    function ReaderPageMap:_postInit(...)
        local result = original_postInit(self, ...)

        if not (self.ui and self.ui.rolling and self.ui.document and self.ui.doc_settings) then
            return result
        end

        local document = self.ui.document

        if isEpubDocument(document) then
            -- Burrow intentionally ignores EPUB publisher page maps. Reflowable
            -- EPUBs always use a synthetic character-based map so numbering is
            -- predictable across books, devices and EPUB packaging quirks.
            local chars = getSyntheticChars(self)
            local active_is_synthetic = isSyntheticMap(document)
            local active_chars = getActiveSyntheticChars(document)

            if not active_is_synthetic or active_chars ~= chars then
                local register_view = not self.has_pagemap
                installSyntheticMap(self, document, chars, register_view)
            else
                self.chars_per_synthetic_page = chars
                self.has_pagemap = true
            end

            if isSyntheticMap(document) then
                -- The file may still physically contain publisher page data, but
                -- Burrow does not expose it as an alternate active page source.
                self.has_pagemap_document_provided = false
            end
        elseif not self.has_pagemap then
            -- Preserve Burrow's existing behavior for other reflowable formats:
            -- create synthetic stable pages only when KOReader has no page map.
            local chars = getSyntheticChars(self)
            installSyntheticMap(self, document, chars, true)
        end

        if self.has_pagemap then
            self.use_page_labels = true
            self.page_labels_cache = nil
            self.ui.doc_settings:saveSetting("pagemap_use_page_labels", true)
        end

        return result
    end

    Module.applied = true
    return true
end

return Module

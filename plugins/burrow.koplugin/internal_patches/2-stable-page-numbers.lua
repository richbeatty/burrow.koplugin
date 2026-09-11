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
    if ReaderPageMap._burrow_stable_page_numbers_v3 then
        Module.applied = true
        return true
    end
    ReaderPageMap._burrow_stable_page_numbers_v1 = true
    ReaderPageMap._burrow_stable_page_numbers_v2 = true
    ReaderPageMap._burrow_stable_page_numbers_v3 = true

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

    local function installSyntheticMap(self, document, chars, register_view)
        local ok, err = pcall(document.buildSyntheticPageMap, document, chars)
        if not ok then
            logger.warn("Burrow stable page numbers: synthetic page-map build failed", err)
            return false
        end
        if not document:hasPageMap() then
            logger.warn("Burrow stable page numbers: synthetic page-map build returned no map")
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

    local function addSampleIndex(indices, seen, index, total)
        if index < 1 then index = 1 end
        if index > total then index = total end
        if not seen[index] then
            seen[index] = true
            indices[#indices + 1] = index
        end
    end

    -- Publisher maps are kept unless their anchors are objectively unusable.
    -- Labels themselves are never judged: Roman numerals, duplicate labels,
    -- unusual numbering schemes and partial front matter are all valid.
    --
    -- We deliberately require a large map and document, then use three
    -- conservative signals:
    --   1. ordered anchors make a large backwards jump through the rendered
    --      document, which violates page-list reading order;
    --   2. almost all map entries literally reuse one or two XPointers; or
    --   3. anchors sampled across the entire map resolve into essentially the
    --      same tiny rendered-page span.
    --
    -- This catches malformed publisher maps without second-guessing healthy
    -- print pagination.
    local function publisherMapClearlyBroken(document)
        local ok, page_list = pcall(document.getPageMap, document)
        if not ok or type(page_list) ~= "table" then
            return false
        end

        local total = #page_list
        if total < 40 then
            return false
        end

        local ok_pages, rendered_pages = pcall(document.getPages, document)
        rendered_pages = ok_pages and tonumber(rendered_pages) or 0
        if not rendered_pages or rendered_pages < 40 then
            return false
        end

        -- EPUB page-list targets are required to follow reading order. Allow
        -- equal pages and small layout noise, but a substantial backwards jump
        -- means the map cannot be used safely by CRengine's ordered lookup.
        local backward_limit = math.max(8, math.floor(rendered_pages * 0.10))
        local previous_page
        local previous_index
        for index, entry in ipairs(page_list) do
            local xp = type(entry) == "table" and entry.xpointer or nil
            if type(xp) == "string" and xp ~= "" then
                local resolved_ok, page = pcall(document.getPageFromXPointer, document, xp)
                page = resolved_ok and tonumber(page) or nil
                if page then
                    if previous_page and previous_page - page >= backward_limit then
                        return true, string.format(
                            "page-map anchor %d resolves to rendered page %d after anchor %d resolved to page %d",
                            index,
                            page,
                            previous_index,
                            previous_page
                        )
                    end
                    previous_page = page
                    previous_index = index
                end
            end
        end

        local xpointer_count = 0
        local unique_xpointers = {}
        local unique_xpointer_count = 0
        for _, entry in ipairs(page_list) do
            local xp = type(entry) == "table" and entry.xpointer or nil
            if type(xp) == "string" and xp ~= "" then
                xpointer_count = xpointer_count + 1
                if not unique_xpointers[xp] then
                    unique_xpointers[xp] = true
                    unique_xpointer_count = unique_xpointer_count + 1
                end
            end
        end

        if xpointer_count >= 40 then
            local duplicate_limit = math.max(2, math.floor(xpointer_count * 0.03))
            if unique_xpointer_count <= duplicate_limit then
                return true, string.format(
                    "%d page-map entries use only %d distinct anchors",
                    xpointer_count,
                    unique_xpointer_count
                )
            end
        end

        local indices = {}
        local seen = {}
        for step = 0, 8 do
            local index = 1 + math.floor((total - 1) * step / 8)
            addSampleIndex(indices, seen, index, total)
        end
        table.sort(indices)

        local resolved_count = 0
        local min_page
        local max_page
        for _, index in ipairs(indices) do
            local entry = page_list[index]
            local xp = type(entry) == "table" and entry.xpointer or nil
            if type(xp) == "string" and xp ~= "" then
                local resolved_ok, page = pcall(document.getPageFromXPointer, document, xp)
                page = resolved_ok and tonumber(page) or nil
                if page then
                    resolved_count = resolved_count + 1
                    if not min_page or page < min_page then min_page = page end
                    if not max_page or page > max_page then max_page = page end
                end
            end
        end

        if resolved_count >= 7 and min_page and max_page then
            local span = max_page - min_page
            local collapsed_span = math.max(2, math.floor(rendered_pages * 0.01))
            if span <= collapsed_span then
                return true, string.format(
                    "%d sampled anchors span only %d of %d rendered pages",
                    resolved_count,
                    span,
                    rendered_pages
                )
            end
        end

        return false
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

        -- KOReader normally prefers a publisher-supplied page map. Keep that
        -- preference unless the publisher map is clearly broken. A synthetic
        -- map already selected by the user is never validated or replaced here.
        if self.has_pagemap
            and self.has_pagemap_document_provided
            and not self.chars_per_synthetic_page
        then
            local broken, reason = publisherMapClearlyBroken(document)
            if broken then
                local chars = getSyntheticChars(self)
                logger.warn(
                    "Burrow stable page numbers: publisher page map is broken; using synthetic map instead:",
                    reason
                )
                -- The publisher map was already registered by KOReader's
                -- _postInit(), so rebuilding it does not require registering the
                -- same view module a second time.
                installSyntheticMap(self, document, chars, false)
            end
        end

        -- If KOReader has no page map at all, preserve Burrow's existing default:
        -- create a stable synthetic map for reflowable documents.
        if not self.has_pagemap then
            local chars = getSyntheticChars(self)
            installSyntheticMap(self, document, chars, true)
        end

        if self.has_pagemap then
            -- The footer, Reading Location, bookmarks and other KOReader
            -- consumers already switch to page-map labels through this flag.
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

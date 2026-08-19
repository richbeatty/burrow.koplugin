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
    if ReaderPageMap._burrow_stable_page_numbers_v1 then
        Module.applied = true
        return true
    end
    ReaderPageMap._burrow_stable_page_numbers_v1 = true

    local DEFAULT_CHARS_PER_PAGE = 1500
    local original_onReadSettings = ReaderPageMap.onReadSettings
    local original_postInit = ReaderPageMap._postInit

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

        -- If KOReader already has a page map, leave its source alone. This keeps
        -- publisher-supplied page maps intact and also respects an existing
        -- user-selected synthetic map.
        if not self.has_pagemap then
            local chars = tonumber(
                self.ui.doc_settings:readSetting("pagemap_chars_per_synthetic_page")
                or G_reader_settings:readSetting("pagemap_chars_per_synthetic_page")
                or self.chars_per_synthetic_page
                or self.chars_per_synthetic_page_default
                or DEFAULT_CHARS_PER_PAGE
            ) or DEFAULT_CHARS_PER_PAGE

            if chars < 500 then chars = 500 end
            if chars > 3000 then chars = 3000 end

            local ok = pcall(document.buildSyntheticPageMap, document, chars)
            if ok and document:hasPageMap() then
                self.chars_per_synthetic_page = chars
                self.has_pagemap = true
                self.page_labels_cache = nil
                self:resetLayout()
                self.view:registerViewModule("pagemap", self)
                self.ui.doc_settings:saveSetting("pagemap_chars_per_synthetic_page", chars)
                self.ui.doc_settings:saveSetting(
                    "pagemap_doc_pages",
                    select(3, self:getCurrentPageLabel())
                )
            end
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

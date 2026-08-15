from pathlib import Path

def replace_once(text, old, new, label):
    count = text.count(old)
    assert count == 1, f"{label}: expected 1 match, found {count}"
    return text.replace(old, new, 1)

# 3. Add a dedicated early module that owns only selective ornament
#    shadow loading. It deliberately loads before Quick Settings/Bionic.
p = Path('plugins/burrow.koplugin/internal_patches/2-epub-ornaments.lua')
assert not p.exists()
p.write_text('''local MODULE_KEY = "burrow.internal.2_epub_ornaments"\nlocal existing_module = package.loaded[MODULE_KEY]\nif existing_module then return existing_module end\n\nlocal Module = {\n    key = MODULE_KEY,\n    phase = "early",\n    filename = "2-epub-ornaments.lua",\n}\npackage.loaded[MODULE_KEY] = Module\n\nlocal ORNAMENT_SETTING = "burrow_soft_palette_recolor_ornaments"\n\nlocal function isEpub(path)\n    return type(path) == "string" and path:lower():match("%.epub$") ~= nil\nend\n\nlocal function hasUserReaderPalette()\n    return G_reader_settings:has("cre_background_color")\n        or G_reader_settings:has("cre_background_image")\nend\n\nlocal function softPaletteActive(Blitbuffer)\n    return tonumber(Blitbuffer.COLOR_WHITE.a) == 0xF2\n        and tonumber(Blitbuffer.COLOR_BLACK.a) == 0x20\nend\n\nlocal function desiredTone(document, Screen)\n    if Screen.night_mode and document._nightmode_images ~= false then\n        return "night"\n    end\n    return "light"\nend\n\nfunction Module.desiredTone(document)\n    if type(document) ~= "table" then return nil end\n    local Screen = require("device").screen\n    return desiredTone(document, Screen)\nend\n\nfunction Module.apply()\n    if Module.applied then return true end\n\n    local Blitbuffer = require("ffi/blitbuffer")\n    local CreDocument = require("document/credocument")\n    local OrnamentEpub = require("burrow_soft_palette_epub")\n    local Screen = require("device").screen\n    local logger = require("logger")\n\n    if not CreDocument._burrow_epub_ornament_loader_v2 then\n        CreDocument._burrow_epub_ornament_loader_v2 = true\n        local originalLoadDocument = CreDocument.loadDocument\n\n        function CreDocument:loadDocument(fullDocument)\n            if self._loaded\n                or fullDocument == false\n                or (self._burrow_epub_ornament_reader_context ~= true\n                    and self._burrow_bionic_reader_context ~= true)\n                or not G_reader_settings:isTrue(ORNAMENT_SETTING)\n                or hasUserReaderPalette()\n                or not isEpub(self.file)\n            then\n                return originalLoadDocument(self, fullDocument)\n            end\n\n            local tone = desiredTone(self, Screen)\n            local palette = (softPaletteActive(Blitbuffer) and "soft-" or "pure-") .. tone\n            local originalFile = self.file\n            local shadow, shadowErr, recolored = OrnamentEpub.ensureCache(originalFile, palette)\n\n            if recolored == 0 then\n                return originalLoadDocument(self, fullDocument)\n            end\n            if not shadow then\n                if shadowErr then\n                    logger.warn("[Burrow ornaments] Falling back to original EPUB", shadowErr)\n                end\n                return originalLoadDocument(self, fullDocument)\n            end\n\n            self.file = shadow\n            local ok, result = pcall(originalLoadDocument, self, fullDocument)\n            self.file = originalFile\n            if not ok then error(result) end\n\n            if result then\n                self._burrow_epub_ornaments_active = true\n                self._burrow_epub_ornaments_shadow_file = shadow\n                self._burrow_epub_ornaments_palette = palette\n                self._burrow_epub_ornaments_tone = tone\n                logger.info(\n                    "[Burrow ornaments] Loaded decorative EPUB shadow",\n                    palette,\n                    recolored\n                )\n            end\n            return result\n        end\n    end\n\n    Module.applied = true\n    return true\nend\n\nreturn Module\n''', encoding='utf-8')

# 4. Load ornament handling independently of the optional soft palette,
#    but before Quick Settings, which is where Bionic Reading attaches.
p = Path('plugins/burrow.koplugin/burrow_settings.lua')
s = p.read_text(encoding='utf-8')
assert 'add("epub_ornaments"' not in s
marker = '    if self:isFeatureEnabled("quick_settings") then\n'
assert s.count(marker) == 1
block = '''    -- Selective decorative EPUB handling is independent of the optional\n    -- soft palette. Load it before Quick Settings so its CreDocument wrapper\n    -- stays inside Bionic Reading's later shadow-file wrapper.\n    add("epub_ornaments", "2-epub-ornaments.lua", "early", {\n        filename = "2-epub-ornaments.lua",\n        feature = "epub_ornaments",\n    })\n\n'''
s = s.replace(marker, block + marker, 1)
p.write_text(s, encoding='utf-8')

# 5. Keep the existing Appearance setting, but make it independent and
#    mark real Reader documents for the new loader. Add narrowly scoped
#    reload hooks for live Night Mode / native Invert Images changes.
p = Path('plugins/burrow.koplugin/internal_patches/2-zzzz-soft-palette-settings.lua')
s = p.read_text(encoding='utf-8')
s = replace_once(
    s,
    '    local UIManager = require("ui/uimanager")\n',
    '    local UIManager = require("ui/uimanager")\n    local logger = require("logger")\n',
    'settings logger require',
)
s = replace_once(
    s,
    '''    -- Mark the real reader CreDocument before CRengine loads it. The soft\n    -- palette EPUB shadow loader checks this marker so file-browser cover and\n    -- metadata probes are never redirected through a transformed copy. Keep\n    -- this wrapper composable with Bionic Reading and the other Burrow hooks.\n''',
    '''    -- Mark the real reader CreDocument before CRengine loads it. The\n    -- decorative EPUB shadow loader checks this marker so file-browser cover\n    -- and metadata probes are never redirected through a transformed copy.\n    -- Keep this wrapper composable with Bionic Reading and other Burrow hooks.\n''',
    'reader context comment',
)
s = replace_once(
    s,
    '                doc._burrow_soft_palette_reader_context = true\n',
    '''                doc._burrow_epub_ornament_reader_context = true\n                -- Retain the old marker for same-process upgrade compatibility.\n                doc._burrow_soft_palette_reader_context = true\n''',
    'reader context marker',
)
s = replace_once(
    s,
    '''    -- This is an experimental test overlay. Turn the new ornament treatment on\n    -- for first-time testers so reopening an EPUB immediately exercises it.\n    -- The setting remains independently switchable in Burrow Settings.\n''',
    '''    -- Preserve the existing default and every saved user choice. Decorative\n    -- EPUB handling now works independently of the optional soft palette.\n''',
    'ornament default comment',
)
default_block = '''    if G_reader_settings:readSetting(ORNAMENT_SETTING) == nil then\n        G_reader_settings:saveSetting(ORNAMENT_SETTING, true)\n    end\n\n'''
assert s.count(default_block) == 1
reload_block = '''    local ornament_reload_pending = false\n\n    local function scheduleOrnamentReload()\n        if ornament_reload_pending then return end\n        ornament_reload_pending = true\n\n        -- Wait two UI ticks. KOReader's DeviceListener/ReaderTypeset handlers\n        -- first update Night Mode / native image inversion, and Burrow Quick\n        -- Settings gets one tick to refresh its own menu before any reload.\n        UIManager:tickAfterNext(function()\n            ornament_reload_pending = false\n\n            local ok_reader, ReaderUI = pcall(require, "apps/reader/readerui")\n            local reader = ok_reader and ReaderUI.instance or nil\n            local document = reader and reader.document or nil\n            if not document\n                or reader.tearing_down\n                or document._burrow_epub_ornaments_active ~= true\n            then\n                return\n            end\n\n            local ornaments = package.loaded["burrow.internal.2_epub_ornaments"]\n            if type(ornaments) ~= "table"\n                or type(ornaments.desiredTone) ~= "function"\n            then\n                return\n            end\n\n            local desired = ornaments.desiredTone(document)\n            if not desired\n                or desired == document._burrow_epub_ornaments_tone\n                or type(reader.reloadDocument) ~= "function"\n            then\n                return\n            end\n\n            local ok_reload, reload_error = pcall(\n                reader.reloadDocument,\n                reader,\n                nil,\n                true\n            )\n            if not ok_reload then\n                logger.warn(\n                    "[Burrow ornaments] Could not reload after image-mode change",\n                    reload_error\n                )\n            end\n        end)\n    end\n\n    if not plugin._burrow_epub_ornament_mode_reload_hook then\n        plugin._burrow_epub_ornament_mode_reload_hook = true\n\n        local originalToggleNightMode = plugin.onToggleNightMode\n        function plugin:onToggleNightMode(...)\n            local result\n            if originalToggleNightMode then\n                result = originalToggleNightMode(self, ...)\n            end\n            scheduleOrnamentReload()\n            return result\n        end\n\n        local originalToggleNightmodeImages = plugin.onToggleNightmodeImages\n        function plugin:onToggleNightmodeImages(...)\n            local result\n            if originalToggleNightmodeImages then\n                result = originalToggleNightmodeImages(self, ...)\n            end\n            scheduleOrnamentReload()\n            return result\n        end\n    end\n\n'''
s = s.replace(default_block, default_block + reload_block, 1)
s = replace_once(
    s,
    '                        help_text = _("For EPUB books, recolor only small monochrome images and simple SVG ornaments to match Burrow\'s soft page colors. Covers, large images, and colored artwork are left unchanged. Reopen the book after changing this setting."),\n',
    '                        help_text = _("For EPUB books, adjust only small monochrome images and simple SVG ornaments so they follow the page in light and night modes. Covers, large images, and colored artwork keep KOReader\'s normal image behavior. Reopen the book after changing this setting."),\n',
    'ornament help text',
)
ornament_item = s.index('                        text = _("Recolor decorative book elements"),\n')
next_item = s.index('                    },\n', ornament_item)
region = s[ornament_item:next_item]
assert region.count('                        enabled_func = enabled,\n') == 1
region = region.replace('                        enabled_func = enabled,\n', '', 1)
s = s[:ornament_item] + region + s[next_item:]
p.write_text(s, encoding='utf-8')

# 6. Version this as the first beta after 0.4.3 stable.
p = Path('plugins/burrow.koplugin/burrow_version.lua')
s = p.read_text(encoding='utf-8')
s = replace_once(s, '    VERSION = "0.4.3"\n', '    VERSION = "0.4.4-beta.1"\n', 'version')
s = replace_once(s, '    DISPLAY_VERSION = "0.4.3"\n', '    DISPLAY_VERSION = "0.4.4-beta.1"\n', 'display version')
p.write_text(s, encoding='utf-8')

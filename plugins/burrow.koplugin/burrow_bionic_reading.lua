local bit = require("bit")
local Blitbuffer = require("ffi/blitbuffer")
local Screen = require("device").screen
local DataStorage = require("datastorage")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local util = require("util")
local _ = require("gettext")

local Epub = require("burrow_bionic_epub")
local OrnamentEpub = require("burrow_soft_palette_epub")

local MODULE_KEY = "burrow.bionic_reading"
local existing = package.loaded[MODULE_KEY]
if existing then return existing end

local Bionic = {
    key = MODULE_KEY,
    SETTING_KEY = "burrow_bionic_reading",
    CACHE_VERSION = "crosspoint45-v4-mixed-ornament-tones",
}
package.loaded[MODULE_KEY] = Bionic

local function isEpub(path)
    return type(path) == "string" and path:lower():match("%.epub$") ~= nil
end

local function ensureDir(path)
    if lfs.attributes(path, "mode") == "directory" then return true end
    local ok = lfs.mkdir(path)
    return ok or lfs.attributes(path, "mode") == "directory"
end

function Bionic.isEnabled()
    return G_reader_settings:isTrue(Bionic.SETTING_KEY)
end

function Bionic.setEnabled(enabled)
    G_reader_settings:saveSetting(Bionic.SETTING_KEY, enabled == true)
    if type(G_reader_settings.flush) == "function" then
        G_reader_settings:flush()
    end
end

function Bionic.isSupportedFile(path)
    return isEpub(path)
end

function Bionic.cacheDirectory()
    local root
    if type(DataStorage.getFullDataDir) == "function" then
        root = DataStorage:getFullDataDir()
    end
    root = root or DataStorage:getDataDir()
    return root .. "/cache/burrow-bionic"
end

local function ornamentCacheToken()
    if not G_reader_settings:isTrue("burrow_soft_palette_recolor_ornaments")
        or G_reader_settings:has("cre_background_color")
        or G_reader_settings:has("cre_background_image")
    then
        return "ornaments-off"
    end

    local soft = tonumber(Blitbuffer.COLOR_WHITE.a) == 0xF2
        and tonumber(Blitbuffer.COLOR_BLACK.a) == 0x20
    return soft and "ornaments-soft" or "ornaments-pure"
end

function Bionic.cachePath(source)
    local checksum = util.partialMD5(source)
    if not checksum then return nil, "Could not identify this EPUB." end

    local attrs = lfs.attributes(source) or {}
    local identity = table.concat({
        tostring(checksum),
        tostring(attrs.size or ""),
        tostring(attrs.modification or ""),
        Bionic.CACHE_VERSION,
        ornamentCacheToken(),
    }, "-")
    identity = identity:gsub("[^%w%-_%.]", "_")
    return Bionic.cacheDirectory() .. "/" .. identity .. ".epub"
end

local HOT_SPINE_RADIUS = 12
local ASYNC_STEP_DELAY = 0.01
local ASYNC_JOBS = {}
local OPEN_PROGRESS_HINTS = {}
local FORCED_DISPLAY = {}
local tone_update_token = 0
local tone_update_pending = false

-- These helpers are implemented later in the module, but hot-cache lifecycle
-- callbacks are registered before their definitions. Keep explicit upvalues so
-- promotion and reader-event tracking share the same position logic.
local captureTextAnchor
local captureReadingPercent
local restoreSemanticAnchor
local restoreReadingPercent
local isPendingAnchor

local function bionicOrnamentsEnabled()
    return G_reader_settings:isTrue("burrow_soft_palette_recolor_ornaments")
        and not G_reader_settings:has("cre_background_color")
        and not G_reader_settings:has("cre_background_image")
end

local function softPaletteActive()
    return tonumber(Blitbuffer.COLOR_WHITE.a) == 0xF2
        and tonumber(Blitbuffer.COLOR_BLACK.a) == 0x20
end

local function ornamentPalette(tone)
    if tone == "night" then
        return softPaletteActive() and "soft-night" or "pure-night"
    end
    return softPaletteActive() and "soft-light" or "pure-light"
end

local function isMixedOrnamentProfile(profile)
    return type(profile) == "table"
        and tonumber(profile.eligible_count) ~= nil
        and tonumber(profile.eligible_count) > 0
        and profile.all_eligible ~= true
end

local function currentTone()
    return Screen.night_mode == true and "night" or "light"
end

local function cachedDisplayShadow(source, baseShadow, profile)
    if not baseShadow then return nil, "plain" end
    if not bionicOrnamentsEnabled()
        or type(profile) ~= "table"
        or tonumber(profile.eligible_count or 0) <= 0
    then
        return baseShadow, "plain"
    end

    if profile.all_eligible == true then
        return baseShadow, "adaptive"
    end

    local tone = currentTone()
    if tone == "light" then
        return baseShadow, "light"
    end

    local decorated = OrnamentEpub.cachedResult(
        baseShadow,
        ornamentPalette("night")
    )
    if decorated then
        return decorated, "night"
    end
    return baseShadow, "light"
end

local function ensureDisplayShadowAsync(source, baseShadow, profile, tone, callback)
    if not baseShadow or type(callback) ~= "function" then return end
    if not bionicOrnamentsEnabled()
        or not isMixedOrnamentProfile(profile)
        or tone == "light"
    then
        UIManager:nextTick(function()
            callback(baseShadow, nil, tone == "light" and "light" or "plain")
        end)
        return
    end

    OrnamentEpub.ensureCacheAsync(
        baseShadow,
        ornamentPalette("night"),
        profile,
        function(path, err)
            callback(path or baseShadow, err, path and "night" or "light")
        end
    )
end

local function applyAdaptiveOrnamentState(document, source, profile)
    if not document or not bionicOrnamentsEnabled() then return false, false end
    profile = profile or OrnamentEpub.peekProfile(source)
    if type(profile) ~= "table"
        or profile.all_eligible ~= true
        or document._burrow_bionic_display_tone ~= "adaptive"
        or document._nightmode_images == false
    then
        return false, false
    end

    local changed = document._burrow_epub_ornaments_fast_adaptive ~= true
    document._burrow_epub_ornaments_active = true
    document._burrow_epub_ornaments_fast_adaptive = true
    document._burrow_epub_ornaments_fast_adaptive_candidate = true
    document._burrow_epub_ornaments_profile = profile
    document._burrow_epub_ornaments_source_file = source
    document._burrow_epub_ornaments_tone = "adaptive"
    return true, changed
end

local function refreshAdaptiveOrnaments(plugin)
    local reader = plugin and plugin.ui or nil
    local document = reader and reader.document or nil
    if not reader or not document or reader.tearing_down
        or document._burrow_bionic_active ~= true
    then
        return
    end

    local source = document._burrow_bionic_original_file or document.file
    local profile = OrnamentEpub.peekProfile(source)
    local applied, changed = applyAdaptiveOrnamentState(document, source, profile)
    if applied then
        if changed then
            if type(document.resetBufferCache) == "function" then
                pcall(document.resetBufferCache, document)
            elseif document.buffer then
                pcall(document.buffer.free, document.buffer)
                document.buffer = nil
            end
            UIManager:setDirty(reader, "full")
        end
        return
    end

    if profile or not bionicOrnamentsEnabled()
        or type(OrnamentEpub.inspectAsync) ~= "function"
    then
        return
    end

    OrnamentEpub.inspectAsync(source, function(asyncProfile, err)
        if err then
            logger.warn("[Burrow bionic] Ornament profile inspection failed", err)
            return
        end

        local currentReader = plugin and plugin.ui or nil
        local currentDocument = currentReader and currentReader.document or nil
        if not currentReader or not currentDocument or currentReader.tearing_down
            or currentDocument._burrow_bionic_active ~= true
            or currentDocument._burrow_bionic_original_file ~= source
        then
            return
        end

        local okApplied, didChange =
            applyAdaptiveOrnamentState(currentDocument, source, asyncProfile)
        if okApplied and didChange then
            if type(currentDocument.resetBufferCache) == "function" then
                pcall(currentDocument.resetBufferCache, currentDocument)
            elseif currentDocument.buffer then
                pcall(currentDocument.buffer.free, currentDocument.buffer)
                currentDocument.buffer = nil
            end
            UIManager:setDirty(currentReader, "full")
        end
    end)
end

function Bionic.cachedPath(source)
    local target, err = Bionic.cachePath(source)
    if not target then return nil, err end
    if lfs.attributes(target, "mode") == "file" then return target end
    return nil
end

function Bionic.ensureCache(source)
    if not Bionic.isSupportedFile(source) then
        return nil, "Bionic Reading currently supports EPUB books."
    end

    local directory = Bionic.cacheDirectory()
    if not ensureDir(directory) then
        return nil, "Could not create Burrow's Bionic Reading cache."
    end

    local target, err = Bionic.cachePath(source)
    if not target then return nil, err end
    if lfs.attributes(target, "mode") == "file" then return target end

    logger.info("[Burrow bionic] Building complete shadow EPUB", source)
    local ok, buildErr = Epub.generate(source, target)
    if not ok then
        os.remove(target)
        return nil, buildErr
    end
    return target
end

function Bionic.hotCachePath(source, progress, radius)
    local full, err = Bionic.cachePath(source)
    if not full then return nil, err end

    progress = tonumber(progress) or 0
    if progress < 0 then progress = 0 end
    if progress > 1 then progress = 1 end
    radius = math.max(0, tonumber(radius) or HOT_SPINE_RADIUS)

    local bucket = math.floor(progress * 1000 + 0.5)
    return full:gsub(
        "%.epub$",
        string.format("-hot-%04d-r%d.epub", bucket, radius)
    )
end

function Bionic.ensureHotCache(source, progress, radius)
    if not Bionic.isSupportedFile(source) then
        return nil, "Bionic Reading currently supports EPUB books."
    end

    local directory = Bionic.cacheDirectory()
    if not ensureDir(directory) then
        return nil, "Could not create Burrow's Bionic Reading cache."
    end

    local target, err = Bionic.hotCachePath(source, progress, radius)
    if not target then return nil, err end
    if lfs.attributes(target, "mode") == "file" then return target end

    logger.info("[Burrow bionic] Building spine-priority hot EPUB", source, progress)
    local ok, buildErr = Epub.generateHot(
        source,
        target,
        progress,
        radius or HOT_SPINE_RADIUS
    )
    if not ok then
        os.remove(target)
        return nil, buildErr
    end
    return target
end

function Bionic.ensureCacheAsync(source, callback)
    if not Bionic.isSupportedFile(source) then
        UIManager:nextTick(function()
            callback(nil, "Bionic Reading currently supports EPUB books.")
        end)
        return
    end

    local directory = Bionic.cacheDirectory()
    if not ensureDir(directory) then
        UIManager:nextTick(function()
            callback(nil, "Could not create Burrow's Bionic Reading cache.")
        end)
        return
    end

    local target, err = Bionic.cachePath(source)
    if not target then
        UIManager:nextTick(function() callback(nil, err) end)
        return
    end
    if lfs.attributes(target, "mode") == "file" then
        UIManager:nextTick(function() callback(target, nil) end)
        return
    end

    local existingJob = ASYNC_JOBS[target]
    if existingJob then
        existingJob.callbacks[#existingJob.callbacks + 1] = callback
        return
    end

    local job = {
        callbacks = { callback },
    }
    ASYNC_JOBS[target] = job

    local co = coroutine.create(function()
        local function cooperate()
            coroutine.yield()
        end
        local ok, buildErr = Epub.generateCooperative(source, target, cooperate)
        if not ok then
            return nil, buildErr
        end
        return target, nil
    end)

    local function finish(result, buildErr)
        if ASYNC_JOBS[target] == job then
            ASYNC_JOBS[target] = nil
        end
        if not result then os.remove(target) end

        local callbacks = job.callbacks
        job.callbacks = {}
        for _, cb in ipairs(callbacks) do
            if type(cb) == "function" then
                local ok, callbackErr = pcall(cb, result, buildErr)
                if not ok then
                    logger.warn(
                        "[Burrow bionic] Background cache callback failed",
                        callbackErr
                    )
                end
            end
        end
    end

    local function step()
        if ASYNC_JOBS[target] ~= job then return end
        local ok, result, buildErr = coroutine.resume(co)
        if not ok then
            finish(nil, tostring(result))
            return
        end
        if coroutine.status(co) == "dead" then
            finish(result, buildErr)
            return
        end
        UIManager:scheduleIn(ASYNC_STEP_DELAY, step)
    end

    logger.info("[Burrow bionic] Starting cooperative full shadow build", source)
    UIManager:nextTick(step)
end

function Bionic.setOpenProgressHint(source, progress)
    if not Bionic.isSupportedFile(source) then return end
    progress = tonumber(progress)
    if not progress then return end
    if progress < 0 then progress = 0 end
    if progress > 1 then progress = 1 end
    OPEN_PROGRESS_HINTS[source] = progress
end

local function currentXPointer(document)
    if not document or type(document.getXPointer) ~= "function" then return nil end
    local ok, value = pcall(document.getXPointer, document)
    if ok then return value end
end

local function trackHotPosition(plugin)
    local reader = plugin and plugin.ui or nil
    local document = reader and reader.document or nil
    if not reader or not document or reader.tearing_down
        or document._burrow_bionic_hot ~= true
    then
        return
    end

    local anchor = captureTextAnchor and captureTextAnchor(reader) or nil
    if anchor and isPendingAnchor and isPendingAnchor(anchor) then
        document._burrow_bionic_boundary_waiting = true
        local fallback = document._burrow_bionic_last_valid_xpointer
        if fallback and reader.rolling
            and type(reader.rolling.onGotoXPointer) == "function"
        then
            pcall(reader.rolling.onGotoXPointer, reader.rolling, fallback)
        end
        if not document._burrow_bionic_boundary_notice then
            document._burrow_bionic_boundary_notice = true
            UIManager:show(InfoMessage:new{
                text = _("Preparing more Bionic text…"),
                timeout = 1.5,
            })
        end
        return
    end

    local xpointer = currentXPointer(document)
    if xpointer then
        document._burrow_bionic_last_valid_xpointer = xpointer
    end
    if anchor then
        document._burrow_bionic_last_valid_anchor = anchor
    end
    if captureReadingPercent then
        document._burrow_bionic_last_valid_percent =
            captureReadingPercent(reader)
    end

    local currentPage, pageCount
    if type(document.getCurrentPage) == "function" then
        local ok, value = pcall(document.getCurrentPage, document)
        if ok then currentPage = tonumber(value) end
    end
    if type(document.getPageCount) == "function" then
        local ok, value = pcall(document.getPageCount, document)
        if ok then pageCount = tonumber(value) end
    end

    document._burrow_bionic_boundary_waiting =
        currentPage ~= nil and pageCount ~= nil and currentPage >= pageCount - 1
    if not document._burrow_bionic_boundary_waiting then
        document._burrow_bionic_boundary_notice = false
    end
end

local function scheduleHotPromotion(source, hotPath, fullPath)
    local stableTicks = 0
    local lastXPointer

    local function check()
        local okReader, ReaderUI = pcall(require, "apps/reader/readerui")
        local reader = okReader and ReaderUI.instance or nil
        local document = reader and reader.document or nil

        if not reader or not document or reader.tearing_down then return end
        if document._burrow_bionic_original_file ~= source
            or document._burrow_bionic_hot ~= true
        then
            return
        end

        if reader.menu and reader.menu.menu_container then
            stableTicks = 0
            UIManager:scheduleIn(0.6, check)
            return
        end

        local rolling = reader.rolling
        if rolling and rolling._current_rerendering_pid ~= nil then
            stableTicks = 0
            UIManager:scheduleIn(0.6, check)
            return
        end

        local xpointer = currentXPointer(document)
        if lastXPointer ~= nil and xpointer == lastXPointer then
            stableTicks = stableTicks + 1
        else
            stableTicks = 0
        end
        lastXPointer = xpointer

        if document._burrow_bionic_boundary_waiting ~= true
            and stableTicks < 2
        then
            UIManager:scheduleIn(0.6, check)
            return
        end

        if type(reader.reloadDocument) ~= "function" then return end

        local currentAnchor = captureTextAnchor and captureTextAnchor(reader) or nil
        local pending = currentAnchor and isPendingAnchor
            and isPendingAnchor(currentAnchor)
        local savedXPointer = pending
            and document._burrow_bionic_last_valid_xpointer
            or xpointer
        local savedAnchor = pending
            and document._burrow_bionic_last_valid_anchor
            or currentAnchor
        local savedPercent = pending
            and document._burrow_bionic_last_valid_percent
            or (captureReadingPercent and captureReadingPercent(reader) or nil)

        if not savedXPointer then
            savedXPointer = document._burrow_bionic_last_valid_xpointer
        end
        if not savedAnchor then
            savedAnchor = document._burrow_bionic_last_valid_anchor
        end

        logger.info("[Burrow bionic] Promoting hot EPUB to complete shadow")
        local okReload, reloadErr = pcall(
            reader.reloadDocument,
            reader,
            nil,
            true,
            function(reopenedReader)
                local rawRestored = false
                if savedXPointer
                    and reopenedReader
                    and reopenedReader.rolling
                    and type(reopenedReader.rolling.onGotoXPointer) == "function"
                then
                    rawRestored = pcall(
                        reopenedReader.rolling.onGotoXPointer,
                        reopenedReader.rolling,
                        savedXPointer
                    )
                end

                -- Prepared spine items contain the same transformed XHTML in the
                -- hot and complete shadows, so their XPointer is normally exact.
                -- The semantic anchor is an independent guard against a DOM/path
                -- mismatch and never relies on a synthetic preparation chapter.
                if savedAnchor and restoreSemanticAnchor then
                    restoreSemanticAnchor(reopenedReader, savedAnchor)
                elseif not rawRestored and restoreReadingPercent then
                    restoreReadingPercent(reopenedReader, savedPercent)
                end

                os.remove(hotPath)
            end
        )
        if not okReload then
            logger.warn("[Burrow bionic] Could not promote complete shadow", reloadErr)
        end
    end

    UIManager:scheduleIn(0.8, check)
end

local function activeDocument(search)
    return search and search.ui and search.ui.document
        and search.ui.document._burrow_bionic_active == true
end

function Bionic.attachPluginClass(Burrow)
    if type(Burrow) ~= "table" or Burrow._burrow_bionic_reader_context_hook then
        return
    end
    Burrow._burrow_bionic_reader_context_hook = true

    local originalDocSettingsLoad = Burrow.onDocSettingsLoad
    function Burrow:onDocSettingsLoad(docSettings, document)
        if originalDocSettingsLoad then
            originalDocSettingsLoad(self, docSettings, document)
        end

        -- This event is emitted only by an actual ReaderUI instance, after
        -- document modules/plugins are created but before CRengine performs its
        -- full document load. Mark that exact CreDocument so file-manager cover
        -- and metadata probes never get routed through the Bionic shadow EPUB.
        local doc = document or self.document or (self.ui and self.ui.document)
        if doc and doc.provider == "crengine" then
            doc._burrow_bionic_reader_context = true
            if docSettings and type(docSettings.readSetting) == "function" then
                doc._burrow_bionic_percent_hint =
                    tonumber(docSettings:readSetting("percent_finished")) or 0
            end
        end
    end

    local originalReaderReady = Burrow.onReaderReady
    function Burrow:onReaderReady(...)
        local result
        if originalReaderReady then
            result = originalReaderReady(self, ...)
        end
        UIManager:nextTick(function()
            refreshAdaptiveOrnaments(self)
            trackHotPosition(self)
        end)
        return result
    end

    local originalPageUpdate = Burrow.onPageUpdate
    function Burrow:onPageUpdate(...)
        local result
        if originalPageUpdate then
            result = originalPageUpdate(self, ...)
        end
        UIManager:nextTick(function()
            trackHotPosition(self)
        end)
        return result
    end

    local originalPosUpdate = Burrow.onPosUpdate
    function Burrow:onPosUpdate(...)
        local result
        if originalPosUpdate then
            result = originalPosUpdate(self, ...)
        end
        UIManager:nextTick(function()
            trackHotPosition(self)
        end)
        return result
    end
end

function Bionic.apply()
    if Bionic.applied then return true end

    local CreDocument = require("document/credocument")
    local ReaderSearch = require("apps/reader/modules/readersearch")

    if not CreDocument._burrow_bionic_shadow_loader_v1 then
        CreDocument._burrow_bionic_shadow_loader_v1 = true
        local originalLoad = CreDocument.loadDocument

        function CreDocument:loadDocument(fullDocument)
            if self._loaded or fullDocument == false
                or self._burrow_bionic_reader_context ~= true
                or not Bionic.isEnabled()
                or not Bionic.isSupportedFile(self.file)
            then
                return originalLoad(self, fullDocument)
            end

            local originalFile = self.file
            local shadow = Bionic.cachedPath(originalFile)
            local hot = false

            if not shadow then
                local progress = OPEN_PROGRESS_HINTS[originalFile]
                    or tonumber(self._burrow_bionic_percent_hint)
                    or 0
                OPEN_PROGRESS_HINTS[originalFile] = nil

                local hotErr
                shadow, hotErr = Bionic.ensureHotCache(
                    originalFile,
                    progress,
                    HOT_SPINE_RADIUS
                )
                if not shadow then
                    logger.warn(
                        "[Burrow bionic] Could not prepare Bionic-only hot EPUB",
                        hotErr
                    )
                    UIManager:nextTick(function()
                        UIManager:show(InfoMessage:new{
                            text = _("Bionic Reading could not prepare this EPUB. The normal-text book was not opened."),
                            timeout = 4,
                        })
                    end)
                    return false
                end
                hot = true
            end

            self.file = shadow
            local ok, result = pcall(originalLoad, self, fullDocument)
            self.file = originalFile
            if not ok then error(result) end

            if result then
                self._burrow_bionic_active = true
                self._burrow_bionic_hot = hot
                self._burrow_bionic_shadow_file = shadow
                self._burrow_bionic_original_file = originalFile

                -- When the existing ornament profile proves every non-cover
                -- image is eligible for Burrow's adaptive treatment, mark the
                -- Bionic document for the same no-reload dark-mode renderer.
                -- If the profile is not ready yet, onReaderReady inspects it
                -- cooperatively and applies this state afterward.
                applyAdaptiveOrnamentState(
                    self,
                    originalFile,
                    OrnamentEpub.peekProfile(originalFile)
                )

                logger.info(
                    hot
                        and "[Burrow bionic] Loaded spine-priority hot EPUB"
                        or "[Burrow bionic] Loaded complete shadow EPUB"
                )

                if hot then
                    local hotPath = shadow
                    Bionic.ensureCacheAsync(originalFile, function(fullPath, buildErr)
                        if not fullPath then
                            logger.warn(
                                "[Burrow bionic] Cooperative full shadow build failed",
                                buildErr
                            )
                            return
                        end
                        scheduleHotPromotion(originalFile, hotPath, fullPath)
                    end)
                end
            end
            return result
        end
    end

    -- Current CRengine can search across inline text-node boundaries. Always
    -- enable that flag on a Burrow shadow document, because each fixation point
    -- intentionally introduces an inline <b> boundary inside a word.
    if not ReaderSearch._burrow_bionic_search_bridge_v1 then
        ReaderSearch._burrow_bionic_search_bridge_v1 = true

        local originalSearch = ReaderSearch.search
        function ReaderSearch:search(pattern, origin, searchType, caseInsensitive)
            if not activeDocument(self) then
                return originalSearch(self, pattern, origin, searchType, caseInsensitive)
            end

            local adjusted = {}
            if type(searchType) == "table" then
                for key, value in pairs(searchType) do adjusted[key] = value end
            end
            adjusted.flags = bit.bor(tonumber(adjusted.flags) or 0, 0x0001)
            if adjusted.regex == nil then adjusted.regex = false end
            return originalSearch(self, pattern, origin, adjusted, caseInsensitive)
        end

        local originalFindAll = ReaderSearch.findAllText
        function ReaderSearch:findAllText(searchText)
            if not activeDocument(self) or type(self.current_search_type) ~= "table" then
                return originalFindAll(self, searchText)
            end

            local searchType = self.current_search_type
            local previousFlags = searchType.flags
            searchType.flags = bit.bor(tonumber(previousFlags) or 0, 0x0001)
            local ok, a, b, c = pcall(originalFindAll, self, searchText)
            searchType.flags = previousFlags
            if not ok then error(a) end
            return a, b, c
        end
    end

    Bionic.applied = true
    logger.info("[Burrow] Bionic Reading shadow loader available")
    return true
end

local function closeReaderMenu(reader, touchMenu)
    if reader and reader.menu and reader.menu.menu_container
        and type(reader.menu.onCloseReaderMenu) == "function"
    then
        local ok, err = pcall(reader.menu.onCloseReaderMenu, reader.menu)
        if ok then return end
        logger.warn("[Burrow bionic] Could not close ReaderMenu", err)
    end
    if touchMenu then UIManager:close(touchMenu) end
end

-- A percentage is a useful coarse location across a reflow, but it is not a
-- stable content identity: real bold changes line wrapping and total document
-- height. Capture a short sequence of actual words near the current page start
-- and use it as the primary post-reload anchor.
local ANCHOR_WORD_COUNT = 10
local ANCHOR_BACKTRACK_WORDS = 1800
local ANCHOR_FORWARD_WORDS = 3800

local function normalizeAnchorWord(text)
    if type(text) ~= "string" then return nil end
    text = text:gsub("^%s+", ""):gsub("%s+$", "")
    text = text:gsub("%s+", " ")
    if text == "" then return nil end
    return text:lower()
end

local function getWordAt(document, wordStart)
    if not document
        or not wordStart
        or type(document.getNextVisibleWordEnd) ~= "function"
        or type(document.getTextFromXPointers) ~= "function"
    then
        return nil, nil
    end

    local okEnd, wordEnd = pcall(
        document.getNextVisibleWordEnd,
        document,
        wordStart
    )
    if not okEnd or not wordEnd then
        return nil, nil
    end

    local okText, text = pcall(
        document.getTextFromXPointers,
        document,
        wordStart,
        wordEnd,
        false
    )
    if not okText then
        return nil, wordEnd
    end

    return normalizeAnchorWord(text), wordEnd
end

local function nextWordStart(document, from)
    if not document
        or not from
        or type(document.getNextVisibleWordStart) ~= "function"
    then
        return nil
    end

    local ok, xp = pcall(
        document.getNextVisibleWordStart,
        document,
        from
    )
    if ok then return xp end
end

local function previousWordStart(document, from)
    if not document
        or not from
        or type(document.getPrevVisibleWordStart) ~= "function"
    then
        return nil
    end

    local ok, xp = pcall(
        document.getPrevVisibleWordStart,
        document,
        from
    )
    if ok then return xp end
end

captureTextAnchor = function(reader)
    local document = reader and reader.document
    if not document
        or document.provider ~= "crengine"
        or type(document.getXPointer) ~= "function"
    then
        return nil
    end

    local ok, current = pcall(document.getXPointer, document)
    if not ok or not current then
        return nil
    end

    local start = nextWordStart(document, current)
    if not start then
        start = previousWordStart(document, current)
    end
    if not start then
        return nil
    end

    local words = {}
    local cursor = start
    local firstStart = start

    -- Collect enough semantic words to make accidental duplicate matches very
    -- unlikely, without depending on rendered page numbers or DOM node paths.
    for _ = 1, ANCHOR_WORD_COUNT do
        if not cursor then break end

        local word, wordEnd = getWordAt(document, cursor)
        if word then
            words[#words + 1] = word
        end

        if not wordEnd then break end
        local nextStart = nextWordStart(document, wordEnd)
        if not nextStart or nextStart == cursor then break end
        cursor = nextStart
    end

    if #words < 5 then
        return nil
    end

    logger.dbg(
        "[Burrow bionic] Captured semantic position anchor",
        #words
    )

    return {
        words = words,
        source_xpointer = firstStart,
    }
end

isPendingAnchor = function(anchor)
    if type(anchor) ~= "table" or type(anchor.words) ~= "table" then
        return false
    end
    local first = anchor.words[1]
    local second = anchor.words[2]
    local third = anchor.words[3]
    return first == "preparing"
        and second == "bionic"
        and third == "reading"
end

local function wordsMatch(window, expected)
    if #window ~= #expected then return false end
    for i = 1, #expected do
        if window[i].word ~= expected[i] then
            return false
        end
    end
    return true
end

local function locateTextAnchor(reader, anchor)
    if type(anchor) ~= "table"
        or type(anchor.words) ~= "table"
        or #anchor.words < 5
    then
        return nil
    end

    local document = reader and reader.document
    if not document
        or document.provider ~= "crengine"
        or type(document.getXPointer) ~= "function"
    then
        return nil
    end

    local ok, coarse = pcall(document.getXPointer, document)
    if not ok or not coarse then
        return nil
    end

    -- Percentage restoration should already put us within a few pages. Move
    -- backward enough to bracket the old location, then scan forward with a
    -- small rolling word window. This avoids invoking ReaderSearch or altering
    -- the user's search state/history.
    local scanStart = coarse
    for _ = 1, ANCHOR_BACKTRACK_WORDS do
        local previous = previousWordStart(document, scanStart)
        if not previous or previous == scanStart then break end
        scanStart = previous
    end

    local cursor = scanStart
    local window = {}

    for _ = 1, ANCHOR_FORWARD_WORDS do
        if not cursor then break end

        local word, wordEnd = getWordAt(document, cursor)
        if word then
            window[#window + 1] = {
                word = word,
                xpointer = cursor,
            }
            if #window > #anchor.words then
                table.remove(window, 1)
            end

            if #window == #anchor.words
                and wordsMatch(window, anchor.words)
            then
                logger.dbg(
                    "[Burrow bionic] Matched semantic position anchor"
                )
                return window[1].xpointer
            end
        end

        if not wordEnd then break end
        local nextStart = nextWordStart(document, wordEnd)
        if not nextStart or nextStart == cursor then break end
        cursor = nextStart
    end

    logger.dbg(
        "[Burrow bionic] Semantic position anchor not found; keeping percentage fallback"
    )
    return nil
end

restoreSemanticAnchor = function(reader, anchor)
    local xpointer = locateTextAnchor(reader, anchor)
    if not xpointer
        or not reader
        or not reader.rolling
        or type(reader.rolling.onGotoXPointer) ~= "function"
    then
        return false
    end

    local ok, err = pcall(
        reader.rolling.onGotoXPointer,
        reader.rolling,
        xpointer
    )
    if not ok then
        logger.warn(
            "[Burrow bionic] Could not restore semantic position anchor",
            err
        )
        return false
    end

    logger.dbg(
        "[Burrow bionic] Restored semantic position anchor"
    )
    return true
end

captureReadingPercent = function(reader)
    if not reader or not reader.rolling then
        return nil
    end

    local rolling = reader.rolling
    if type(rolling.getLastPercent) == "function" then
        local ok, percent = pcall(rolling.getLastPercent, rolling)
        if ok and type(percent) == "number" then
            if percent < 0 then percent = 0 end
            if percent > 1 then percent = 1 end
            return percent
        end
    end

    local footer = reader.view and reader.view.footer
    local percent = footer and footer.percent_finished
    if type(percent) == "number" then
        if percent < 0 then percent = 0 end
        if percent > 1 then percent = 1 end
        return percent
    end

    return nil
end

restoreReadingPercent = function(reader, percent)
    if type(percent) ~= "number"
        or not reader
        or not reader.rolling
        or type(reader.rolling.onGotoPercent) ~= "function"
    then
        return false
    end

    local ok, err = pcall(
        reader.rolling.onGotoPercent,
        reader.rolling,
        percent * 100
    )
    if not ok then
        logger.warn(
            "[Burrow bionic] Could not restore reading position after toggle",
            err
        )
        return false
    end

    logger.dbg(
        "[Burrow bionic] Restored reading position after toggle",
        percent
    )
    return true
end

function Bionic.toggleFromQuickSettings(touchMenu)
    local ReaderUI = require("apps/reader/readerui")
    local reader = ReaderUI.instance
    local savedPercent = captureReadingPercent(reader)
    local savedTextAnchor = captureTextAnchor(reader)

    Bionic.setEnabled(not Bionic.isEnabled())
    local nowEnabled = Bionic.isEnabled()
    closeReaderMenu(reader, touchMenu)

    if not reader or not reader.document then return nowEnabled end

    local file = reader.document._burrow_bionic_original_file or reader.document.file
    if not Bionic.isSupportedFile(file) then
        UIManager:nextTick(function()
            UIManager:show(InfoMessage:new{
                text = _("Bionic Reading is saved globally and will apply to EPUB books."),
                timeout = 3,
            })
        end)
        return nowEnabled
    end

    UIManager:nextTick(function()
        local info = InfoMessage:new{
            text = nowEnabled and _("Applying Bionic Reading…")
                or _("Returning to normal text…"),
            timeout = 0,
        }
        UIManager:show(info)
        UIManager:forceRePaint()

        UIManager:scheduleIn(0.05, function()
            if nowEnabled then
                Bionic.setOpenProgressHint(file, savedPercent)
            end
            reader:reloadDocument(nil, true, function(reopenedReader)
                -- First get close using layout-independent relative progress.
                restoreReadingPercent(reopenedReader, savedPercent)

                -- Then pin the reload to the same actual words. Unlike page
                -- count/height, the book's text is unchanged by the shadow
                -- EPUB transformation.
                restoreSemanticAnchor(reopenedReader, savedTextAnchor)

                UIManager:close(info)
            end)
        end)
    end)

    return nowEnabled
end

return Bionic

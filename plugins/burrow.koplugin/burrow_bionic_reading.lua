local bit = require("bit")
local DataStorage = require("datastorage")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local util = require("util")
local _ = require("gettext")

local Epub = require("burrow_bionic_epub")

local MODULE_KEY = "burrow.bionic_reading"
local existing = package.loaded[MODULE_KEY]
if existing then return existing end

local Bionic = {
    key = MODULE_KEY,
    SETTING_KEY = "burrow_bionic_reading",
    CACHE_VERSION = "crosspoint45-v1",
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

function Bionic.cachePath(source)
    local checksum = util.partialMD5(source)
    if not checksum then return nil, "Could not identify this EPUB." end

    local attrs = lfs.attributes(source) or {}
    local identity = table.concat({
        tostring(checksum),
        tostring(attrs.size or ""),
        tostring(attrs.modification or ""),
        Bionic.CACHE_VERSION,
    }, "-")
    identity = identity:gsub("[^%w%-_%.]", "_")
    return Bionic.cacheDirectory() .. "/" .. identity .. ".epub"
end

local HOT_SPINE_RADIUS = 2
local ASYNC_STEP_DELAY = 0.01
local ASYNC_JOBS = {}
local OPEN_PROGRESS_HINTS = {}

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

        local xpointer
        if type(document.getXPointer) == "function" then
            local ok, value = pcall(document.getXPointer, document)
            if ok then xpointer = value end
        end

        if lastXPointer ~= nil and xpointer == lastXPointer then
            stableTicks = stableTicks + 1
        else
            stableTicks = 0
        end
        lastXPointer = xpointer

        if stableTicks < 2 then
            UIManager:scheduleIn(0.6, check)
            return
        end

        if type(reader.reloadDocument) ~= "function" then return end

        local savedXPointer = xpointer
        logger.info("[Burrow bionic] Promoting hot EPUB to complete shadow")
        local okReload, reloadErr = pcall(
            reader.reloadDocument,
            reader,
            nil,
            true,
            function(reopenedReader)
                if savedXPointer
                    and reopenedReader
                    and reopenedReader.rolling
                    and type(reopenedReader.rolling.onGotoXPointer) == "function"
                then
                    pcall(
                        reopenedReader.rolling.onGotoXPointer,
                        reopenedReader.rolling,
                        savedXPointer
                    )
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

local function captureTextAnchor(reader)
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

local function restoreSemanticAnchor(reader, anchor)
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

local function captureReadingPercent(reader)
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

local function restoreReadingPercent(reader, percent)
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

    local file = reader.document.file
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

local logger = require("logger")

local Module = {}

local PAUSE_INTERVAL = 0.20
local MAX_IDLE_TICKS = 12
local URGENT_SWAP_DELAY = 0.08

local JOB_SOURCES = {}
local IDENTITY_CACHE = {}

local Epub
local UIManager
local Screen
local Blitbuffer
local urgent_request
local urgent_token = 0

local function getUpValue(fn, wanted)
    if type(fn) ~= "function" then return nil, nil end
    for index = 1, 100 do
        local name, value = debug.getupvalue(fn, index)
        if not name then break end
        if name == wanted then return index, value end
    end
    return nil, nil
end

local function setUpValue(fn, wanted, value)
    local index = getUpValue(fn, wanted)
    if not index then return false end
    debug.setupvalue(fn, index, value)
    return true
end

local function originalSourcePath(document)
    if type(document) ~= "table" then return nil end
    return document._burrow_epub_ornaments_source_file or document.file
end

local function activeReaderState(sourcePath)
    local ok, ReaderUI = pcall(require, "apps/reader/readerui")
    if not ok or type(ReaderUI) ~= "table" then return "idle" end

    local reader = ReaderUI.instance
    if type(reader) ~= "table" or reader.tearing_down then return "idle" end
    local document = reader.document
    if type(document) ~= "table" then return "idle" end

    local active_source = originalSourcePath(document)
    if active_source == sourcePath then
        return "active", reader, document
    end
    return "other", reader, document
end

local function currentProgress(document)
    if type(document) ~= "table" then return 0 end

    if type(document.getCurrentPage) == "function"
        and type(document.getPageCount) == "function"
    then
        local ok_page, page = pcall(document.getCurrentPage, document)
        local ok_count, count = pcall(document.getPageCount, document)
        page, count = tonumber(page), tonumber(count)
        if ok_page and ok_count and page and count and count > 1 then
            local progress = (page - 1) / (count - 1)
            if progress < 0 then return 0 end
            if progress > 1 then return 1 end
            return progress
        end
    end

    if type(document.getCurrentPos) == "function"
        and type(document.getFullHeight) == "function"
    then
        local ok_pos, pos = pcall(document.getCurrentPos, document)
        local ok_height, height = pcall(document.getFullHeight, document)
        pos, height = tonumber(pos), tonumber(height)
        if ok_pos and ok_height and pos and height and height > 0 then
            local progress = pos / height
            if progress < 0 then return 0 end
            if progress > 1 then return 1 end
            return progress
        end
    end

    if type(document.getProgress) == "function" then
        local ok, progress = pcall(document.getProgress, document)
        progress = tonumber(progress)
        if ok and progress then
            if progress > 1 and progress <= 100 then progress = progress / 100 end
            if progress < 0 then return 0 end
            if progress > 1 then return 1 end
            return progress
        end
    end

    return 0
end

local function hotWindowStillRelevant(document, meta)
    if type(meta) ~= "table" then return false end
    local total = tonumber(meta.total_spine) or 0
    local center = tonumber(meta.center) or 0
    local radius = math.max(1, tonumber(meta.radius) or 1)
    if total <= 0 or center <= 0 then return false end

    local current = math.floor(currentProgress(document) * total) + 1
    if current > total then current = total end
    if current < 1 then current = 1 end
    return math.abs(current - center) <= radius
end

local function softPaletteActive()
    return tonumber(Blitbuffer.COLOR_WHITE.a) == 0xF2
        and tonumber(Blitbuffer.COLOR_BLACK.a) == 0x20
end

local function paletteForDocument(document)
    local tone = "light"
    if Screen.night_mode and document._nightmode_images ~= false then
        tone = "night"
    end
    return (softPaletteActive() and "soft-" or "pure-") .. tone
end

local function makeReaderAwareScheduler()
    return function(job_table, key, co, callback)
        local existing = job_table[key]
        if existing then
            if type(callback) == "function" then
                existing.callbacks[#existing.callbacks + 1] = callback
            end
            return existing
        end

        local job = {
            callbacks = {},
            inactive_ticks = 0,
        }
        if type(callback) == "function" then
            job.callbacks[1] = callback
        end
        job_table[key] = job

        local function abandon(reason)
            if job_table[key] == job then job_table[key] = nil end
            JOB_SOURCES[key] = nil
            job.callbacks = {}
            logger.dbg("[Burrow ornaments] Paused background job discarded", reason, key)
        end

        local function finish(a, b, c, d)
            if job_table[key] == job then job_table[key] = nil end
            JOB_SOURCES[key] = nil
            local callbacks = job.callbacks
            job.callbacks = {}
            for _, cb in ipairs(callbacks) do
                if type(cb) == "function" then
                    local ok, err = pcall(cb, a, b, c, d)
                    if not ok then
                        logger.warn("[Burrow ornaments] Async callback failed", err)
                    end
                end
            end
        end

        local function step()
            if job_table[key] ~= job then return end

            local sourcePath = JOB_SOURCES[key]
            if sourcePath then
                local state = activeReaderState(sourcePath)
                if state == "other" then
                    abandon("different book is active")
                    return
                elseif state ~= "active" then
                    job.inactive_ticks = job.inactive_ticks + 1
                    if job.inactive_ticks >= MAX_IDLE_TICKS then
                        abandon("reader has been closed")
                        return
                    end
                    UIManager:scheduleIn(PAUSE_INTERVAL, step)
                    return
                end
                job.inactive_ticks = 0
            end

            local ok, a, b, c, d = coroutine.resume(co)
            if not ok then
                finish(nil, tostring(a), nil)
                return
            end
            if coroutine.status(co) == "dead" then
                finish(a, b, c, d)
                return
            end
            UIManager:scheduleIn(0.01, step)
        end

        UIManager:nextTick(step)
        return job
    end
end

local function installIdentityMemo(EpubModule, profilePath)
    local original_source_identity
    local memoized_source_identity

    local function patch(fn)
        if type(fn) ~= "function" then return false end
        local index, current = getUpValue(fn, "sourceIdentity")
        if not index or type(current) ~= "function" then return false end

        if not original_source_identity then
            original_source_identity = current
            memoized_source_identity = function(source)
                local lfs = require("libs/libkoreader-lfs")
                local attrs = lfs.attributes(source) or {}
                local size = attrs.size
                local modification = attrs.modification
                local cached = IDENTITY_CACHE[source]
                if cached
                    and cached.size == size
                    and cached.modification == modification
                then
                    return cached.identity
                end

                local identity = original_source_identity(source)
                if identity then
                    IDENTITY_CACHE[source] = {
                        size = size,
                        modification = modification,
                        identity = identity,
                    }
                end
                return identity
            end
        end

        if current ~= memoized_source_identity then
            debug.setupvalue(fn, index, memoized_source_identity)
        end
        return true
    end

    local patched = false
    patched = patch(EpubModule.cachePath) or patched
    patched = patch(EpubModule.hotCachePath) or patched
    patched = patch(profilePath) or patched
    return patched
end

local function tryUrgentSwap(request)
    if urgent_request ~= request then return false end

    local state, reader, document = activeReaderState(request.source)
    if state ~= "active" or not reader or not document then
        urgent_request = nil
        return false
    end

    if document._burrow_epub_ornaments_fast_adaptive == true then
        urgent_request = nil
        return true
    end

    if paletteForDocument(document) ~= request.palette then
        urgent_request = nil
        return false
    end

    if document._burrow_epub_ornaments_active == true
        and document._burrow_epub_ornaments_palette == request.palette
    then
        urgent_request = nil
        return true
    end

    local full, fullErr, fullCount = Epub.cachedResult(
        request.source,
        request.palette
    )
    if fullErr then
        logger.warn("[Burrow ornaments] Urgent palette lookup failed", fullErr)
    end

    local candidate = full
    if not candidate and fullCount ~= 0 then
        local preferred, _, meta = Epub.preferredCache(
            request.source,
            request.palette
        )
        if preferred and hotWindowStillRelevant(document, meta) then
            candidate = preferred
        end
    end

    if not candidate then return false end
    if type(reader.reloadDocument) ~= "function" then
        urgent_request = nil
        return false
    end

    local ok, err = pcall(reader.reloadDocument, reader, nil, true)
    if not ok then
        logger.warn("[Burrow ornaments] Immediate palette reload failed", err)
        urgent_request = nil
        return false
    end

    urgent_request = nil
    logger.dbg("[Burrow ornaments] Applied prepared palette immediately", request.palette)
    return true
end

local function scheduleUrgentCheck(request, delay)
    UIManager:scheduleIn(delay or 0.02, function()
        if urgent_request == request then
            tryUrgentSwap(request)
        end
    end)
end

local function maybeRetryUrgent(sourcePath)
    local request = urgent_request
    if request and request.source == sourcePath then
        scheduleUrgentCheck(request, 0.02)
    end
end

local function wrapCallback(sourcePath, callback)
    return function(a, b, c, d)
        if type(callback) == "function" then
            callback(a, b, c, d)
        end
        maybeRetryUrgent(sourcePath)
    end
end

function Module.apply()
    if Module.applied then return true end

    UIManager = require("ui/uimanager")
    Screen = require("device").screen
    Blitbuffer = require("ffi/blitbuffer")
    Epub = require("burrow_soft_palette_epub")

    if type(Epub.inspectAsync) ~= "function"
        or type(Epub.ensureCacheAsync) ~= "function"
        or type(Epub.ensureHotCacheAsync) ~= "function"
        or type(Epub.cachePath) ~= "function"
        or type(Epub.hotCachePath) ~= "function"
    then
        return false, "Decorative EPUB async cache API is unavailable"
    end

    if Epub._burrow_reader_latency_v1 then
        Module.applied = true
        return true
    end

    local publicInspectAsync = Epub.inspectAsync
    local publicEnsureCacheAsync = Epub.ensureCacheAsync
    local publicEnsureHotCacheAsync = Epub.ensureHotCacheAsync

    -- The beta.1 dual-tone helper wraps ensureCacheAsync. Reach through that
    -- wrapper so the low-level cooperative scheduler itself remains patchable.
    local _, baseEnsureCacheAsync = getUpValue(
        publicEnsureCacheAsync,
        "originalEnsureCacheAsync"
    )
    if type(baseEnsureCacheAsync) ~= "function" then
        baseEnsureCacheAsync = publicEnsureCacheAsync
    end

    local _, profilePath = getUpValue(publicInspectAsync, "profilePath")
    local readerAwareScheduler = makeReaderAwareScheduler()
    local scheduler_patched = false

    for _, fn in ipairs({
        publicInspectAsync,
        baseEnsureCacheAsync,
        publicEnsureHotCacheAsync,
    }) do
        if setUpValue(fn, "scheduleCoroutine", readerAwareScheduler) then
            scheduler_patched = true
        end
    end

    if not scheduler_patched then
        return false, "Could not locate decorative EPUB async scheduler"
    end

    installIdentityMemo(Epub, profilePath)

    function Epub.inspectAsync(sourcePath, callback)
        local key = sourcePath
        if type(profilePath) == "function" then
            local ok, value = pcall(profilePath, sourcePath)
            if ok and value then key = value end
        end
        JOB_SOURCES[key] = sourcePath

        local result = publicInspectAsync(
            sourcePath,
            wrapCallback(sourcePath, callback)
        )
        if result and result.completed then
            JOB_SOURCES[key] = nil
        end
        return result
    end

    function Epub.ensureCacheAsync(sourcePath, paletteName, knownProfile, callback)
        local target = Epub.cachePath(sourcePath, paletteName)
        if target then JOB_SOURCES[target] = sourcePath end

        local result = publicEnsureCacheAsync(
            sourcePath,
            paletteName,
            knownProfile,
            wrapCallback(sourcePath, callback)
        )
        if result and result.completed and target then
            JOB_SOURCES[target] = nil
        end
        return result
    end

    function Epub.ensureHotCacheAsync(sourcePath, paletteName, progress, radius, callback)
        local target = Epub.hotCachePath(
            sourcePath,
            paletteName,
            progress,
            radius
        )
        if target then JOB_SOURCES[target] = sourcePath end

        local result = publicEnsureHotCacheAsync(
            sourcePath,
            paletteName,
            progress,
            radius,
            wrapCallback(sourcePath, callback)
        )
        if result and result.completed and target then
            JOB_SOURCES[target] = nil
        end
        return result
    end

    Epub._burrow_reader_latency_v1 = true
    Module.applied = true
    return true
end

function Module.attachPluginClass(plugin_class)
    if type(plugin_class) ~= "table" then
        return false, "Burrow plugin class is unavailable"
    end
    if plugin_class._burrow_reader_latency_v1 then return true end
    plugin_class._burrow_reader_latency_v1 = true

    local function requestImmediatePalette(plugin)
        local reader = plugin and plugin.ui or nil
        local document = reader and reader.document or nil
        if not document or reader.tearing_down then return end
        if document._burrow_epub_ornaments_fast_adaptive == true then return end

        local sourcePath = originalSourcePath(document)
        if type(sourcePath) ~= "string"
            or sourcePath:lower():match("%.epub$") == nil
        then
            return
        end

        urgent_token = urgent_token + 1
        local request = {
            token = urgent_token,
            source = sourcePath,
            palette = paletteForDocument(document),
        }
        urgent_request = request
        scheduleUrgentCheck(request, URGENT_SWAP_DELAY)
    end

    local originalToggleNightMode = plugin_class.onToggleNightMode
    function plugin_class:onToggleNightMode(...)
        local result
        if originalToggleNightMode then
            result = originalToggleNightMode(self, ...)
        end
        requestImmediatePalette(self)
        return result
    end

    local originalSetNightMode = plugin_class.onSetNightMode
    function plugin_class:onSetNightMode(...)
        local result
        if originalSetNightMode then
            result = originalSetNightMode(self, ...)
        end
        requestImmediatePalette(self)
        return result
    end

    return true
end

return Module

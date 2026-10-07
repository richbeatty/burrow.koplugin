local Device = require("device")
local logger = require("logger")
local time = require("ui/time")
local UIManager = require("ui/uimanager")

local Module = {}

local RERENDER_RETRY = 0.35
local LIBRARY_IDLE_DELAY = 2.0
local LIBRARY_IDLE_RETRIES = 5
local MAINTENANCE_IDLE_SECONDS = 8.0
local MAINTENANCE_RECHECK_SECONDS = 1.0
local MAINTENANCE_SECOND_PASS_DELAY = 1.5

local last_input_time = time.now()
local maintenance_scheduled = false
local maintenance_reason
local input_watcher

local function pack(...)
    return { n = select("#", ...), ... }
end

local function unpackPacked(values)
    return unpack(values, 1, values.n or #values)
end

local function stripPcallStatus(values)
    local ok = values[1]
    local result = { n = values.n - 1 }
    for index = 2, values.n do
        result[index - 1] = values[index]
    end
    if not ok then error(result[1]) end
    return unpackPacked(result)
end

local function markInputActivity()
    last_input_time = time.now()
end

local function activeReaderDocuments()
    local ok, ReaderUI = pcall(require, "apps/reader/readerui")
    if not ok or type(ReaderUI) ~= "table" then
        return nil, nil, nil
    end

    local reader = ReaderUI.instance
    if type(reader) ~= "table" or reader.tearing_down then
        return nil, nil, nil
    end

    local document = reader.document
    if type(document) ~= "table" then
        return reader, nil, nil
    end

    local ornamentSource =
        document._burrow_epub_ornaments_source_file or document.file
    local bionicSource =
        document._burrow_bionic_original_file or document.file
    return reader, ornamentSource, bionicSource
end

local function readerHasBlockingWork(reader)
    if not reader or reader.tearing_down then return false end
    local rolling = reader.rolling
    return type(rolling) == "table"
        and rolling._current_rerendering_pid ~= nil
end

local function readRssKb()
    local file = io.open("/proc/self/status", "r")
    if not file then return nil end
    local content = file:read("*a")
    file:close()
    if not content then return nil end
    return tonumber(content:match("VmRSS:%s+(%d+)%s+kB"))
end

local function pruneRuntimeState()
    local _, ornamentSource, bionicSource = activeReaderDocuments()
    local removed = 0
    local cancelled = 0

    local okOrnaments, OrnamentEpub = pcall(
        require,
        "burrow_soft_palette_epub"
    )
    if okOrnaments
        and type(OrnamentEpub) == "table"
        and type(OrnamentEpub.pruneRuntimeState) == "function"
    then
        local ok, count = pcall(
            OrnamentEpub.pruneRuntimeState,
            ornamentSource
        )
        if ok then removed = removed + (tonumber(count) or 0) end
    end

    local okLatency, ReaderLatency = pcall(
        require,
        "burrow_reader_latency"
    )
    if okLatency
        and type(ReaderLatency) == "table"
        and type(ReaderLatency.pruneRuntimeState) == "function"
    then
        local ok, count = pcall(
            ReaderLatency.pruneRuntimeState,
            ornamentSource
        )
        if ok then removed = removed + (tonumber(count) or 0) end
    end

    local Bionic = package.loaded["burrow.bionic_reading"]
    if type(Bionic) == "table"
        and type(Bionic.pruneRuntimeState) == "function"
    then
        local ok, hints, jobs = pcall(
            Bionic.pruneRuntimeState,
            bionicSource
        )
        if ok then
            removed = removed + (tonumber(hints) or 0)
            cancelled = cancelled + (tonumber(jobs) or 0)
        end
    end

    return removed, cancelled
end

local function scheduleIdleMaintenance(reason, initialDelay)
    maintenance_reason = reason or maintenance_reason or "transition"
    if maintenance_scheduled then return end
    maintenance_scheduled = true

    local phase = 1
    local function step()
        local reader = activeReaderDocuments()
        if readerHasBlockingWork(reader) then
            UIManager:scheduleIn(MAINTENANCE_RECHECK_SECONDS, step)
            return
        end

        local idleMs = time.to_ms(time.since(last_input_time))
        local idleNeededMs = MAINTENANCE_IDLE_SECONDS * 1000
        if idleMs < idleNeededMs then
            local wait = math.max(
                MAINTENANCE_RECHECK_SECONDS,
                (idleNeededMs - idleMs) / 1000
            )
            UIManager:scheduleIn(wait, step)
            return
        end

        local removed, cancelled = pruneRuntimeState()
        local luaBefore = collectgarbage("count")
        local rssBefore = readRssKb()

        -- KOReader normally performs two full collections at document open.
        -- Burrow still keeps only the first on the critical Kindle open path,
        -- but performs the missing work here after the device has genuinely
        -- been idle. Split the two maintenance passes so a new touch can defer
        -- the second one instead of trapping the reader behind a long pause.
        pcall(collectgarbage)

        local luaAfter = collectgarbage("count")
        local rssAfter = readRssKb()
        logger.dbg(
            "[Burrow performance] Kindle idle maintenance",
            maintenance_reason,
            "pass",
            phase,
            "lua_kb",
            math.floor(luaBefore),
            "->",
            math.floor(luaAfter),
            "rss_kb",
            rssBefore or -1,
            "->",
            rssAfter or -1,
            "runtime_entries",
            removed,
            "cancelled_jobs",
            cancelled
        )

        if phase == 1 then
            phase = 2
            UIManager:scheduleIn(MAINTENANCE_SECOND_PASS_DELAY, step)
            return
        end

        maintenance_scheduled = false
        maintenance_reason = nil
    end

    UIManager:scheduleIn(initialDelay or MAINTENANCE_IDLE_SECONDS, step)
end

local function replaceUpvalue(fn, wanted, replacement)
    if type(fn) ~= "function" then return false end
    for index = 1, 100 do
        local name = debug.getupvalue(fn, index)
        if not name then break end
        if name == wanted then
            debug.setupvalue(fn, index, replacement)
            return true
        end
    end
    return false
end

local function disableGeneralKindleWarmups()
    local ok, transition = pcall(require, "burrow_transition_performance")
    if not ok or type(transition) ~= "table" or type(transition.apply) ~= "function" then
        return false, "General transition module unavailable"
    end

    -- beta.3's larger disk-cache default and synchronous CRengine warmup helped
    -- Android, but both add avoidable storage/CPU pressure on slower Kindles.
    -- Patch only these two local helpers before main.lua invokes apply().
    local disabled_cache = replaceUpvalue(
        transition.apply,
        "installReopenCacheDefault",
        function() end
    )
    local disabled_warmup = replaceUpvalue(
        transition.apply,
        "scheduleEngineWarmup",
        function() end
    )

    if not disabled_cache or not disabled_warmup then
        return false, "Could not isolate Kindle from general warmup helpers"
    end
    return true
end

local function installOnePassDocumentGc()
    local ok, DocumentRegistry = pcall(require, "document/documentregistry")
    if not ok or type(DocumentRegistry) ~= "table" then
        return false, "DocumentRegistry unavailable"
    end
    if DocumentRegistry._burrow_kindle_one_pass_gc_v1 then return true end

    local originalOpenDocument = DocumentRegistry.openDocument
    if type(originalOpenDocument) ~= "function" then
        return false, "DocumentRegistry openDocument unavailable"
    end

    function DocumentRegistry:openDocument(file, provider)
        local selected = provider
        if selected == nil and type(self.getProvider) == "function" then
            selected = self:getProvider(file)
        end

        -- Keep PDFs, comics and other fixed-layout providers entirely native.
        if type(selected) ~= "table" or selected.provider ~= "crengine" then
            return originalOpenDocument(self, file, provider)
        end

        -- KOReader intentionally runs two consecutive full Lua collections at
        -- each document open. Keep the first for memory safety, but suppress the
        -- immediately-following second pass on Kindle. Restore the global before
        -- the document provider begins doing real work.
        local originalCollect = _G.collectgarbage
        local noargCalls = 0
        local shim
        shim = function(option, arg)
            if option == nil then
                noargCalls = noargCalls + 1
                if noargCalls == 1 then
                    return originalCollect()
                elseif noargCalls == 2 then
                    _G.collectgarbage = originalCollect
                    return 0
                end
            end
            return originalCollect(option, arg)
        end

        _G.collectgarbage = shim
        local results = pack(pcall(originalOpenDocument, self, file, provider))
        if _G.collectgarbage == shim then
            _G.collectgarbage = originalCollect
        end
        if results[1] then
            scheduleIdleMaintenance("document open")
        end
        return stripPcallStatus(results)
    end

    DocumentRegistry._burrow_kindle_one_pass_gc_v1 = true
    return true
end

local function withoutDocCacheSerialize(callback)
    local ok, DocCache = pcall(require, "document/doccache")
    if not ok or type(DocCache) ~= "table" or type(DocCache.serialize) ~= "function" then
        return callback()
    end

    local originalSerialize = DocCache.serialize
    DocCache.serialize = function() return end
    local results = pack(pcall(callback))
    DocCache.serialize = originalSerialize
    return stripPcallStatus(results)
end

local function isBurrowOrnamentDocument(document)
    return type(document) == "table"
        and type(document._burrow_epub_ornaments_source_file) == "string"
end

local function installReaderTransitions()
    local ok, ReaderUI = pcall(require, "apps/reader/readerui")
    if not ok or type(ReaderUI) ~= "table" then
        return false, "ReaderUI unavailable"
    end
    if ReaderUI._burrow_kindle_transition_v1 then return true end

    local originalReloadDocument = ReaderUI.reloadDocument
    local originalOnHome = ReaderUI.onHome
    if type(originalReloadDocument) ~= "function" or type(originalOnHome) ~= "function" then
        return false, "Reader transition methods unavailable"
    end

    local function hasRunningRerender(reader)
        local rolling = reader and reader.rolling
        return type(rolling) == "table"
            and rolling._current_rerendering_pid ~= nil
    end

    local function scheduleReloadRetry(reader)
        if reader._burrow_kindle_reload_retry_scheduled then return end
        reader._burrow_kindle_reload_retry_scheduled = true

        UIManager:scheduleIn(RERENDER_RETRY, function()
            reader._burrow_kindle_reload_retry_scheduled = nil

            if ReaderUI.instance ~= reader
                or reader.tearing_down
                or not reader.document
            then
                reader._burrow_kindle_reload_pending = nil
                return
            end

            if hasRunningRerender(reader) then
                scheduleReloadRetry(reader)
                return
            end

            local pending = reader._burrow_kindle_reload_pending
            reader._burrow_kindle_reload_pending = nil
            if pending then
                reader._burrow_kindle_reload_ready = true
                reader:reloadDocument(unpackPacked(pending))
            end
        end)
    end

    function ReaderUI:reloadDocument(...)
        local arguments = pack(...)
        local ornament_reload = isBurrowOrnamentDocument(self.document)

        -- ReaderRolling can already have a large CRengine rerender subprocess.
        -- KOReader's close lifecycle waits for that child. Coalesce Burrow's
        -- ornament reload until the child is gone rather than blocking the UI.
        if ornament_reload
            and not self._burrow_kindle_reload_ready
            and hasRunningRerender(self)
        then
            self._burrow_kindle_reload_pending = arguments
            scheduleReloadRetry(self)
            logger.dbg("[Burrow performance] Deferred Kindle reload behind active CRengine rerender")
            return true
        end

        self._burrow_kindle_reload_ready = nil

        local results
        if ornament_reload then
            -- This transition immediately reopens the same book and position.
            -- Saving KOReader's current-page bitmap before tearing down adds a
            -- synchronous Kindle disk write without helping the new ReaderUI.
            results = pack(pcall(
                withoutDocCacheSerialize,
                function()
                    return originalReloadDocument(
                        self,
                        unpackPacked(arguments)
                    )
                end
            ))
        else
            results = pack(pcall(
                originalReloadDocument,
                self,
                unpackPacked(arguments)
            ))
        end

        if results[1] then
            scheduleIdleMaintenance(
                ornament_reload and "ornament reload" or "document reload"
            )
        end
        return stripPcallStatus(results)
    end

    local function deferHomeSerialization(docPath, serializer, docCache)
        local attempts = 0
        local lastInput = UIManager:getTime()
        local watcher = function()
            lastInput = UIManager:getTime()
        end
        UIManager.event_hook:register("InputEvent", watcher)

        local function finish()
            UIManager.event_hook:unregister("InputEvent", watcher)
        end

        local function trySerialize()
            attempts = attempts + 1

            -- If another book is already open, do not make its first seconds
            -- compete with a stale page-bitmap write from the previous book.
            if ReaderUI.instance then
                finish()
                return
            end

            local idleFor = UIManager:getTime() - lastInput
            if idleFor < time.s(LIBRARY_IDLE_DELAY) then
                if attempts < LIBRARY_IDLE_RETRIES then
                    UIManager:scheduleIn(1.0, trySerialize)
                else
                    finish()
                end
                return
            end

            finish()
            local okWrite, err = pcall(serializer, docCache, docPath)
            if not okWrite then
                logger.warn("[Burrow performance] Deferred Kindle page-cache save failed", err)
            end
        end

        UIManager:scheduleIn(LIBRARY_IDLE_DELAY, trySerialize)
    end

    function ReaderUI:onHome(...)
        local document = self.document
        if not document or document.provider ~= "crengine" then
            return originalOnHome(self, ...)
        end

        local okCache, DocCache = pcall(require, "document/doccache")
        if not okCache or type(DocCache) ~= "table" or type(DocCache.serialize) ~= "function" then
            return originalOnHome(self, ...)
        end

        local originalSerialize = DocCache.serialize
        local deferredPath
        DocCache.serialize = function(_, path)
            deferredPath = path
        end

        local results = pack(pcall(originalOnHome, self, ...))
        DocCache.serialize = originalSerialize

        if deferredPath then
            deferHomeSerialization(deferredPath, originalSerialize, DocCache)
        end
        if results[1] then
            scheduleIdleMaintenance("reader home")
        end

        return stripPcallStatus(results)
    end

    ReaderUI._burrow_kindle_transition_v1 = true
    return true
end

function Module.attachPluginClass(plugin_class)
    if not Device:isKindle() then return true end
    if type(plugin_class) ~= "table" then
        return false, "Burrow plugin class unavailable"
    end
    if plugin_class._burrow_kindle_idle_maintenance_v1 then return true end
    plugin_class._burrow_kindle_idle_maintenance_v1 = true

    local originalResume = plugin_class.onResume
    function plugin_class:onResume(...)
        markInputActivity()
        local result
        if originalResume then
            result = originalResume(self, ...)
        end
        scheduleIdleMaintenance("resume")
        return result
    end

    local originalReaderReady = plugin_class.onReaderReady
    function plugin_class:onReaderReady(...)
        markInputActivity()
        local result
        if originalReaderReady then
            result = originalReaderReady(self, ...)
        end
        scheduleIdleMaintenance("reader ready")
        return result
    end

    return true
end

function Module.apply()
    if Module.applied then return true end
    if not Device:isKindle() then
        Module.applied = true
        return true
    end

    if not input_watcher then
        input_watcher = markInputActivity
        UIManager.event_hook:register("InputEvent", input_watcher)
    end

    local warmupOk, warmupErr = disableGeneralKindleWarmups()
    if not warmupOk then
        logger.warn("[Burrow performance] Kindle warmup isolation unavailable", warmupErr)
    end

    local gcOk, gcErr = installOnePassDocumentGc()
    if not gcOk then
        logger.warn("[Burrow performance] Kindle document-open GC optimization unavailable", gcErr)
    end

    local readerOk, readerErr = installReaderTransitions()
    if not readerOk then
        logger.warn("[Burrow performance] Kindle reader transition optimization unavailable", readerErr)
    end

    Module.applied = true
    return true
end

return Module

local Device = require("device")
local logger = require("logger")
local time = require("ui/time")
local UIManager = require("ui/uimanager")

local Module = {}

local RERENDER_RETRY = 0.35
local LIBRARY_IDLE_DELAY = 2.0
local LIBRARY_IDLE_RETRIES = 5

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

        if ornament_reload then
            -- This transition immediately reopens the same book and position.
            -- Saving KOReader's current-page bitmap before tearing down adds a
            -- synchronous Kindle disk write without helping the new ReaderUI.
            return withoutDocCacheSerialize(function()
                return originalReloadDocument(self, unpackPacked(arguments))
            end)
        end

        return originalReloadDocument(self, unpackPacked(arguments))
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

        return stripPcallStatus(results)
    end

    ReaderUI._burrow_kindle_transition_v1 = true
    return true
end

function Module.apply()
    if Module.applied then return true end
    if not Device:isKindle() then
        Module.applied = true
        return true
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

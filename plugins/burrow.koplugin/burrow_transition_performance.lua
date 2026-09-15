local logger = require("logger")
local time = require("ui/time")
local UIManager = require("ui/uimanager")

local Module = {}

local DEFAULT_REOPEN_CACHE_MB = 128
local ENGINE_WARM_DELAY = 1.5
local INTERACTION_WINDOW_MS = 1400
local FULL_BUSY_TICKS = 8
local FULL_IDLE_TICKS = 3
local PROFILE_BUSY_TICKS = 4
local PROFILE_IDLE_TICKS = 2

local last_reader_activity = time.now()
local SCHEDULER_WRAPPERS = {}

local function markReaderActivity()
    last_reader_activity = time.now()
end

local function readerWasRecentlyActive()
    return time.to_ms(time.since(last_reader_activity)) < INTERACTION_WINDOW_MS
end

local function getUpvalueIndex(fn, wanted)
    if type(fn) ~= "function" then return nil, nil end
    for index = 1, 100 do
        local name, value = debug.getupvalue(fn, index)
        if not name then break end
        if name == wanted then return index, value end
    end
    return nil, nil
end

local function setNamedUpvalue(fn, wanted, value)
    local index = getUpvalueIndex(fn, wanted)
    if not index then return false end
    debug.setupvalue(fn, index, value)
    return true
end

local function activeReader()
    local ok, ReaderUI = pcall(require, "apps/reader/readerui")
    if not ok or type(ReaderUI) ~= "table" then return nil end
    local reader = ReaderUI.instance
    if type(reader) ~= "table" or reader.tearing_down then return nil end
    return reader
end

local function installReopenCacheDefault()
    if G_reader_settings:readSetting("cre_disk_cache_max_size") == nil then
        G_reader_settings:saveSetting("cre_disk_cache_max_size", DEFAULT_REOPEN_CACHE_MB)
        logger.info(
            "[Burrow performance] Using larger CRengine reopen cache",
            DEFAULT_REOPEN_CACHE_MB,
            "MB"
        )
    end
end

local function scheduleEngineWarmup()
    local attempts = 0

    local function tryWarm()
        attempts = attempts + 1

        -- If a reader is already active, CRengine either initialized naturally
        -- for a reflowable document or is not currently needed.
        if activeReader() then return end

        local ok_fm, FileManager = pcall(require, "apps/filemanager/filemanager")
        if not ok_fm or type(FileManager) ~= "table" or not FileManager.instance then
            if attempts < 8 then UIManager:scheduleIn(0.75, tryWarm) end
            return
        end

        -- Do not compete with Burrow's first library metadata/cover extraction.
        local ok_info, BookInfoManager = pcall(require, "bookinfomanager")
        if ok_info
            and type(BookInfoManager) == "table"
            and type(BookInfoManager.isExtractingInBackground) == "function"
        then
            local ok_extracting, extracting = pcall(
                BookInfoManager.isExtractingInBackground,
                BookInfoManager
            )
            if ok_extracting and extracting and attempts < 8 then
                UIManager:scheduleIn(0.75, tryWarm)
                return
            end
        end

        local ok_cre, CreDocument = pcall(require, "document/credocument")
        if not ok_cre
            or type(CreDocument) ~= "table"
            or type(CreDocument.engineInit) ~= "function"
        then
            logger.warn("[Burrow performance] CRengine warmup unavailable", CreDocument)
            return
        end

        local ok_warm, err = pcall(CreDocument.engineInit, CreDocument)
        if not ok_warm then
            logger.warn("[Burrow performance] CRengine warmup failed", err)
            return
        end
        logger.dbg("[Burrow performance] CRengine initialized while library was idle")
    end

    UIManager:scheduleIn(ENGINE_WARM_DELAY, tryWarm)
end

local function isHotCacheJob(key)
    return tostring(key or ""):find("-hot-", 1, true) ~= nil
end

local function isProfileJob(key)
    local text = tostring(key or "")
    return text:sub(-8) == ".profile"
end

local function makeThrottledCoroutine(co, key)
    local profile_job = isProfileJob(key)

    return coroutine.create(function()
        local first = true
        while true do
            -- Let every job make one immediate cooperative step. After that,
            -- distant/full-book work yields much more often than the nearby hot
            -- window, especially for roughly 1.4 seconds after reader activity.
            if not first then
                local ticks
                if profile_job then
                    ticks = readerWasRecentlyActive()
                        and PROFILE_BUSY_TICKS
                        or PROFILE_IDLE_TICKS
                else
                    ticks = readerWasRecentlyActive()
                        and FULL_BUSY_TICKS
                        or FULL_IDLE_TICKS
                end
                for _ = 1, ticks do coroutine.yield() end
            end
            first = false

            local values = { coroutine.resume(co) }
            local ok = table.remove(values, 1)
            if not ok then error(values[1]) end

            if coroutine.status(co) == "dead" then
                return unpack(values)
            end
            coroutine.yield()
        end
    end)
end

local function schedulerWrapper(original)
    local existing = SCHEDULER_WRAPPERS[original]
    if existing then return existing end

    local wrapped = function(job_table, key, co, callback)
        -- Current/nearby spine work remains at the existing high priority.
        if isHotCacheJob(key) then
            return original(job_table, key, co, callback)
        end
        return original(
            job_table,
            key,
            makeThrottledCoroutine(co, key),
            callback
        )
    end

    -- scheduleCoroutine is a shared upvalue in the ornament module. Mark both
    -- directions so later closures that see the already-wrapped value do not
    -- wrap it a second or third time.
    SCHEDULER_WRAPPERS[original] = wrapped
    SCHEDULER_WRAPPERS[wrapped] = wrapped
    return wrapped
end

local function patchSchedulerTree(fn, seen, depth)
    if type(fn) ~= "function" then return 0 end
    seen = seen or {}
    depth = depth or 0
    if seen[fn] or depth > 6 then return 0 end
    seen[fn] = true

    local changed = 0
    for index = 1, 100 do
        local name, value = debug.getupvalue(fn, index)
        if not name then break end

        if name == "scheduleCoroutine" and type(value) == "function" then
            debug.setupvalue(fn, index, schedulerWrapper(value))
            changed = changed + 1
        elseif type(value) == "function" then
            changed = changed + patchSchedulerTree(value, seen, depth + 1)
        end
    end
    return changed
end

local function installOrnamentThrottle()
    local ok, Epub = pcall(require, "burrow_soft_palette_epub")
    if not ok or type(Epub) ~= "table" then
        return false, "Decorative EPUB cache module unavailable"
    end
    if Epub._burrow_transition_throttle_v1 then return true end

    local changed = 0
    local seen = {}
    for _, fn in ipairs({
        Epub.inspectAsync,
        Epub.ensureCacheAsync,
        Epub.ensureHotCacheAsync,
    }) do
        changed = changed + patchSchedulerTree(fn, seen, 0)
    end

    if changed == 0 then
        return false, "Could not locate the cooperative ornament scheduler"
    end

    Epub._burrow_transition_throttle_v1 = true
    logger.dbg("[Burrow performance] Throttled distant ornament background work")
    return true
end

local function scheduleDeferredGc()
    local remaining = 2
    local postpones = 0

    local function step()
        -- Never put a deliberate GC pause directly after a page turn or mode
        -- switch. Natural Lua GC remains enabled; these are only small cleanup
        -- nudges replacing CoverMenu's old double full collection.
        if readerWasRecentlyActive() and postpones < 8 then
            postpones = postpones + 1
            UIManager:scheduleIn(0.75, step)
            return
        end

        pcall(collectgarbage, "step", 160)
        remaining = remaining - 1
        if remaining > 0 then
            UIManager:scheduleIn(1.5, step)
        end
    end

    UIManager:scheduleIn(2.5, step)
end

local function installCoverMenuClosePatch()
    local ok_cover, CoverMenu = pcall(require, "covermenu")
    if not ok_cover or type(CoverMenu) ~= "table" then
        return false, "Burrow CoverMenu unavailable"
    end
    if CoverMenu._burrow_transition_close_v1 then return true end

    local oldClose = CoverMenu.onCloseWidget
    if type(oldClose) ~= "function" then
        return false, "Burrow CoverMenu close handler unavailable"
    end

    local Menu = require("ui/widget/menu")
    local BookInfoManager = require("bookinfomanager")
    local burrow_debug = require("burrow_debug")

    local function fastClose(self)
        -- Mirror Burrow's established close lifecycle exactly, except replace
        -- the scheduled double full collectgarbage() with deferred small steps.
        if self._covermenu_onclose_done then return end
        self._covermenu_onclose_done = true

        logger.dbg(burrow_debug.logprefix, "CoverMenu:onCloseWidget: terminating jobs if needed")
        BookInfoManager:terminateBackgroundJobs()
        BookInfoManager:closeDbConnection()
        BookInfoManager:cleanUp()
        setNamedUpvalue(oldClose, "is_pathchooser", false)

        if self.items_update_action then
            logger.dbg(burrow_debug.logprefix, "CoverMenu:onCloseWidget: unscheduling items_update_action")
            UIManager:unschedule(self.items_update_action)
            self.items_update_action = nil
        end

        if self.item_group then self.item_group:free() end
        self.cover_info_cache = nil

        setNamedUpvalue(oldClose, "nb_drawings_since_last_collectgarbage", 0)
        scheduleDeferredGc()

        Menu.onCloseWidget(self)
    end

    CoverMenu.onCloseWidget = fastClose
    CoverMenu._burrow_transition_close_v1 = true

    -- burrow_library assigns the CoverMenu close function directly onto the
    -- FileChooser class during core initialization, so update that exact copy.
    local ok_fc, FileChooser = pcall(require, "ui/widget/filechooser")
    if ok_fc and type(FileChooser) == "table" and FileChooser.onCloseWidget == oldClose then
        FileChooser.onCloseWidget = fastClose
    end

    return true
end

local function attachActivityHooks(plugin_class)
    if type(plugin_class) ~= "table" then
        return false, "Burrow plugin class unavailable"
    end
    if plugin_class._burrow_transition_activity_v1 then return true end
    plugin_class._burrow_transition_activity_v1 = true

    local function wrap(name)
        local original = plugin_class[name]
        plugin_class[name] = function(self, ...)
            markReaderActivity()
            if original then return original(self, ...) end
        end
    end

    wrap("onReaderReady")
    wrap("onPageUpdate")
    wrap("onPosUpdate")
    wrap("onToggleNightMode")
    wrap("onSetNightMode")
    return true
end

function Module.apply(plugin_class)
    if Module.applied then return true end

    installReopenCacheDefault()

    local throttle_ok, throttle_err = installOrnamentThrottle()
    if not throttle_ok then
        logger.warn("[Burrow performance] Ornament throttle unavailable", throttle_err)
    end

    local close_ok, close_err = installCoverMenuClosePatch()
    if not close_ok then
        logger.warn("[Burrow performance] Library close optimization unavailable", close_err)
    end

    local hook_ok, hook_err = attachActivityHooks(plugin_class)
    if not hook_ok then
        logger.warn("[Burrow performance] Reader activity hook unavailable", hook_err)
    end

    scheduleEngineWarmup()
    Module.applied = true
    return true
end

return Module

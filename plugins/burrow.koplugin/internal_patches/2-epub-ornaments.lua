local MODULE_KEY = "burrow.internal.2_epub_ornaments"
local existing_module = package.loaded[MODULE_KEY]
if existing_module then return existing_module end

local Module = {
    key = MODULE_KEY,
    phase = "early",
    filename = "2-epub-ornaments.lua",
}
package.loaded[MODULE_KEY] = Module

local ORNAMENT_SETTING = "burrow_soft_palette_recolor_ornaments"

local function isEpub(path)
    return type(path) == "string" and path:lower():match("%.epub$") ~= nil
end

local function hasUserReaderPalette()
    return G_reader_settings:has("cre_background_color")
        or G_reader_settings:has("cre_background_image")
end

local function softPaletteActive(Blitbuffer)
    return tonumber(Blitbuffer.COLOR_WHITE.a) == 0xF2
        and tonumber(Blitbuffer.COLOR_BLACK.a) == 0x20
end

local function desiredTone(document, Screen)
    if Screen.night_mode and document._nightmode_images ~= false then
        return "night"
    end
    return "light"
end

local function paletteName(Blitbuffer, tone)
    return (softPaletteActive(Blitbuffer) and "soft-" or "pure-") .. tone
end

local function currentFingerprint(document)
    local parts = {}
    if type(document) ~= "table" then return "" end
    if type(document.getCurrentPage) == "function" then
        local ok, page = pcall(document.getCurrentPage, document)
        if ok then parts[#parts + 1] = tostring(page) end
    end
    if type(document.getCurrentPos) == "function" then
        local ok, pos = pcall(document.getCurrentPos, document)
        if ok then parts[#parts + 1] = tostring(pos) end
    end
    return table.concat(parts, ":")
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
    if type(meta) ~= "table" then return true end
    local total = tonumber(meta.total_spine) or 0
    local center = tonumber(meta.center) or 0
    local radius = math.max(1, tonumber(meta.radius) or 1)
    if total <= 0 or center <= 0 then return true end

    local current = math.floor(currentProgress(document) * total) + 1
    if current > total then current = total end
    if current < 1 then current = 1 end
    return math.abs(current - center) <= radius
end

function Module.desiredTone(document)
    if type(document) ~= "table" then return nil end
    if document._burrow_epub_ornaments_fast_adaptive == true then
        return "adaptive"
    end
    return desiredTone(document, require("device").screen)
end

local function syncKindleNightMode(logger)
    local sync = package.loaded["burrow.internal.2_kindle_night_sync"]
    if type(sync) ~= "table" or type(sync.sync) ~= "function" then
        return true
    end

    local call_ok, synced, sync_error = pcall(sync.sync)
    if not call_ok or synced == false then
        logger.warn(
            "[Burrow ornaments] Kindle Night Mode synchronization failed",
            call_ok and sync_error or synced
        )
        return false
    end
    return true
end

function Module.apply()
    if Module.applied then return true end

    local Blitbuffer = require("ffi/blitbuffer")
    local CreDocument = require("document/credocument")
    local OrnamentEpub = require("burrow_soft_palette_epub")
    local Screen = require("device").screen
    local UIManager = require("ui/uimanager")
    local logger = require("logger")

    local function prepareCachesInBackground(document, originalFile, profile)
        if type(document) ~= "table" or not isEpub(originalFile) then return end

        local function start(profileValue)
            if type(profileValue) ~= "table" then return end
            document._burrow_epub_ornaments_profile = profileValue
            document._burrow_epub_ornaments_source_file = originalFile
            document._burrow_epub_ornaments_fast_adaptive_candidate =
                profileValue.all_eligible == true and document._nightmode_images ~= false

            if tonumber(profileValue.eligible_count) == 0 then
                document._burrow_epub_ornaments_no_eligible = true
                return
            end

            local fast = document._burrow_epub_ornaments_fast_adaptive_candidate == true
            local firstTone = fast and "light" or desiredTone(document, Screen)
            local firstPalette = paletteName(Blitbuffer, firstTone)

            OrnamentEpub.ensureCacheAsync(
                originalFile,
                firstPalette,
                profileValue,
                function(shadow, err)
                    if err then
                        logger.warn("[Burrow ornaments] Background cache preparation failed", err)
                        return
                    end
                    if not shadow then return end
                    document._burrow_epub_ornaments_prepared_palette = firstPalette

                    -- Mixed-image books need separate explicit light/night caches.
                    -- Prepare the alternate tone only after the current tone is done
                    -- so background work stays gentle while the user is reading.
                    if not fast then
                        local secondTone = firstTone == "night" and "light" or "night"
                        OrnamentEpub.ensureCacheAsync(
                            originalFile,
                            paletteName(Blitbuffer, secondTone),
                            profileValue,
                            function(_, secondErr)
                                if secondErr then
                                    logger.warn(
                                        "[Burrow ornaments] Alternate background cache failed",
                                        secondErr
                                    )
                                end
                            end
                        )
                    end
                end
            )
        end

        if profile then
            start(profile)
        else
            OrnamentEpub.inspectAsync(originalFile, function(asyncProfile, err)
                if err then
                    logger.warn("[Burrow ornaments] Background preflight failed", err)
                    return
                end
                start(asyncProfile)
            end)
        end
    end

    -- Opening a book must never wait for first-time ornament analysis or cache
    -- generation. Use a completed cache when one already exists; otherwise open
    -- the original EPUB immediately and prepare the cache cooperatively after the
    -- reader has become interactive.
    if not CreDocument._burrow_epub_ornament_loader_v7 then
        CreDocument._burrow_epub_ornament_loader_v7 = true
        local originalLoadDocument = CreDocument.loadDocument

        function CreDocument:loadDocument(fullDocument)
            if self._loaded
                or fullDocument == false
                or (self._burrow_epub_ornament_reader_context ~= true
                    and self._burrow_bionic_reader_context ~= true)
                or not G_reader_settings:isTrue(ORNAMENT_SETTING)
                or hasUserReaderPalette()
                or not isEpub(self.file)
            then
                return originalLoadDocument(self, fullDocument)
            end

            local originalFile = self.file
            self._burrow_epub_ornaments_source_file = originalFile

            local profile = OrnamentEpub.peekProfile(originalFile)
            if profile and tonumber(profile.eligible_count) == 0 then
                self._burrow_epub_ornaments_profile = profile
                self._burrow_epub_ornaments_no_eligible = true
                return originalLoadDocument(self, fullDocument)
            end

            local fast_adaptive = profile
                and profile.all_eligible == true
                and self._nightmode_images ~= false
            local tone = fast_adaptive and "light" or desiredTone(self, Screen)
            local palette = paletteName(Blitbuffer, tone)
            local shadow, shadowErr, normalized
            local hot_used = false
            local hot_meta

            if palette then
                shadow, shadowErr, normalized = OrnamentEpub.cachedResult(
                    originalFile,
                    palette
                )
                if shadowErr then
                    logger.warn("[Burrow ornaments] Could not inspect completed cache", shadowErr)
                end

                if shadow == nil then
                    local preferred, preferredCount, preferredMeta =
                        OrnamentEpub.preferredCache(originalFile, palette)
                    if preferred then
                        shadow = preferred
                        normalized = preferredCount
                        hot_meta = preferredMeta
                        hot_used = true
                    end
                end

                -- A hot cache may have been built before the full profile proved
                -- that every image is adaptive-safe. If that happened, prefer the
                -- already-prepared explicit current-tone cache for this reload
                -- instead of discarding nearby work and reopening the original.
                if shadow == nil and fast_adaptive then
                    local explicitTone = desiredTone(self, Screen)
                    local explicitPalette = paletteName(Blitbuffer, explicitTone)
                    local preferred, preferredCount, preferredMeta =
                        OrnamentEpub.preferredCache(originalFile, explicitPalette)
                    if preferred then
                        fast_adaptive = false
                        tone = explicitTone
                        palette = explicitPalette
                        shadow = preferred
                        normalized = preferredCount
                        hot_meta = preferredMeta
                        hot_used = true
                    end
                end
            end

            if shadow then
                self.file = shadow
                local ok, result = pcall(originalLoadDocument, self, fullDocument)
                self.file = originalFile
                if not ok then error(result) end

                if result then
                    self._burrow_epub_ornaments_active = true
                    self._burrow_epub_ornaments_image_count = tonumber(normalized) or 0
                    self._burrow_epub_ornaments_shadow_file = shadow
                    self._burrow_epub_ornaments_palette = palette
                    self._burrow_epub_ornaments_fast_adaptive = fast_adaptive == true
                    self._burrow_epub_ornaments_fast_adaptive_candidate = fast_adaptive == true
                    self._burrow_epub_ornaments_tone = fast_adaptive and "adaptive" or tone
                    self._burrow_epub_ornaments_profile = profile
                    self._burrow_epub_ornaments_hot = hot_used
                    self._burrow_epub_ornaments_hot_meta = hot_meta
                    logger.info(
                        hot_used
                            and "[Burrow ornaments] Loaded nearby spine-priority ornament EPUB"
                            or (fast_adaptive
                                and "[Burrow ornaments] Loaded cooperative adaptive ornament EPUB"
                                or "[Burrow ornaments] Loaded cooperative explicit ornament EPUB"),
                        palette,
                        self._burrow_epub_ornaments_image_count
                    )
                end
                return result
            end

            -- Missing profile/cache: open the original now. Background work begins
            -- only after this call returns and yields back to KOReader's event loop.
            local result = originalLoadDocument(self, fullDocument)
            if result then
                self._burrow_epub_ornaments_active = false
                self._burrow_epub_ornaments_profile = profile
                self._burrow_epub_ornaments_fast_adaptive_candidate = fast_adaptive == true
                -- ReaderReady will start a spine-priority nearby cache first.
                -- Full-book analysis begins only after that hot window is ready,
                -- so background work cannot outrun the pages the user is reading.
                self._burrow_epub_ornaments_needs_background = true
            end
            return result
        end
    end

    -- Once a book has been loaded from the single adaptive cache, Night Mode can
    -- switch with a normal page repaint. No EPUB swap or ReaderUI reload is needed.
    if not CreDocument._burrow_epub_ornament_draw_v7 then
        CreDocument._burrow_epub_ornament_draw_v7 = true
        local originalDrawCurrentView = CreDocument.drawCurrentView

        function CreDocument:drawCurrentView(...)
            if self._burrow_epub_ornaments_fast_adaptive ~= true
                or not Screen.night_mode
                or self._nightmode_images == false
            then
                return originalDrawCurrentView(self, ...)
            end

            local currentPage
            if type(self.getCurrentPage) == "function" then
                local ok_page, page = pcall(self.getCurrentPage, self)
                if ok_page then currentPage = tonumber(page) end
            end
            if currentPage and currentPage <= 1 then
                return originalDrawCurrentView(self, ...)
            end

            local originalNightmodeImages = self._nightmode_images
            self._nightmode_images = false
            local results = { pcall(originalDrawCurrentView, self, ...) }
            self._nightmode_images = originalNightmodeImages

            local ok = table.remove(results, 1)
            if not ok then error(results[1]) end
            return unpack(results)
        end
    end

    Module.applied = true
    return true
end

function Module.attachPluginClass(plugin_class)
    if type(plugin_class) ~= "table" then
        return false, "Burrow plugin class is unavailable"
    end
    if plugin_class._burrow_epub_ornament_post_night_v4 then return true end
    plugin_class._burrow_epub_ornament_post_night_v4 = true

    local Blitbuffer = require("ffi/blitbuffer")
    local UIManager = require("ui/uimanager")
    local Screen = require("device").screen
    local OrnamentEpub = require("burrow_soft_palette_epub")
    local logger = require("logger")
    local update_pending = false
    local update_token = 0
    local HOT_RADIUS = 3

    local function scheduleIdleReload(plugin, token, wantedTone)
        local stable_ticks = 0
        local last_fingerprint

        local function checkIdle()
            if token ~= update_token then return end
            local reader = plugin and plugin.ui or nil
            local document = reader and reader.document or nil
            if not document or reader.tearing_down then return end
            if desiredTone(document, Screen) ~= wantedTone then return end

            local fingerprint = currentFingerprint(document)
            if last_fingerprint ~= nil and fingerprint ~= last_fingerprint then
                stable_ticks = 0
            else
                stable_ticks = stable_ticks + 1
            end
            last_fingerprint = fingerprint

            -- Reading always wins. Keep postponing the cache swap while the user
            -- is moving through the book; only reload after a short stable pause.
            if stable_ticks < 2 then
                UIManager:scheduleIn(0.55, checkIdle)
                return
            end

            if type(reader.reloadDocument) ~= "function" then return end
            local ok_reload, reload_error = pcall(reader.reloadDocument, reader, nil, true)
            if not ok_reload then
                logger.warn("[Burrow ornaments] Could not apply nearby ornament palette", reload_error)
                return
            end
            UIManager:nextTick(function()
                syncKindleNightMode(logger)
            end)
        end

        UIManager:scheduleIn(0.55, checkIdle)
    end

    local function startFullBackground(document, originalFile, wantedTone, knownProfile)
        if not document or not isEpub(originalFile) then return end

        local function withProfile(profile)
            if type(profile) ~= "table" then return end
            document._burrow_epub_ornaments_profile = profile
            if tonumber(profile.eligible_count) == 0 then return end

            local fast = profile.all_eligible == true
                and document._nightmode_images ~= false
            document._burrow_epub_ornaments_fast_adaptive_candidate = fast
            local firstTone = fast and "light" or wantedTone
            local firstPalette = paletteName(Blitbuffer, firstTone)

            OrnamentEpub.ensureCacheAsync(
                originalFile,
                firstPalette,
                profile,
                function(_, firstErr)
                    if firstErr then
                        logger.warn("[Burrow ornaments] Full background cache failed", firstErr)
                        return
                    end

                    -- For mixed-image books, quietly prepare the opposite tone
                    -- after the current tone is complete. Never reload just because
                    -- this distant/background work finished.
                    if not fast then
                        local secondTone = firstTone == "night" and "light" or "night"
                        OrnamentEpub.ensureCacheAsync(
                            originalFile,
                            paletteName(Blitbuffer, secondTone),
                            profile,
                            function(_, secondErr)
                                if secondErr then
                                    logger.warn(
                                        "[Burrow ornaments] Alternate full background cache failed",
                                        secondErr
                                    )
                                end
                            end
                        )
                    end
                end
            )
        end

        local profile = knownProfile
            or document._burrow_epub_ornaments_profile
            or OrnamentEpub.peekProfile(originalFile)
        if profile then
            withProfile(profile)
        else
            OrnamentEpub.inspectAsync(originalFile, function(asyncProfile, err)
                if err then
                    logger.warn("[Burrow ornaments] Deferred full-book preflight failed", err)
                    return
                end
                withProfile(asyncProfile)
            end)
        end
    end

    local function prepareNearbyFirst(plugin, document, token, wantedTone)
        local originalFile = document._burrow_epub_ornaments_source_file or document.file
        if not isEpub(originalFile) then return end

        local profile = document._burrow_epub_ornaments_profile
            or OrnamentEpub.peekProfile(originalFile)
        if profile then
            document._burrow_epub_ornaments_profile = profile
            if tonumber(profile.eligible_count) == 0 then return end
        end

        local fast = profile
            and profile.all_eligible == true
            and document._nightmode_images ~= false
        local toneForFull = fast and "light" or wantedTone
        local fullPalette = paletteName(Blitbuffer, toneForFull)
        local cached, cacheErr, cachedCount = OrnamentEpub.cachedResult(
            originalFile,
            fullPalette
        )
        if cacheErr then
            logger.warn("[Burrow ornaments] Full cache lookup failed", cacheErr)
        elseif cached then
            OrnamentEpub.setPreferredCache(originalFile, fullPalette, nil)
            scheduleIdleReload(plugin, token, wantedTone)
            startFullBackground(document, originalFile, wantedTone, profile)
            return
        elseif cachedCount == 0 then
            return
        end

        -- If this document is already showing the requested tone (for example,
        -- after the nearby cache reload), do not reload it again. Use the idle
        -- time only for full-book completion.
        if document._burrow_epub_ornaments_active == true
            and (document._burrow_epub_ornaments_fast_adaptive == true
                or document._burrow_epub_ornaments_tone == wantedTone)
        then
            startFullBackground(document, originalFile, wantedTone, profile)
            return
        end

        local progress = currentProgress(document)
        local hotTone = fast and "light" or wantedTone
        local hotPalette = paletteName(Blitbuffer, hotTone)

        OrnamentEpub.ensureHotCacheAsync(
            originalFile,
            hotPalette,
            progress,
            HOT_RADIUS,
            function(shadow, err, count, meta)
                if err then
                    logger.warn("[Burrow ornaments] Nearby spine-priority cache failed", err)
                    startFullBackground(document, originalFile, wantedTone, profile)
                    return
                end
                if token ~= update_token then return end

                local reader = plugin and plugin.ui or nil
                local currentDocument = reader and reader.document or nil
                if not currentDocument or reader.tearing_down then return end
                if desiredTone(currentDocument, Screen) ~= wantedTone then return end

                if shadow then
                    -- The user may have moved several chapters while the hot cache
                    -- was being built. Do not apply stale nearby work. Retarget the
                    -- window around the new reading position instead.
                    if not hotWindowStillRelevant(currentDocument, meta) then
                        logger.dbg(
                            "[Burrow ornaments] Reading position moved; retargeting nearby cache",
                            meta and meta.center,
                            meta and meta.total_spine
                        )
                        UIManager:scheduleIn(0.05, function()
                            if token == update_token then
                                prepareNearbyFirst(
                                    plugin,
                                    currentDocument,
                                    token,
                                    wantedTone
                                )
                            end
                        end)
                        return
                    end

                    OrnamentEpub.setPreferredCache(
                        originalFile,
                        hotPalette,
                        shadow,
                        count,
                        meta
                    )
                    scheduleIdleReload(plugin, token, wantedTone)
                end

                -- Only after current/nearby sections have had first claim on CPU
                -- do we begin scanning and converting the rest of the book.
                startFullBackground(
                    currentDocument,
                    originalFile,
                    wantedTone,
                    profile
                )
            end
        )
    end

    local function scheduleUpdate(plugin)
        update_token = update_token + 1
        if update_pending then return end
        update_pending = true

        UIManager:nextTick(function()
            update_pending = false
            local token = update_token

            local reader = plugin and plugin.ui or nil
            local document = reader and reader.document or nil
            if not document or reader.tearing_down then return end
            local originalFile = document._burrow_epub_ornaments_source_file or document.file
            if not isEpub(originalFile) then return end
            if not G_reader_settings:isTrue(ORNAMENT_SETTING)
                or hasUserReaderPalette()
            then
                return
            end

            local logical_night = Screen.night_mode == true
            if G_reader_settings:isTrue("night_mode") ~= logical_night then
                logger.warn("[Burrow ornaments] Night Mode state is not settled; update skipped")
                return
            end

            if not syncKindleNightMode(logger) then return end

            local wanted = desiredTone(document, Screen)
            if document._burrow_epub_ornaments_fast_adaptive == true then
                if type(document.resetBufferCache) == "function" then
                    pcall(document.resetBufferCache, document)
                elseif document.buffer then
                    pcall(document.buffer.free, document.buffer)
                    document.buffer = nil
                end
                UIManager:setDirty(reader, "full")
                logger.dbg("[Burrow ornaments] Repainted adaptive Night Mode without reload")
                startFullBackground(
                    document,
                    originalFile,
                    wanted,
                    document._burrow_epub_ornaments_profile
                )
                return
            end

            if document._burrow_epub_ornaments_active == true
                and wanted == document._burrow_epub_ornaments_tone
            then
                startFullBackground(
                    document,
                    originalFile,
                    wanted,
                    document._burrow_epub_ornaments_profile
                )
                return
            end

            prepareNearbyFirst(plugin, document, token, wanted)
        end)
    end

    -- ReaderReady occurs after KOReader has restored the book position, which is
    -- the earliest useful moment to decide which EPUB spine section is "current".
    -- This gives first-open work the same current/nearby priority as Night Mode.
    local originalReaderReady = plugin_class.onReaderReady
    function plugin_class:onReaderReady(...)
        local result
        if originalReaderReady then result = originalReaderReady(self, ...) end
        scheduleUpdate(self)
        return result
    end

    local originalToggleNightMode = plugin_class.onToggleNightMode
    function plugin_class:onToggleNightMode(...)
        local result
        if originalToggleNightMode then result = originalToggleNightMode(self, ...) end
        scheduleUpdate(self)
        return result
    end

    local originalSetNightMode = plugin_class.onSetNightMode
    function plugin_class:onSetNightMode(...)
        local result
        if originalSetNightMode then result = originalSetNightMode(self, ...) end
        scheduleUpdate(self)
        return result
    end

    return true
end

return Module

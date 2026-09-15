local logger = require("logger")
local Device = require("device")

-- Kindle needs a different latency strategy from Android. Load this before
-- main.lua applies the general transition module so the Kindle helper can
-- disable only the general CRengine warmup/cache defaults while preserving the
-- rest of beta.3's tested transition work.
if Device:isKindle() then
    local kindle_ok, KindleTransition = pcall(
        require,
        "burrow_kindle_transition_performance"
    )
    if kindle_ok
        and type(KindleTransition) == "table"
        and type(KindleTransition.apply) == "function"
    then
        local apply_ok, applied, apply_error = pcall(
            KindleTransition.apply,
            KindleTransition
        )
        if not apply_ok or applied == false then
            logger.warn(
                "[Burrow performance] Kindle transition layer could not be applied",
                apply_ok and apply_error or applied
            )
        end
    else
        logger.warn(
            "[Burrow performance] Kindle transition layer could not be loaded",
            KindleTransition
        )
    end
end

local Module = {}

local HOT_RADIUS = 3

local function oppositePalette(palette)
    if type(palette) ~= "string" then return nil end
    local family, tone = palette:match("^(%a+)%-(%a+)$")
    if family ~= "soft" and family ~= "pure" then return nil end
    if tone == "light" then
        return family .. "-night"
    elseif tone == "night" then
        return family .. "-light"
    end
    return nil
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

local function activeDocumentFor(sourcePath)
    local ok, ReaderUI = pcall(require, "apps/reader/readerui")
    if not ok or type(ReaderUI) ~= "table" then return nil end

    local reader = ReaderUI.instance
    if type(reader) ~= "table" or reader.tearing_down then return nil end
    local document = reader.document
    if type(document) ~= "table" then return nil end

    local originalFile = document._burrow_epub_ornaments_source_file or document.file
    if originalFile ~= sourcePath then return nil end
    return document
end

function Module.apply()
    if Module.applied then return true end

    local Epub = require("burrow_soft_palette_epub")
    if type(Epub.ensureCacheAsync) ~= "function"
        or type(Epub.ensureHotCacheAsync) ~= "function"
        or type(Epub.cachedResult) ~= "function"
        or type(Epub.preferredCache) ~= "function"
        or type(Epub.setPreferredCache) ~= "function"
    then
        return false, "Decorative EPUB cache API is unavailable"
    end

    if Epub._burrow_dual_tone_prewarm_v1 then
        Module.applied = true
        return true
    end

    local originalEnsureCacheAsync = Epub.ensureCacheAsync

    function Epub.ensureCacheAsync(sourcePath, paletteName, knownProfile, callback)
        local opposite = oppositePalette(paletteName)
        local profile = knownProfile

        -- Adaptive books use one light-form shadow EPUB for both display modes,
        -- and books with no eligible ornaments need no shadow EPUB at all.
        if not opposite
            or type(profile) ~= "table"
            or profile.all_eligible == true
            or tonumber(profile.eligible_count) == 0
        then
            return originalEnsureCacheAsync(
                sourcePath,
                paletteName,
                knownProfile,
                callback
            )
        end

        local document = activeDocumentFor(sourcePath)
        if not document or document._nightmode_images == false then
            return originalEnsureCacheAsync(
                sourcePath,
                paletteName,
                knownProfile,
                callback
            )
        end

        -- If the full opposite-tone cache already exists, or profiling proved
        -- there is nothing to recolor for it, there is nothing useful to prewarm.
        local oppositeFull, oppositeErr, oppositeCount = Epub.cachedResult(
            sourcePath,
            opposite
        )
        if oppositeErr then
            logger.warn("[Burrow ornaments] Opposite-tone cache lookup failed", oppositeErr)
        end
        if oppositeFull ~= nil or oppositeCount == 0 then
            return originalEnsureCacheAsync(
                sourcePath,
                paletteName,
                knownProfile,
                callback
            )
        end

        -- Reuse a nearby opposite-tone window when it still covers the reader's
        -- current position. Drop only the in-memory preference when it is stale;
        -- the disposable cache file itself may still be useful later.
        local preferred, _, preferredMeta = Epub.preferredCache(sourcePath, opposite)
        if preferred and hotWindowStillRelevant(document, preferredMeta) then
            return originalEnsureCacheAsync(
                sourcePath,
                paletteName,
                knownProfile,
                callback
            )
        elseif preferred then
            Epub.setPreferredCache(sourcePath, opposite, nil)
        end

        local progress = currentProgress(document)

        -- Full-book work is intentionally held until the nearby opposite-tone
        -- window has had first claim on CPU. This gives a light/dark toggle a
        -- ready current chapter while both full-book caches continue quietly.
        return Epub.ensureHotCacheAsync(
            sourcePath,
            opposite,
            progress,
            HOT_RADIUS,
            function(shadow, err, count, meta)
                if err then
                    logger.warn("[Burrow ornaments] Opposite nearby prewarm failed", err)
                else
                    local currentDocument = activeDocumentFor(sourcePath)
                    if shadow
                        and currentDocument
                        and hotWindowStillRelevant(currentDocument, meta)
                    then
                        Epub.setPreferredCache(
                            sourcePath,
                            opposite,
                            shadow,
                            count,
                            meta
                        )
                        logger.dbg(
                            "[Burrow ornaments] Prepared opposite-tone nearby cache before full-book work",
                            opposite,
                            meta and meta.center,
                            meta and meta.total_spine
                        )
                    end
                end

                originalEnsureCacheAsync(
                    sourcePath,
                    paletteName,
                    knownProfile,
                    callback
                )
            end
        )
    end

    Epub._burrow_dual_tone_prewarm_v1 = true
    Module.applied = true
    return true
end

return Module

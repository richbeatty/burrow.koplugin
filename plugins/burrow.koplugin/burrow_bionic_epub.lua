local Archiver = require("ffi/archiver")
local Blitbuffer = require("ffi/blitbuffer")
local logger = require("logger")

local OrnamentEpub = require("burrow_soft_palette_epub")
local Transformer = require("burrow_bionic_xhtml")

local Epub = {}

local function dirname(path)
    return path:match("^(.*[/\\])") or ""
end

local function normalizePath(path)
    local parts = {}
    path = (path or ""):gsub("\\", "/")
    for part in path:gmatch("[^/]+") do
        if part == "." or part == "" then
            -- skip
        elseif part == ".." then
            if #parts > 0 then table.remove(parts) end
        else
            parts[#parts + 1] = part
        end
    end
    return table.concat(parts, "/")
end

local function containerRootfile(xml)
    if not xml then return nil end
    return xml:match('<rootfile[^>]-full%-path%s*=%s*"([^"]+)"')
        or xml:match("<rootfile[^>]-full%-path%s*=%s*'([^']+)'")
end

local function attr(tag, name)
    return tag:match(name .. '%s*=%s*"([^"]*)"')
        or tag:match(name .. "%s*=%s*'([^']*)'")
end

local function closeQuietly(object)
    if object then pcall(object.close, object) end
end

local function manifestItems(opf, opfPath)
    local items = {}
    local content = {}
    local nav = {}
    local images = {}
    local base = dirname(opfPath)
    local epub2_cover_id = (opf or ""):match(
        '<meta[^>]-name%s*=%s*"cover"[^>]-content%s*=%s*"([^"]+)"'
    ) or (opf or ""):match(
        "<meta[^>]-name%s*=%s*'cover'[^>]-content%s*=%s*'([^']+)'"
    )

    for tag in (opf or ""):gmatch("<item%s+[^>]->") do
        local id = attr(tag, "id")
        local media = attr(tag, "media%-type")
        local href = attr(tag, "href")
        local properties = attr(tag, "properties") or ""
        if id and href then
            href = href:gsub("#.*$", "")
            local path = normalizePath(base .. href)
            items[id] = {
                path = path,
                media = media,
                properties = properties,
            }
            if media == "application/xhtml+xml" or media == "text/html" then
                content[path] = true
                if properties:match("%f[%w]nav%f[%W]") then
                    nav[path] = true
                end
            elseif media == "image/png"
                or media == "image/jpeg"
                or media == "image/svg+xml"
            then
                local is_cover = properties:find("cover%-image") ~= nil
                    or (epub2_cover_id and id == epub2_cover_id)
                    or path:lower():find("cover", 1, true) ~= nil
                if not is_cover then
                    images[path] = media
                end
            end
        end
    end

    return items, content, nav, images
end

local function spineDocuments(opf, items)
    local result = {}
    for tag in (opf or ""):gmatch("<itemref%s+[^>]->") do
        local idref = attr(tag, "idref")
        local item = idref and items[idref] or nil
        if item and item.path then
            result[#result + 1] = item.path
        end
    end
    return result
end

local function filterHotSpine(opf, items, hotSet)
    if type(opf) ~= "string" or type(hotSet) ~= "table" then
        return opf
    end

    local filtered, replaced = opf:gsub(
        "(<spine[^>]*>)(.-)(</spine>)",
        function(openTag, body, closeTag)
            local kept = body:gsub("<itemref%s+[^>]->", function(tag)
                local idref = attr(tag, "idref")
                local item = idref and items[idref] or nil
                if item and hotSet[item.path] then
                    return tag
                end
                return ""
            end)
            return openTag .. kept .. closeTag
        end,
        1
    )

    if replaced == 0 then return opf end
    return filtered
end

local function cleanReference(ref)
    if type(ref) ~= "string" then return nil end
    ref = ref:gsub("&amp;", "&"):gsub("#.*$", "")
    if ref == "" or ref:match("^%a+:") or ref:sub(1, 1) == "#" then
        return nil
    end
    return ref
end

local function referencedImages(content, documentPath, imageSet)
    local found = {}
    if type(content) ~= "string" then return found end
    local base = dirname(documentPath)

    local function add(ref)
        ref = cleanReference(ref)
        if not ref then return end
        local path = normalizePath(base .. ref)
        if imageSet[path] then found[path] = true end
    end

    for ref in content:gmatch('[Ss][Rr][Cc]%s*=%s*"([^"]+)"') do add(ref) end
    for ref in content:gmatch("[Ss][Rr][Cc]%s*=%s*'([^']+)'") do add(ref) end
    for ref in content:gmatch('[Hh][Rr][Ee][Ff]%s*=%s*"([^"]+)"') do add(ref) end
    for ref in content:gmatch("[Hh][Rr][Ee][Ff]%s*=%s*'([^']+)'") do add(ref) end
    for ref in content:gmatch('[Xx][Ll][Ii][Nn][Kk]:[Hh][Rr][Ee][Ff]%s*=%s*"([^"]+)"') do add(ref) end
    for ref in content:gmatch("[Xx][Ll][Ii][Nn][Kk]:[Hh][Rr][Ee][Ff]%s*=%s*'([^']+)'") do add(ref) end
    for ref in content:gmatch('[Dd][Aa][Tt][Aa]%s*=%s*"([^"]+)"') do add(ref) end
    for ref in content:gmatch("[Dd][Aa][Tt][Aa]%s*=%s*'([^']+)'") do add(ref) end
    for ref in content:gmatch("[Uu][Rr][Ll]%s*%(%s*['\"]?([^)'\"]+)['\"]?%s*%)") do add(ref) end

    return found
end

local function ornamentNormalizationEnabled()
    return G_reader_settings:isTrue("burrow_soft_palette_recolor_ornaments")
        and not G_reader_settings:has("cre_background_color")
        and not G_reader_settings:has("cre_background_image")
        and type(OrnamentEpub.transformAdaptiveImage) == "function"
end

local function softPaletteActive()
    return tonumber(Blitbuffer.COLOR_WHITE.a) == 0xF2
        and tonumber(Blitbuffer.COLOR_BLACK.a) == 0x20
end

local function pendingXhtml()
    return [[<?xml version="1.0" encoding="utf-8"?>
<html xmlns="http://www.w3.org/1999/xhtml">
<head><title>Preparing Bionic Reading</title></head>
<body>
<p><b class="burrow-bionic">Prepa</b>ring <b class="burrow-bionic">Bio</b>nic Reading for this section...</p>
</body>
</html>]]
end

local function archiveCompression(writer, path, content_documents, hot)
    if hot then
        writer:setZipCompression("store")
        return
    end

    -- Recompress text where it is useful, but do not spend Kindle CPU trying to
    -- deflate JPEG/PNG/font assets that are already compressed.
    if content_documents[path]
        or path:lower():match("%.css$")
        or path:lower():match("%.xml$")
        or path:lower():match("%.opf$")
        or path:lower():match("%.ncx$")
    then
        writer:setZipCompression("deflate")
    else
        writer:setZipCompression("store")
    end
end

local function generateImpl(sourcePath, targetPath, options)
    options = options or {}
    local cooperate = options.cooperate

    local reader = Archiver.Reader:new()
    if not reader:open(sourcePath) then
        return false, "Could not open source EPUB."
    end

    -- Populate the reader entry lookup table, as KOReader's Archiver expects.
    for _ in reader:iterate() do end

    local container = reader:extractToMemory("META-INF/container.xml")
    local opfPath = containerRootfile(container)
    if not opfPath then
        closeQuietly(reader)
        return false, "EPUB package document was not found."
    end
    opfPath = normalizePath(opfPath)

    local opf = reader:extractToMemory(opfPath)
    if not opf then
        closeQuietly(reader)
        return false, "EPUB package document could not be read."
    end

    local items, content_documents, nav_documents, image_documents =
        manifestItems(opf, opfPath)
    local spine = spineDocuments(opf, items)

    local hot_set
    local hot_image_set
    local hot_opf
    local hot_meta
    if options.hot then
        hot_set = {}
        local total = #spine
        local progress = tonumber(options.progress) or 0
        if progress < 0 then progress = 0 end
        if progress > 1 then progress = 1 end
        local radius = math.max(0, tonumber(options.radius) or 2)
        local center = 1
        if total > 1 then
            center = math.floor(progress * (total - 1)) + 1
        end
        if center < 1 then center = 1 end
        if center > total and total > 0 then center = total end

        for index = math.max(1, center - radius), math.min(total, center + radius) do
            hot_set[spine[index]] = true
        end
        for path in pairs(nav_documents) do
            hot_set[path] = true
        end

        hot_image_set = {}
        for path in pairs(hot_set) do
            if content_documents[path] then
                local source_content = reader:extractToMemory(path)
                if source_content then
                    for image_path in pairs(
                        referencedImages(source_content, path, image_documents)
                    ) do
                        hot_image_set[image_path] = true
                    end
                end
            end
        end

        hot_opf = filterHotSpine(opf, items, hot_set)
        hot_meta = {
            center = center,
            radius = radius,
            total_spine = total,
        }
    end

    local tempPath = targetPath .. ".tmp"
    local ornamentTempBase = targetPath .. ".ornament.tmp"
    os.remove(tempPath)
    os.remove(ornamentTempBase .. ".png")
    os.remove(ornamentTempBase .. ".jpg")
    local writer = Archiver.Writer:new()
    if not writer:open(tempPath, "epub") then
        closeQuietly(reader)
        return false, "Could not create Bionic Reading cache."
    end

    local mtime = os.time()
    writer:setZipCompression("store")
    if not writer:addFileFromMemory("mimetype", "application/epub+zip", mtime) then
        closeQuietly(writer)
        closeQuietly(reader)
        os.remove(tempPath)
        return false, "Could not write EPUB mimetype."
    end

    for entry in reader:iterate() do
        if entry.mode == "file" and entry.path ~= "mimetype" then
            local content = reader:extractToMemory(entry.path)
            if content == nil then
                closeQuietly(writer)
                closeQuietly(reader)
                os.remove(tempPath)
                return false, "Could not read EPUB entry: " .. tostring(entry.path)
            end

            local normalized = normalizePath(entry.path)

            -- The hot EPUB exposes only the prepared spine window. Normal page
            -- turns therefore stop at the edge of prepared Bionic content instead
            -- of entering synthetic placeholder chapters that do not exist in the
            -- completed shadow and cannot preserve a stable reading position.
            if options.hot and hot_opf and normalized == opfPath then
                content = hot_opf
            end

            if content_documents[normalized] then
                if not options.hot or hot_set[normalized] then
                    local ok, transformed = pcall(
                        Transformer.process,
                        content,
                        cooperate
                    )
                    if not ok or not transformed then
                        logger.warn(
                            "[Burrow bionic] XHTML transform failed",
                            entry.path,
                            transformed
                        )
                        closeQuietly(writer)
                        closeQuietly(reader)
                        os.remove(tempPath)
                        return false, "Could not transform EPUB text."
                    end
                    content = transformed
                else
                    -- The hot cache never exposes ordinary text. Sections outside
                    -- the prepared spine window are represented by a lightweight
                    -- placeholder until the complete Bionic shadow is ready.
                    content = pendingXhtml()
                end
            end

            if ornamentNormalizationEnabled()
                and image_documents[normalized]
                and (not options.hot
                    or (hot_image_set and hot_image_set[normalized]))
            then
                local ok, transformed = pcall(
                    OrnamentEpub.transformAdaptiveImage,
                    content,
                    image_documents[normalized],
                    ornamentTempBase,
                    softPaletteActive(),
                    cooperate
                )
                if ok and transformed then
                    content = transformed
                    logger.dbg(
                        "[Burrow bionic] Embedded adaptive ornament palette",
                        entry.path
                    )
                elseif not ok then
                    logger.warn(
                        "[Burrow bionic] Adaptive ornament transform failed",
                        entry.path,
                        transformed
                    )
                end
            end

            archiveCompression(writer, normalized, content_documents, options.hot)
            if not writer:addFileFromMemory(entry.path, content, mtime) then
                closeQuietly(writer)
                closeQuietly(reader)
                os.remove(tempPath)
                return false, "Could not write EPUB entry: " .. tostring(entry.path)
            end

            if cooperate then cooperate() end
        end
    end

    closeQuietly(writer)
    closeQuietly(reader)
    os.remove(ornamentTempBase .. ".png")
    os.remove(ornamentTempBase .. ".jpg")

    os.remove(targetPath)
    local ok, err = os.rename(tempPath, targetPath)
    if not ok then
        os.remove(tempPath)
        return false, "Could not finalize Bionic Reading cache: " .. tostring(err)
    end

    return true, hot_meta
end

function Epub.generate(sourcePath, targetPath)
    local ok, result = generateImpl(sourcePath, targetPath)
    if not ok then return false, result end
    return true
end

function Epub.generateCooperative(sourcePath, targetPath, cooperate)
    local ok, result = generateImpl(sourcePath, targetPath, {
        cooperate = cooperate,
    })
    if not ok then return false, result end
    return true
end

function Epub.generateHot(sourcePath, targetPath, progress, radius)
    local ok, result = generateImpl(sourcePath, targetPath, {
        hot = true,
        progress = progress,
        radius = radius,
    })
    if not ok then return false, result end
    return true, result
end

return Epub

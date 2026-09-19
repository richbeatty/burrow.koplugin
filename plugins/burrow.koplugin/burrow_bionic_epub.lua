local Archiver = require("ffi/archiver")
local logger = require("logger")

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
    local base = dirname(opfPath)

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
            end
        end
    end

    return items, content, nav
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

    local items, content_documents, nav_documents = manifestItems(opf, opfPath)
    local spine = spineDocuments(opf, items)

    local hot_set
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

        hot_meta = {
            center = center,
            radius = radius,
            total_spine = total,
        }
    end

    local tempPath = targetPath .. ".tmp"
    os.remove(tempPath)
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

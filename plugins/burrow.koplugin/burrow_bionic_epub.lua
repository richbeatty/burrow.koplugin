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

local function contentDocuments(opf, opfPath)
    local result = {}
    local base = dirname(opfPath)
    for tag in (opf or ""):gmatch("<item%s+[^>]->") do
        local media = attr(tag, "media%-type")
        local href = attr(tag, "href")
        if href and media
            and (media == "application/xhtml+xml" or media == "text/html")
        then
            href = href:gsub("#.*$", "")
            result[normalizePath(base .. href)] = true
        end
    end
    return result
end

local function closeQuietly(object)
    if object then pcall(object.close, object) end
end

function Epub.generate(sourcePath, targetPath)
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
    local transformSet = contentDocuments(opf, opfPath)

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
    writer:setZipCompression("deflate")

    for entry in reader:iterate() do
        if entry.mode == "file" and entry.path ~= "mimetype" then
            local content = reader:extractToMemory(entry.path)
            if content == nil then
                closeQuietly(writer)
                closeQuietly(reader)
                os.remove(tempPath)
                return false, "Could not read EPUB entry: " .. tostring(entry.path)
            end

            if transformSet[normalizePath(entry.path)] then
                local ok, transformed = pcall(Transformer.process, content)
                if not ok or not transformed then
                    logger.warn("[Burrow bionic] XHTML transform failed", entry.path, transformed)
                    closeQuietly(writer)
                    closeQuietly(reader)
                    os.remove(tempPath)
                    return false, "Could not transform EPUB text."
                end
                content = transformed
            end

            if not writer:addFileFromMemory(entry.path, content, mtime) then
                closeQuietly(writer)
                closeQuietly(reader)
                os.remove(tempPath)
                return false, "Could not write EPUB entry: " .. tostring(entry.path)
            end
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

    return true
end

return Epub

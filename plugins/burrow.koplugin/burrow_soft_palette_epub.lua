local Archiver = require("ffi/archiver")
local Blitbuffer = require("ffi/blitbuffer")
local DataStorage = require("datastorage")
local RenderImage = require("ui/renderimage")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local util = require("util")

local Epub = {
    CACHE_VERSION = "ornaments-v1-f2f2f0-202020",
}

local BLACK_R, BLACK_G, BLACK_B = 0x20, 0x20, 0x20
local WHITE_R, WHITE_G, WHITE_B = 0xF2, 0xF2, 0xF0

-- Keep this deliberately conservative. The goal is to catch scene-break art,
-- chapter flourishes and other small monochrome assets without recoloring
-- illustrations, covers, comics or photographs.
local MAX_RASTER_PIXELS = 220000
local MAX_RASTER_DIMENSION = 1400
local MAX_COMPRESSED_BYTES = 2 * 1024 * 1024
local SAMPLE_TARGET = 6000
local MAX_CHROMA = 18
local MAX_COLORED_SAMPLE_FRACTION = 0.02
local MIN_EXTREME_SAMPLE_FRACTION = 0.82
local MIN_LIGHT_SAMPLE_FRACTION = 0.20
local MIN_DARK_SAMPLE_FRACTION = 0.002

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

local function imageDocuments(opf, opfPath)
    local result = {}
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
        if href and media then
            local supported = media == "image/png"
                or media == "image/jpeg"
                or media == "image/svg+xml"
            if supported then
                href = href:gsub("#.*$", "")
                local path = normalizePath(base .. href)
                local is_cover = properties:find("cover%-image") ~= nil
                    or (epub2_cover_id and id == epub2_cover_id)
                    or path:lower():find("cover", 1, true) ~= nil
                if not is_cover then
                    result[path] = media
                end
            end
        end
    end
    return result
end

local function closeQuietly(object)
    if object then pcall(object.close, object) end
end

local function ensureDir(path)
    if lfs.attributes(path, "mode") == "directory" then return true end
    local ok = lfs.mkdir(path)
    return ok or lfs.attributes(path, "mode") == "directory"
end

function Epub.cacheDirectory()
    local root
    if type(DataStorage.getFullDataDir) == "function" then
        root = DataStorage:getFullDataDir()
    end
    root = root or DataStorage:getDataDir()
    return root .. "/cache/burrow-soft-palette"
end

function Epub.cachePath(source)
    local checksum = util.partialMD5(source)
    if not checksum then return nil, "Could not identify this EPUB." end

    local attrs = lfs.attributes(source) or {}
    local identity = table.concat({
        tostring(checksum),
        tostring(attrs.size or ""),
        tostring(attrs.modification or ""),
        Epub.CACHE_VERSION,
    }, "-")
    identity = identity:gsub("[^%w%-_%.]", "_")
    return Epub.cacheDirectory() .. "/" .. identity .. ".epub"
end

local function visibleChannel(channel, alpha)
    -- MuPDF commonly returns premultiplied alpha. Adding the uncovered white
    -- portion gives us the visible value on a white page and also behaves well
    -- for straight-alpha black/white artwork.
    local value = channel + (255 - alpha)
    if value > 255 then value = 255 end
    return value
end

local function visibleRGB(bb, x, y)
    local color = bb:getPixel(x, y):getColorRGB32()
    local alpha = tonumber(color.alpha) or 255
    return visibleChannel(tonumber(color.r) or 0, alpha),
        visibleChannel(tonumber(color.g) or 0, alpha),
        visibleChannel(tonumber(color.b) or 0, alpha)
end

local function luminance(r, g, b)
    -- Integer approximation of Rec. 601 luma.
    return math.floor((77 * r + 150 * g + 29 * b + 128) / 256)
end

local function isSmallMonochromeRaster(bb)
    local w, h = bb:getWidth(), bb:getHeight()
    if w < 4 or h < 4 then return false end
    if w > MAX_RASTER_DIMENSION or h > MAX_RASTER_DIMENSION then return false end
    local area = w * h
    if area > MAX_RASTER_PIXELS then return false end

    local step = math.max(1, math.floor(math.sqrt(area / SAMPLE_TARGET)))
    local total, colored, extremes, light, dark = 0, 0, 0, 0, 0

    for y = 0, h - 1, step do
        for x = 0, w - 1, step do
            local r, g, b = visibleRGB(bb, x, y)
            local high = math.max(r, g, b)
            local low = math.min(r, g, b)
            if high - low > MAX_CHROMA then colored = colored + 1 end

            local luma = luminance(r, g, b)
            if luma <= 96 then dark = dark + 1 end
            if luma >= 200 then light = light + 1 end
            if luma <= 96 or luma >= 200 then extremes = extremes + 1 end
            total = total + 1
        end
    end

    if total == 0 then return false end
    if colored / total > MAX_COLORED_SAMPLE_FRACTION then return false end
    if extremes / total < MIN_EXTREME_SAMPLE_FRACTION then return false end
    if light / total < MIN_LIGHT_SAMPLE_FRACTION then return false end
    if dark / total < MIN_DARK_SAMPLE_FRACTION then return false end
    return true
end

local function remapChannel(luma, target_white)
    return math.floor(BLACK_R + (luma * (target_white - BLACK_R) + 127) / 255)
end

local function recolorRaster(content, media, tempBase)
    if #content > MAX_COMPRESSED_BYTES then return nil end

    local ok, bb = pcall(
        RenderImage.renderImageDataWithMupdf,
        RenderImage,
        content,
        #content
    )
    if not ok or not bb then return nil end

    if not isSmallMonochromeRaster(bb) then
        pcall(bb.free, bb)
        return nil
    end

    local w, h = bb:getWidth(), bb:getHeight()
    local out = Blitbuffer.new(w, h, Blitbuffer.TYPE_BBRGB24)
    local ColorRGB24 = Blitbuffer.ColorRGB24

    for y = 0, h - 1 do
        for x = 0, w - 1 do
            local r, g, b = visibleRGB(bb, x, y)
            local luma = luminance(r, g, b)
            local rr = remapChannel(luma, WHITE_R)
            local gg = remapChannel(luma, WHITE_G)
            local bbv = remapChannel(luma, WHITE_B)
            out:setPixel(x, y, ColorRGB24(rr, gg, bbv))
        end
    end

    local suffix = media == "image/jpeg" and ".jpg" or ".png"
    local tempPath = tempBase .. suffix
    os.remove(tempPath)

    local write_ok, write_err
    if media == "image/jpeg" then
        write_ok, write_err = pcall(out.writeJPG, out, tempPath, 95)
    else
        write_ok, write_err = pcall(out.writePNG, out, tempPath)
    end

    pcall(out.free, out)
    pcall(bb.free, bb)

    if not write_ok then
        os.remove(tempPath)
        logger.warn("[Burrow palette] Could not encode recolored ornament", write_err)
        return nil
    end

    local file = io.open(tempPath, "rb")
    if not file then
        os.remove(tempPath)
        return nil
    end
    local transformed = file:read("*a")
    file:close()
    os.remove(tempPath)
    return transformed
end

local function remapGrayValue(value)
    local r = remapChannel(value, WHITE_R)
    local g = remapChannel(value, WHITE_G)
    local b = remapChannel(value, WHITE_B)
    return string.format("#%02x%02x%02x", r, g, b)
end

local function recolorSvg(content)
    if #content > 100000 then return nil end
    local lower = content:lower()
    if lower:find("<image", 1, true)
        or lower:find("lineargradient", 1, true)
        or lower:find("radialgradient", 1, true)
        or lower:find("<filter", 1, true)
        or lower:find("<pattern", 1, true)
    then
        return nil
    end

    local paths = 0
    for _ in lower:gmatch("<path[%s>]" ) do
        paths = paths + 1
        if paths > 80 then return nil end
    end

    local changed = false
    local saw_dark = false

    local transformed = content:gsub("#([%x]+)", function(hex)
        local n = #hex
        local value
        if n == 3 then
            local a, b, c = hex:sub(1,1), hex:sub(2,2), hex:sub(3,3)
            if a:lower() == b:lower() and b:lower() == c:lower() then
                value = tonumber(a .. a, 16)
            end
        elseif n == 6 then
            local r = tonumber(hex:sub(1,2), 16)
            local g = tonumber(hex:sub(3,4), 16)
            local b = tonumber(hex:sub(5,6), 16)
            if r == g and g == b then value = r end
        end
        if value then
            if value <= 96 then saw_dark = true end
            changed = true
            return remapGrayValue(value)
        end
        return "#" .. hex
    end)

    transformed = transformed:gsub("([Rr][Gg][Bb]%s*%(%s*)(%d+)(%s*,%s*)(%d+)(%s*,%s*)(%d+)(%s*%))", function(prefix, r, comma1, g, comma2, b, suffix)
        r, g, b = tonumber(r), tonumber(g), tonumber(b)
        if r and g and b and r == g and g == b and r >= 0 and r <= 255 then
            if r <= 96 then saw_dark = true end
            changed = true
            local rr = remapChannel(r, WHITE_R)
            local gg = remapChannel(r, WHITE_G)
            local bbv = remapChannel(r, WHITE_B)
            return string.format("rgb(%d,%d,%d)", rr, gg, bbv)
        end
        return prefix .. tostring(r) .. comma1 .. tostring(g) .. comma2 .. tostring(b) .. suffix
    end)

    transformed = transformed:gsub("([" .. "'=:%s" .. "])black([;\"'%s>/])", function(pre, post)
        changed = true
        saw_dark = true
        return pre .. "#202020" .. post
    end)
    transformed = transformed:gsub("([" .. "'=:%s" .. "])white([;\"'%s>/])", function(pre, post)
        changed = true
        return pre .. "#f2f2f0" .. post
    end)

    if changed and saw_dark then return transformed end
    return nil
end

local function transformImage(content, media, tempBase)
    if media == "image/svg+xml" then
        return recolorSvg(content)
    end
    return recolorRaster(content, media, tempBase)
end

function Epub.generate(sourcePath, targetPath)
    local reader = Archiver.Reader:new()
    if not reader:open(sourcePath) then
        return false, "Could not open source EPUB."
    end

    -- Populate KOReader Archiver's entry lookup table.
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
    local imageSet = imageDocuments(opf, opfPath)

    local tempPath = targetPath .. ".tmp"
    local tempImageBase = targetPath .. ".ornament.tmp"
    os.remove(tempPath)
    os.remove(tempImageBase .. ".png")
    os.remove(tempImageBase .. ".jpg")

    local writer = Archiver.Writer:new()
    if not writer:open(tempPath, "epub") then
        closeQuietly(reader)
        return false, "Could not create soft-palette EPUB cache."
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

    local recolored = 0
    for entry in reader:iterate() do
        if entry.mode == "file" and entry.path ~= "mimetype" then
            local content = reader:extractToMemory(entry.path)
            if content == nil then
                closeQuietly(writer)
                closeQuietly(reader)
                os.remove(tempPath)
                return false, "Could not read EPUB entry: " .. tostring(entry.path)
            end

            local media = imageSet[normalizePath(entry.path)]
            if media then
                local ok, transformed = pcall(transformImage, content, media, tempImageBase)
                if ok and transformed then
                    content = transformed
                    recolored = recolored + 1
                    logger.dbg("[Burrow palette] Recolored decorative EPUB image", entry.path)
                elseif not ok then
                    logger.warn("[Burrow palette] Ornament transform failed", entry.path, transformed)
                end
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
    os.remove(tempImageBase .. ".png")
    os.remove(tempImageBase .. ".jpg")

    os.remove(targetPath)
    local ok, err = os.rename(tempPath, targetPath)
    if not ok then
        os.remove(tempPath)
        return false, "Could not finalize soft-palette EPUB cache: " .. tostring(err)
    end

    logger.info("[Burrow palette] Built EPUB ornament cache", recolored)
    return true
end

function Epub.ensureCache(sourcePath)
    local directory = Epub.cacheDirectory()
    if not ensureDir(directory) then
        return nil, "Could not create Burrow's soft-palette cache."
    end

    local target, err = Epub.cachePath(sourcePath)
    if not target then return nil, err end
    if lfs.attributes(target, "mode") == "file" then return target end

    local ok, buildErr = Epub.generate(sourcePath, target)
    if not ok then
        os.remove(target)
        return nil, buildErr
    end
    return target
end

return Epub

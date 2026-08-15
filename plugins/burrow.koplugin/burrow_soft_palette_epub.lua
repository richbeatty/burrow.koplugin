local Archiver = require("ffi/archiver")
local Blitbuffer = require("ffi/blitbuffer")
local DataStorage = require("datastorage")
local RenderImage = require("ui/renderimage")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local util = require("util")

local Epub = {
    CACHE_VERSION = "ornaments-v2-selective-night",
}

local PALETTES = {
    ["pure-light"] = {
        dark = { 0x00, 0x00, 0x00 },
        light = { 0xFF, 0xFF, 0xFF },
    },
    ["pure-night"] = {
        dark = { 0xFF, 0xFF, 0xFF },
        light = { 0x00, 0x00, 0x00 },
    },
    ["soft-light"] = {
        dark = { 0x20, 0x20, 0x20 },
        light = { 0xF2, 0xF2, 0xF0 },
    },
    ["soft-night"] = {
        dark = { 0xDF, 0xDF, 0xDF },
        light = { 0x0D, 0x0D, 0x0F },
    },
}

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

local function paletteFor(name)
    return PALETTES[name]
end

function Epub.cacheDirectory()
    local root
    if type(DataStorage.getFullDataDir) == "function" then
        root = DataStorage:getFullDataDir()
    end
    root = root or DataStorage:getDataDir()
    return root .. "/cache/burrow-soft-palette"
end

function Epub.cachePath(source, paletteName)
    if not paletteFor(paletteName) then
        return nil, "Unknown decorative EPUB palette: " .. tostring(paletteName)
    end

    local checksum = util.partialMD5(source)
    if not checksum then return nil, "Could not identify this EPUB." end

    local attrs = lfs.attributes(source) or {}
    local identity = table.concat({
        tostring(checksum),
        tostring(attrs.size or ""),
        tostring(attrs.modification or ""),
        Epub.CACHE_VERSION,
        paletteName,
    }, "-")
    identity = identity:gsub("[^%w%-_%.]", "_")
    return Epub.cacheDirectory() .. "/" .. identity .. ".epub"
end

local function countPath(targetPath)
    return targetPath .. ".count"
end

local function readRecoloredCount(path)
    local file = io.open(path, "r")
    if not file then return nil end
    local value = tonumber(file:read("*l"))
    file:close()
    if not value or value < 0 then return nil end
    return math.floor(value)
end

local function writeRecoloredCount(path, count)
    local file = io.open(path, "w")
    if not file then return false end
    file:write(tostring(count), "\n")
    file:close()
    return true
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

local function remapChannel(luma, darkTarget, lightTarget)
    local value = darkTarget + luma * (lightTarget - darkTarget) / 255
    return math.floor(value + 0.5)
end

local function recolorRaster(content, media, tempBase, palette)
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
            local rr = remapChannel(luma, palette.dark[1], palette.light[1])
            local gg = remapChannel(luma, palette.dark[2], palette.light[2])
            local bbv = remapChannel(luma, palette.dark[3], palette.light[3])
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

local function remapGrayValue(value, palette)
    local r = remapChannel(value, palette.dark[1], palette.light[1])
    local g = remapChannel(value, palette.dark[2], palette.light[2])
    local b = remapChannel(value, palette.dark[3], palette.light[3])
    return string.format("#%02x%02x%02x", r, g, b)
end

local function paletteEndpoint(rgb)
    return string.format("#%02x%02x%02x", rgb[1], rgb[2], rgb[3])
end

local function recolorSvg(content, palette)
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
            return remapGrayValue(value, palette)
        end
        return "#" .. hex
    end)

    transformed = transformed:gsub("([Rr][Gg][Bb]%s*%(%s*)(%d+)(%s*,%s*)(%d+)(%s*,%s*)(%d+)(%s*%))", function(prefix, r, comma1, g, comma2, b, suffix)
        r, g, b = tonumber(r), tonumber(g), tonumber(b)
        if r and g and b and r == g and g == b and r >= 0 and r <= 255 then
            if r <= 96 then saw_dark = true end
            changed = true
            local rr = remapChannel(r, palette.dark[1], palette.light[1])
            local gg = remapChannel(r, palette.dark[2], palette.light[2])
            local bbv = remapChannel(r, palette.dark[3], palette.light[3])
            return string.format("rgb(%d,%d,%d)", rr, gg, bbv)
        end
        return prefix .. tostring(r) .. comma1 .. tostring(g) .. comma2 .. tostring(b) .. suffix
    end)

    transformed = transformed:gsub("([" .. "'=:%s" .. "])black([;\"'%s>/])", function(pre, post)
        changed = true
        saw_dark = true
        return pre .. paletteEndpoint(palette.dark) .. post
    end)
    transformed = transformed:gsub("([" .. "'=:%s" .. "])white([;\"'%s>/])", function(pre, post)
        changed = true
        return pre .. paletteEndpoint(palette.light) .. post
    end)

    if changed and saw_dark then return transformed end
    return nil
end

local function transformImage(content, media, tempBase, palette)
    if media == "image/svg+xml" then
        return recolorSvg(content, palette)
    end
    return recolorRaster(content, media, tempBase, palette)
end

function Epub.generate(sourcePath, targetPath, paletteName)
    local palette = paletteFor(paletteName)
    if not palette then
        return false, "Unknown decorative EPUB palette: " .. tostring(paletteName)
    end

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
        return false, "Could not create decorative EPUB cache."
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
                local ok, transformed = pcall(
                    transformImage,
                    content,
                    media,
                    tempImageBase,
                    palette
                )
                if ok and transformed then
                    content = transformed
                    recolored = recolored + 1
                    logger.dbg("[Burrow ornaments] Adjusted decorative EPUB image", entry.path)
                elseif not ok then
                    logger.warn("[Burrow ornaments] Ornament transform failed", entry.path, transformed)
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

    if recolored == 0 then
        os.remove(tempPath)
        logger.dbg("[Burrow ornaments] No eligible decorative EPUB images found")
        return true, 0
    end

    os.remove(targetPath)
    local ok, err = os.rename(tempPath, targetPath)
    if not ok then
        os.remove(tempPath)
        return false, "Could not finalize soft-palette EPUB cache: " .. tostring(err)
    end

    logger.info("[Burrow ornaments] Built EPUB ornament cache", paletteName, recolored)
    return true, recolored
end

function Epub.ensureCache(sourcePath, paletteName)
    local directory = Epub.cacheDirectory()
    if not ensureDir(directory) then
        return nil, "Could not create Burrow's decorative EPUB cache.", nil
    end

    local target, err = Epub.cachePath(sourcePath, paletteName)
    if not target then return nil, err, nil end

    local countFile = countPath(target)
    local recolored = readRecoloredCount(countFile)
    if recolored ~= nil then
        if recolored == 0 then
            return nil, nil, 0
        end
        if lfs.attributes(target, "mode") == "file" then
            return target, nil, recolored
        end
        os.remove(countFile)
    elseif lfs.attributes(target, "mode") == "file" then
        -- A completed v2 cache always has a count marker. If it is missing,
        -- rebuild rather than trusting a potentially interrupted cache write.
        os.remove(target)
    end

    local ok, result = Epub.generate(sourcePath, target, paletteName)
    if not ok then
        os.remove(target)
        os.remove(countFile)
        return nil, result, nil
    end

    recolored = tonumber(result) or 0
    writeRecoloredCount(countFile, recolored)
    if recolored == 0 then
        os.remove(target)
        return nil, nil, 0
    end
    return target, nil, recolored
end

return Epub

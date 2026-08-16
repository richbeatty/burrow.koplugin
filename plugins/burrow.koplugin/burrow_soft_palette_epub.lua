local Archiver = require("ffi/archiver")
local Blitbuffer = require("ffi/blitbuffer")
local DataStorage = require("datastorage")
local RenderImage = require("ui/renderimage")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local util = require("util")

local Epub = {
    CACHE_VERSION = "ornaments-v8-spine-priority",
}

local PALETTES = {
    ["pure-light"] = {
        dark = { 0x00, 0x00, 0x00 },
        light = { 0xFF, 0xFF, 0xFF },
        force_rgb = false,
    },
    ["pure-night"] = {
        -- Keep a two-level blue-channel offset across the entire grayscale
        -- ramp. CRengine treats any r/g/b mismatch as a color pixel and
        -- pre-inverts it in Night Mode, so the final Kindle framebuffer
        -- inversion restores these explicit night colors instead of flipping
        -- them back to the light palette. The offset is visually neutral on
        -- grayscale e-ink and negligible on color screens.
        dark = { 0xFD, 0xFD, 0xFF },
        light = { 0x00, 0x00, 0x02 },
        force_rgb = true,
    },
    ["soft-light"] = {
        dark = { 0x20, 0x20, 0x20 },
        light = { 0xF2, 0xF2, 0xF2 },
        force_rgb = false,
    },
    ["soft-night"] = {
        -- Match Burrow's native-inverted soft page background (#0D0D0F) and
        -- near-#DFDFDF foreground while retaining the tiny RGB distinction
        -- CRengine needs to preserve the explicit night image through the
        -- final hardware/page inversion.
        dark = { 0xDF, 0xDF, 0xE1 },
        light = { 0x0D, 0x0D, 0x0F },
        force_rgb = true,
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
local ASYNC_INTERVAL = 0.01
local ASYNC_PROFILE_JOBS = {}
local ASYNC_CACHE_JOBS = {}
local ASYNC_HOT_CACHE_JOBS = {}
local PREFERRED_CACHES = {}

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

local SUPPORTED_IMAGE_MEDIA = {
    ["image/png"] = true,
    ["image/jpeg"] = true,
    ["image/svg+xml"] = true,
}

local function imageAssets(opf, opfPath)
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
        if href and media and media:match("^image/") then
            href = href:gsub("#.*$", "")
            local path = normalizePath(base .. href)
            local is_cover = properties:find("cover%-image") ~= nil
                or (epub2_cover_id and id == epub2_cover_id)
                or path:lower():find("cover", 1, true) ~= nil
            if not is_cover then
                result[path] = {
                    media = media,
                    supported = SUPPORTED_IMAGE_MEDIA[media] == true,
                }
            end
        end
    end
    return result
end

local function imageDocuments(opf, opfPath)
    local result = {}
    for path, image in pairs(imageAssets(opf, opfPath)) do
        if image.supported then
            result[path] = image.media
        end
    end
    return result
end

local XHTML_MEDIA = {
    ["application/xhtml+xml"] = true,
    ["text/html"] = true,
}

local function manifestItems(opf, opfPath)
    local items = {}
    local base = dirname(opfPath)
    for tag in (opf or ""):gmatch("<item%s+[^>]->") do
        local id = attr(tag, "id")
        local href = attr(tag, "href")
        local media = attr(tag, "media%-type")
        if id and href then
            href = href:gsub("#.*$", "")
            items[id] = {
                path = normalizePath(base .. href),
                media = media,
            }
        end
    end
    return items
end

local function spineDocuments(opf, opfPath)
    local manifest = manifestItems(opf, opfPath)
    local spine = {}
    for tag in (opf or ""):gmatch("<itemref%s+[^>]->") do
        local idref = attr(tag, "idref")
        local item = idref and manifest[idref] or nil
        if item and XHTML_MEDIA[item.media] then
            spine[#spine + 1] = item.path
        end
    end
    return spine
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

local function clampProgress(value)
    value = tonumber(value) or 0
    if value < 0 then return 0 end
    if value > 1 then return 1 end
    return value
end

local function spineCenter(progress, count)
    if count <= 1 then return 1 end
    local center = math.floor(clampProgress(progress) * count) + 1
    if center > count then center = count end
    if center < 1 then center = 1 end
    return center
end

local function priorityIndices(count, center, radius)
    local result = {}
    if count <= 0 then return result end
    radius = math.max(0, tonumber(radius) or 0)
    result[#result + 1] = center
    for distance = 1, radius do
        local ahead = center + distance
        local behind = center - distance
        if ahead <= count then result[#result + 1] = ahead end
        if behind >= 1 then result[#result + 1] = behind end
    end
    return result
end

local function hotWindow(reader, opf, opfPath, imageSet, progress, radius, cooperate)
    local spine = spineDocuments(opf, opfPath)
    local total = #spine
    if total == 0 then
        return {}, { center = 0, total_spine = 0, radius = radius or 0 }
    end

    local center = spineCenter(progress, total)
    local indices = priorityIndices(total, center, radius or 2)
    local images = {}
    local ordered_images = {}
    local ordered_sections = {}

    for _, index in ipairs(indices) do
        local path = spine[index]
        ordered_sections[#ordered_sections + 1] = path
        local content = reader:extractToMemory(path)
        if content then
            for imagePath in pairs(referencedImages(content, path, imageSet)) do
                if not images[imagePath] then
                    images[imagePath] = true
                    ordered_images[#ordered_images + 1] = imagePath
                end
            end
        end
        if cooperate then cooperate() end
    end

    return images, {
        center = center,
        total_spine = total,
        radius = radius or 2,
        ordered_sections = ordered_sections,
        ordered_images = ordered_images,
    }
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

local function sourceIdentity(source)
    local checksum = util.partialMD5(source)
    if not checksum then return nil end
    local attrs = lfs.attributes(source) or {}
    local identity = table.concat({
        tostring(checksum),
        tostring(attrs.size or ""),
        tostring(attrs.modification or ""),
        Epub.CACHE_VERSION,
    }, "-")
    return identity:gsub("[^%w%-_%.]", "_")
end

local function preferenceKey(source, paletteName)
    return tostring(source or "") .. "\0" .. tostring(paletteName or "")
end

function Epub.setPreferredCache(source, paletteName, path, count, meta)
    if not source or not paletteName then return false end
    if not path then
        PREFERRED_CACHES[preferenceKey(source, paletteName)] = nil
        return true
    end
    PREFERRED_CACHES[preferenceKey(source, paletteName)] = {
        path = path,
        count = tonumber(count) or 0,
        meta = meta,
    }
    return true
end

function Epub.preferredCache(source, paletteName)
    local preferred = PREFERRED_CACHES[preferenceKey(source, paletteName)]
    if not preferred then return nil, nil, nil end
    if lfs.attributes(preferred.path, "mode") ~= "file" then
        PREFERRED_CACHES[preferenceKey(source, paletteName)] = nil
        return nil, nil, nil
    end
    return preferred.path, preferred.count, preferred.meta
end

local function hotBucket(progress)
    return math.floor(clampProgress(progress) * 1000 + 0.5)
end

function Epub.hotCachePath(source, paletteName, progress, radius)
    if not paletteFor(paletteName) then
        return nil, "Unknown decorative EPUB palette: " .. tostring(paletteName)
    end
    local identity = sourceIdentity(source)
    if not identity then return nil, "Could not identify this EPUB." end
    radius = math.max(0, tonumber(radius) or 2)
    return string.format(
        "%s/%s-%s-hot-%04d-r%d.epub",
        Epub.cacheDirectory(),
        identity,
        paletteName,
        hotBucket(progress),
        radius
    )
end

local function hotMetaPath(targetPath)
    return targetPath .. ".hotmeta"
end

local function writeHotMeta(path, meta)
    if not path or type(meta) ~= "table" then return false end
    local file = io.open(path, "w")
    if not file then return false end
    file:write(
        tostring(meta.center or 0), "|",
        tostring(meta.total_spine or 0), "|",
        tostring(meta.radius or 0), "\n"
    )
    file:close()
    return true
end

local function readHotMeta(path)
    local file = path and io.open(path, "r") or nil
    if not file then return nil end
    local line = file:read("*l")
    file:close()
    if not line then return nil end
    local center, total, radius = line:match("^(%d+)|(%d+)|(%d+)$")
    center, total, radius = tonumber(center), tonumber(total), tonumber(radius)
    if not center or not total or not radius then return nil end
    return { center = center, total_spine = total, radius = radius }
end

function Epub.cachePath(source, paletteName)
    if not paletteFor(paletteName) then
        return nil, "Unknown decorative EPUB palette: " .. tostring(paletteName)
    end

    local identity = sourceIdentity(source)
    if not identity then return nil, "Could not identify this EPUB." end
    return Epub.cacheDirectory() .. "/" .. identity .. "-" .. paletteName .. ".epub"
end

local function profilePath(source)
    local identity = sourceIdentity(source)
    if not identity then return nil end
    return Epub.cacheDirectory() .. "/" .. identity .. ".profile"
end

local function readProfile(path)
    if not path then return nil end
    local file = io.open(path, "r")
    if not file then return nil end
    local line = file:read("*l")
    file:close()
    if not line then return nil end
    local images, eligible = line:match("^(%d+)|(%d+)$")
    images, eligible = tonumber(images), tonumber(eligible)
    if not images or not eligible then return nil end
    return {
        image_count = images,
        eligible_count = eligible,
        all_eligible = images > 0 and images == eligible,
    }
end

local function writeProfile(path, profile)
    if not path or type(profile) ~= "table" then return false end
    local file = io.open(path, "w")
    if not file then return false end
    file:write(tostring(profile.image_count or 0), "|", tostring(profile.eligible_count or 0), "\n")
    file:close()
    return true
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

local function isSmallMonochromeRaster(bb, cooperate)
    local w, h = bb:getWidth(), bb:getHeight()
    if w < 4 or h < 4 then return false end
    if w > MAX_RASTER_DIMENSION or h > MAX_RASTER_DIMENSION then return false end
    local area = w * h
    if area > MAX_RASTER_PIXELS then return false end

    local step = math.max(1, math.floor(math.sqrt(area / SAMPLE_TARGET)))
    local total, colored, extremes, light, dark = 0, 0, 0, 0, 0

    local sampled_rows = 0
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
        sampled_rows = sampled_rows + 1
        if cooperate and sampled_rows % 8 == 0 then cooperate() end
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

local function recolorRaster(content, media, tempBase, palette, cooperate)
    if #content > MAX_COMPRESSED_BYTES then return nil end

    local ok, bb = pcall(
        RenderImage.renderImageDataWithMupdf,
        RenderImage,
        content,
        #content
    )
    if not ok or not bb then return nil end

    if not isSmallMonochromeRaster(bb, cooperate) then
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
        if cooperate and y % 6 == 0 then cooperate() end
    end

    local suffix = media == "image/jpeg" and ".jpg" or ".png"
    local tempPath = tempBase .. suffix
    os.remove(tempPath)

    local write_ok, write_err
    if media == "image/jpeg" then
        local Jpeg = require("ffi/jpeg")
        local ffi = require("ffi")

        -- CRengine deliberately pre-inverts only *colored* image pixels in
        -- Night Mode so photographs keep their normal appearance after the
        -- whole page is inverted. Encode eligible JPEG ornaments as a true
        -- grayscale JPEG (TJSAMP_GRAY), guaranteeing r == g == b when
        -- CRengine decodes them. They will then follow the page naturally.
        local bbdump, components = out:getBufferData()
        local jpeg_quality = palette.force_rgb and 100 or 95
        local jpeg_subsample = palette.force_rgb
            and ffi.C.TJSAMP_444
            or ffi.C.TJSAMP_GRAY
        local call_ok, encoded, encode_err = pcall(
            Jpeg.encodeToFile,
            tempPath,
            ffi.cast("uint8_t*", bbdump.data),
            bbdump.w,
            bbdump.h,
            components,
            jpeg_quality,
            bbdump.stride,
            jpeg_subsample
        )
        if bbdump ~= out then pcall(bbdump.free, bbdump) end
        write_ok = call_ok and encoded ~= false
        write_err = call_ok and encode_err or encoded
    else
        local call_ok, encoded, encode_err = pcall(out.writePNG, out, tempPath)
        write_ok = call_ok and encoded ~= false
        write_err = call_ok and encode_err or encoded
    end

    pcall(out.free, out)
    pcall(bb.free, bb)

    if not write_ok then
        os.remove(tempPath)
        logger.warn("[Burrow ornaments] Could not encode adjusted ornament", write_err)
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

local function transformImage(content, media, tempBase, palette, cooperate)
    if media == "image/svg+xml" then
        return recolorSvg(content, palette)
    end
    return recolorRaster(content, media, tempBase, palette, cooperate)
end

local function isMonochromeSvgColor(value)
    value = (value or ""):lower():match("^%s*(.-)%s*$")
    if value == "none" or value == "transparent"
        or value == "currentcolor" or value == "black" or value == "white"
    then
        return true
    end

    local hex = value:match("^#([%x]+)$")
    if hex then
        if #hex == 3 or #hex == 4 then
            return hex:sub(1, 1) == hex:sub(2, 2)
                and hex:sub(2, 2) == hex:sub(3, 3)
        elseif #hex == 6 or #hex == 8 then
            local r = hex:sub(1, 2)
            local g = hex:sub(3, 4)
            local b = hex:sub(5, 6)
            return r == g and g == b
        end
        return false
    end

    local r, g, b = value:match(
        "^rgb%s*%(%s*(%d+)%s*,%s*(%d+)%s*,%s*(%d+)%s*%)$"
    )
    if r then
        r, g, b = tonumber(r), tonumber(g), tonumber(b)
        return r == g and g == b and r >= 0 and r <= 255
    end
    return false
end

local function svgHasOnlyMonochromeColors(content)
    local lower = content:lower()
    if lower:find("rgba%s*%(") or lower:find("hsl%s*%(")
        or lower:find("hsla%s*%(")
    then
        return false
    end

    for _, attribute in ipairs({ "fill", "stroke", "color" }) do
        for value in lower:gmatch(attribute .. '%s*=%s*"([^"]*)"') do
            if not isMonochromeSvgColor(value) then return false end
        end
        for value in lower:gmatch(attribute .. "%s*=%s*'([^']*)'") do
            if not isMonochromeSvgColor(value) then return false end
        end
        for value in lower:gmatch(attribute .. [[%s*:%s*([^;"']+)]]) do
            if not isMonochromeSvgColor(value) then return false end
        end
    end
    return true
end

local function isEligibleImage(content, media, cooperate)
    if media == "image/svg+xml" then
        return svgHasOnlyMonochromeColors(content)
            and recolorSvg(content, PALETTES["pure-light"]) ~= nil
    end
    if media ~= "image/png" and media ~= "image/jpeg" then
        return false
    end
    if #content > MAX_COMPRESSED_BYTES then return false end

    local ok, bb = pcall(
        RenderImage.renderImageDataWithMupdf,
        RenderImage,
        content,
        #content
    )
    if not ok or not bb then return false end

    local eligible = isSmallMonochromeRaster(bb, cooperate)
    pcall(bb.free, bb)
    return eligible
end

local function inspectImpl(sourcePath, cooperate)
    local reader = Archiver.Reader:new()
    if not reader:open(sourcePath) then
        return nil, "Could not open source EPUB."
    end

    local indexed = 0
    for _ in reader:iterate() do
        indexed = indexed + 1
        if cooperate and indexed % 24 == 0 then cooperate() end
    end

    local container = reader:extractToMemory("META-INF/container.xml")
    local opfPath = containerRootfile(container)
    if not opfPath then
        closeQuietly(reader)
        return nil, "EPUB package document was not found."
    end
    opfPath = normalizePath(opfPath)

    local opf = reader:extractToMemory(opfPath)
    if not opf then
        closeQuietly(reader)
        return nil, "EPUB package document could not be read."
    end

    local assets = imageAssets(opf, opfPath)
    local image_count = 0
    local eligible_count = 0

    for path, image in pairs(assets) do
        image_count = image_count + 1
        if image.supported then
            local content = reader:extractToMemory(path)
            if content ~= nil then
                if cooperate then
                    if isEligibleImage(content, image.media, cooperate) then
                        eligible_count = eligible_count + 1
                    end
                else
                    local ok, eligible = pcall(isEligibleImage, content, image.media, nil)
                    if ok and eligible then eligible_count = eligible_count + 1 end
                end
            end
        end
        if cooperate then cooperate() end
    end

    closeQuietly(reader)
    return {
        image_count = image_count,
        eligible_count = eligible_count,
        all_eligible = image_count > 0 and eligible_count == image_count,
    }
end

function Epub.inspect(sourcePath)
    return inspectImpl(sourcePath, nil)
end

function Epub.peekProfile(sourcePath)
    local directory = Epub.cacheDirectory()
    if not ensureDir(directory) then return nil end
    return readProfile(profilePath(sourcePath))
end

function Epub.inspectCached(sourcePath)
    local directory = Epub.cacheDirectory()
    if not ensureDir(directory) then
        return nil, "Could not create Burrow's decorative EPUB cache."
    end

    local path = profilePath(sourcePath)
    local cached = readProfile(path)
    if cached then return cached end

    local profile, err = Epub.inspect(sourcePath)
    if profile then writeProfile(path, profile) end
    return profile, err
end

local function generateImpl(sourcePath, targetPath, paletteName, cooperate)
    local palette = paletteFor(paletteName)
    if not palette then
        return false, "Unknown decorative EPUB palette: " .. tostring(paletteName)
    end

    local reader = Archiver.Reader:new()
    if not reader:open(sourcePath) then
        return false, "Could not open source EPUB."
    end

    -- Populate KOReader Archiver's entry lookup table. Yield periodically in
    -- cooperative mode so even large EPUB manifests do not monopolize the UI.
    local indexed = 0
    for _ in reader:iterate() do
        indexed = indexed + 1
        if cooperate and indexed % 24 == 0 then cooperate() end
    end

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
    -- Shadow EPUBs are disposable caches. Store entries without recompressing
    -- them so first-open processing is limited mostly to archive I/O and the
    -- handful of ornament transforms instead of spending CPU deflating every
    -- unchanged book resource.
    writer:setZipCompression("store")

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
                -- Raster transforms run the conservative monochrome detector
                -- internally. SVGs need one extra gate because recolorSvg()
                -- intentionally rewrites only recognized gray tokens; without
                -- this check a mixed-color SVG could otherwise be changed only
                -- in part. Leave any such artwork byte-for-byte untouched.
                local safe_svg = media ~= "image/svg+xml"
                    or svgHasOnlyMonochromeColors(content)
                if safe_svg then
                    local transformed
                    if cooperate then
                        transformed = transformImage(
                            content,
                            media,
                            tempImageBase,
                            palette,
                            cooperate
                        )
                    else
                        local ok, value = pcall(
                            transformImage,
                            content,
                            media,
                            tempImageBase,
                            palette,
                            nil
                        )
                        if ok then
                            transformed = value
                        else
                            logger.warn("[Burrow ornaments] Ornament transform failed", entry.path, value)
                        end
                    end
                    if transformed then
                        content = transformed
                        recolored = recolored + 1
                        logger.dbg("[Burrow ornaments] Normalized decorative EPUB image", entry.path)
                    end
                end
            end

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
        return false, "Could not finalize decorative EPUB cache: " .. tostring(err)
    end

    logger.info("[Burrow ornaments] Built explicit ornament palette cache", paletteName, recolored)
    return true, recolored
end

local function generateHotImpl(sourcePath, targetPath, paletteName, progress, radius, cooperate)
    local palette = paletteFor(paletteName)
    if not palette then
        return false, "Unknown decorative EPUB palette: " .. tostring(paletteName), nil
    end

    local reader = Archiver.Reader:new()
    if not reader:open(sourcePath) then
        return false, "Could not open source EPUB.", nil
    end

    local indexed = 0
    for _ in reader:iterate() do
        indexed = indexed + 1
        if cooperate and indexed % 24 == 0 then cooperate() end
    end

    local container = reader:extractToMemory("META-INF/container.xml")
    local opfPath = containerRootfile(container)
    if not opfPath then
        closeQuietly(reader)
        return false, "EPUB package document was not found.", nil
    end
    opfPath = normalizePath(opfPath)

    local opf = reader:extractToMemory(opfPath)
    if not opf then
        closeQuietly(reader)
        return false, "EPUB package document could not be read.", nil
    end

    local imageSet = imageDocuments(opf, opfPath)
    local hotImages, meta = hotWindow(
        reader,
        opf,
        opfPath,
        imageSet,
        progress,
        radius,
        cooperate
    )

    -- Do the expensive image analysis/conversion in reading order before the
    -- cheap whole-archive copy. This makes the current section and nearby
    -- sections the first ornament work Burrow performs.
    local transformedHot = {}
    local recolored = 0
    local tempImageBase = targetPath .. ".ornament.tmp"
    os.remove(tempImageBase .. ".png")
    os.remove(tempImageBase .. ".jpg")

    for _, imagePath in ipairs(meta.ordered_images or {}) do
        local media = imageSet[imagePath]
        if media and hotImages[imagePath] then
            local content = reader:extractToMemory(imagePath)
            if content then
                local safe_svg = media ~= "image/svg+xml"
                    or svgHasOnlyMonochromeColors(content)
                if safe_svg then
                    local transformed
                    if cooperate then
                        transformed = transformImage(
                            content,
                            media,
                            tempImageBase,
                            palette,
                            cooperate
                        )
                    else
                        local ok, value = pcall(
                            transformImage,
                            content,
                            media,
                            tempImageBase,
                            palette,
                            nil
                        )
                        if ok then transformed = value end
                    end
                    if transformed then
                        transformedHot[imagePath] = transformed
                        recolored = recolored + 1
                        logger.dbg(
                            "[Burrow ornaments] Prepared nearby ornament first",
                            imagePath,
                            meta.center,
                            meta.total_spine
                        )
                    end
                end
            end
        end
        if cooperate then cooperate() end
    end

    if recolored == 0 then
        closeQuietly(reader)
        os.remove(tempImageBase .. ".png")
        os.remove(tempImageBase .. ".jpg")
        return true, 0, meta
    end

    local tempPath = targetPath .. ".tmp"
    os.remove(tempPath)
    local writer = Archiver.Writer:new()
    if not writer:open(tempPath, "epub") then
        closeQuietly(reader)
        return false, "Could not create nearby decorative EPUB cache.", meta
    end

    local mtime = os.time()
    writer:setZipCompression("store")
    if not writer:addFileFromMemory("mimetype", "application/epub+zip", mtime) then
        closeQuietly(writer)
        closeQuietly(reader)
        os.remove(tempPath)
        return false, "Could not write EPUB mimetype.", meta
    end
    writer:setZipCompression("store")

    for entry in reader:iterate() do
        if entry.mode == "file" and entry.path ~= "mimetype" then
            local normalized = normalizePath(entry.path)
            local content = transformedHot[normalized]
                or reader:extractToMemory(entry.path)
            if content == nil then
                closeQuietly(writer)
                closeQuietly(reader)
                os.remove(tempPath)
                return false, "Could not read EPUB entry: " .. tostring(entry.path), meta
            end
            if not writer:addFileFromMemory(entry.path, content, mtime) then
                closeQuietly(writer)
                closeQuietly(reader)
                os.remove(tempPath)
                return false, "Could not write EPUB entry: " .. tostring(entry.path), meta
            end
            if cooperate then cooperate() end
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
        return false, "Could not finalize nearby decorative EPUB cache: " .. tostring(err), meta
    end

    logger.info(
        "[Burrow ornaments] Built nearby spine-priority cache",
        paletteName,
        recolored,
        meta.center,
        meta.total_spine
    )
    return true, recolored, meta
end

function Epub.generate(sourcePath, targetPath, paletteName)
    return generateImpl(sourcePath, targetPath, paletteName, nil)
end

function Epub.cachedResult(sourcePath, paletteName)
    local target, err = Epub.cachePath(sourcePath, paletteName)
    if not target then return nil, err, nil end
    local recolored = readRecoloredCount(countPath(target))
    if recolored == nil then return nil, nil, nil end
    if recolored == 0 then return false, nil, 0 end
    if lfs.attributes(target, "mode") == "file" then
        return target, nil, recolored
    end
    return nil, nil, nil
end

function Epub.ensureCache(sourcePath, paletteName, knownProfile)
    local directory = Epub.cacheDirectory()
    if not ensureDir(directory) then
        return nil, "Could not create Burrow's decorative EPUB cache.", nil
    end

    local profile = knownProfile
    if not profile then
        profile = Epub.inspectCached(sourcePath)
    end
    if profile and tonumber(profile.eligible_count) == 0 then
        return nil, nil, 0
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
        -- A completed Burrow ornament cache always has a count marker. If it is missing,
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


local function scheduleCoroutine(job_table, key, co, callback)
    local UIManager = require("ui/uimanager")
    local existing = job_table[key]
    if existing then
        existing.callbacks[#existing.callbacks + 1] = callback
        return existing
    end

    local job = { callbacks = { callback } }
    job_table[key] = job

    local function finish(a, b, c, d)
        if job_table[key] == job then job_table[key] = nil end
        local callbacks = job.callbacks
        job.callbacks = {}
        for _, cb in ipairs(callbacks) do
            if type(cb) == "function" then
                local ok, err = pcall(cb, a, b, c, d)
                if not ok then logger.warn("[Burrow ornaments] Async callback failed", err) end
            end
        end
    end

    local function step()
        if job_table[key] ~= job then return end
        local ok, a, b, c, d = coroutine.resume(co)
        if not ok then
            finish(nil, tostring(a), nil)
            return
        end
        if coroutine.status(co) == "dead" then
            finish(a, b, c, d)
            return
        end
        UIManager:scheduleIn(ASYNC_INTERVAL, step)
    end

    UIManager:nextTick(step)
    return job
end

function Epub.inspectAsync(sourcePath, callback)
    local cached = Epub.peekProfile(sourcePath)
    if cached then
        local UIManager = require("ui/uimanager")
        UIManager:nextTick(function() callback(cached, nil) end)
        return { completed = true }
    end

    local key = profilePath(sourcePath) or sourcePath
    local co = coroutine.create(function()
        local function cooperate() coroutine.yield() end
        local profile, err = inspectImpl(sourcePath, cooperate)
        if profile then writeProfile(profilePath(sourcePath), profile) end
        return profile, err
    end)
    return scheduleCoroutine(ASYNC_PROFILE_JOBS, key, co, callback)
end

function Epub.ensureCacheAsync(sourcePath, paletteName, knownProfile, callback)
    local directory = Epub.cacheDirectory()
    if not ensureDir(directory) then
        local UIManager = require("ui/uimanager")
        UIManager:nextTick(function()
            callback(nil, "Could not create Burrow's decorative EPUB cache.", nil)
        end)
        return { completed = true }
    end

    local cached, cachedErr, cachedCount = Epub.cachedResult(sourcePath, paletteName)
    if cached ~= nil or cachedCount == 0 then
        local UIManager = require("ui/uimanager")
        UIManager:nextTick(function() callback(cached or nil, cachedErr, cachedCount) end)
        return { completed = true }
    end

    local profile = knownProfile
    if profile and tonumber(profile.eligible_count) == 0 then
        local UIManager = require("ui/uimanager")
        UIManager:nextTick(function() callback(nil, nil, 0) end)
        return { completed = true }
    end

    local target, err = Epub.cachePath(sourcePath, paletteName)
    if not target then
        local UIManager = require("ui/uimanager")
        UIManager:nextTick(function() callback(nil, err, nil) end)
        return { completed = true }
    end

    local key = target
    local co = coroutine.create(function()
        local function cooperate() coroutine.yield() end
        local ok, result = generateImpl(sourcePath, target, paletteName, cooperate)
        if not ok then
            os.remove(target)
            os.remove(countPath(target))
            return nil, result, nil
        end
        local recolored = tonumber(result) or 0
        writeRecoloredCount(countPath(target), recolored)
        if recolored == 0 then
            os.remove(target)
            return nil, nil, 0
        end
        return target, nil, recolored
    end)
    return scheduleCoroutine(ASYNC_CACHE_JOBS, key, co, callback)
end

function Epub.ensureHotCacheAsync(sourcePath, paletteName, progress, radius, callback)
    local directory = Epub.cacheDirectory()
    if not ensureDir(directory) then
        local UIManager = require("ui/uimanager")
        UIManager:nextTick(function()
            callback(nil, "Could not create Burrow's nearby EPUB cache.", nil, nil)
        end)
        return { completed = true }
    end

    progress = clampProgress(progress)
    radius = math.max(0, tonumber(radius) or 2)
    local target, err = Epub.hotCachePath(sourcePath, paletteName, progress, radius)
    if not target then
        local UIManager = require("ui/uimanager")
        UIManager:nextTick(function() callback(nil, err, nil, nil) end)
        return { completed = true }
    end

    local recolored = readRecoloredCount(countPath(target))
    if recolored ~= nil then
        local meta = readHotMeta(hotMetaPath(target))
        if recolored == 0 then
            local UIManager = require("ui/uimanager")
            UIManager:nextTick(function() callback(nil, nil, 0, meta) end)
            return { completed = true }
        end
        if lfs.attributes(target, "mode") == "file" then
            local UIManager = require("ui/uimanager")
            UIManager:nextTick(function() callback(target, nil, recolored, meta) end)
            return { completed = true }
        end
        os.remove(countPath(target))
        os.remove(hotMetaPath(target))
    elseif lfs.attributes(target, "mode") == "file" then
        os.remove(target)
        os.remove(hotMetaPath(target))
    end

    local key = target
    local co = coroutine.create(function()
        local function cooperate() coroutine.yield() end
        local ok, result, meta = generateHotImpl(
            sourcePath,
            target,
            paletteName,
            progress,
            radius,
            cooperate
        )
        if not ok then
            os.remove(target)
            os.remove(countPath(target))
            os.remove(hotMetaPath(target))
            return nil, result, nil, meta
        end

        local count = tonumber(result) or 0
        writeRecoloredCount(countPath(target), count)
        if meta then writeHotMeta(hotMetaPath(target), meta) end
        if count == 0 then
            os.remove(target)
            return nil, nil, 0, meta
        end
        return target, nil, count, meta
    end)
    return scheduleCoroutine(ASYNC_HOT_CACHE_JOBS, key, co, callback)
end

return Epub

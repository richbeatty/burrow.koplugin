from pathlib import Path

def replace_once(text, old, new, label):
    count = text.count(old)
    assert count == 1, f"{label}: expected 1 match, found {count}"
    return text.replace(old, new, 1)

# 1. Split ornament handling out of the optional soft-palette module.
p = Path('plugins/burrow.koplugin/internal_patches/2-soft-palette.lua')
s = p.read_text(encoding='utf-8')
s = replace_once(
    s,
    '    local SoftPaletteEpub = require("burrow_soft_palette_epub")\n',
    '',
    'remove soft ornament require',
)
s = replace_once(
    s,
    '    local ORNAMENT_SETTING = "burrow_soft_palette_recolor_ornaments"\n',
    '',
    'remove soft ornament setting',
)
s = replace_once(
    s,
    '    local function isEpub(path)\n        return type(path) == "string" and path:lower():match("%.epub$") ~= nil\n    end\n\n',
    '',
    'remove EPUB helper',
)
ornament_comment = """    -- Optional Kindle-like treatment for small monochrome EPUB artwork. Rather
    -- than recoloring CRengine's final framebuffer, build a cached shadow EPUB
    -- where only conservative ornament candidates have #000/#FFF mapped to the
    -- same #202020/#F2F2F0 palette as the page. Large and colored images remain
    -- byte-for-byte original. The reader-context marker prevents file-browser
    -- cover and metadata probes from ever being redirected through this cache.
"""
s = replace_once(s, ornament_comment, '', 'remove old ornament comment')
start_marker = '    if not CreDocument._burrow_soft_palette_ornament_loader_v1 then\n'
end_marker = '    if not CreDocument._burrow_soft_palette_v5 then\n'
assert s.count(start_marker) == 1 and s.count(end_marker) == 1
start = s.index(start_marker)
end = s.index(end_marker, start)
s = s[:start] + s[end:]
assert 'SoftPaletteEpub' not in s
assert 'ORNAMENT_SETTING' not in s
assert '_burrow_soft_palette_ornament_loader_v1' not in s
p.write_text(s, encoding='utf-8')

# 2. Generalize the existing conservative EPUB transformer to four
#    source palettes: pure/soft x light/night.
p = Path('plugins/burrow.koplugin/burrow_soft_palette_epub.lua')
s = p.read_text(encoding='utf-8')
s = replace_once(
    s,
    '''local Epub = {\n    CACHE_VERSION = "ornaments-v1-f2f2f0-202020",\n}\n\nlocal BLACK_R, BLACK_G, BLACK_B = 0x20, 0x20, 0x20\nlocal WHITE_R, WHITE_G, WHITE_B = 0xF2, 0xF2, 0xF0\n''',
    '''local Epub = {\n    CACHE_VERSION = "ornaments-v2-selective-night",\n}\n\nlocal PALETTES = {\n    ["pure-light"] = {\n        dark = { 0x00, 0x00, 0x00 },\n        light = { 0xFF, 0xFF, 0xFF },\n    },\n    ["pure-night"] = {\n        dark = { 0xFF, 0xFF, 0xFF },\n        light = { 0x00, 0x00, 0x00 },\n    },\n    ["soft-light"] = {\n        dark = { 0x20, 0x20, 0x20 },\n        light = { 0xF2, 0xF2, 0xF0 },\n    },\n    ["soft-night"] = {\n        dark = { 0xDF, 0xDF, 0xDF },\n        light = { 0x0D, 0x0D, 0x0F },\n    },\n}\n''',
    'palette header',
)
s = replace_once(
    s,
    '''local function ensureDir(path)\n    if lfs.attributes(path, "mode") == "directory" then return true end\n    local ok = lfs.mkdir(path)\n    return ok or lfs.attributes(path, "mode") == "directory"\nend\n\nfunction Epub.cacheDirectory()\n''',
    '''local function ensureDir(path)\n    if lfs.attributes(path, "mode") == "directory" then return true end\n    local ok = lfs.mkdir(path)\n    return ok or lfs.attributes(path, "mode") == "directory"\nend\n\nlocal function paletteFor(name)\n    return PALETTES[name]\nend\n\nfunction Epub.cacheDirectory()\n''',
    'palette lookup',
)
s = replace_once(s, 'function Epub.cachePath(source)\n', 'function Epub.cachePath(source, paletteName)\n', 'cache signature')
s = replace_once(
    s,
    '''function Epub.cachePath(source, paletteName)\n    local checksum = util.partialMD5(source)\n''',
    '''function Epub.cachePath(source, paletteName)\n    if not paletteFor(paletteName) then\n        return nil, "Unknown decorative EPUB palette: " .. tostring(paletteName)\n    end\n\n    local checksum = util.partialMD5(source)\n''',
    'cache palette guard',
)
s = replace_once(
    s,
    '''        Epub.CACHE_VERSION,\n    }, "-")\n''',
    '''        Epub.CACHE_VERSION,\n        paletteName,\n    }, "-")\n''',
    'cache palette identity',
)
marker = '''    return Epub.cacheDirectory() .. "/" .. identity .. ".epub"\nend\n\nlocal function visibleChannel(channel, alpha)\n'''
insert = '''    return Epub.cacheDirectory() .. "/" .. identity .. ".epub"\nend\n\nlocal function countPath(targetPath)\n    return targetPath .. ".count"\nend\n\nlocal function readRecoloredCount(path)\n    local file = io.open(path, "r")\n    if not file then return nil end\n    local value = tonumber(file:read("*l"))\n    file:close()\n    if not value or value < 0 then return nil end\n    return math.floor(value)\nend\n\nlocal function writeRecoloredCount(path, count)\n    local file = io.open(path, "w")\n    if not file then return false end\n    file:write(tostring(count), "\\n")\n    file:close()\n    return true\nend\n\nlocal function visibleChannel(channel, alpha)\n'''
s = replace_once(s, marker, insert, 'count cache helpers')
s = replace_once(
    s,
    '''local function remapChannel(luma, target_white)\n    return math.floor(BLACK_R + (luma * (target_white - BLACK_R) + 127) / 255)\nend\n''',
    '''local function remapChannel(luma, darkTarget, lightTarget)\n    local value = darkTarget + luma * (lightTarget - darkTarget) / 255\n    return math.floor(value + 0.5)\nend\n''',
    'channel remap',
)
s = replace_once(s, 'local function recolorRaster(content, media, tempBase)\n', 'local function recolorRaster(content, media, tempBase, palette)\n', 'raster signature')
s = replace_once(
    s,
    '''            local rr = remapChannel(luma, WHITE_R)\n            local gg = remapChannel(luma, WHITE_G)\n            local bbv = remapChannel(luma, WHITE_B)\n''',
    '''            local rr = remapChannel(luma, palette.dark[1], palette.light[1])\n            local gg = remapChannel(luma, palette.dark[2], palette.light[2])\n            local bbv = remapChannel(luma, palette.dark[3], palette.light[3])\n''',
    'raster palette mapping',
)
s = replace_once(
    s,
    '''local function remapGrayValue(value)\n    local r = remapChannel(value, WHITE_R)\n    local g = remapChannel(value, WHITE_G)\n    local b = remapChannel(value, WHITE_B)\n    return string.format("#%02x%02x%02x", r, g, b)\nend\n\nlocal function recolorSvg(content)\n''',
    '''local function remapGrayValue(value, palette)\n    local r = remapChannel(value, palette.dark[1], palette.light[1])\n    local g = remapChannel(value, palette.dark[2], palette.light[2])\n    local b = remapChannel(value, palette.dark[3], palette.light[3])\n    return string.format("#%02x%02x%02x", r, g, b)\nend\n\nlocal function paletteEndpoint(rgb)\n    return string.format("#%02x%02x%02x", rgb[1], rgb[2], rgb[3])\nend\n\nlocal function recolorSvg(content, palette)\n''',
    'SVG palette helpers',
)
s = replace_once(s, '            return remapGrayValue(value)\n', '            return remapGrayValue(value, palette)\n', 'SVG gray mapping')
s = replace_once(
    s,
    '''            local rr = remapChannel(r, WHITE_R)\n            local gg = remapChannel(r, WHITE_G)\n            local bbv = remapChannel(r, WHITE_B)\n''',
    '''            local rr = remapChannel(r, palette.dark[1], palette.light[1])\n            local gg = remapChannel(r, palette.dark[2], palette.light[2])\n            local bbv = remapChannel(r, palette.dark[3], palette.light[3])\n''',
    'SVG rgb mapping',
)
s = replace_once(s, '        return pre .. "#202020" .. post\n', '        return pre .. paletteEndpoint(palette.dark) .. post\n', 'SVG black endpoint')
s = replace_once(s, '        return pre .. "#f2f2f0" .. post\n', '        return pre .. paletteEndpoint(palette.light) .. post\n', 'SVG white endpoint')
s = replace_once(
    s,
    '''local function transformImage(content, media, tempBase)\n    if media == "image/svg+xml" then\n        return recolorSvg(content)\n    end\n    return recolorRaster(content, media, tempBase)\nend\n\nfunction Epub.generate(sourcePath, targetPath)\n''',
    '''local function transformImage(content, media, tempBase, palette)\n    if media == "image/svg+xml" then\n        return recolorSvg(content, palette)\n    end\n    return recolorRaster(content, media, tempBase, palette)\nend\n\nfunction Epub.generate(sourcePath, targetPath, paletteName)\n    local palette = paletteFor(paletteName)\n    if not palette then\n        return false, "Unknown decorative EPUB palette: " .. tostring(paletteName)\n    end\n\n''',
    'transform and generate signatures',
)
s = replace_once(s, '        return false, "Could not create soft-palette EPUB cache."\n', '        return false, "Could not create decorative EPUB cache."\n', 'writer error')
s = replace_once(
    s,
    '                local ok, transformed = pcall(transformImage, content, media, tempImageBase)\n',
    '''                local ok, transformed = pcall(\n                    transformImage,\n                    content,\n                    media,\n                    tempImageBase,\n                    palette\n                )\n''',
    'transform invocation',
)
s = replace_once(
    s,
    '[Burrow palette] Recolored decorative EPUB image',
    '[Burrow ornaments] Adjusted decorative EPUB image',
    'recolor log prefix',
)
s = replace_once(
    s,
    '[Burrow palette] Ornament transform failed',
    '[Burrow ornaments] Ornament transform failed',
    'transform failure log prefix',
)
s = replace_once(
    s,
    '''    closeQuietly(writer)\n    closeQuietly(reader)\n    os.remove(tempImageBase .. ".png")\n    os.remove(tempImageBase .. ".jpg")\n\n    os.remove(targetPath)\n''',
    '''    closeQuietly(writer)\n    closeQuietly(reader)\n    os.remove(tempImageBase .. ".png")\n    os.remove(tempImageBase .. ".jpg")\n\n    if recolored == 0 then\n        os.remove(tempPath)\n        logger.dbg("[Burrow ornaments] No eligible decorative EPUB images found")\n        return true, 0\n    end\n\n    os.remove(targetPath)\n''',
    'zero-match handling',
)
s = replace_once(
    s,
    '''    logger.info("[Burrow palette] Built EPUB ornament cache", recolored)\n    return true\nend\n\nfunction Epub.ensureCache(sourcePath)\n''',
    '''    logger.info("[Burrow ornaments] Built EPUB ornament cache", paletteName, recolored)\n    return true, recolored\nend\n\nfunction Epub.ensureCache(sourcePath, paletteName)\n''',
    'generate return and ensure signature',
)
ensure_start = s.index('function Epub.ensureCache(sourcePath, paletteName)\n')
ensure_end = s.index('\nreturn Epub\n', ensure_start)
new_ensure = '''function Epub.ensureCache(sourcePath, paletteName)\n    local directory = Epub.cacheDirectory()\n    if not ensureDir(directory) then\n        return nil, "Could not create Burrow's decorative EPUB cache.", nil\n    end\n\n    local target, err = Epub.cachePath(sourcePath, paletteName)\n    if not target then return nil, err, nil end\n\n    local countFile = countPath(target)\n    local recolored = readRecoloredCount(countFile)\n    if recolored ~= nil then\n        if recolored == 0 then\n            return nil, nil, 0\n        end\n        if lfs.attributes(target, "mode") == "file" then\n            return target, nil, recolored\n        end\n        os.remove(countFile)\n    elseif lfs.attributes(target, "mode") == "file" then\n        -- A completed v2 cache always has a count marker. If it is missing,\n        -- rebuild rather than trusting a potentially interrupted cache write.\n        os.remove(target)\n    end\n\n    local ok, result = Epub.generate(sourcePath, target, paletteName)\n    if not ok then\n        os.remove(target)\n        os.remove(countFile)\n        return nil, result, nil\n    end\n\n    recolored = tonumber(result) or 0\n    writeRecoloredCount(countFile, recolored)\n    if recolored == 0 then\n        os.remove(target)\n        return nil, nil, 0\n    end\n    return target, nil, recolored\nend\n'''
s = s[:ensure_start] + new_ensure + s[ensure_end:]
# Conservative candidate detection and cover exclusion must remain.
for required in [
    'local MAX_RASTER_PIXELS = 220000',
    'local MAX_RASTER_DIMENSION = 1400',
    'local MAX_COMPRESSED_BYTES = 2 * 1024 * 1024',
    'local SAMPLE_TARGET = 6000',
    'local MAX_CHROMA = 18',
    'local MAX_COLORED_SAMPLE_FRACTION = 0.02',
    'local MIN_EXTREME_SAMPLE_FRACTION = 0.82',
    'local MIN_LIGHT_SAMPLE_FRACTION = 0.20',
    'local MIN_DARK_SAMPLE_FRACTION = 0.002',
    'properties:find("cover%-image")',
    'path:lower():find("cover", 1, true)',
    'lower:find("<image", 1, true)',
    'lower:find("lineargradient", 1, true)',
    'lower:find("radialgradient", 1, true)',
    'lower:find("<filter", 1, true)',
    'lower:find("<pattern", 1, true)',
    'if paths > 80 then return nil end',
]:
    assert required in s, required
p.write_text(s, encoding='utf-8')

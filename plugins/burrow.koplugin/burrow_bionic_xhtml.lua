local util = require("util")

local Transformer = {}

Transformer.RATIO_PERCENT = 45
Transformer.MIN_PREFIX = 1
Transformer.MAX_PREFIX = 9

local OPAQUE = {
    script = true, style = true, head = true, title = true,
    svg = true, math = true, code = true, pre = true,
    kbd = true, samp = true, var = true, tt = true,
    b = true, strong = true,
}

local RAW_TEXT = { script = true, style = true }

local function utf8Codepoint(ch)
    local b1, b2, b3, b4 = ch:byte(1, 4)
    if not b1 then return nil end
    if b1 < 0x80 then
        return b1
    elseif b1 < 0xE0 and b2 then
        return (b1 - 0xC0) * 0x40 + (b2 - 0x80)
    elseif b1 < 0xF0 and b2 and b3 then
        return (b1 - 0xE0) * 0x1000 + (b2 - 0x80) * 0x40 + (b3 - 0x80)
    elseif b2 and b3 and b4 then
        return (b1 - 0xF0) * 0x40000
            + (b2 - 0x80) * 0x1000
            + (b3 - 0x80) * 0x40
            + (b4 - 0x80)
    end
    return b1
end

local function isWordChar(ch)
    local cp = utf8Codepoint(ch)
    if not cp then return false end
    if cp < 128 then
        local lower = cp
        if lower >= 65 and lower <= 90 then lower = lower + 32 end
        return (lower >= 97 and lower <= 122) or cp == 39
    end
    if cp >= 0x2000 and cp <= 0x2BFF then
        return cp == 0x2018 or cp == 0x2019
    end
    if cp >= 0x00A1 and cp <= 0x00BF then
        return cp == 0x00AA or cp == 0x00B5 or cp == 0x00BA
    end
    if cp >= 0x2E00 and cp <= 0x2E7F then return false end
    if cp == 0x02D7 or cp == 0xFE63 or cp == 0xFF0D then return false end
    return true
end

local function bionicizeText(text)
    if not text or text == "" then return text end
    local chars = util.splitToChars(text)
    local out = {}
    local i = 1
    while i <= #chars do
        if chars[i] == "&" then
            local entity = { chars[i] }
            i = i + 1
            local guard = 0
            while i <= #chars and guard < 16 do
                entity[#entity + 1] = chars[i]
                local done = chars[i] == ";"
                i = i + 1
                guard = guard + 1
                if done then break end
            end
            out[#out + 1] = table.concat(entity)
        elseif not isWordChar(chars[i]) then
            out[#out + 1] = chars[i]
            i = i + 1
        else
            local first = i
            while i <= #chars and chars[i] ~= "&" and isWordChar(chars[i]) do
                i = i + 1
            end
            local count = i - first
            local prefixCount = math.floor(count * Transformer.RATIO_PERCENT / 100)
            if prefixCount < Transformer.MIN_PREFIX then
                prefixCount = Transformer.MIN_PREFIX
            elseif prefixCount > Transformer.MAX_PREFIX then
                prefixCount = Transformer.MAX_PREFIX
            end
            if prefixCount > count then prefixCount = count end
            local prefix = table.concat(chars, "", first, first + prefixCount - 1)
            local suffix = ""
            if prefixCount < count then
                suffix = table.concat(chars, "", first + prefixCount, i - 1)
            end
            out[#out + 1] = '<b class="burrow-bionic">' .. prefix .. '</b>' .. suffix
        end
    end
    return table.concat(out)
end

local function findTagEnd(source, startPos)
    local quote
    local i = startPos + 1
    while i <= #source do
        local c = source:sub(i, i)
        if quote then
            if c == quote then quote = nil end
        elseif c == '"' or c == "'" then
            quote = c
        elseif c == ">" then
            return i
        end
        i = i + 1
    end
    return #source
end

local function tagInfo(tag)
    local closing = tag:sub(2, 2) == "/"
    local offset = closing and 3 or 2
    local name = tag:sub(offset):match("^%s*([%w:_%-]+)")
    if name then name = name:lower() end
    local selfClosing = tag:match("/%s*>$") ~= nil
    return name, closing, selfClosing
end

function Transformer.process(source)
    if not source or source == "" then return source end
    local out = {}
    local text = {}
    local stack = {}
    local opaqueDepth = 0
    local i = 1
    local lowerSource

    local function flushText()
        if #text == 0 then return end
        local chunk = table.concat(text)
        text = {}
        if opaqueDepth > 0 then
            out[#out + 1] = chunk
        else
            out[#out + 1] = bionicizeText(chunk)
        end
    end

    while i <= #source do
        if source:sub(i, i) ~= "<" then
            text[#text + 1] = source:sub(i, i)
            i = i + 1
        else
            flushText()
            if source:sub(i, i + 3) == "<!--" then
                local close = source:find("-->", i + 4, true)
                if not close then out[#out + 1] = source:sub(i); break end
                out[#out + 1] = source:sub(i, close + 2)
                i = close + 3
            elseif source:sub(i, i + 8) == "<![CDATA[" then
                local close = source:find("]]>", i + 9, true)
                if not close then out[#out + 1] = source:sub(i); break end
                out[#out + 1] = source:sub(i, close + 2)
                i = close + 3
            elseif source:sub(i, i + 1) == "<?" then
                local close = source:find("?>", i + 2, true)
                if not close then out[#out + 1] = source:sub(i); break end
                out[#out + 1] = source:sub(i, close + 1)
                i = close + 2
            elseif source:sub(i, i + 1) == "<!" then
                local close = source:find(">", i + 2, true) or #source
                out[#out + 1] = source:sub(i, close)
                i = close + 1
            else
                local close = findTagEnd(source, i)
                local tag = source:sub(i, close)
                local name, isClose, selfClosing = tagInfo(tag)
                out[#out + 1] = tag
                if name and not selfClosing then
                    if isClose then
                        for index = #stack, 1, -1 do
                            if stack[index].name == name then
                                if stack[index].opaque then
                                    opaqueDepth = math.max(0, opaqueDepth - 1)
                                end
                                table.remove(stack, index)
                                break
                            end
                        end
                    else
                        local opaque = OPAQUE[name] == true
                        stack[#stack + 1] = { name = name, opaque = opaque }
                        if opaque then opaqueDepth = opaqueDepth + 1 end
                    end
                end
                i = close + 1
                if name and RAW_TEXT[name] and not isClose and not selfClosing then
                    lowerSource = lowerSource or source:lower()
                    local rawClose = lowerSource:find("</" .. name, i, true)
                    if rawClose then
                        out[#out + 1] = source:sub(i, rawClose - 1)
                        i = rawClose
                    else
                        out[#out + 1] = source:sub(i)
                        break
                    end
                end
            end
        end
    end
    flushText()
    return table.concat(out)
end

return Transformer

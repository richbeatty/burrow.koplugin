-- Centralized KOReader compatibility policy for Burrow.

local Version = require("version")
local BurrowVersion = require("burrow_version")

local Compatibility = {}

local function inKnownBadRange(current)
    for _, range in ipairs(BurrowVersion.KNOWN_INCOMPATIBLE_KOREADER or {}) do
        local first = tonumber(range.first or range.min)
        local last = tonumber(range.last or range.max or first)
        if first and last and current >= first and current <= last then
            return range
        end
    end
end

function Compatibility:evaluate(skip_check)
    local current, commit = Version:getNormalizedCurrentVersion()
    local short = Version:getShortVersion() or "unknown"
    local result = {
        current = current,
        commit = commit,
        short = short,
        minimum = BurrowVersion.MIN_KOREADER_NORMALIZED,
        last_tested = BurrowVersion.LAST_TESTED_KOREADER_NORMALIZED,
        allowed = false,
        level = "blocked",
        warning = nil,
        reason = nil,
    }

    if skip_check then
        result.allowed = true
        result.level = "override"
        result.warning = "KOReader compatibility checking has been manually bypassed."
        return result
    end

    if type(current) ~= "number" or current == 0 then
        result.reason = "Burrow could not determine the installed KOReader version."
        return result
    end

    local bad_range = inKnownBadRange(current)
    if bad_range then
        result.reason = bad_range.reason
            or "This KOReader build is known to be incompatible with Burrow."
        result.level = "known_incompatible"
        return result
    end

    if current < BurrowVersion.MIN_KOREADER_NORMALIZED then
        result.reason = string.format(
            "Burrow requires KOReader %s or newer. Installed version: %s.",
            BurrowVersion.MIN_KOREADER,
            short
        )
        result.level = "too_old"
        return result
    end

    result.allowed = true
    if current > BurrowVersion.LAST_TESTED_KOREADER_NORMALIZED then
        result.level = "untested_newer"
        result.warning = string.format(
            "KOReader %s is newer than Burrow's last tested release (%s). Burrow will continue loading, but interface changes in newer KOReader builds may affect some features.",
            short,
            BurrowVersion.LAST_TESTED_KOREADER
        )
    else
        result.level = "supported"
    end
    return result
end

return Compatibility

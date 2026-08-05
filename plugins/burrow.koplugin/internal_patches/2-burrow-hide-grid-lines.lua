local MODULE_KEY = "burrow.internal.2_burrow_hide_grid_lines"
local existing_module = package.loaded[MODULE_KEY]
if existing_module then return existing_module end
local Module = { key = MODULE_KEY, phase = "instance", filename = "2-burrow-hide-grid-lines.lua" }
package.loaded[MODULE_KEY] = Module

--[[
    Burrow Quiet Lines

    Hides Burrow's decorative black and gray grid/footer rules by
    changing only its line factory helpers to draw white lines of the exact
    same size. Layout, spacing, grid calculations, footer ownership, and
    widget trees are left untouched.

    Remove this file to restore Burrow's normal lines.
--]]

local logger = require("logger")

local function patchBurrowLines(plugin)
    local Blitbuffer = require("ffi/blitbuffer")
    local Size = require("ui/size")
    local burrow_util = require("burrow_util")

    if burrow_util._quiet_lines_patched then
        return
    end
    burrow_util._quiet_lines_patched = true

    -- Preserve the original helper signatures and exact line thicknesses.
    -- Only the paint color changes to the white page background.
    burrow_util.thinGrayLine = function(width)
        return burrow_util.line(width, Blitbuffer.COLOR_WHITE, Size.line.thin)
    end

    burrow_util.thinBlackLine = function(width)
        return burrow_util.line(width, Blitbuffer.COLOR_WHITE, Size.line.thin)
    end

    burrow_util.mediumBlackLine = function(width)
        return burrow_util.line(width, Blitbuffer.COLOR_WHITE, Size.line.medium)
    end

    logger.info("Burrow quiet line patch loaded")
end

Module.apply = patchBurrowLines
return Module

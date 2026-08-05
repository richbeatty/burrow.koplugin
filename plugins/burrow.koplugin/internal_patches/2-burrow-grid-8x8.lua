local MODULE_KEY = "burrow.internal.2_burrow_grid_8x8"
local existing_module = package.loaded[MODULE_KEY]
if existing_module then return existing_module end
local Module = { key = MODULE_KEY, phase = "instance", filename = "2-burrow-grid-8x8.lua" }
package.loaded[MODULE_KEY] = Module

--[[
    Burrow 8 x 8 Cover Grid

    Extends Burrow's selectable Cover Grid limits from 4 columns / 4 rows
    to 8 columns / 8 rows. Portrait and landscape layouts remain independently
    configurable in Burrow's existing Items per page menu.

    This patch does not force an 8 x 8 grid. It only raises the maximum offered
    by the existing controls and by the Increase Items Per Page action.
--]]

local logger = require("logger")

local function patchBurrowGridLimits(plugin)
    local ok, burrow_util = pcall(require, "burrow_util")
    if not ok or type(burrow_util) ~= "table" or type(burrow_util.grid_defaults) ~= "table" then
        logger.warn("Burrow 8x8 grid: burrow_util.grid_defaults was not available")
        return
    end

    burrow_util.grid_defaults.max_cols = 8
    burrow_util.grid_defaults.max_rows = 8

    -- The existing Burrow menu and gesture actions read these values at
    -- runtime, so no widget replacement or active layout rebuild is needed.
    logger.info("Burrow 8x8 grid: maximum set to 8 columns and 8 rows")
end

Module.apply = patchBurrowGridLimits
return Module

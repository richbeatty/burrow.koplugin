local MODULE_KEY = "burrow.internal.2_burrow_grid_8x8"
local existing_module = package.loaded[MODULE_KEY]
if existing_module then return existing_module end
local Module = { key = MODULE_KEY, phase = "instance", filename = "2-burrow-grid-8x8.lua" }
package.loaded[MODULE_KEY] = Module

--[[
    Burrow 1 x 1 through 8 x 8 Cover Grid

    Extends Burrow's selectable Cover Grid limits to 8 columns / 8 rows while
    restoring the earlier ability to reduce either dimension to 1. This allows
    layouts such as 2 x 1, 1 x 3, 4 x 1, and other rectangular combinations.
    Portrait and landscape layouts remain independently configurable.

    This patch does not force a particular grid. It only expands the range
    offered by the existing controls and Increase/Decrease Items Per Page actions.
--]]

local logger = require("logger")

local function patchBurrowGridLimits(plugin)
    local ok, burrow_util = pcall(require, "burrow_util")
    if not ok or type(burrow_util) ~= "table" or type(burrow_util.grid_defaults) ~= "table" then
        logger.warn("Burrow grid limits: burrow_util.grid_defaults was not available")
        return
    end

    burrow_util.grid_defaults.max_cols = 8
    burrow_util.grid_defaults.max_rows = 8
    burrow_util.grid_defaults.min_cols = 1
    burrow_util.grid_defaults.min_rows = 1

    -- The existing Burrow menu and gesture actions read these values at
    -- runtime, so no widget replacement or active layout rebuild is needed.
    logger.info("Burrow grid limits: range set to 1-8 columns and 1-8 rows")
end

Module.apply = patchBurrowGridLimits
return Module

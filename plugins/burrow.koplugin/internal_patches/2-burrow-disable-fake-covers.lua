local MODULE_KEY = "burrow.internal.2_burrow_disable_fake_covers"
local existing_module = package.loaded[MODULE_KEY]
if existing_module then return existing_module end
local Module = { key = MODULE_KEY, phase = "instance", filename = "2-burrow-disable-fake-covers.lua" }
package.loaded[MODULE_KEY] = Module

--[[
    Burrow folder-stack compatibility module.

    This patch disables fake covers from stack-view of folders with less than
    4 book covers. Only the covers which are available in this folder are shown.

    Author: Timo Leistner
    License: GNU AGPL v3
--]]


local function patchCoverBrowser(plugin)
    local burrow_util = require("burrow_util")
    local Blitbuffer = require("ffi/blitbuffer")
    local CenterContainer = require("ui/widget/container/centercontainer")
    local FrameContainer = require("ui/widget/container/framecontainer")
    local Geom = require("ui/geometry")
    local HorizontalSpan = require("ui/widget/horizontalspan")
    local Size = require("ui/size")

    local orig_create_blank_cover = burrow_util.create_blank_cover

    burrow_util.create_blank_cover = function(width, height, background_idx)
        local max_img_w = width - (Size.border.thin * 2)
        local max_img_h = height - (Size.border.thin * 2)
        return FrameContainer:new {
            width = width,
            height = height,
            radius = Size.radius.default,
            margin = 0,
            padding = 0,
            bordersize = Size.border.thin,
            color = Blitbuffer.COLOR_WHITE,
            CenterContainer:new {
                dimen = Geom:new { w = max_img_w, h = max_img_h },
                HorizontalSpan:new { width = max_img_w, height = max_img_h },
            }
        }
    end

end

Module.apply = patchCoverBrowser
return Module
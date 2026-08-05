local MODULE_KEY = "burrow.internal.2_rounded_reader_bottom_menu"
local existing_module = package.loaded[MODULE_KEY]
if existing_module then return existing_module end
local Module = { key = MODULE_KEY, phase = "early", filename = "2-rounded-reader-bottom-menu.lua" }
package.loaded[MODULE_KEY] = Module

function Module.apply()
    if Module.applied then return true end


-- Burrow safe menu-sheet rounding
--
-- Paint-only styling for KOReader's native menus.
--
-- This patch deliberately does NOT replace menu bars, tab buttons, callbacks,
-- focus layouts, gesture regions, or widget trees. It only marks the native
-- outer FrameContainer instances and changes how those specific frames paint.
--
-- TouchMenu (the top menu):
--   * no outer top/bottom border rules
--   * square top edge
--   * rounded lower corners
--
-- ConfigDialog (the in-reader bottom menu):
--   * no outer border rule
--   * rounded upper corners
--   * square lower edge at the bottom of the screen

local BD = require("ui/bidi")
local Blitbuffer = require("ffi/blitbuffer")
local ConfigDialog = require("ui/widget/configdialog")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local TouchMenu = require("ui/widget/touchmenu")

local Screen = Device.screen
local TOP_MENU_RADIUS = Screen:scaleBySize(18)
local READER_MENU_RADIUS = Screen:scaleBySize(22)

-- Install one guarded paint wrapper. Unmarked FrameContainers continue through
-- KOReader's original implementation unchanged.
if not FrameContainer._burrow_safe_menu_paint then
    FrameContainer._burrow_safe_menu_paint = true
    local original_paintTo = FrameContainer.paintTo

    local function paintMenuShape(self, bb, x, y)
        local my_size = self:getSize()
        if not self.dimen then
            self.dimen = Geom:new{
                x = x,
                y = y,
                w = my_size.w,
                h = my_size.h,
            }
        else
            self.dimen.x = x
            self.dimen.y = y
            self.dimen.w = my_size.w
            self.dimen.h = my_size.h
        end

        local container_width = self.width or my_size.w
        local container_height = self.height or my_size.h
        local radius = math.min(
            self._burrow_menu_radius or 0,
            math.floor(container_width / 2),
            math.floor(container_height / 2)
        )

        local shift_x = 0
        if BD.mirroredUILayout() and self.allow_mirroring then
            shift_x = container_width - my_size.w
        end

        if self.background then
            local paintRoundedRect = Blitbuffer.isColor8(self.background)
                and bb.paintRoundedRect
                or bb.paintRoundedRectRGB32
            paintRoundedRect(
                bb,
                x,
                y,
                container_width,
                container_height,
                self.background,
                radius
            )

            -- Start with a fully rounded rectangle, then square only the edge
            -- that should remain attached to the screen. The opposite edge
            -- keeps its corner cutouts and lets the already-painted page show.
            if radius > 0 then
                if self._burrow_round_bottom_only then
                    bb:paintRect(x, y, container_width, radius, self.background)
                elseif self._burrow_round_top_only then
                    bb:paintRect(
                        x,
                        y + container_height - radius,
                        container_width,
                        radius,
                        self.background
                    )
                end
            end
        end

        -- Preserve KOReader's native geometry. The original border width is
        -- still used as an inset for the child, but the border itself is not
        -- painted. This avoids relayout and keeps all touch regions identical.
        if self[1] then
            self[1]:paintTo(
                bb,
                x + self.margin + self.bordersize + self._padding_left + shift_x,
                y + self.margin + self.bordersize + self._padding_top
            )
        end

        if self.invert then
            bb:invertRect(
                x + self.bordersize,
                y + self.bordersize,
                container_width - 2 * self.bordersize,
                container_height - 2 * self.bordersize
            )
        end
        if self.dim then
            bb:lightenRect(
                x + self.bordersize,
                y + self.bordersize,
                container_width - 2 * self.bordersize,
                container_height - 2 * self.bordersize
            )
        end
    end

    function FrameContainer:paintTo(bb, x, y)
        if self._burrow_round_bottom_only or self._burrow_round_top_only then
            return paintMenuShape(self, bb, x, y)
        end
        return original_paintTo(self, bb, x, y)
    end
end

local function markTopMenu(menu)
    if menu and menu.menu_frame then
        menu.menu_frame._burrow_round_bottom_only = true
        menu.menu_frame._burrow_round_top_only = nil
        menu.menu_frame._burrow_menu_radius = TOP_MENU_RADIUS
    end
end

-- Wrap the final TouchMenu methods after Burrow's Quick Settings patch has
-- loaded. We only attach paint flags to the existing native frame.
if not TouchMenu._burrow_safe_sheet_rounding then
    TouchMenu._burrow_safe_sheet_rounding = true

    local original_init = TouchMenu.init
    function TouchMenu:init(...)
        local result = original_init(self, ...)
        markTopMenu(self)
        return result
    end

    local original_updateItems = TouchMenu.updateItems
    function TouchMenu:updateItems(...)
        local result = original_updateItems(self, ...)
        markTopMenu(self)
        return result
    end
end

local function markReaderBottomMenu(dialog)
    if dialog and dialog.dialog_frame then
        dialog.dialog_frame._burrow_round_top_only = true
        dialog.dialog_frame._burrow_round_bottom_only = nil
        dialog.dialog_frame._burrow_menu_radius = READER_MENU_RADIUS
    end
end

-- ConfigDialog creates a fresh native dialog_frame on each tab switch. Mark the
-- new frame after KOReader completes its own update; do not rebuild anything.
if not ConfigDialog._burrow_safe_sheet_rounding then
    ConfigDialog._burrow_safe_sheet_rounding = true
    local original_update = ConfigDialog.update

    function ConfigDialog:update(...)
        local result = original_update(self, ...)
        markReaderBottomMenu(self)
        return result
    end
end

    Module.applied = true
    return true
end

return Module

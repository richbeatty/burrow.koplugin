-- Shared Burrow Store visual language.
--
-- Keeps the embedded OPDS browser aligned with the Burrow library: a minimal
-- Burrow top bar, Home / Store navigation, page dots, rounded cover artwork,
-- and a high-contrast e-ink loading indicator.

local Blitbuffer = require("ffi/blitbuffer")
local BottomContainer = require("ui/widget/container/bottomcontainer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local InputContainer = require("ui/widget/container/inputcontainer")
local LineWidget = require("ui/widget/linewidget")
local OverlapGroup = require("ui/widget/overlapgroup")
local Screen = require("device").screen
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Widget = require("ui/widget/widget")

local Theme = {}

-- ---------------------------------------------------------------------------
-- Rounded cover mask
-- ---------------------------------------------------------------------------

local RoundedCover = Widget:extend {
    inner = nil,
    width = nil,
    height = nil,
    radius = nil,
    border_size = nil,
}

function RoundedCover:init()
    self.radius = self.radius or math.max(Screen:scaleBySize(6), Size.radius.default)
    self.border_size = self.border_size or Size.border.thin
    self.dimen = Geom:new { w = self.width, h = self.height }
end

function RoundedCover:getSize()
    return self.dimen
end

function RoundedCover:free(...)
    if self.inner and self.inner.free then
        self.inner:free(...)
    end
end

function RoundedCover:paintTo(bb, x, y)
    local radius = math.min(
        self.radius,
        math.floor(self.width / 2),
        math.floor(self.height / 2)
    )

    bb:paintRect(x, y, self.width, self.height, Blitbuffer.COLOR_WHITE)
    if self.inner then
        self.inner:paintTo(bb, x, y)
    end

    if radius > 0 then
        local radius_sq = radius * radius
        for dy = 0, radius - 1 do
            local cutoff = 0
            local ddy = dy - radius
            while cutoff < radius
                    and (cutoff - radius) * (cutoff - radius) + ddy * ddy > radius_sq do
                cutoff = cutoff + 1
            end
            if cutoff > 0 then
                bb:paintRect(x, y + dy, cutoff, 1, Blitbuffer.COLOR_WHITE)
                bb:paintRect(x + self.width - cutoff, y + dy, cutoff, 1, Blitbuffer.COLOR_WHITE)
                bb:paintRect(x, y + self.height - dy - 1, cutoff, 1, Blitbuffer.COLOR_WHITE)
                bb:paintRect(
                    x + self.width - cutoff,
                    y + self.height - dy - 1,
                    cutoff,
                    1,
                    Blitbuffer.COLOR_WHITE
                )
            end
        end
    end

    if self.border_size > 0 then
        bb:paintBorder(
            x,
            y,
            self.width,
            self.height,
            self.border_size,
            Blitbuffer.COLOR_GRAY_3,
            radius,
            true
        )
    end
end

function Theme.roundedCover(inner, width, height)
    return RoundedCover:new {
        inner = inner,
        width = width,
        height = height,
    }
end

-- ---------------------------------------------------------------------------
-- E-ink activity ring
-- ---------------------------------------------------------------------------

local ActivityRing = Widget:extend {
    size = nil,
    step = 1,
    segments = 8,
}

function ActivityRing:init()
    self.size = math.max(Screen:scaleBySize(18), self.size or Screen:scaleBySize(40))
    self.dimen = Geom:new { w = self.size, h = self.size }
end

function ActivityRing:getSize()
    return self.dimen
end

function ActivityRing:setStep(step)
    self.step = ((step or 1) - 1) % self.segments + 1
end

function ActivityRing:paintTo(bb, x, y)
    self.dimen.x = x
    self.dimen.y = y

    local center = self.size / 2
    local orbit = self.size * 0.34
    local dot = math.max(2, math.floor(self.size * 0.12))
    local radius = math.floor(dot / 2)

    for index = 1, self.segments do
        local angle = ((index - 1) / self.segments) * math.pi * 2 - math.pi / 2
        local dx = math.floor(center + math.cos(angle) * orbit - dot / 2 + 0.5)
        local dy = math.floor(center + math.sin(angle) * orbit - dot / 2 + 0.5)
        local distance = (index - self.step) % self.segments
        local color
        if distance == 0 then
            color = Blitbuffer.COLOR_BLACK
        elseif distance <= 2 then
            color = Blitbuffer.COLOR_DARK_GRAY
        else
            color = Blitbuffer.COLOR_LIGHT_GRAY
        end
        bb:paintRoundedRect(x + dx, y + dy, dot, dot, color, radius)
    end
end

function Theme.activityRing(size, step)
    return ActivityRing:new { size = size, step = step or 1 }
end

local LoadingOverlay = InputContainer:extend {
    text = nil,
    animation_interval = 0.28,
}

function LoadingOverlay:init()
    self.dimen = Geom:new {
        x = 0,
        y = 0,
        w = Screen:getWidth(),
        h = Screen:getHeight(),
    }
    self.ring = Theme.activityRing(Screen:scaleBySize(48), 1)
    local label = TextWidget:new {
        text = self.text or "Loading Store…",
        face = Font:getFace("smallinfofont", 18),
        bold = true,
    }
    local panel = FrameContainer:new {
        padding = Screen:scaleBySize(18),
        margin = 0,
        bordersize = Size.border.thin,
        radius = math.max(Screen:scaleBySize(10), Size.radius.default),
        color = Blitbuffer.COLOR_GRAY_3,
        background = Blitbuffer.COLOR_WHITE,
        VerticalGroup:new {
            align = "center",
            self.ring,
            VerticalSpan:new { width = Screen:scaleBySize(12) },
            label,
        },
    }
    self[1] = FrameContainer:new {
        width = self.dimen.w,
        height = self.dimen.h,
        padding = 0,
        margin = 0,
        bordersize = 0,
        background = Blitbuffer.COLOR_WHITE,
        CenterContainer:new {
            dimen = self.dimen,
            panel,
        },
    }
    self.ges_events = {
        TapConsume = {
            GestureRange:new { ges = "tap", range = self.dimen },
        },
    }
end

function LoadingOverlay:onTapConsume()
    return true
end

function LoadingOverlay:onShow()
    local function tick()
        if self._stopped then
            return
        end
        self.ring:setStep(self.ring.step + 1)
        UIManager:setDirty(self, "fast", self.ring.dimen or self.dimen)
        UIManager:scheduleIn(self.animation_interval, tick)
    end
    self._tick = tick
    UIManager:scheduleIn(self.animation_interval, tick)
end

function LoadingOverlay:onCloseWidget()
    self._stopped = true
    if self._tick then
        UIManager:unschedule(self._tick)
    end
end

function Theme.beginLoading(text)
    local overlay = LoadingOverlay:new { text = text }
    UIManager:show(overlay)
    -- Get one complete e-ink frame on screen before the synchronous socket call.
    UIManager:forceRePaint()
    UIManager:yieldToEPDC()
    return overlay
end

function Theme.endLoading(overlay)
    if overlay then
        UIManager:close(overlay)
    end
end

-- ---------------------------------------------------------------------------
-- Home / Store footer and page dots
-- ---------------------------------------------------------------------------

local TabLine = Widget:extend {
    width = nil,
    height = nil,
    active = false,
}

function TabLine:getSize()
    return Geom:new { w = self.width, h = self.height }
end

function TabLine:paintTo(bb, x, y)
    self.dimen = self.dimen or Geom:new {}
    self.dimen.x, self.dimen.y = x, y
    self.dimen.w, self.dimen.h = self.width, self.height
    if self.active then
        bb:paintRect(x, y, self.width, self.height, Blitbuffer.COLOR_BLACK)
    end
end

local NavTab = InputContainer:extend {
    width = nil,
    height = nil,
    label = nil,
    active = false,
    callback = nil,
    hold_callback = nil,
    label_size_percent = 100,
}

function NavTab:init()
    local line_height = math.max(1, Screen:scaleBySize(1))
    local bottom_inset = math.max(3, Screen:scaleBySize(3))
    local base_label_size = math.max(14, math.floor(self.height * 0.42))
    local label_size = math.max(
        8,
        math.floor(base_label_size * (self.label_size_percent or 100) / 100 + 0.5)
    )
    local label = TextWidget:new {
        text = self.label,
        face = Font:getFace("smallinfofont", label_size),
    }
    local label_width = label:getSize().w
    local line_width = math.min(
        math.floor(self.width * 0.52),
        label_width + Screen:scaleBySize(4)
    )
    local dimen = Geom:new { w = self.width, h = self.height }
    local label_height = math.max(1, self.height - line_height - bottom_inset)
    self[1] = OverlapGroup:new {
        dimen = dimen,
        CenterContainer:new {
            dimen = Geom:new { w = self.width, h = label_height },
            label,
        },
        BottomContainer:new {
            dimen = dimen,
            VerticalGroup:new {
                align = "center",
                TabLine:new {
                    width = line_width,
                    height = line_height,
                    active = self.active,
                },
                VerticalSpan:new { width = bottom_inset },
            },
        },
    }
    self.dimen = dimen
    self.ges_events = {
        TapNavTab = {
            GestureRange:new { ges = "tap", range = self.dimen },
        },
        HoldNavTab = {
            GestureRange:new { ges = "hold", range = self.dimen },
        },
    }
end

function NavTab:onTapNavTab()
    if self.callback then
        self.callback()
    end
    return true
end

function NavTab:onHoldNavTab()
    if self.hold_callback then
        self.hold_callback()
        return true
    end
    return false
end

local PageDots = Widget:extend {
    page = 1,
    page_num = 1,
    dot_size = nil,
    active_width = nil,
    gap = nil,
    height = nil,
    max_visible = 9,
}

function PageDots:_visiblePages()
    local total = math.max(1, tonumber(self.page_num) or 1)
    local current = math.max(1, math.min(total, tonumber(self.page) or 1))
    local count = math.min(total, self.max_visible)
    local first = 1
    if total > count then
        first = math.max(1, math.min(current - math.floor(count / 2), total - count + 1))
    end
    if total <= 1 then
        return {}, current
    end
    local pages = {}
    for value = first, first + count - 1 do
        table.insert(pages, value)
    end
    return pages, current
end

function PageDots:getSize()
    local pages, current = self:_visiblePages()
    local width = 0
    for index, page in ipairs(pages) do
        width = width + (page == current and self.active_width or self.dot_size)
        if index < #pages then
            width = width + self.gap
        end
    end
    return Geom:new { w = math.max(1, width), h = self.height }
end

function PageDots:setPage(page, page_num)
    self.page = page or 1
    self.page_num = page_num or 1
    self.dimen = nil
end

function PageDots:paintTo(bb, x, y)
    local size = self:getSize()
    self.dimen = self.dimen or Geom:new {}
    self.dimen.x, self.dimen.y = x, y
    self.dimen.w, self.dimen.h = size.w, size.h

    local pages, current = self:_visiblePages()
    local offset = 0
    local dot_y = y + math.floor((self.height - self.dot_size) / 2)
    for index, page in ipairs(pages) do
        local width = page == current and self.active_width or self.dot_size
        local color = page == current and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_LIGHT_GRAY
        bb:paintRoundedRect(
            x + offset,
            dot_y,
            width,
            self.dot_size,
            color,
            math.floor(self.dot_size / 2)
        )
        offset = offset + width
        if index < #pages then
            offset = offset + self.gap
        end
    end
end

function Theme.buildFooter(menu, options)
    options = options or {}
    local footer_height = options.footer_height
        or (menu.page_info and menu.page_info:getSize().h)
        or Screen:scaleBySize(56)
    local show_labels = options.show_labels ~= false
    local line_height = math.max(1, Screen:scaleBySize(1))
    local dots_height = show_labels
        and math.max(6, math.floor(footer_height * 0.22))
        or footer_height
    local gap_above_line = math.max(1, math.floor(footer_height * 0.03))
    local gap_below_line = math.max(1, math.floor(footer_height * 0.04))
    local nav_height = math.max(
        20,
        footer_height - dots_height - line_height - gap_above_line - gap_below_line
    )
    local dot_size = show_labels
        and math.max(3, math.floor(dots_height * 0.42))
        or math.max(3, math.floor(footer_height * 0.18))
    local dots = PageDots:new {
        page = menu.page or 1,
        page_num = menu.page_num or 1,
        dot_size = dot_size,
        active_width = math.max(dot_size * 2, math.floor(dot_size * 2.5)),
        gap = math.max(5, math.floor(dot_size * 1.6)),
        height = dots_height,
    }

    if not show_labels then
        return VerticalGroup:new { align = "center", dots }, dots
    end

    local nav_width = math.floor((menu.screen_w or Screen:getWidth()) * 0.88)
    local tab_width = math.max(1, math.floor(nav_width / 2))
    local active = options.active or "home"
    local home_tab = NavTab:new {
        width = tab_width,
        height = nav_height,
        label = options.home_label or "Home",
        active = active == "home",
        callback = options.home_callback,
        hold_callback = options.home_hold_callback,
        label_size_percent = options.label_size_percent or 100,
    }
    local store_tab = NavTab:new {
        width = tab_width,
        height = nav_height,
        label = options.store_label or "Store",
        active = active == "store",
        callback = options.store_callback,
        hold_callback = options.store_hold_callback,
        label_size_percent = options.label_size_percent or 100,
    }
    local divider = LineWidget:new {
        background = Blitbuffer.COLOR_LIGHT_GRAY,
        dimen = Geom:new {
            w = math.floor((menu.screen_w or Screen:getWidth()) * 0.94),
            h = line_height,
        },
    }
    local root = VerticalGroup:new {
        align = "center",
        dots,
        VerticalSpan:new { width = gap_above_line },
        divider,
        VerticalSpan:new { width = gap_below_line },
        HorizontalGroup:new { home_tab, store_tab },
    }
    return root, dots, home_tab, store_tab
end

local function hideReturnControls(menu)
    if menu.page_return_arrow and menu.page_return_arrow.hide then
        menu.page_return_arrow:hide()
    end
    if menu.return_button and menu.return_button.hide then
        menu.return_button:hide()
    end
end

function Theme.installStoreFooter(menu)
    if menu._burrow_store_footer then
        return
    end
    local frame = menu[1]
    local content = frame and frame[1]
    local footer = content and content[4]
    local original_page_info = menu.page_info
    if not footer or not original_page_info then
        return
    end

    local footer_height = original_page_info:getSize().h
    local root, dots = Theme.buildFooter(menu, {
        footer_height = footer_height,
        active = "store",
        home_callback = function()
            if menu.close_callback then
                menu.close_callback()
            elseif menu.onClose then
                menu:onClose()
            end
        end,
        store_callback = function()
            if menu.showCurrentStoreMenu then
                menu:showCurrentStoreMenu()
            end
        end,
        store_hold_callback = function()
            if menu.showOPDSMenu then
                menu:showOPDSMenu()
            end
        end,
    })
    local container = CenterContainer:new {
        dimen = Geom:new { w = menu.inner_dimen.w, h = footer_height },
        root,
    }

    footer[1] = container
    menu.page_info = root
    menu._burrow_store_footer = {
        root = root,
        dots = dots,
        footer = footer,
        original_page_info = original_page_info,
    }
    hideReturnControls(menu)
end

function Theme.updateStoreFooter(menu)
    local state = menu._burrow_store_footer
    if state then
        state.dots:setPage(menu.page or 1, menu.page_num or 1)
        hideReturnControls(menu)
    end
end

return Theme

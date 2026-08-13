local MODULE_KEY = "burrow.internal.2_dialog_pager_icons"
local existing_module = package.loaded[MODULE_KEY]
if existing_module then return existing_module end

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Geom = require("ui/geometry")
local KeyValuePage = require("ui/widget/keyvaluepage")
local Menu = require("ui/widget/menu")
local Screen = require("device").screen
local Widget = require("ui/widget/widget")

local Module = { key = MODULE_KEY, phase = "early", filename = "2-dialog-pager-icons.lua" }
package.loaded[MODULE_KEY] = Module

-- Same visual language as Burrow's Home pager: a dark elongated pill for the
-- current page and small light-gray dots for the surrounding pages. Paging is
-- intentionally gesture-first; KOReader's existing horizontal swipe handlers
-- remain untouched.
local PageDots = Widget:extend {
    page = 1,
    page_num = 1,
    max_visible = 9,
    dimen = nil,
}

function PageDots:init()
    self.dot_size = self.dot_size or math.max(3, Screen:scaleBySize(3))
    self.active_width = self.active_width
        or math.max(self.dot_size * 2, math.floor(self.dot_size * 2.5))
    self.gap = self.gap or math.max(5, math.floor(self.dot_size * 1.6))
    self.height = self.height or math.max(self.dot_size, Screen:scaleBySize(10))
end

function PageDots:_visiblePages()
    local total = math.max(1, tonumber(self.page_num) or 1)
    local current = math.max(1, math.min(total, tonumber(self.page) or 1))
    local count = math.min(total, self.max_visible)
    local first = 1
    if total > count then
        first = math.max(1, math.min(current - math.floor(count / 2), total - count + 1))
    end
    local pages = {}
    for value = first, first + count - 1 do
        pages[#pages + 1] = value
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
    return Geom:new { w = math.max(1, width), h = math.max(1, self.height) }
end

function PageDots:setPage(page, page_num)
    self.page = page or 1
    self.page_num = page_num or 1
    self.dimen = nil
end

-- Compatibility methods. KOReader's Menu and KeyValuePage update routines still
-- talk to page_info_text as though it were a Button. We deliberately ignore the
-- old text/enable state and render only the Home-style page indicator.
function PageDots:setText() end
function PageDots:enable() end
function PageDots:disable() end
function PageDots:disableWithoutDimming() end
function PageDots:enableDisable() end
function PageDots:show() end
function PageDots:hide() end

function PageDots:paintTo(bb, x, y)
    local size = self:getSize()
    if not self.dimen then
        self.dimen = Geom:new { x = x, y = y, w = size.w, h = size.h }
    else
        self.dimen.x = x
        self.dimen.y = y
        self.dimen.w = size.w
        self.dimen.h = size.h
    end

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

-- Zero-size stand-ins for the four stock pager buttons. KOReader can continue
-- calling show/hide/enableDisable on them, but they contribute no visible glyph
-- and no width to the pager footer.
local BlankPagerControl = Widget:extend { dimen = nil }
function BlankPagerControl:init()
    self.dimen = Geom:new { w = 0, h = 0 }
end
function BlankPagerControl:getSize() return self.dimen end
function BlankPagerControl:paintTo() end
function BlankPagerControl:show() end
function BlankPagerControl:hide() end
function BlankPagerControl:enable() end
function BlankPagerControl:disable() end
function BlankPagerControl:disableWithoutDimming() end
function BlankPagerControl:enableDisable() end

local function primePager(widget)
    if widget._burrow_page_dots then return end
    local dots = PageDots:new { show_parent = widget.show_parent or widget }
    widget._burrow_page_dots = dots
    widget.page_info_text = dots
    widget.page_info_left_chev = BlankPagerControl:new {}
    widget.page_info_right_chev = BlankPagerControl:new {}
    widget.page_info_first_chev = BlankPagerControl:new {}
    widget.page_info_last_chev = BlankPagerControl:new {}
end

local function refreshMenuDots(widget)
    if not widget._burrow_page_dots then return end

    local dots = widget._burrow_page_dots
    dots:setPage(widget.page or 1, widget.page_num or 1)

    -- ReaderToc uses Menu's footer, which is naturally right-biased by the
    -- stock pager group. Keep the existing footer object (the BottomContainer
    -- already references it), but replace its children with one full-width
    -- CenterContainer. This makes the indicator sit at the true horizontal
    -- center, exactly like Burrow's Home page dots.
    if widget.page_info then
        local width = widget.inner_dimen and widget.inner_dimen.w
            or widget.dimen and widget.dimen.w
            or Screen:getWidth()
        local height = dots:getSize().h

        for index = #widget.page_info, 1, -1 do
            widget.page_info[index] = nil
        end
        widget.page_info[1] = CenterContainer:new {
            dimen = Geom:new { w = width, h = height },
            dots,
        }
        if widget.page_info.resetLayout then
            widget.page_info:resetLayout()
        end
    end
end

local function refreshKeyValueDots(widget)
    if widget._burrow_page_dots then
        widget._burrow_page_dots:setPage(widget.show_page or 1, widget.pages or 1)
        if widget.page_info and widget.page_info.resetLayout then
            widget.page_info:resetLayout()
        end
    end
end

function Module.apply()
    if Module.applied then return true end

    if not Menu._burrow_dialog_page_dots then
        Menu._burrow_dialog_page_dots = true
        local original_init = Menu.init
        function Menu:init(...)
            primePager(self)
            local result = original_init(self, ...)
            refreshMenuDots(self)
            return result
        end

        local original_update_items = Menu.updateItems
        function Menu:updateItems(...)
            local result = original_update_items(self, ...)
            refreshMenuDots(self)
            return result
        end
    end

    if not KeyValuePage._burrow_dialog_page_dots then
        KeyValuePage._burrow_dialog_page_dots = true
        local original_init = KeyValuePage.init
        function KeyValuePage:init(...)
            primePager(self)
            local result = original_init(self, ...)
            refreshKeyValueDots(self)
            return result
        end

        local original_populate = KeyValuePage._populateItems
        function KeyValuePage:_populateItems(...)
            local result = original_populate(self, ...)
            refreshKeyValueDots(self)
            return result
        end
    end

    Module.applied = true
    return true
end

return Module

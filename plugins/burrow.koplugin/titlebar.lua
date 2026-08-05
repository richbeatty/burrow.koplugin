local Device = require("device")
local Geom = require("ui/geometry")
local IconButton = require("ui/widget/iconbutton")
local OverlapGroup = require("ui/widget/overlapgroup")
local LeftContainer = require("ui/widget/container/leftcontainer")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local Screen = Device.screen
local logger = require("logger")
local burrow_util = require("burrow_util")
local burrow_debug = require("burrow_debug")

local DGENERIC_ICON_SIZE = G_defaults:readSetting("DGENERIC_ICON_SIZE")

local TitleBar = OverlapGroup:extend {
    left1_icon = nil,
    left1_icon_tap_callback = function() end,
    left1_icon_hold_callback = function() end,
    left2_icon = nil,
    left2_icon_tap_callback = function() end,
    left2_icon_hold_callback = function() end,
    left3_icon = nil,
    left3_icon_tap_callback = function() end,
    left3_icon_hold_callback = function() end,
    center_icon = nil,
    center_icon_tap_callback = function() end,
    center_icon_hold_callback = function() end,
    right3_icon = nil,
    right3_icon_tap_callback = function() end,
    right3_icon_hold_callback = function() end,
    right2_icon = nil,
    right2_icon_tap_callback = function() end,
    right2_icon_hold_callback = function() end,
    right1_icon = nil,
    right1_icon_tap_callback = function() end,
    right1_icon_hold_callback = function() end,
    show_parent = nil,
    icon_size = Screen:scaleBySize(DGENERIC_ICON_SIZE),
    center_icon_size = nil,
    center_icon_size_ratio = 1.25,
    icon_padding_top = Screen:scaleBySize(5),
    icon_padding_bottom = Screen:scaleBySize(5),
    icon_margin_lr = Screen:scaleBySize(35),
    icon_reserved_width = nil,
    titlebar_margin_lr = Screen:scaleBySize(16),
    title = "",
    subtitle = "",
    fullscreen = "true",
    align = "center",
}

function TitleBar:init()
    self.width = Screen:getWidth()
    self.titlebar_height = self.icon_size + self.icon_padding_top + self.icon_padding_bottom
    self.dimen = Geom:new {
        x = 0,
        y = 0,
        w = self.width,
        h = self.titlebar_height,
    }
    self.icon_total_width = self.icon_size + self.icon_margin_lr
    local padding1 = self.titlebar_margin_lr
    local padding2 = self.titlebar_margin_lr + self.icon_total_width
    local padding3 = self.titlebar_margin_lr + (self.icon_total_width * 2)
    self.center_icon_size = math.ceil(self.icon_size * self.center_icon_size_ratio)
    local total_width = self.center_icon_size + (padding3 * 2) + (self.icon_total_width * 2)

    local function build_container(button, is_left_button, padding)
        local pre_padding
        local post_padding
        if is_left_button then
            pre_padding = padding
            post_padding = self.width - padding - button:getSize().w
        else
            pre_padding = self.width - padding - button:getSize().w
            post_padding = padding
        end
        return LeftContainer:new {
            dimen = self.dimen,
            HorizontalGroup:new {
                HorizontalSpan:new { width = pre_padding },
                button,
                HorizontalSpan:new { width = post_padding },
            },
        }
    end

    self.left1_button = IconButton:new {
        icon = self.left1_icon,
        icon_rotation_angle = 0,
        width = self.icon_size,
        height = self.icon_size,
        padding = 0,
        padding_bottom = self.icon_padding_bottom,
        padding_top = self.icon_padding_top,
        callback = self.left1_icon_tap_callback,
        hold_callback = self.left1_icon_hold_callback,
        show_parent = self.show_parent,
    }
    self.left1_button_container = build_container(self.left1_button, true, padding1)

    self.left2_button = IconButton:new {
        icon = self.left2_icon,
        width = self.icon_size,
        height = self.icon_size,
        padding = 0,
        padding_bottom = self.icon_padding_bottom,
        padding_top = self.icon_padding_top,
        callback = self.left2_icon_tap_callback,
        hold_callback = self.left2_icon_hold_callback,
        show_parent = self.show_parent,
    }
    self.left2_button_container = build_container(self.left2_button, true, padding2)

    self.left3_button = IconButton:new {
        icon = self.left3_icon,
        width = self.icon_size,
        height = self.icon_size,
        padding = 0,
        padding_bottom = self.icon_padding_bottom,
        padding_top = self.icon_padding_top,
        callback = self.left3_icon_tap_callback,
        hold_callback = self.left3_icon_hold_callback,
        show_parent = self.show_parent,
    }
    self.left3_button_container = build_container(self.left3_button, true, padding3)

    self.center_button = IconButton:new {
        icon = self.center_icon,
        width = self.center_icon_size,
        height = self.center_icon_size,
        padding = 0,
        padding_bottom = 0,
        padding_top = 0,
        overlap_align = "center", -- this does all the work of centering itself, no container needed
        callback = self.center_icon_tap_callback,
        hold_callback = self.center_icon_hold_callback,
        show_parent = self.show_parent,
    }
    self.center_button_container = self.center_button

    self.right3_button = IconButton:new {
        icon = self.right3_icon,
        width = self.icon_size,
        height = self.icon_size,
        padding = 0,
        padding_bottom = self.icon_padding_bottom,
        padding_top = self.icon_padding_top,
        callback = self.right3_icon_tap_callback,
        hold_callback = self.right3_icon_hold_callback,
        show_parent = self.show_parent,
    }
    self.right3_button_container = build_container(self.right3_button, false, padding3)

    self.right2_button = IconButton:new {
        icon = self.right2_icon,
        width = self.icon_size,
        height = self.icon_size,
        padding = 0,
        padding_bottom = self.icon_padding_bottom,
        padding_top = self.icon_padding_top,
        callback = self.right2_icon_tap_callback,
        hold_callback = self.right2_icon_hold_callback,
        show_parent = self.show_parent,
    }
    self.right2_button_container = build_container(self.right2_button, false, padding2)

    self.right1_button = IconButton:new {
        icon = self.right1_icon,
        width = self.icon_size,
        height = self.icon_size,
        padding = 0,
        padding_bottom = self.icon_padding_bottom,
        padding_top = self.icon_padding_top,
        callback = self.right1_icon_tap_callback,
        hold_callback = self.right1_icon_hold_callback,
        show_parent = self.show_parent,
    }
    self.right1_button_container = build_container(self.right1_button, false, padding1)

    -- insert buttons into final layout...
    table.insert(self, self.center_button_container)
    table.insert(self, self.left1_button_container)
    table.insert(self, self.right1_button_container)
    table.insert(self, self.left2_button_container)
    table.insert(self, self.right2_button_container)
    -- and check to make sure all buttons will fit, if not remove two
    if total_width < self.width then
        table.insert(self, self.left3_button_container)
        table.insert(self, self.right3_button_container)
    else
        self.left3_button = nil
        self.right3_button = nil
    end

    -- insert optional button pairs provided through user patches
    if self.left4_button and self.right4_button then
        table.insert(self, self.left4_button_container)
        table.insert(self, self.right4_button_container)
    end
    if self.left5_button and self.right5_button then
        table.insert(self, self.left5_button_container)
        table.insert(self, self.right5_button_container)
    end

    -- maintain compatibility with FileManager or anything else that might expect the stock 2 buttons
    self.left_button = self.left1_button
    self.right_button = self.right1_button

    -- Call our base class's init (especially since OverlapGroup has very peculiar self.dimen semantics...)
    OverlapGroup.init(self)
end

function TitleBar:paintTo(bb, x, y)
    -- We need to update self.dimen's x and y for any ges.pos:intersectWith(title_bar)
    -- to work. (This is done by FrameContainer, but not by most other widgets... It
    -- should probably be done in all of them, but not sure of side effects...)
    self.dimen.x = x
    self.dimen.y = y
    OverlapGroup.paintTo(self, bb, x, y)
end

function TitleBar:getHeight()
    return self.titlebar_height
end

function TitleBar:setTitle(title, no_refresh)
    self.title = ""
end

function TitleBar:setSubTitle(subtitle, no_refresh)
    self.subtitle = ""
end

function TitleBar:setLeftIcon(icon)
    -- do nothing, we don't want our icon changing
end

function TitleBar:setRightIcon(icon)
    -- do nothing, we don't want our icon changing
end

-- layout for FocusManager
function TitleBar:generateHorizontalLayout()
    local row = {}
    if self.left1_button then
        table.insert(row, self.left1_button)
    end
    if self.left2_button then
        table.insert(row, self.left2_button)
    end
    if self.left3_button then
        table.insert(row, self.left3_button)
    end
    if self.center_button then
        table.insert(row, self.center_button)
    end
    if self.right3_button then
        table.insert(row, self.right3_button)
    end
    if self.right2_button then
        table.insert(row, self.right2_button)
    end
    if self.right1_button then
        table.insert(row, self.right1_button)
    end
    local layout = {}
    if #row > 0 then
        table.insert(layout, row)
    end
    return layout
end

-- layout for FocusManager
function TitleBar:generateVerticalLayout()
    local layout = {}
    if self.left1_button then
        table.insert(layout, { self.left1_button })
    end
    if self.left2_button then
        table.insert(layout, { self.left2_button })
    end
    if self.left3_button then
        table.insert(layout, { self.left3_button })
    end
    if self.center_button then
        table.insert(layout, { self.center_button })
    end
    if self.right3_button then
        table.insert(layout, { self.right3_button })
    end
    if self.right2_button then
        table.insert(layout, { self.right2_button })
    end
    if self.right1_button then
        table.insert(layout, { self.right1_button })
    end
    return layout
end

return TitleBar

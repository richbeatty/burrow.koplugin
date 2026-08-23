local MODULE_KEY = "burrow.internal.2_kindle_style_alt_status_clock"
local existing_module = package.loaded[MODULE_KEY]
if existing_module then return existing_module end

local Module = {
    key = MODULE_KEY,
    phase = "early",
    filename = "2-kindle-style-alt-status-clock.lua",
}
package.loaded[MODULE_KEY] = Module

-- Add a Kindle-style centered clock as an optional CRE Alt status bar item.
-- KOReader keeps ownership of the Alt status bar, all of its native items,
-- header layout, auto-refresh preference, and suspend/resume lifecycle.
function Module.apply()
    if Module.applied then return true end

    local CenterContainer = require("ui/widget/container/centercontainer")
    local Event = require("ui/event")
    local Font = require("ui/font")
    local Geom = require("ui/geometry")
    local ReaderCoptListener = require("apps/reader/modules/readercoptlistener")
    local Screen = require("device").screen
    local TextWidget = require("ui/widget/textwidget")
    local Widget = require("ui/widget/widget")
    local datetime = require("datetime")
    local logger = require("logger")
    local _ = require("gettext")

    if ReaderCoptListener._burrow_kindle_alt_clock_v2 then
        Module.applied = true
        return true
    end

    local SETTING_CENTERED_CLOCK = "burrow_cre_header_centered_clock"
    local VIEW_MODULE_NAME = "burrow_kindle_alt_clock"

    local function centeredClockEnabled()
        return G_reader_settings:isTrue(SETTING_CENTERED_CLOCK)
    end

    local function nativeHeaderHasContent(listener)
        return listener.title == 1
            or listener.author == 1
            or listener.clock == 1
            or listener.page_number == 1
            or listener.page_count == 1
            or listener.reading_percent == 1
            or listener.battery == 1
            or listener.chapter_marks == 1
    end

    -- If the centered clock is the only selected header item, keep a harmless
    -- blank CRengine page-info item at runtime so the native Alt status bar still
    -- reserves its normal header strip. This never changes the saved native item
    -- choices and disappears as soon as any native item is enabled again.
    local function ensureCenteredClockHeaderSpace(listener)
        local document = listener and listener.document
        local cre = document and document._document
        if not cre then return end

        if centeredClockEnabled() and not nativeHeaderHasContent(listener) then
            cre:setIntProperty("window.status.pos.page.number", 1)
            document:setPageInfoOverride(" ")
            listener._burrow_centered_clock_spacer = true
        else
            if listener._burrow_centered_clock_spacer then
                cre:setIntProperty("window.status.pos.page.number", listener.page_number or 0)
            end
            listener._burrow_centered_clock_spacer = nil
        end
    end

    local ClockOverlay = Widget:extend {}

    function ClockOverlay:init()
        self._burrow_container = nil
        self._burrow_text = nil
        self._burrow_face = nil
        self._burrow_bold = nil
        self._burrow_header_h = nil
        self._burrow_screen_w = nil
        self._burrow_clock_text = nil
    end

    function ClockOverlay:_freeCached()
        if self._burrow_container and self._burrow_container.free then
            pcall(self._burrow_container.free, self._burrow_container)
        elseif self._burrow_text and self._burrow_text.free then
            pcall(self._burrow_text.free, self._burrow_text)
        end
        self._burrow_container = nil
        self._burrow_text = nil
        self._burrow_face = nil
        self._burrow_bold = nil
        self._burrow_header_h = nil
        self._burrow_screen_w = nil
        self._burrow_clock_text = nil
    end

    function ClockOverlay:resetLayout()
        self:_freeCached()
    end

    function ClockOverlay:free()
        self:_freeCached()
    end

    function ClockOverlay:paintTo(bb, x, y)
        if not centeredClockEnabled() then return end

        local listener = self.listener
        if not listener
            or not listener.document
            or not listener.document.configurable
            or listener.document.configurable.status_line ~= 0
            or not listener.view
            or listener.view.view_mode ~= "page"
        then
            return
        end

        local ok, header_h = pcall(listener.document.getHeaderHeight, listener.document)
        header_h = ok and tonumber(header_h) or 0
        if not header_h or header_h <= 0 then return end

        local footer = listener.view.footer
        local face = footer and footer.footer_text_face
            or Font:getFace("smallinfofont", 14)
        local bold = footer and footer.settings and footer.settings.text_font_bold or false
        local clock_text = datetime.secondsToHour(
            os.time(),
            G_reader_settings:isTrue("twelve_hour_clock")
        )
        local screen_w = Screen:getWidth()

        if not self._burrow_container
            or self._burrow_clock_text ~= clock_text
            or self._burrow_face ~= face
            or self._burrow_bold ~= bold
            or self._burrow_header_h ~= header_h
            or self._burrow_screen_w ~= screen_w
        then
            self:_freeCached()
            self._burrow_text = TextWidget:new {
                text = clock_text,
                face = face,
                bold = bold,
            }
            self._burrow_container = CenterContainer:new {
                dimen = Geom:new { x = 0, y = 0, w = screen_w, h = header_h },
                self._burrow_text,
            }
            self._burrow_clock_text = clock_text
            self._burrow_face = face
            self._burrow_bold = bold
            self._burrow_header_h = header_h
            self._burrow_screen_w = screen_w
        end

        self._burrow_container:paintTo(bb, x, y)
    end

    local function ensureOverlay(listener)
        local view = listener and listener.view
        if not view or type(view.registerViewModule) ~= "function" then return end

        local overlay = view.view_modules and view.view_modules[VIEW_MODULE_NAME]
        if overlay then
            overlay.listener = listener
            return
        end

        view:registerViewModule(VIEW_MODULE_NAME, ClockOverlay:new {
            listener = listener,
        })
    end

    -- KOReader normally schedules the Alt status bar minute refresh only when
    -- its native clock or battery is selected. Treat Burrow's centered clock as
    -- another dynamic header item while leaving the native clock flag untouched.
    local original_rescheduleHeaderRefreshIfNeeded = ReaderCoptListener.rescheduleHeaderRefreshIfNeeded
    function ReaderCoptListener:rescheduleHeaderRefreshIfNeeded(...)
        if not centeredClockEnabled() then
            return original_rescheduleHeaderRefreshIfNeeded(self, ...)
        end

        local native_clock = self.clock
        self.clock = 1
        local ok, result = pcall(original_rescheduleHeaderRefreshIfNeeded, self, ...)
        self.clock = native_clock
        if not ok then error(result) end
        return result
    end

    local function wrapHeaderRefresh(listener)
        if type(listener.headerRefresh) ~= "function" then return end
        if listener.headerRefresh == listener._burrow_centered_clock_refresh_wrapper then return end

        local native_refresh = listener.headerRefresh
        if type(listener.unscheduleHeaderRefresh) == "function" then
            listener:unscheduleHeaderRefresh()
        end
        local function wrappedRefresh()
            local result = native_refresh()
            if centeredClockEnabled()
                and listener.document
                and listener.document.configurable
                and listener.document.configurable.status_line == 0
                and listener.view
                and listener.view.view_mode == "page"
            then
                listener:updateHeader()
            end
            return result
        end

        listener._burrow_centered_clock_native_refresh = native_refresh
        listener._burrow_centered_clock_refresh_wrapper = wrappedRefresh
        listener.headerRefresh = wrappedRefresh
    end

    local original_onReadSettings = ReaderCoptListener.onReadSettings
    function ReaderCoptListener:onReadSettings(...)
        local result = original_onReadSettings(self, ...)
        ensureOverlay(self)
        ensureCenteredClockHeaderSpace(self)
        wrapHeaderRefresh(self)
        self:rescheduleHeaderRefreshIfNeeded()
        return result
    end

    local original_onReaderReady = ReaderCoptListener.onReaderReady
    function ReaderCoptListener:onReaderReady(...)
        local result = original_onReaderReady(self, ...)
        ensureOverlay(self)
        ensureCenteredClockHeaderSpace(self)
        return result
    end

    -- Preserve KOReader's normal page-info builder, then add only the invisible
    -- runtime spacer when the centered clock is the sole selected header item.
    local original_updatePageInfoOverride = ReaderCoptListener.updatePageInfoOverride
    function ReaderCoptListener:updatePageInfoOverride(...)
        local result = original_updatePageInfoOverride(self, ...)
        ensureCenteredClockHeaderSpace(self)
        return result
    end

    local original_updateHeader = ReaderCoptListener.updateHeader
    function ReaderCoptListener:updateHeader(...)
        ensureOverlay(self)
        ensureCenteredClockHeaderSpace(self)
        return original_updateHeader(self, ...)
    end

    local original_onSetStatusLine = ReaderCoptListener.onSetStatusLine
    function ReaderCoptListener:onSetStatusLine(...)
        local result = original_onSetStatusLine and original_onSetStatusLine(self, ...)
        ensureOverlay(self)
        ensureCenteredClockHeaderSpace(self)
        self:rescheduleHeaderRefreshIfNeeded()
        if centeredClockEnabled()
            and self.document
            and self.document.configurable
            and self.document.configurable.status_line == 0
        then
            self:updateHeader()
        end
        return result
    end

    local original_onTimeFormatChanged = ReaderCoptListener.onTimeFormatChanged
    function ReaderCoptListener:onTimeFormatChanged(...)
        local result = original_onTimeFormatChanged(self, ...)
        if centeredClockEnabled() then
            self:updateHeader()
        end
        return result
    end

    -- Keep every native Alt status bar choice exactly as KOReader provides it.
    -- Add one independent Burrow item immediately after Current time.
    local original_getAltStatusBarMenu = ReaderCoptListener.getAltStatusBarMenu
    function ReaderCoptListener:getAltStatusBarMenu(...)
        local menu = original_getAltStatusBarMenu(self, ...)
        local items = menu and menu.sub_item_table
        if type(items) ~= "table" then return menu end

        local centered_item = {
            text = _("Centered clock"),
            checked_func = function()
                return centeredClockEnabled()
            end,
            callback = function()
                if centeredClockEnabled() then
                    G_reader_settings:delSetting(SETTING_CENTERED_CLOCK)
                else
                    G_reader_settings:makeTrue(SETTING_CENTERED_CLOCK)
                end

                ensureOverlay(self)
                self:updatePageInfoOverride()
                self:rescheduleHeaderRefreshIfNeeded()
                self:updateHeader()
                if self.ui and self.ui.handleEvent then
                    self.ui:handleEvent(Event:new("UpdatePos"))
                end
            end,
        }

        local insert_at = #items + 1
        for i, item in ipairs(items) do
            if item.text == _("Current time") then
                insert_at = i + 1
                break
            end
        end
        table.insert(items, insert_at, centered_item)
        return menu
    end

    ReaderCoptListener._burrow_kindle_alt_clock_v2 = true
    Module.applied = true
    logger.info("Burrow optional centered Alt status clock installed")
    return true
end

return Module

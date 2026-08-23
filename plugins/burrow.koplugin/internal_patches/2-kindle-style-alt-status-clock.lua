local MODULE_KEY = "burrow.internal.2_kindle_style_alt_status_clock"
local existing_module = package.loaded[MODULE_KEY]
if existing_module then return existing_module end

local Module = {
    key = MODULE_KEY,
    phase = "early",
    filename = "2-kindle-style-alt-status-clock.lua",
}
package.loaded[MODULE_KEY] = Module

-- Turn KOReader's CRE Alt status bar into a Kindle-style centered clock.
-- The native Alt status bar still owns visibility, header space, repaint timing,
-- suspend/resume behavior, and document layout. Burrow only suppresses its
-- built-in content and paints a centered clock with the live footer typography.
function Module.apply()
    if Module.applied then return true end

    local CenterContainer = require("ui/widget/container/centercontainer")
    local Font = require("ui/font")
    local Geom = require("ui/geometry")
    local ReaderCoptListener = require("apps/reader/modules/readercoptlistener")
    local Screen = require("device").screen
    local TextWidget = require("ui/widget/textwidget")
    local Widget = require("ui/widget/widget")
    local datetime = require("datetime")
    local logger = require("logger")

    if ReaderCoptListener._burrow_kindle_alt_clock_v1 then
        Module.applied = true
        return true
    end

    local VIEW_MODULE_NAME = "burrow_kindle_alt_clock"

    local ClockOverlay = Widget:extend {}

    function ClockOverlay:init()
        self._burrow_container = nil
        self._burrow_text = nil
        self._burrow_face = nil
        self._burrow_bold = nil
        self._burrow_header_h = nil
        self._burrow_screen_w = nil
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

    local function suppressNativeHeader(listener)
        local document = listener and listener.document
        local cre = document and document._document
        if not cre then return end

        -- Keep listener.clock = 1 so KOReader's own minute-aligned refresh,
        -- suspend, resume, and screensaver lifecycle continues to drive repaint.
        listener.title = 0
        listener.author = 0
        listener.clock = 1
        listener.page_number = 0
        listener.page_count = 0
        listener.reading_percent = 0
        listener.battery = 0
        listener.battery_percent = 0
        listener.chapter_marks = 0
        listener.page_info_override = false

        cre:setIntProperty("window.status.title", 0)
        cre:setIntProperty("window.status.author", 0)
        cre:setIntProperty("window.status.clock", 0)
        cre:setIntProperty("window.status.pos.page.number", 0)
        cre:setIntProperty("window.status.pos.page.count", 0)
        cre:setIntProperty("window.status.pos.percent", 0)
        cre:setIntProperty("window.status.battery", 0)
        cre:setIntProperty("window.status.battery.percent", 0)
        cre:setIntProperty("crengine.page.header.chapter.marks", 0)
        document:setPageInfoOverride("")
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

    local original_onReadSettings = ReaderCoptListener.onReadSettings
    function ReaderCoptListener:onReadSettings(...)
        local result = original_onReadSettings(self, ...)
        self._burrow_kindle_alt_clock = true
        suppressNativeHeader(self)
        ensureOverlay(self)
        self:rescheduleHeaderRefreshIfNeeded()
        return result
    end

    local original_onReaderReady = ReaderCoptListener.onReaderReady
    function ReaderCoptListener:onReaderReady(...)
        local result = original_onReaderReady(self, ...)
        self._burrow_kindle_alt_clock = true
        suppressNativeHeader(self)
        ensureOverlay(self)
        return result
    end

    local original_updatePageInfoOverride = ReaderCoptListener.updatePageInfoOverride
    function ReaderCoptListener:updatePageInfoOverride(...)
        if self._burrow_kindle_alt_clock then
            suppressNativeHeader(self)
            return
        end
        return original_updatePageInfoOverride(self, ...)
    end

    local original_updateHeader = ReaderCoptListener.updateHeader
    function ReaderCoptListener:updateHeader(...)
        if self._burrow_kindle_alt_clock then
            suppressNativeHeader(self)
            ensureOverlay(self)
        end
        return original_updateHeader(self, ...)
    end

    local original_onUpdateHeader = ReaderCoptListener.onUpdateHeader
    function ReaderCoptListener:onUpdateHeader(...)
        if self._burrow_kindle_alt_clock then
            suppressNativeHeader(self)
        end
        return original_onUpdateHeader(self, ...)
    end

    local original_onSetStatusLine = ReaderCoptListener.onSetStatusLine
    function ReaderCoptListener:onSetStatusLine(...)
        if self._burrow_kindle_alt_clock then
            suppressNativeHeader(self)
            ensureOverlay(self)
        end
        local result = original_onSetStatusLine and original_onSetStatusLine(self, ...)
        if self._burrow_kindle_alt_clock
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
        if self._burrow_kindle_alt_clock then
            suppressNativeHeader(self)
            self:updateHeader()
        end
        return result
    end

    ReaderCoptListener._burrow_kindle_alt_clock_v1 = true
    Module.applied = true
    logger.info("Burrow Kindle-style Alt status clock installed")
    return true
end

return Module

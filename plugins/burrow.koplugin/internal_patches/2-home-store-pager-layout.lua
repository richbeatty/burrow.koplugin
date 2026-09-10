local MODULE_KEY = "burrow.internal.2_home_store_pager_layout"
local existing_module = package.loaded[MODULE_KEY]
if existing_module then return existing_module end

local Module = {
    key = MODULE_KEY,
    phase = "instance",
    filename = "2-home-store-pager-layout.lua",
}
package.loaded[MODULE_KEY] = Module

-- Keep the Home page indicator centered from its very first render.
--
-- The Home/Store footer can be constructed while its PageDots child still has
-- an earlier page count. PageDots updates itself later, but VerticalGroup may
-- retain the child offset calculated from the old width until another page
-- navigation causes a layout pass. This layer invalidates only the custom
-- footer geometry when the rendered dot-group width changes.

local function applyHomePagerLayoutFix()
    local CoverMenu = require("covermenu")
    local Menu = require("ui/widget/menu")

    if CoverMenu._burrow_home_store_pager_layout_patched then
        return true
    end

    local original_menu_init = CoverMenu.menuInit
    local original_update_page_info = CoverMenu.updatePageInfo
    local menu_was_using_covermenu_init = Menu.init == original_menu_init
    local menu_was_using_covermenu_update = Menu.updatePageInfo == original_update_page_info

    local function resetIfDotWidthChanged(menu)
        local state = menu and menu._home_store_state
        if not state or not menu._home_store_active or not state.dots then
            return
        end

        local ok, size = pcall(state.dots.getSize, state.dots)
        local width = ok and size and tonumber(size.w) or nil
        if not width or state._burrow_home_pager_dot_width == width then
            return
        end
        state._burrow_home_pager_dot_width = width

        -- The dots themselves already know the current page/page count. Only
        -- their parent alignment caches need to be rebuilt so the new width is
        -- centered immediately. Fixed footer dimensions and navigation widgets
        -- are left unchanged.
        if state.custom_root and state.custom_root.resetLayout then
            state.custom_root:resetLayout()
        end
        if state.custom_container and state.custom_container.resetLayout then
            state.custom_container:resetLayout()
        end
        if state.page_controls and state.page_controls.resetLayout then
            state.page_controls:resetLayout()
        end
        if state.footer and state.footer.resetLayout then
            state.footer:resetLayout()
        end
    end

    function CoverMenu:menuInit(...)
        local result = original_menu_init(self, ...)
        resetIfDotWidthChanged(self)
        return result
    end

    function CoverMenu:updatePageInfo(...)
        local result = original_update_page_info(self, ...)
        resetIfDotWidthChanged(self)
        return result
    end

    if menu_was_using_covermenu_init then
        Menu.init = CoverMenu.menuInit
    end
    if menu_was_using_covermenu_update then
        Menu.updatePageInfo = CoverMenu.updatePageInfo
    end

    CoverMenu._burrow_home_store_pager_layout_patched = true
    return true
end

Module.apply = applyHomePagerLayoutFix
return Module

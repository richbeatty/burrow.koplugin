-- Small Burrow-owned UI wording corrections applied before optional modules load.
local MODULE_KEY = "burrow.ui_text"
local existing = package.loaded[MODULE_KEY]
if existing then return existing end

local Module = {}
package.loaded[MODULE_KEY] = Module

local original_gettext = require("gettext")
if type(original_gettext) == "function" and not package.loaded["burrow.gettext_override"] then
    local function burrowGettext(text, ...)
        if text == "Reading controls" then
            text = "Reading Controls"
        end
        return original_gettext(text, ...)
    end

    package.loaded["gettext"] = burrowGettext
    package.loaded["burrow.gettext_override"] = true
end

return Module

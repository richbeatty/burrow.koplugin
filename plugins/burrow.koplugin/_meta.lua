local _ = require("gettext")
local V = require("burrow_version")
return {
    fullname = _("Burrow"),
    version = V.VERSION,
    description = _([[A unified library, Store, and reader interface for KOReader.]]),
}

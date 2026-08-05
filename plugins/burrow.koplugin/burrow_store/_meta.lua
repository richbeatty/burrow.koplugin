local _ = require("gettext")
local V = require("burrow_store.version")
return {
    name = "burrow_store",
    fullname = _("Burrow Store"),
    version = V.VERSION,
    description = _([[OPDS catalog browser with book cover display support. Browse and download books from online catalogs with visual cover previews in list or grid view.]]),
}

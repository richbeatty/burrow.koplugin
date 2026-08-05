from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PLUGIN = ROOT / "plugins" / "burrow.koplugin"


def replace_required(path: Path, old: str, new: str) -> None:
    text = path.read_text(encoding="utf-8")
    count = text.count(old)
    if count != 1:
        raise RuntimeError(f"Expected one match in {path}, found {count}")
    path.write_text(text.replace(old, new), encoding="utf-8")


library = PLUGIN / "burrow_library.lua"
replace_required(
    library,
    """-- Burrow core library runtime.\n--\n-- This module owns the legacy ProjectTitle-derived library hooks that were\n-- previously defined directly in main.lua. It is required once per KOReader\n-- process, keeps the original KOReader methods in one guarded runtime, and can\n-- attach the same method set to a newly sourced Burrow plugin class without\n-- wrapping KOReader a second time.\n""",
    """-- Burrow core library runtime.\n--\n-- This module owns Burrow's guarded library hooks. It is required once per\n-- KOReader process, keeps the original KOReader methods in one runtime, and can\n-- attach the same method set to a newly sourced Burrow plugin class without\n-- wrapping KOReader a second time.\n""",
)
replace_required(
    library,
    """        if not BurrowClass._plugin_only_notice_checked then\n            BurrowClass._plugin_only_notice_checked = true\n            local notices = {}\n            if BurrowLoader:isLegacyBootstrapPresent()\n                and not G_reader_settings:isTrue(\"burrow_bootstrap_removal_notice_v020\")\n            then\n                notices[#notices + 1] = _(\"Burrow no longer needs patches/2-burrow-bootstrap.lua. Remove that old file and restart KOReader.\")\n                G_reader_settings:makeTrue(\"burrow_bootstrap_removal_notice_v020\")\n            end\n            if BurrowClass._compatibility_notice then\n""",
    """        if not BurrowClass._startup_notice_checked then\n            BurrowClass._startup_notice_checked = true\n            local notices = {}\n            if BurrowClass._compatibility_notice then\n""",
)
replace_required(
    library,
    """                text = T(_(\"Burrow %1\\n\\nUnified library, Store, and reader interface for KOReader.\\n\\nPlugin-only installation. No bootstrap patch is required.\\n\\nLibrary engine derived from ProjectTitle by Joshua Cantrell. Store engine derived from OPDS Plus by greywolf1499. Licensed under GNU AGPL v3.\"), BurrowVersion.DISPLAY_VERSION),""",
    """                text = T(_(\"Burrow %1\\n\\nA unified library, Store, and reader interface for KOReader.\\n\\nInspired by ProjectTitle, OPDS Plus, and the wider KOReader community.\\n\\nLicensed under GNU AGPL v3.\"), BurrowVersion.DISPLAY_VERSION),""",
)

loader = PLUGIN / "burrow_loader.lua"
replace_required(loader, 'local DataStorage = require("datastorage")\n', "")
replace_required(
    loader,
    """function Loader:getLegacyBootstrapPath()\n    return DataStorage:getPatchesDir() .. \"/2-burrow-bootstrap.lua\"\nend\n\nfunction Loader:isLegacyBootstrapPresent()\n    return lfs.attributes(self:getLegacyBootstrapPath(), \"mode\") == \"file\"\nend\n\n""",
    "",
)

settings = PLUGIN / "burrow_settings.lua"
replace_required(
    settings,
    """-- Compatibility for the 0.1.x bootstrap. If an old bootstrap remains after an\n-- upgrade, it can still discover the files. Each file is now an idempotent\n-- plugin module, so the plugin-owned loader will not apply it twice.\nfunction BurrowSettings:getPatchManifest()\n    local files = {}\n    for _, module in ipairs(self:getModuleManifest()) do\n        if module.filename then\n            files[#files + 1] = module.filename\n        end\n    end\n    return files\nend\n\n""",
    "",
)
replace_required(settings, '        "burrow_bootstrap_removal_notice_v020",\n', "")

for path in (library, loader, settings, PLUGIN / "main.lua"):
    if "bootstrap" in path.read_text(encoding="utf-8").lower():
        raise RuntimeError(f"Obsolete bootstrap reference remains in {path}")

print("Public source cleanup completed.")

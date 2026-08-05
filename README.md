# Burrow 0.2.1 alpha

Burrow is a unified library, Store, and reader interface for KOReader. Version 0.2.1 is a **plugin-only build**: it loads its own interface modules directly from `burrow.koplugin` and no longer requires a file in KOReader's `patches` folder.

## Target

Burrow requires **KOReader 2026.07.1 or newer** and was last tested with **KOReader 2026.07.1**. Newer releases and nightlies are allowed to load with a warning instead of being blocked. Only versions older than the minimum, or builds explicitly listed as incompatible, are refused.

Optional interface modules are loaded by feature group. A module that fails before application disables only that feature. A module that fails while applying is quarantined for the next restart, while the core library remains available.

## Before installing

Back up the KOReader data folder. Disable KOReader's built-in **Cover Browser** and remove or disable the legacy standalone plugins listed in `REMOVE_OLD_FILES.txt`.

When upgrading from Burrow 0.1.x, also remove:

```text
patches/2-burrow-bootstrap.lua
```

The 0.2.1 plugin can tolerate that old bootstrap for one transitional startup, but it is no longer used and should be deleted.

## Install

1. Delete the existing `plugins/burrow.koplugin` folder.
2. Delete the old `patches/2-burrow-bootstrap.lua` file when present.
3. Extract this archive into the root of the KOReader data folder.
4. Confirm these paths exist:

```text
plugins/burrow.koplugin/main.lua
plugins/burrow.koplugin/_meta.lua
plugins/burrow.koplugin/burrow_loader.lua
plugins/burrow.koplugin/burrow_library.lua
```

5. Fully close and restart KOReader.

No Burrow file should be required in `koreader/patches/`.

## Plugin-only architecture

KOReader temporarily adds each plugin directory to `package.path` while sourcing its `main.lua`. Burrow uses that plugin load phase to:

- check compatibility and conflicts
- install Burrow-owned icons
- load early interface modules through explicit `apply()` entry points
- define the small Burrow plugin class
- attach the guarded core library runtime from `burrow_library.lua`
- preflight and apply optional feature modules by dependency group

Bundled modules are idempotent and identify themselves through `package.loaded`. The core library runtime keeps one process-wide set of original KOReader method references, so sourcing the plugin class again does not wrap those methods again. This also prevents an old 0.1.x bootstrap left behind during an upgrade from applying the same module twice.

## Settings and data migration

Burrow uses these persistent filenames:

```text
settings/burrow_library.sqlite3
settings/burrow_store.lua
```

On first startup, Burrow imports compatible data from earlier standalone installations when the new files do not yet exist. The legacy source files are left untouched as backups. Existing library metadata, display preferences, Store catalogs, download history, and Store preferences should therefore carry forward automatically.

Keep the legacy files until Burrow has started successfully and the library and Store have been verified. Exact legacy names are documented in `REMOVE_OLD_FILES.txt`.

Burrow does not bundle personal catalog URLs, account credentials, device identifiers, reading history, home-folder paths, download-folder paths, or book files.

## Included features

- Burrow library with cover grid and cover list modes
- Embedded Store with list and grid catalog views
- Download queue accessible from every Store catalog menu
- Book-format filtering that excludes cover images such as JPEG and PNG
- Home and Store footer with page indicators
- Optional Home and Store labels, including automatic hiding when no catalogs are configured
- Honey badger hero icon that follows KOReader light and dark mode
- Flexible library top bar and hero card
- Automatic virtual series folders
- Rounded book, folder, and series covers
- Bookmark-shaped reading percentage badges
- Numbered series badges and series-folder icon
- Independent cover gap and cover-size controls
- Cover resizing for books, folders, and virtual series folders
- Cover grid controls up to 8 by 8
- Native KOReader top-menu tabs retained without widget replacement
- Rounded quick settings with optional KoSync Push and Pull actions
- Independent reader status-bar margins and preset cycling
- Reading-location return control
- Paint-only rounded menu sheets for the native top menu and in-reader bottom menu

## Fonts and icons

Burrow does not bundle font files. It uses KOReader's registered UI font aliases.

Burrow bundles and installs every icon required by its custom features. Burrow-owned icon names are refreshed during upgrades. Generic KOReader names such as Favorites, History, Go Up, Last Document, and Plus are copied only when missing so existing themes and user customizations are not overwritten.

## License and acknowledgements

Burrow is distributed under GNU AGPL v3. See `LICENSE` and `NOTICE.md` for source acknowledgements and license details.

## Alpha status

All bundled Lua files are syntax-checked before packaging. The plugin-owned loader and old-bootstrap compatibility behavior are also tested with a loader harness. This build still requires testing on a real KOReader device before it should replace the 0.1.9 fallback.

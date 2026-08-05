# Burrow

[![Validate Burrow](https://github.com/richbeatty/burrow.koplugin/actions/workflows/validate.yml/badge.svg)](https://github.com/richbeatty/burrow.koplugin/actions/workflows/validate.yml)
[![License: AGPL v3](https://img.shields.io/badge/License-AGPL_v3-blue.svg)](LICENSE)

Burrow is a unified library, Store, and reader interface for KOReader. The current release candidate is **0.2.1 alpha**.

Burrow is a plugin-only build. It loads its interface modules directly from `burrow.koplugin` and does not require a file in KOReader's `patches` folder.

> Burrow is pre-release software. Back up the KOReader data folder before installing and keep a known-working Burrow package available for rollback.

## Compatibility

Burrow requires **KOReader 2026.07.1 or newer** and was last tested with **KOReader 2026.07.1**. Newer releases and nightlies are allowed to load with a warning instead of being blocked. Versions older than the minimum, and builds explicitly listed as incompatible, are refused.

Optional interface modules are loaded by feature group. A module that fails before application disables only that feature. A module that fails while applying is quarantined for the next restart, while the core library remains available.

## Before installing

Back up the KOReader data folder. Disable KOReader's built-in **Cover Browser** and remove or disable the legacy standalone plugins listed in [`REMOVE_OLD_FILES.txt`](REMOVE_OLD_FILES.txt).

When upgrading from Burrow 0.1.x, also remove:

```text
patches/2-burrow-bootstrap.lua
```

The current plugin can tolerate that old bootstrap for one transitional startup, but it is no longer used and should be deleted.

## Installation

1. Download or build the Burrow package.
2. Delete the existing `plugins/burrow.koplugin` folder when upgrading.
3. Delete the old `patches/2-burrow-bootstrap.lua` file when present.
4. Extract the package into the root of the KOReader data folder.
5. Confirm these paths exist:

```text
plugins/burrow.koplugin/main.lua
plugins/burrow.koplugin/_meta.lua
plugins/burrow.koplugin/burrow_loader.lua
plugins/burrow.koplugin/burrow_library.lua
```

6. Fully close and restart KOReader.

No Burrow file should be required in `koreader/patches/`.

See [`INSTALL.txt`](INSTALL.txt) for the compact installation checklist.

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
- Rounded Quick Settings with optional KoSync Push and Pull actions
- Independent reader status-bar margins and preset cycling
- Reading-location return control
- Paint-only rounded menu sheets for the native top menu and in-reader bottom menu

## Plugin architecture

KOReader temporarily adds each plugin directory to `package.path` while sourcing its `main.lua`. Burrow uses that load phase to:

- check compatibility and conflicts
- install Burrow-owned icons
- load early interface modules through explicit `apply()` entry points
- define the Burrow plugin class
- attach the guarded core library runtime from `burrow_library.lua`
- preflight and apply optional feature modules by dependency group

Bundled modules are idempotent and identify themselves through `package.loaded`. The core library runtime keeps one process-wide set of original KOReader method references, so sourcing the plugin class again does not wrap those methods again.

## Settings and migration

Burrow uses these persistent files:

```text
settings/burrow_library.sqlite3
settings/burrow_store.lua
```

On first startup, Burrow imports compatible data from earlier standalone installations when the new files do not yet exist. Legacy source files are left untouched as backups. Existing library metadata, display preferences, Store catalogs, download history, and Store preferences should carry forward automatically.

Keep the legacy files until Burrow has started successfully and the library and Store have been verified. Exact legacy names are documented in [`REMOVE_OLD_FILES.txt`](REMOVE_OLD_FILES.txt).

Burrow release packages do not include personal catalog URLs, account credentials, device identifiers, reading history, home-folder paths, download-folder paths, or book files.

## Repository layout

```text
plugins/burrow.koplugin/   Burrow plugin source
scripts/package.sh         Reproducible release packaging
.github/workflows/         Automated syntax, privacy, and package checks
```

The repository keeps the KOReader installation layout so release packages can be extracted directly into the KOReader data folder.

## Building a package

On Linux, macOS, or a compatible shell:

```bash
bash scripts/package.sh
```

The generated ZIP and SHA-256 checksum are placed in `dist/`. A fresh `FILES.sha256` manifest is generated inside the ZIP.

GitHub Actions also builds the package when a version tag beginning with `v` is pushed or when the packaging workflow is run manually.

## Reporting problems

Use the repository's bug-report form and include the Burrow version, KOReader version, device, exact reproduction steps, and the relevant portion of `crash.log`.

Before posting logs, remove passwords, tokens, private catalog URLs, personal paths, and book information. See [`CONTRIBUTING.md`](CONTRIBUTING.md) and [`SECURITY.md`](SECURITY.md).

## Fonts and icons

Burrow does not bundle font files. It uses KOReader's registered UI font aliases.

Burrow bundles every icon required by its custom features. Burrow-owned icon names are refreshed during upgrades. Generic KOReader names are copied only when missing so existing themes and user customizations are not overwritten.

## License and acknowledgements

Burrow is distributed under GNU AGPL v3. See [`LICENSE`](LICENSE) and [`NOTICE.md`](NOTICE.md) for source acknowledgements and license details.

Burrow includes and modifies work from ProjectTitle, OPDS Plus, KOReader, and credited community patches. Burrow is not affiliated with or endorsed by those upstream projects or contributors.

## Development status

Burrow remains alpha software while real-device testing continues. The current public-beta threshold is:

- no known startup or data-loss bugs
- clean installation and upgrade paths
- reliable series navigation and reader return behavior
- working Store downloads across multiple catalogs
- successful degraded-mode behavior when an optional module fails
- documented rollback and compatibility guidance

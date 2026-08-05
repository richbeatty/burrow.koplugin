# Burrow

[![Release](https://img.shields.io/github/v/release/richbeatty/burrow.koplugin?include_prereleases&label=release)](https://github.com/richbeatty/burrow.koplugin/releases)
[![Validate Burrow](https://github.com/richbeatty/burrow.koplugin/actions/workflows/validate.yml/badge.svg)](https://github.com/richbeatty/burrow.koplugin/actions/workflows/validate.yml)
[![License: AGPL v3](https://img.shields.io/badge/License-AGPL_v3-blue.svg)](LICENSE)

**A library-first interface for KOReader.**

Burrow brings your local library, online catalogs, series navigation, and useful reader controls into one consistent, cover-forward experience.

[Download Burrow](https://github.com/richbeatty/burrow.koplugin/releases) · [Report a bug](https://github.com/richbeatty/burrow.koplugin/issues/new?template=bug_report.yml) · [Request a feature](https://github.com/richbeatty/burrow.koplugin/issues/new?template=feature_request.yml)

> Burrow is pre-release software. Back up your KOReader data folder before installing.

## Screenshots

| Library | Store | Reader |
|:---:|:---:|:---:|
| _Screenshot coming soon_ | _Screenshot coming soon_ | _Screenshot coming soon_ |

<!--
Suggested screenshot paths:
- docs/screenshots/library.png
- docs/screenshots/store.png
- docs/screenshots/reader.png
-->

## Features

### Library

- Cover grid and cover list views
- Automatic series folders
- Rounded book, folder, and series covers
- Reading percentage and numbered series badges
- Adjustable cover size, spacing, and grids up to 8 by 8
- Flexible top bar, hero card, page indicators, and optional labels

### Store

- Browse OPDS catalogs in list or cover-grid views
- Download books directly into your library
- Download queue available from every catalog
- Book-format filtering that keeps cover images out of download choices
- Store styling that matches the local library

### Reader and controls

- Quick Settings with optional KoSync Push and Pull actions
- Independent reader status-bar margins and preset cycling
- Reading-location return control
- Native top and in-reader menus
- Light and dark mode-aware Burrow icons

## Compatibility

Burrow requires **KOReader 2026.07.1 or newer** and was last tested with **KOReader 2026.07.1**. Newer releases and nightlies may show a compatibility warning while testing continues.

KOReader's built-in **Cover Browser** should be disabled before using Burrow.

## Installation

1. Open [Releases](https://github.com/richbeatty/burrow.koplugin/releases) and download the latest `Burrow-*.zip` file.
2. Back up your KOReader data folder.
3. When upgrading, replace the existing `plugins/burrow.koplugin` folder.
4. Extract the ZIP into the root of the KOReader data folder.
5. Confirm the final path includes:

```text
plugins/burrow.koplugin/main.lua
```

6. Fully close and restart KOReader.

## Inspiration and credits

Burrow began as a personal effort to make KOReader feel more like one connected bookshelf instead of several separate tools. It would not exist without the work shared by the wider KOReader community:

- **[ProjectTitle](https://github.com/joshuacant/ProjectTitle)** by Joshua Cantrell was the cover-first library project that started this work.
- **OPDS Plus** by greywolf1499 provided the foundation for a richer catalog and Store experience.
- **[Zen UI](https://github.com/AnthonyGress/zen_ui.koplugin)** by Anthony Gress showed how a complete KOReader interface can feel focused, cohesive, and approachable.
- **[qewer33/koreader-patches](https://github.com/qewer33/koreader-patches)** and **[sebdelsol/KOReader.patches](https://github.com/sebdelsol/KOReader.patches)** provided ideas and techniques for interface controls and reader status bars.
- **[KOReader](https://github.com/koreader/koreader)** and its contributors make all of this possible.

See [`NOTICE.md`](NOTICE.md) for licensing and source acknowledgements.

## Status and contributing

Burrow is currently in alpha testing on real devices. Bug reports, focused fixes, documentation improvements, and additional device testing are welcome.

See [`CONTRIBUTING.md`](CONTRIBUTING.md) before opening a pull request. Please remove passwords, tokens, private catalog URLs, personal paths, and book information from screenshots or logs.

## License

Burrow is distributed under the [GNU Affero General Public License v3](LICENSE).

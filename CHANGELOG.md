# Changelog

All notable changes to Burrow will be documented here.

## [Unreleased]

## [0.3.6-beta] - 2026-08-05

### Added

- Extended the Home and Store footer to nested manual folders inside the configured library

### Fixed

- Anchored the folder and collection marker to the upper-left corner of the cover
- Applied real rounded-corner masking to manual-folder artwork in Cover Grid and Cover List

## [0.3.5-beta] - 2026-08-05

### Added

- Added the stacked-books series marker to physical folders and collection-style directory tiles in Cover Grid
- Added the Burrow Return to Library icon to the corresponding Cover List row

## [0.3.4-beta] - 2026-08-05

### Fixed

- Stopped the physical-folder consistency layer from rebuilding automatic-series tiles
- Removed duplicated automatic-series covers and doubled series captions
- Reduced physical-folder covers to the same caption-reserved height used by normal book covers
- Kept automatic-series Cover Grid rendering on its native Burrow path while retaining rounded full-size folder artwork in Cover List

## [0.3.3-beta] - 2026-08-05

### Fixed

- Prevented legacy ProjectTitle and generated folder-cover cache paths from being treated as custom folder images
- Physical folders now use only a real folder-local cover image or the first available book cover
- Published the folder fix under a new version so users do not receive a cached 0.3.2 package

## [0.3.2-beta] - 2026-08-05

### Added

- Added a Burrow setting to show or hide numbered series badges on book covers

### Changed

- Made physical folders and automatic-series folders use the same cover presentation
- Physical folders now use a custom folder cover when available, otherwise the first available book cover
- Removed the multi-cover mosaic fallback from folder tiles

### Fixed

- Reworked Cover List folder styling so full-size rounded covers are applied during every row build
- Prevented folder-name overlays and item-count circles from being redrawn over unified Cover Grid tiles

## [0.3.1-beta] - 2026-08-05

### Fixed

- Made folder and automatic-series artwork use the full available cover size in Cover List
- Applied the same rounded frame to folder and series artwork used for book covers in Cover List

## [0.3.0-beta] - 2026-08-05

### Added

- Public beta documentation and device screenshots
- Beta notes covering current compatibility and testing limits

### Changed

- Promoted Burrow from alpha to public beta
- Updated the last-tested KOReader version to 2026.07.2

### Fixed

- Capitalized the Reading Controls and Quick Settings panel titles

## [0.2.2-alpha] - 2026-08-05

### Fixed

- Made cover-size values above 100% render at the requested scale instead of being capped by the original tile dimensions
- Corrected the capitalization of the Reading Controls heading

## [0.2.1-alpha] - 2026-08-05

### Added

- Flexible KOReader compatibility policy with minimum and last-tested versions
- Dependency-aware degraded mode for optional feature groups
- Module status reporting and quarantined-feature retry controls
- Guarded `burrow_library.lua` core runtime

### Changed

- Removed the exact KOReader version lock
- Reduced `main.lua` to prerequisite checks, loader setup, and plugin-class creation
- Moved the core library runtime into a guarded module

### Fixed

- Prevented one optional module failure from disabling unrelated Burrow features
- Prevented repeated sourcing from wrapping KOReader methods more than once

## [0.2.0-alpha] - 2026-08-05

### Changed

- Converted Burrow into a self-contained KOReader plugin
- Added a phased, plugin-owned module loader

## [0.1.9-alpha] - 2026-08-05

### Fixed

- Rebuilt the return-to-library tile with a fresh, uncached icon widget after leaving the reader
- Prevented stale reader pixels from appearing through the return icon

## [0.1.4-alpha] - 2026-08-05

### Fixed

- Restored access to the Store download queue
- Excluded JPEG and other cover-image links from book download choices

## [0.1.3-alpha] - 2026-08-04

### Changed

- Consolidated the library and Store under Burrow-owned names
- Added one-time migration for compatible earlier settings and databases

## [0.1.0-alpha] - 2026-08-04

### Added

- Initial unified Burrow library, Store, and reader-interface package

[Unreleased]: https://github.com/richbeatty/burrow.koplugin/compare/v0.3.6-beta...HEAD
[0.3.6-beta]: https://github.com/richbeatty/burrow.koplugin/releases/tag/v0.3.6-beta
[0.3.5-beta]: https://github.com/richbeatty/burrow.koplugin/releases/tag/v0.3.5-beta
[0.3.4-beta]: https://github.com/richbeatty/burrow.koplugin/releases/tag/v0.3.4-beta
[0.3.3-beta]: https://github.com/richbeatty/burrow.koplugin/releases/tag/v0.3.3-beta
[0.3.2-beta]: https://github.com/richbeatty/burrow.koplugin/releases/tag/v0.3.2-beta
[0.3.1-beta]: https://github.com/richbeatty/burrow.koplugin/releases/tag/v0.3.1-beta
[0.3.0-beta]: https://github.com/richbeatty/burrow.koplugin/releases/tag/v0.3.0-beta
[0.2.2-alpha]: https://github.com/richbeatty/burrow.koplugin/releases/tag/v0.2.2-alpha
[0.2.1-alpha]: https://github.com/richbeatty/burrow.koplugin/releases/tag/v0.2.1-alpha
[0.2.0-alpha]: https://github.com/richbeatty/burrow.koplugin/releases/tag/v0.2.0-alpha

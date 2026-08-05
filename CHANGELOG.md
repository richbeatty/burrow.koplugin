# Changelog

All notable changes to Burrow will be documented here.

## [Unreleased]

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

[Unreleased]: https://github.com/richbeatty/burrow.koplugin/compare/v0.3.0-beta...HEAD
[0.3.0-beta]: https://github.com/richbeatty/burrow.koplugin/releases/tag/v0.3.0-beta
[0.2.2-alpha]: https://github.com/richbeatty/burrow.koplugin/releases/tag/v0.2.2-alpha
[0.2.1-alpha]: https://github.com/richbeatty/burrow.koplugin/releases/tag/v0.2.1-alpha
[0.2.0-alpha]: https://github.com/richbeatty/burrow.koplugin/releases/tag/v0.2.0-alpha

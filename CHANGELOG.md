# Changelog

All notable changes to Burrow will be documented here.

## [Unreleased]

### Planned

- Wider real-device testing across Android and dedicated e-ink devices
- Public beta packaging and screenshots
- Additional automated regression coverage

## [0.2.1-alpha] - 2026-08-05

### Added

- Flexible KOReader compatibility policy with minimum and last-tested versions
- Dependency-aware degraded mode for optional feature groups
- Module status reporting and quarantined-feature retry controls
- Guarded `burrow_library.lua` core runtime

### Changed

- Removed the exact KOReader version lock
- Reduced `main.lua` to prerequisite checks, loader setup, and plugin-class creation
- Moved remaining ProjectTitle-derived runtime patches into a guarded core module

### Fixed

- Prevented one optional module failure from disabling unrelated Burrow features
- Prevented repeated sourcing from wrapping KOReader methods more than once

## [0.2.0-alpha] - 2026-08-05

### Changed

- Removed the external bootstrap userpatch
- Converted Burrow to a plugin-only installation
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

- Renamed active ProjectTitle and OPDS Plus namespaces to Burrow-owned names
- Added one-time migration for compatible legacy settings and databases

## [0.1.0-alpha] - 2026-08-04

### Added

- Initial unified Burrow library, Store, and reader-interface package

[Unreleased]: https://github.com/richbeatty/burrow.koplugin/compare/v0.2.1-alpha...HEAD
[0.2.1-alpha]: https://github.com/richbeatty/burrow.koplugin/releases/tag/v0.2.1-alpha
[0.2.0-alpha]: https://github.com/richbeatty/burrow.koplugin/releases/tag/v0.2.0-alpha

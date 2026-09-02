# Changelog

All notable changes to Burrow will be documented here.

## [Unreleased]

## [0.4.7] - 2026-09-02

### Fixed

- Made Burrow Store sync settings, catalog flags, credentials, pending work, and sync checkpoints persist safely across KOReader restarts.
- Made OPDS sync discover a canonical immediate book shelf from navigation-only catalog roots, while avoiding recursive traversal through author, series, category, genre, and tag indexes.
- Hardened mixed navigation/book OPDS feeds and restored safe file-type filtering and subcatalog fallback behavior.
- Prevented false `Up to date!` results when no catalogs are enabled or when no downloadable book shelf can be found.
- Preserved catalog sync cursors when editing settings and prevented duplicate or lost pending sync work across interrupted runs.
- Refreshes the hero card as soon as background metadata and cover extraction finishes for newly synced books while keeping stale metadata and cover invalidation intact.

## [0.4.7-beta.3] - 2026-08-30

### Fixed

- Refreshes and repaints the hero card as soon as background metadata/cover extraction finishes for newly synced books, instead of waiting for a later full library refresh.
- Keeps post-sync BookInfo cache invalidation intact so replaced EPUBs cannot reuse stale cover or metadata.

## [0.4.7-beta.2] - 2026-08-30

### Fixed

- Made OPDS sync resolve a canonical immediate book shelf when the configured catalog URL is a navigation-only root, instead of requiring nested catalog URLs to end in `.opds`.
- Avoided recursively crawling author, series, category, genre, and tag indexes while discovering the book shelf, preventing duplicate-library traversal.
- Hardened mixed navigation/book feeds so sync uses the first real acquisition entry rather than assuming the first feed entry is always a book.
- Added a distinct message when a selected catalog contains no discoverable downloadable book shelf instead of incorrectly reporting `Up to date!`.

## [0.4.7-beta.1] - 2026-08-30

### Fixed

- Made Burrow Store sync folder, file-type, maximum-download, catalog, and credential changes persist immediately across KOReader restarts.
- Repaired the Store settings save path so the root settings table is no longer written inside itself, and migrated usable legacy nested Store settings into the current schema.
- Forwarded KOReader settings flush events from the main Burrow plugin to the embedded Store as a fallback persistence path.
- Persisted OPDS pending-sync work and catalog checkpoints together before downloads begin so interrupted or restarted syncs can resume safely.
- Persisted the pending-sync list again after each download pass so completed and failed work survives correctly.
- Prevented `Sync all catalogs` from reporting `Up to date!` when no catalogs are actually enabled for sync.
- Prevented duplicate pending-sync entries after a restart and preserved dormant pending items for catalogs that are not part of the current sync run.
- Preserved each catalog's `last_download` sync cursor when editing its settings.
- Restored the one-entry subcatalog fallback used by KOReader's OPDS sync path and made file-type filters case-insensitive.

## [0.4.6] - 2026-08-28

### Added

- Added stable page-map numbering for reflowable books so page labels stay consistent across font-size changes while preserving publisher-supplied page maps.
- Added an optional centered Kindle-style clock to KOReader's alternative top status bar without removing the native Alt status-bar choices.
- Added a selectable Quick Settings progress-sync provider so the existing Push sync and Pull sync buttons can use either KOReader Progress Sync or BookOrbit.
- Added adjustable hero-card height and responsive hero-card alignment controls.

### Changed

- Kept KOReader Progress Sync as the default Quick Settings sync provider so existing Burrow users keep their current behavior unless they explicitly select BookOrbit.
- Refined the centered Alt status clock spacing and removed CRengine's progress-gauge line while the centered clock is active.

### Fixed

- Invalidated KOReader's cached book metadata after Store downloads replace an existing file so updated series and other embedded metadata can be read immediately.


## [0.4.5] - 2026-08-16

### Fixed

- Restored the custom Burrow app-bar icon set used by older installations.
- Made newly installed user icons available to KOReader during the same first session instead of requiring an extra restart.

## [0.4.3] - 2026-08-14

### Added

- Added Bionic Reading for EPUB books with real bold fixation prefixes and cached shadow-EPUB rendering so original books remain untouched
- Added Search in Book compatibility and nearby semantic text anchoring for Bionic Reading
- Added last-used reader-presentation inheritance between books while keeping progress, bookmarks, highlights, annotations, reading status, stylesheet selection, and typography-language data book-specific
- Added an optional softer black and white palette for the KOReader interface and reflowable reader pages
- Added optional recoloring of small monochrome EPUB ornaments to match the soft reader palette while leaving covers, large images, and colored artwork unchanged
- Added a configurable two-sided Reading progress footer with separate left/right content, bottom inset, and horizontal inset controls
- Added proportional crop-to-fill for the current book cover on the sleep screen without stretching or distortion

### Changed

- Reader Controls opens Burrow Quick Settings as a standalone top panel instead of automatically opening KOReader's bottom Text/Config panel underneath it
- Reading-time values in Burrow's split footer now use compact human-readable wording such as `1 min` and `1 hr 12 min`
- The softer black and white palette is now opt-in and defaults off when no preference has been saved; explicit enabled or disabled choices are preserved

### Fixed

- Prevented Bionic Reading initialization failures from quarantining unrelated Quick Settings behavior
- Preserved Search in Book behavior across Bionic inline text-node boundaries
- Prevented unresolved normal-DOM XPointers from sending Bionic Reading back to the beginning of the book
- Stabilized the Reading progress footer lifecycle, placement, and Burrow Settings controls
- Removed duplicate Quick Settings button IDs left behind by earlier test builds
- Hid inactive soft-palette pager boundary chevrons without changing unrelated KOReader menus
- Kept the sleep-cover crop control in Burrow Settings > Appearance without modifying KOReader's native menu builders

### Known limitation

- Toggling Bionic Reading can occasionally move a few pages because real bold changes line wrapping and pagination; Burrow uses nearby semantic text anchoring with percentage fallback to keep the reader close to the same text


## [0.4.2] - 2026-08-13

### Added

- Added a GitHub-backed self-updater with Check for Updates in Burrow settings
- Added automatic update checks with stable and beta update-channel support
- Added update safety handling with backup/restore support for recovering the previous Burrow installation

### Changed

- Replaced the Quick Settings Restart glyph with a power-style icon so Restart is visually distinct from Rotate
- Replaced older arrow-based paged-dialog footers with Burrow's Home-style page indicator using a long active pill and small inactive dots
- Centered the Table of Contents page indicator to match the Home library pager

### Fixed

- Restored four-way Quick Settings rotation so Rotate cycles through all four physical screen orientations
- Restored remembered orientation between the library and reader and across full KOReader restarts
- Restored one-row and one-column grid configurations such as 2x1 and 1x3 while retaining the 8x8 maximum
- Improved automatic update scheduling, including due checks when automatic checks are enabled, retry behavior after failed checks, and checks after connectivity becomes available
- Prevented Quick Settings swipes from activating action tiles when a swipe ends over a button
- Kept frontlight and warmth slider dragging functional while consuming other Quick Settings swipes
- Scoped the Home-style Menu pager replacement to Table of Contents instead of modifying every KOReader Menu
- Restored the Home and Store footer while browsing Store after the beta.10 pager regression
- Prevented the pager customization from interfering with unrelated KOReader menus
- Updated Book Information and Table of Contents pagination to use the Home-style swipe-and-dots interface

## [0.4.2-beta.11] - 2026-08-13

### Fixed

- Prevented Quick Settings swipes from activating action tiles when a swipe ends over a button
- Kept frontlight and warmth slider dragging functional while consuming other Quick Settings swipes
- Scoped the Home-style Menu pager replacement to Table of Contents instead of modifying every KOReader Menu
- Restored the Home and Store footer while browsing Store after the beta.10 pager regression
- Prevented the beta.10 pager customization from interfering with unrelated KOReader menus

## [0.4.2-beta.10] - 2026-08-13

### Changed

- Replaced the Quick Settings Restart glyph with a power-style icon so Restart is visually distinct from Rotate
- Replaced the older arrow-based paged-dialog footers with Burrow's Home-style page indicator: a long active pill with small inactive dots
- Centered the Table of Contents page indicator at the bottom of the screen to match the Home library pager

### Fixed

- Restored four-way Quick Settings rotation so Rotate cycles through all four physical screen orientations
- Restored rotation persistence between the library and reader
- Persisted the selected orientation across a full KOReader restart by saving and explicitly restoring the File Manager rotation while rotation locking is enabled
- Restored grid minimums down to one row or one column, allowing layouts such as 2x1, 1x3, and other rectangular combinations while retaining the 8x8 maximum
- Improved automatic update checks so enabling Automatic update checks can immediately run a due check
- Improved automatic update checks when KOReader starts offline by checking again after network connectivity becomes available
- Kept automatic update checks on their recurring schedule while KOReader remains open
- Added retry scheduling after failed automatic checks without allowing checks to run more frequently than hourly
- Updated Book Information pagination to use the Home-style swipe-and-dots interface
- Updated Table of Contents pagination to use the Home-style swipe-and-dots interface

## [0.4.2-beta.9] - 2026-08-13

### Changed

- Promoted the updater, rotation, and grid recovery work to the prerelease channel for device testing

### Fixed

- Restored four-way Quick Settings rotation
- Restored remembered rotation between File Manager and Reader
- Restored one-row and one-column grid configurations
- Improved automatic update-check triggering for the beta update channel

## [0.4.1] - 2026-08-12

### Changed

- Centered the logo-only Burrow badger vertically in the header space above the hero card
- Added a Burrow-scoped Home icon with optically normalized stroke weight while keeping the original toolbar icons and touch-target spacing

### Fixed

- Prevented automatic-series and physical-folder borders from appearing as bright outlines in KOReader night mode

## [0.4.0] - 2026-08-12

### Added

- Added a cleaned-up Burrow Settings structure organized around Library, Navigation, Quick Settings, Store, Advanced, and About
- Added independent controls for book, physical-folder, and series titles under covers
- Added a Return to Library display option independent of automatic series grouping

### Changed

- Promoted Burrow out of beta as the first stable release
- Moved automatic series grouping out of KOReader's stock File Browser settings and into Burrow Settings
- Consolidated Quick Settings configuration under Burrow Settings
- Unified book, physical-folder, and virtual-series cover geometry so all three use the same sizing policy
- Kept cover size and spacing controls available from the cleaned-up Library settings
- Reordered the cover rendering modules so rounded book geometry is established before automatic series processing and final scaling

### Fixed

- Kept Return to Library available for manually organized folders when automatic series grouping is disabled
- Prevented titles from intersecting enlarged covers
- Prevented physical-folder rendering from discarding the configured cover size
- Corrected rebuilt cover tiles so the configured size is reapplied after reader returns and browser refreshes
- Replaced heuristic physical-folder cover discovery with explicit cover references in the final layout pass

## [0.3.8-beta] - 2026-08-06

### Changed

- Unified the Home and Store footer dimensions so the navigation remains the same size when switching screens
- Made the Store respect the configured Home and Store label-size setting
- Standardized the active-tab underline width across Home and Store

## [0.3.7-beta] - 2026-08-05

### Changed

- Improved Store cover loading and short-term catalog caching
- Reduced unnecessary cover-cache pruning and network requests
- Refined the Home and Store footer spacing and active underline

### Fixed

- Hid the return arrow while the Burrow Home and Store footer is active
- Hid page indicators on single-page Store menus
- Increased spacing between the Burrow icon and the first row of Store covers
- Repaired and compacted the Store download queue at startup
- Prevented duplicate queued downloads and removed completed direct downloads from the queue
- Persisted cleared download queues immediately

## [0.3.6-beta] - 2026-08-05

### Added

- Extended the Home and Store footer to nested manual folders inside the configured library

### Changed

- Promoted the device-tested 0.3.6 build to public beta

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

[Unreleased]: https://github.com/richbeatty/burrow.koplugin/compare/v0.4.6...HEAD
[0.4.6]: https://github.com/richbeatty/burrow.koplugin/releases/tag/v0.4.6
[0.4.5]: https://github.com/richbeatty/burrow.koplugin/releases/tag/v0.4.5
[0.4.3]: https://github.com/richbeatty/burrow.koplugin/releases/tag/v0.4.3
[0.4.2]: https://github.com/richbeatty/burrow.koplugin/releases/tag/v0.4.2
[0.4.2-beta.11]: https://github.com/richbeatty/burrow.koplugin/releases/tag/v0.4.2-beta.11
[0.4.2-beta.10]: https://github.com/richbeatty/burrow.koplugin/releases/tag/v0.4.2-beta.10
[0.4.2-beta.9]: https://github.com/richbeatty/burrow.koplugin/releases/tag/v0.4.2-beta.9
[0.4.1]: https://github.com/richbeatty/burrow.koplugin/releases/tag/v0.4.1
[0.4.0]: https://github.com/richbeatty/burrow.koplugin/releases/tag/v0.4.0
[0.3.8-beta]: https://github.com/richbeatty/burrow.koplugin/releases/tag/v0.3.8-beta
[0.3.7-beta]: https://github.com/richbeatty/burrow.koplugin/releases/tag/v0.3.7-beta
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

# Atelier

A personal Lightroom-style photo catalog and editor for macOS (Apple Silicon, macOS 15+).
Scope and architecture follow [Requirements/Atelier-PRD.md](Requirements/Atelier-PRD.md), the source of truth; update it in the same PR as any change it covers.

## Status: Phase 1, Catalog MVP

- Catalog: SQLite through GRDB, WAL mode, in `~/Pictures/Atelier/Atelier Catalog.atelier`.
  Volumes are matched by volume UUID (or remount URL for NAS shares), so remounting a drive or
  the NAS under another path keeps links working. Volumes show online or offline in the sidebar.
- Import: reference files in place, or copy to `YYYY/YYYY-MM-DD Event/` with SHA-256 verification.
  EXIF, GPS, embedded XMP and existing XMP sidecars are read on import. Keywords can be applied to
  the whole import.
- Previews: 256 px thumbnails and 2560 px previews built in the background, so offline photos stay browsable.
- Imports: every import becomes a named entry in the sidebar. Import more photos into an existing
  entry, rename it, remove photos from it, or delete it. Photos always stay in the catalog.
- Library: grid (NSCollectionView) and loupe, folders, collections (rename, delete), filter bar
  (rating, flag, label, text over filename, title, caption and keywords).
- XMP sidecars written on demand (Library > Write XMP, ⌘S), merged into existing sidecars.
- Catalog snapshot on quit, last 10 kept in `Backups/`.

### Culling keys

| Key | Action |
| --- | --- |
| 0–5 | Star rating |
| P / X / U | Pick / reject / unflag |
| 6 / 7 / 8 / 9 | Red / yellow / green / blue label (press again to clear) |
| E or Return, double-click | Loupe |
| G or Esc | Grid |
| ← → | Previous / next photo in loupe |

## Build and run

Requires Xcode 16 or later.

```sh
cd ~/RoshProjects/Atelier/App
swift build            # compile
swift test             # run the core tests
swift run AtelierApp   # launch the app
```

Or `open Package.swift` to work in Xcode and run the `AtelierApp` scheme.

## Not in Phase 1 yet

Smart collections, stacks, duplicate detection by perceptual hash, watch folders, video poster
frames, second backup destination on copy import, metadata presets beyond keywords, App Sandbox
with security-scoped bookmarks (the Phase 1 build runs unsandboxed), full-text search index.

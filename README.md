# Atelier

A personal Lightroom-style photo catalog and editor for macOS (Swift, SwiftUI + AppKit, Apple Silicon, macOS 15+).
Scope and architecture follow [Requirements/Atelier-PRD.md](Requirements/Atelier-PRD.md), the source of truth; update it in the same PR as any change it covers.
Agents working in this repo follow [AGENTS.md](AGENTS.md).

## Features

**Library**
- One catalog (SQLite through GRDB) in `~/Pictures/Atelier/Atelier Catalog.atelier`, snapshotted on quit (last 10 kept in `Backups/`).
- Import dialog: reference files in place or copy to `YYYY/YYYY-MM-DD Event/` with SHA-256 verification, from local drives or the megham NAS. Volumes are matched by UUID, so remounted drives keep their links and show online or offline.
- Every import is a named entry in the sidebar: import more into it, rename it, remove photos, or delete it.
- RAW+JPEG pairs shown as one photo, virtual copies, stacks for Edit In versions.
- Grid, loupe and a full-width filmstrip (F6); folders, collections and a filter bar (rating, flag, label, text).
- Culling view with keyboard rating, flags and labels, and match modes for pairs. Keys are rebindable in Settings > Keyboard; ⌘/ shows them all.
- EXIF, GPS and XMP read on import; XMP sidecars written on demand (Library > Write XMP for Selection, ⌘S, or automatically via Settings > Metadata).

**Develop** (non-destructive)
- RAW default look matched to the camera's embedded preview, plus a Profile menu.
- Basic, Tone Curve, HSL/Color, Color Grading, Detail and Effects panels, with histogram and before/after.
- Masking (brush, linear, radial, subject and luminance range), Lens Corrections, Transform with Upright and Guided guides, crop and straighten.
- History and snapshots, presets, zoom up to 200% at full resolution.

**Output and integrations**
- Export to JPEG, HEIC, TIFF or PNG.
- Edit In external apps through the Processor contract; edited files come back stacked with the original.
- Experimental AI tools through a headless ComfyUI server (Remove Object, Replace Background, Upscale), set up in Settings > AI. Nothing is bundled.
- Themes: System, Light, Dark, Graphite, Darkroom, Neutral Gray (Settings > Appearance).

## Run in Xcode

1. Xcode > File > Open…, pick `Package.swift` in the project folder.
2. Choose the **AtelierApp** scheme and **My Mac** as the destination in the toolbar.
3. Product > Run (⌘R).

From a terminal: `swift build`, `swift test`, `swift run AtelierApp`.

## CI

Every pull request and push to `main` runs [.github/workflows/build.yml](.github/workflows/build.yml) on a macOS runner: build, the `AtelierCoreTests` suite (including a camera-match check against sample Nikon Z RAWs), and layout snapshots of the main screens, uploaded as an artifact and published to the `layout-snapshots` branch.

## Not built yet

Smart collections, perceptual-hash duplicates, watch folders, App Sandbox, model registry and license gate for AI outputs, PSD round-trip, Core ML and MLX backends. See the PRD for the phase plan.

# Photo Catalog & Editor PRD

Oct 25, 2026 · Rosh · Revised Oct 26, 2026 (UX principles and import flow; import entries; Phase 1 before Phase 0; before/after compare views; export dialog; panels, zoom and right-click menus; Tone Curve, HSL / Color and Color Grading panels; editable point curve, panel below the toolbar, slider rows)

Live doc with diagrams: https://claude.ai/artifact/1T8xvdGuJTcGPTHStzDJvn

## Overview

Atelier (working name) is a native macOS photo catalog and non-destructive RAW editor for personal use, with first-class hooks for external editors and local AI models. It replaces a Lightroom subscription for one photographer and artist, and treats AI models as pluggable processing steps rather than a fixed feature set.

**Problem.** Lightroom locks the catalog, the develop pipeline and AI features into one subscription and one cloud. Local AI image models (Qwen-Image-Edit, FLUX.2 Klein, upscalers, segmenters) now match or beat built-in AI tools, but there is no catalog that can route a photo through them and keep the result versioned next to the original.

**Goals**

1. Catalog 100k+ images across local drives and the megham NAS, either in place or copied into a managed library.
2. Non-destructive develop module at Lightroom Classic parity for everyday work: RAW decode, tone, color, HSL, curves, local masks, presets.
3. Round-trip any photo to any external editor (Photoshop, Affinity, Pixelmator Pro, GIMP, Krita) and re-import the result as a stacked version.
4. Run AI edits through pluggable local backends (ComfyUI, Core ML, MLX) with a model registry that tracks license and allowed use.
5. Export web-ready images for roshandavis.com and social posts with presets for size, color space, watermark and metadata.

**Non-goals**

- Cloud sync, multi-user catalogs or mobile apps in v1.
- Training or fine-tuning models inside the app.
- Video editing (video files are cataloged and previewed only).
- Windows or Linux support.

## Target user and use cases

One user: a photographer and watercolor artist running an art business, editing on an Apple Silicon Mac, with originals split between local drives and a NAS. Every use case below must work fully offline except NAS access.

| # | Use case | Flow | Priority |
| --- | --- | --- | --- |
| U1 | Import a shoot | Card or folder, copy to managed library or reference in place, auto-tag, build previews; the photos land in a named import entry, new or existing | P0 |
| U2 | Cull and rate | Grid and loupe, flags, stars, color labels, compare and survey views, keyboard-only | P0 |
| U3 | Develop a RAW | Basic, tone curve, HSL, detail, lens corrections, local masks, sync settings across a batch | P0 |
| U4 | Photograph artwork | Color-checker profile, perspective correction, crop to canvas edge, accurate white balance | P0 |
| U5 | Round-trip to Photoshop or Affinity | Edit In, render a 16-bit TIFF or PSD, re-import as a stacked version | P0 |
| U6 | AI edit | Remove an object, replace a background, relight, upscale, using a chosen local model, result saved as a version | P0 |
| U7 | Batch AI | Run an AI recipe (for example, denoise then upscale) over a collection in a queue | P1 |
| U8 | Find anything | Search by keyword, EXIF, location, color, or natural language ("red barn in fog") | P1 |
| U9 | Publish to the website | Export preset: long edge 2048 px, sRGB, watermark, stripped GPS, WebP and JPEG | P0 |
| U10 | Work while the NAS is off | Browse, rate and edit smart previews; changes apply when the NAS reconnects | P1 |

## User experience principles

Every feature follows these rules. A feature is not done until it meets them.

1. **Start with the task, not a system dialog.** A command opens Atelier's own dialog first; file pickers are a step inside it, never the entry point.
2. **Show what will happen before it happens.** Dialogs preview the outcome (for example "Import 128 photos" on the button) and disable the action until it can succeed.
3. **Drag and drop everywhere it makes sense.** Folders and photos dropped on the window or a dialog do the obvious thing.
4. **Long work runs in the background, visibly.** Imports, previews, exports and AI jobs show progress, can be cancelled, and never block browsing or editing.
5. **Results appear as they arrive.** A new import is selected in the sidebar as soon as it starts, and photos fill in while it runs.
6. **Nothing destructive without a clear confirmation.** Deleting a list explains what is kept ("the photos stay in your catalog and on disk"). Originals are never modified.
7. **Errors name the file and the reason**, and the rest of the batch continues. Problems are listed on request instead of interrupting with alerts.
8. **Keyboard first for repeated work.** Culling, rating, flagging, labels and view switching all have single-key shortcuts; every command is in a menu.
9. **Sensible defaults, remembered choices.** Names default to the folder or event, and the last import mode and library folder are remembered.
10. **Plain language.** Labels describe what happens to the user's photos ("Leave files where they are", "Copy into my library folder"), not internal terms.

### Import flow

1. File > Import Photos (Shift-Cmd-I), the toolbar button, or dropping folders or photos on the window opens the Import dialog.
2. The dialog has four parts, top to bottom:
   - **Photos:** a drop zone with "Choose Folders or Photos…". Each chosen source shows its photo count and can be removed. "Add More…" adds sources.
   - **Import into:** a new import entry (named after the first folder by default) or an existing one.
   - **Files:** leave files where they are, or copy them into the library folder (dated folders, hash-verified).
   - **Keywords:** optional, applied to every photo.
3. The Import button reads "Import N Photos" and is disabled until at least one photo is found.
4. After Import, the dialog closes, the import entry is selected, photos appear as they are cataloged, and the status bar shows progress with Cancel.
5. When done, the status bar summarizes imported, already-in-catalog and unreadable files, with "Show Problems" listing any failures.

## Scope by release

The MVP proves the catalog, a usable develop module and one AI backend. Full develop parity and the plugin system come in v1.

| Area | MVP | v1 | Later |
| --- | --- | --- | --- |
| Catalog | Referenced and copied import, import entries, ratings, flags, labels, keywords, folders, collections | Smart collections, stacks, offline NAS mode, duplicate detection | Face grouping, map view |
| Develop | RAW decode, white balance, exposure, contrast, highlights, shadows, crop, straighten, history, snapshots | Tone curve, HSL, color grading, lens profiles, linear and radial masks, AI subject and sky masks, presets, batch sync | Brush masks with edge-aware refine, HDR and panorama merge, focus stacking |
| External editors | Edit In with any app, TIFF round-trip, stacked version | PSD round-trip, per-app settings, file watcher for live updates | Smart-object style re-edit |
| AI | ComfyUI backend, 3 recipes (object removal, upscale, background replace) | Core ML and MLX backends, recipe builder, batch queue, model registry with license gate | Natural-language search, auto-keywording, MCP server for agents |
| Export | JPEG, HEIC, 16-bit TIFF, PNG; long edge, sharpen for screen, sRGB, Display P3 or Adobe RGB; metadata all, without location, or none; quick settings for website and full size. WebP waits for an encoder (macOS ImageIO reads WebP but cannot write it) | Watermark, metadata rules, named presets, publish to folder | WooCommerce and Instagram publish services |

## Catalog and library management

The catalog never modifies an original file. Every photo is a database record pointing at a file by volume ID and relative path, so moving or remounting a drive does not break links.

### Import modes

1. **Reference in place.** Files stay where they are (local or NAS). The app records the volume UUID, relative path, file size, modified time and a content hash.
2. **Copy to managed library.** Files are copied into a dated folder template (default `YYYY/YYYY-MM-DD Event/`), renamed by an optional pattern, verified by hash after copy, and optionally backed up to a second destination in the same pass.
3. **Watch folder.** A folder is monitored with FSEvents; new files import automatically with a chosen preset (used for tethering and for the ComfyUI output folder).

### Requirements

- Formats: all RAW formats Apple's RAW engine supports, plus DNG, JPEG, HEIC, TIFF, PNG, WebP, PSD (composite only). Video files cataloged with poster frames.
- Import applies a metadata preset (copyright, creator, keywords) and a develop preset.
- Previews: a 256 px thumbnail and a 2560 px preview per photo, generated in the background. Thumbnails come first, from the file's embedded preview when it is large enough, and appear in the grid while the import is still running; 2560 px previews follow at lower priority, except the photo open in the loupe, which jumps the queue. Optional smart preview (lossy DNG, 2560 px long edge) for offline editing.
- Metadata: EXIF, IPTC and XMP read on import. Ratings, labels, keywords and develop settings written to XMP sidecars on demand or automatically, so other apps can read them.
- Organization: folders mirror disk; collections and collection sets are virtual; smart collections are saved queries; stacks group versions and bursts.
- Import entries: every import lands in a named entry listed in the sidebar (default name: the source folder, or the event name for copied imports). An import can create a new entry or add to an existing one; files already in the catalog join the entry without being imported twice. Entries can be renamed and deleted, and photos added to or removed from them by hand. Removing a photo from an entry, or deleting an entry, never removes the photo from the catalog.
- One catalog: a single catalog holds the whole library. Separate sets of photos are kept apart with import entries, folders and collections, not separate catalogs.
- Search: filter bar on any metadata field, combined with AND/OR. Full-text over keywords, titles and captions.
- Duplicate detection by content hash (exact) and perceptual hash (near-duplicates).

### NAS and offline volumes

- Each volume shows online or offline in the sidebar. Offline photos stay browsable through previews.
- Ratings, keywords and develop edits on offline photos are stored in the catalog and synced to XMP when the volume returns.
- Edits that need the original (export, Edit In, AI on full resolution) queue until the volume is online, or run on the smart preview if the user chooses.
- Missing-file finder: relink by hash when files move outside the app.

## Develop module

Edits are a versioned list of parameters stored in the catalog, rendered live on the GPU from the original. Nothing is baked into a file until export, Edit In or an AI step.

### Pipeline order

1. RAW decode and demosaic (CIRAWFilter): white balance, exposure baseline, noise reduction, lens correction.
2. Linear-light global adjustments: exposure, highlights, shadows, whites, blacks.
3. Tone: contrast, tone curve (parametric and point, per channel).
4. Color: vibrance, saturation, HSL (8 hues), color grading (shadows, midtones, highlights).
5. Detail: sharpening with masking, texture, clarity, dehaze.
6. Local adjustments: each mask carries its own subset of steps 2 to 5.
7. Geometry: crop, straighten, perspective (upright), vignette.
8. Output transform: working space (linear Rec. 2020 or ProPhoto) to display or export space.

### Tools and requirements

- Live preview at 60 fps on a 2560 px proxy; full-resolution render once the photo is zoomed past fit, and for export.
- The right column sits beside the photo and below the toolbar (never under it), like Lightroom's panel strip.
- Panels follow Lightroom's layout and order in the right column, each collapsible, remembered between sessions, with a dot and a reset button when it has edits. Right-click a panel header for Solo Mode (one panel open at a time), Expand All and Collapse All.
  - Histogram: RGB, from the current render, with shadow and highlight clipping warnings.
  - Basic: White Balance (Temp, Tint), Tone (Exposure, Contrast, Highlights, Shadows, Whites, Blacks), Presence (Texture, Clarity, Dehaze, Vibrance, Saturation).
  - Tone Curve: an editable point curve for RGB, Red, Green and Blue, drawn over that channel's histogram: click the curve to add a point and drag it, double-click a point to remove it, reset per channel. The overall result of Basic tone and the region sliders (Highlights, Lights, Darks, Shadows) shows as a faint line under the RGB curve.
  - HSL / Color: eight bands (Red, Orange, Yellow, Green, Aqua, Blue, Purple, Magenta) with Hue, Saturation and Luminance, shown one channel at a time or All, on colored slider tracks. Grays are never affected.
  - Color Grading: Shadows, Midtones, Highlights and Global wheels (drag for hue and saturation, slider for luminance), plus Blending and Balance.
  - Detail: Sharpening (Amount, Radius), Noise Reduction (Luminance, Color).
  - Effects: Post-Crop Vignetting (Amount, Midpoint), Grain (Amount, Size).
  - Next, in Lightroom's order: Lens Corrections, Transform, Calibration.
  - Sliders are compact Lightroom-style rows: name, slim track with a mark at the default and the change filled in, then the value (bold when changed). Double-click the name to reset, click the value to type one. Temp, Tint, Vibrance, Saturation and the HSL sliders have colored tracks; Temp moves in perceptual (logarithmic) steps.
- Zoom in loupe and develop: Fit, Fill, 100% (one photo pixel per screen pixel) and 200% in the bar under the photo; Z or a click toggles Fit and 100% at the clicked point; pinch, or ⌥/⌘ and scroll, zooms freely; drag to pan; View > Zoom In (⌘=), Zoom Out (⌘-), Zoom to Fit (⌘0). Zoom is kept when moving between photos.
- Right-click a photo in the grid, loupe or develop for: Open in Loupe, Edit in Develop, zoom levels, Show in Finder, Set Rating, Set Flag, Set Color Label, Develop Settings (Copy, Paste, Reset), Add to Collection, Remove from this collection or import, Write XMP Metadata, Export. Right-clicking an unselected grid photo selects it first.
- Masks: linear gradient, radial, brush, luminance range, color range, and AI masks (subject, sky, background, person) from Vision and Core ML. Masks combine with add, subtract, intersect.
- History: unlimited undo per photo; named snapshots; virtual copies share one original.
- Presets: save any subset of settings; apply on import, by drag, or by batch sync.
- Copy and paste settings with a checkbox picker; auto-sync across a selection.
- Before and after, chosen from a bar under the photo or with Y: side by side, a slider you drag across the photo (original on the left, edit on the right), and a full toggle with \.
- Color management: soft-proofing for sRGB web output and print profiles.
- Artwork profile: a DCP-style profile built from a ColorChecker shot, applied to all artwork photos for consistent color.

### Export dialog

File > Export… (⇧⌘E) or the toolbar Export button opens a dialog for the selected photos, or the open photo in loupe and develop. The dialog shows the count on its title and button, offers quick settings (Website: JPEG 2048 px, sRGB, sharpened, no location; Full-Size JPEG; Full-Size TIFF), and remembers the last choices. Exports run in the background with progress and Cancel in the status bar, keep original file names, never replace an existing file (a number is added), write the catalog's keywords, title, caption and rating, and reveal the files in Finder when done. Offline originals are listed as problems instead of stopping the batch.

### Settings format

Develop settings are a JSON document with a schema version, stored in the catalog and mirrored to XMP in a custom namespace. The renderer reads the same JSON, which makes settings diffable, scriptable and portable between catalogs.

## External editor integration

Every outside tool, whether a desktop app or an AI model, plugs in through one **Processor** contract: take a rendered image plus parameters, return an image file. The catalog then stores the result as a new version stacked on the source.

### Edit In (interactive apps)

1. User picks Edit In and an app from a configurable list (Photoshop, Affinity Photo, Pixelmator Pro, GIMP, Krita, any app that opens TIFF).
2. The app renders the photo with current develop settings to the chosen format: 16-bit TIFF (default), PSD, or the original file for apps that read RAW.
3. The file is written next to the original (or to a managed edits folder for read-only volumes) and opened with that app.
4. An FSEvents watcher detects saves and refreshes the preview live.
5. The edited file is cataloged as a version, stacked on top, inheriting metadata and keywords.

Per-app settings: file format, bit depth, color space, resolution, filename template, and whether to apply develop settings first.

### Processor plugins (headless tools)

For tools without a UI (command-line denoisers, scripts, other AI servers):

- A plugin is a folder with a `manifest.json` (name, version, inputs, parameters schema, output format) and an executable or an HTTP endpoint.
- The app runs it as a sandboxed child process (stdin/stdout JSON) or calls the endpoint, passing file paths and parameters.
- Parameters render as an auto-generated form from the JSON schema.
- Progress, cancel and error reporting follow one protocol for every plugin.
- Built-in AI backends (next section) implement the same contract, so a recipe can mix a Photoshop action, a CLI tool and an AI model.

## AI processing

AI runs locally through swappable backends behind the Processor contract. The app owns the UX (masks, prompts, references, versions); backends only turn inputs into pixels.

### Backends

| Backend | Use for | How the app talks to it | Release |
| --- | --- | --- | --- |
| ComfyUI (headless) | Generative edits: object removal, background replace, relight, multi-reference edits | HTTP + WebSocket API, workflow JSON templates with named inputs | MVP |
| Core ML | Fast on-device tasks: subject and sky masks, denoise, upscale | In-process via Vision and Core ML | v1 |
| MLX | Apple Silicon native diffusion and vision-language models | Bundled Python or Swift MLX worker process | v1 |
| Remote HTTP | A model on another machine or a paid API | Same plugin manifest, endpoint URL | Later |

### Starting model set (permissive licenses only)

| Model | Task | License |
| --- | --- | --- |
| Qwen-Image-Edit-2511 (GGUF) | Instruction-based editing, multi-reference | Apache 2.0 |
| FLUX.2 [klein] 4B | Fast edits and generation | Apache 2.0 |
| Ming-Image-0.1-Design | Website banners and text-heavy graphics with transparency | MIT |
| Segment Anything (SAM 2) | Click-to-mask | Apache 2.0 |
| Real-ESRGAN | Upscaling | BSD-3-Clause |

### Requirements

- **Model registry.** Each model entry stores name, version, backend, file paths, size, memory need, and license with an allowed-use flag (commercial, personal, research). The registry is a JSON file the user can edit.
- **License gate.** Exports tagged for the website or shop block versions produced by a non-commercial model and show which model made them. Qwen-Image-2.1, Fibo 2.0 and FLUX.2 [klein] 9B are allowed for experiments only.
- **Recipes.** A recipe is an ordered list of Processor steps with saved parameters (for example, denoise, then remove distractions, then upscale 2x). Recipes run on one photo or a batch queue.
- **Masked compositing.** Generative models regenerate the whole frame. The app composites only the masked region back onto the original, with feathering, so untouched pixels stay identical. Essential for artwork photos.
- **Inputs.** Prompt, negative prompt, mask, up to 4 reference images picked from the catalog, seed, steps, strength.
- **Provenance.** Every AI version records model, version, recipe, seed and prompt in the catalog and in XMP, so any result can be reproduced or audited.
- **Queue.** One GPU job at a time, background priority, cancel, retry, and an estimate per job. The UI stays responsive while a job runs.
- **Agent access (later).** An MCP server exposes search, develop and recipe tools so an AI agent can drive the catalog.

## Architecture and tech stack

A native Swift app with three layers; every external tool and AI model sits behind the Processor host, so adding a backend never touches the catalog or UI.

> Diagram (see live doc): App UI (Library, Develop, AI panel, Export) -> Core services (Catalog service, Render engine, Job queue, Processor host) -> Storage (catalog and previews on local SSD; originals on local drives and megham NAS) and Processors (external apps, plugins, AI backends).

AI backends and plugins run as separate processes, so a crash or memory spike in a model cannot take down the app.

| Layer | Choice | Why |
| --- | --- | --- |
| UI | SwiftUI, AppKit for the grid and loupe (NSCollectionView, Metal-backed views) | SwiftUI alone struggles with 100k-item grids |
| Catalog | SQLite via GRDB, WAL mode | Fast, embeddable, observable queries for live UI |
| RAW and render | Core Image (CIRAWFilter) on Metal, custom Metal kernels for masks and curves | Apple's RAW engine, GPU throughout |
| Masks | Vision (subject, person), Core ML (sky, SAM 2 port) | On-device, no Python for common masks |
| Metadata | ImageIO for EXIF and XMP; Exiv2 for formats ImageIO misses | Broad read and write coverage |
| File watching | FSEvents; security-scoped bookmarks | Sandbox-safe access to drives and NAS |
| AI bridge | URLSession + WebSocket client for ComfyUI; XPC or child process for MLX workers | Process isolation |
| Plugins | JSON manifest + child process (stdin/stdout JSON) or HTTP | Language-agnostic |
| Concurrency | Swift structured concurrency, actors for the catalog and job queue | Safe background work |

## Data model and storage

The catalog is one SQLite database (WAL mode) in a `.atelier` package on the local SSD, never on the NAS. Previews live beside it in a sharded cache folder.

| Entity | Key fields | Notes |
| --- | --- | --- |
| Volume | id, uuid, name, kind (local, NAS), last seen, online | Matched by volume UUID, not mount path |
| Folder | id, volume id, relative path | Mirrors disk |
| Asset | id, folder id, filename, content hash, perceptual hash, capture time, camera, lens, dimensions | One per original file |
| Version | id, asset id, kind (develop, virtual copy, external edit, AI), parent version id, file path (if rendered), created at | Forms the stack |
| DevelopSettings | version id, schema version, JSON, history JSON | Parameters only, no pixels |
| Mask | id, version id, kind, parameters or bitmap path | AI masks cached as 8-bit PNG |
| Metadata | asset id, rating, flag, label, title, caption, GPS | Synced to XMP |
| Keyword / Collection | id, name, parent id; join tables to assets | Hierarchical |
| ImportGroup | id, name, created at; join table to assets | One per import entry; deleting it keeps the photos |
| Processor | id, kind (app, plugin, backend), manifest JSON | External apps and AI backends |
| Model | id, processor id, name, version, license, allowed use, paths | The model registry |
| Job | id, version id, recipe JSON, model id, seed, status, timings, error | Also the provenance record |

Backups: the catalog is snapshotted on quit (keep the last 10) and can be copied to the NAS. XMP sidecars are the recovery path if the catalog is lost.

## Non-functional requirements

Targets assume an M4 Mac and a catalog of 100k photos. They are starting targets to validate in the MVP, not measured figures.

| Area | Requirement |
| --- | --- |
| Grid performance | Scroll 100k thumbnails without dropped frames; filter results in under 200 ms; opening a folder or import shows cached thumbnails immediately, and missing ones load asynchronously, on-screen first |
| Import | Catalog and thumbnail 1,000 RAW files in under 3 minutes from local SSD; NAS imports never block the UI |
| Develop | Slider changes reflect in under 50 ms on the proxy; loupe opens in under 300 ms from preview cache |
| AI jobs | Run in a separate process; a crash or out-of-memory never takes down the app or corrupts the catalog |
| Data safety | Originals are read-only; catalog writes are transactional; hash-verified copies on import |
| Privacy | No network calls except NAS, user-configured backends and update checks; no telemetry |
| Sandboxing | App Sandbox with security-scoped bookmarks for each volume and folder the user grants |
| Accessibility | Full keyboard workflow for culling; VoiceOver labels on all controls |
| Compatibility | macOS 15 and later, Apple Silicon only |

## Milestones and roadmap

Five phases, each closed by a gate you can test on your own photos. No dates yet; each phase starts only when the previous gate passes. Exception (decided Oct 26, 2026): Phase 1 is built before Phase 0, and the ComfyUI round-trip moves to Phase 3.

1. **Phase 0: Spike.** RAW decode on Metal, ComfyUI round-trip, SQLite catalog prototype.
   - Gate 1: a RAW renders, goes through ComfyUI and returns as a version.
2. **Phase 1: Catalog MVP.** Referenced and copied import, import entries, grid and loupe, ratings, keywords, collections, XMP sidecars.
   - Gate 2: a real shoot (a few hundred photos) from the SSD and one from the NAS cataloged without errors, with folders opening fast. Automated scale tests in CI cover larger catalogs (filtering 20k photos, importing 300 with previews).
3. **Phase 2: Develop basics and Edit In.** Basic panel, crop, history, presets, export presets, Photoshop and Affinity round-trip.
   - Gate 3: one full shoot culled, edited and exported without Lightroom.
4. **Phase 3: AI MVP.** ComfyUI recipes, masked compositing, model registry, license gate on export.
   - Gate 4: a website image with an AI edit passes the license gate.
5. **Phase 4: v1.** Curves, HSL, AI masks, Core ML and MLX backends, plugins, batch queue, offline NAS mode.

Phase 3 depends only on the catalog and Processor host, so it can start in parallel with Phase 2 if AI is the higher priority.

## Risks and open questions

The largest risk is scope: a full develop module at Lightroom parity is years of work for a team, so it is phased and the external-editor path covers gaps meanwhile.

| Risk | Impact | Mitigation |
| --- | --- | --- |
| Develop-module scope | MVP slips by months | Ship basic tools first; route advanced edits through Edit In until parity |
| RAW quality vs Adobe | Colors look different from Lightroom | Use Apple's RAW engine plus custom camera profiles; compare on a reference set |
| AI memory on Mac | Large models swap or fail | Quantized GGUF, one job at a time, memory check before a job starts |
| Model license drift | A model's license changes or is misread | Registry stores license per version; gate exports; review on every model update |
| NAS latency | Slow browsing and imports | Previews cached locally; background import; offline mode |
| Sandbox limits | Launching external apps or reading NAS paths fails | Security-scoped bookmarks; test early; fall back to a non-sandboxed build for personal use |

### Open questions

- [ ] How much unified memory does the target Mac have? It decides default model quantization.
- [ ] Import existing Lightroom Classic catalogs (ratings, keywords, collections) in v1, or start fresh?
- [ ] Should XMP sidecars be written automatically or only on demand?
- [ ] Keep ComfyUI as a separately installed dependency, or bundle a managed install?
- [ ] Which external editors are actually installed and used today?

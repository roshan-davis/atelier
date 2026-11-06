# Atelier

A personal Lightroom-style photo catalog and editor for macOS (Swift, SwiftUI + AppKit, macOS 15+; Apple Silicon first, Intel builds supported).
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
- EXIF, GPS and XMP read on import; XMP sidecars written on demand (Library > Write XMP for Selection, ⌘S, or automatically via Settings > Metadata), including current Develop settings, masks, retained history and snapshots for recovery on new import. Virtual copies, stacks and provenance still require catalog backups.

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
- Atelier Help (Help > Atelier Help, ⌘?): every tool explained with drawn controls and interactive before/after pictures, in `Sources/AtelierApp/Help`. The pages also open in a browser.

## Run in Xcode

1. Xcode > File > Open…, pick `Package.swift` in the project folder.
2. Choose the **AtelierApp** scheme and **My Mac** as the destination in the toolbar.
3. Product > Run (⌘R).

From a terminal: `swift build`, `swift test`, `swift run AtelierApp`.

## Release builds for Apple Silicon and Intel

`Scripts/build_macos_app.py` builds a movable, ad-hoc-signed `Atelier.app` (with the HDR
companion inside) in the Release configuration. `--arch` picks the processor:

```sh
python3 Scripts/build_macos_app.py --arch all        # arm64, x86_64 and universal, side by side
python3 Scripts/build_macos_app.py --arch universal  # one app that runs natively on both
python3 Scripts/build_macos_app.py --arch arm64      # Apple Silicon only
python3 Scripts/build_macos_app.py --arch x86_64     # Intel only
python3 Scripts/build_macos_app.py                   # this Mac's processor (as before)
```

Apps land in `.build/Applications/<arch>/Atelier.app` (`.build/Applications/Atelier.app` for
the default). Each arch is built with `swift build -c release --triple <arch>-apple-macosx15.0`;
universal joins the two executables with `lipo`. Check a result with
`lipo -archs .build/Applications/universal/Atelier.app/Contents/MacOS/AtelierApp`. An Intel build
runs on an Apple Silicon Mac under Rosetta (`softwareupdate --install-rosetta` once). These are
local builds, not notarized: another Mac needs right-click > Open the first time.

In Xcode (`Package.swift` open, scheme **AtelierApp**):

- Release instead of Debug: Product > Scheme > Edit Scheme… (⌘<), select **Run** on the left,
  **Info** tab, set **Build Configuration** to **Release**, Close. Set it back to Debug for everyday work.
- Universal: Product > Destination > **Any Mac (Apple Silicon, Intel)**, then Product > Build (⌘B).
  Any Mac builds but does not run.
- Run the Intel build on an Apple Silicon Mac: Product > Destination > Destination Architectures >
  **Show Rosetta Destinations**, then pick **My Mac (Rosetta)** and Product > Run (⌘R).

What differs on Intel: develop rendering, Vision masks and culling all work, but slower
(no Neural Engine, weaker GPUs). The ComfyUI AI tools need an Apple Silicon Mac in practice,
since current PyTorch no longer ships Intel Mac builds. MLX, when added, is Apple Silicon only
and must be hidden on Intel. See the PRD's Non-functional requirements > Compatibility.

## CI

[.github/workflows/build.yml](.github/workflows/build.yml) is configured for main pushes and PRs: macOS build, tests and layout snapshots. Check the actual run status; configuration alone does not prove Actions is available or passing. The local command below works without GitHub setup. RAW sample tests can skip when fixtures are unavailable.

## Not built yet

Smart collections, perceptual-hash duplicates, watch folders, App Sandbox, model registry and license gate for AI outputs, PSD round-trip, Core ML and MLX backends. See the PRD for the phase plan.

## Local pre-PR checks (Mac agents)

Run from your task branch before opening or updating a PR:

```sh
git fetch origin main
python3 Scripts/check_pr.py
# Optional existing RAW fixtures (no automatic downloads):
python3 Scripts/check_pr.py --samples /absolute/path/to/sample-raws
```

Requires full Xcode and Python 3; the first Swift build may resolve dependencies over the network.
The script checks committed and working-tree whitespace against the merge base with `origin/main`
(and untracked files, accepting Git’s silent new-file difference status while retaining whitespace and command failures), runs its regression tests, validates Help and its generated index without rewriting it,
builds the app, and runs the tests. It exits nonzero if any check fails and retains individual
logs plus `summary.txt` in `.build/local-checks/<run>/`, including the tested commit and working changes.
It honors `DEVELOPER_DIR`, otherwise uses selected Xcode or `/Applications/Xcode.app` when only
Command Line Tools are selected. It never changes the global Xcode selection.

Report failures and skipped RAW tests in the PR; a successful run does not certify real-RAW
coverage or visual layout. For UI changes, render and inspect layout snapshots separately.
This local check requires no GitHub configuration and leaves the existing Actions workflow intact.
Use `--base <ref>` to check against a different fetched PR base. Agent workspace and environment
rules are in [AGENTS.md](AGENTS.md#where-you-work). Cloud Claude cannot execute this Mac-only
command; its PR must disclose that and receive a Mac check before validation is complete.


## Single-image HDR MVP (work in progress)

On the HDR task branch, build both products once before running Atelier in Xcode:

~~~sh
swift build
~~~

Then choose the **AtelierApp** scheme, **My Mac**, and **Product > Run (⌘R)**.
Select one photo and choose **Photo > Edit In > HDR App (Original)…**.
The companion reads original pixels rather than baking Atelier Develop adjustments.
Use **Reset All** in an older test project to try the revised HDR starting look.
**Save & Return to Atelier** writes a full-resolution profiled 16-bit sRGB TIFF and
creates an owned-source HDR project beside it on first Save. Opening and closing without saving leaves no source copy; saves keep only the current and previous generations. Selecting the returned TIFF and choosing
the HDR menu again reopens that project; ordinary Save updates the same result.
**File > Save As New…** forks a project and creates a new result.

This is an implementation under active validation, not an accepted MachineryHDR match.
Bracket processing, presets and batch are not included. Back up the project package
and TIFF as well as the catalog. HDR engine tests run without opening either app:

~~~sh
swift test --filter AtelierHDRCoreTests
~~~

The engine is optimized in Debug builds: the first unoptimized full-resolution UI
trial exceeded two minutes at one CPU core. Revised timing and final-head validation
will be recorded in the PR before this work is considered ready.


To build a movable native app with the HDR companion included:

~~~sh
python3 Scripts/build_macos_app.py
~~~

The generated app is at .build/Applications/Atelier.app. Earlier generated apps
are renamed and preserved when rebuilding. This is a local ad-hoc-signed build,
not a notarized distribution.

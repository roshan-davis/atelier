# Atelier

A personal Lightroom-style photo catalog and editor for macOS (Swift, SwiftUI + AppKit, macOS 15+; Apple Silicon first, Intel builds supported).
Scope and architecture follow [Requirements/Atelier-PRD.md](Requirements/Atelier-PRD.md), the source of truth; update it in the same PR as any change it covers.
Agents working in this repo follow [AGENTS.md](AGENTS.md).

## Features

**Library**
- One catalog (SQLite through GRDB) in `~/Pictures/Atelier/Atelier Catalog.atelier`, snapshotted on quit (last 10 kept in `Backups/`). If the catalog can't open, Atelier offers to try again instead of starting an empty library.
- Import dialog in steps (Choose Photos, optional Cull, Import): reference files in place or copy to `YYYY/YYYY-MM-DD Event/` with SHA-256 verification, from local drives or the megham NAS, with a develop preset and keywords applied on the way in. Volumes are matched by UUID, so remounted drives keep their links and show online or offline.
- Every import is a named entry in the sidebar: import more into it, rename it, remove photos, or delete it. Imports and collections can be marked private; their photos stay hidden until View > Show Private Photos… (Touch ID or your password).
- RAW+JPEG pairs shown as one photo, virtual copies, stacks for Edit In, AI and HDR versions.
- Grid, Loupe and a full-width Filmstrip (F6) with its own source menu, filter and sort; folders, collections and a filter bar (rating, flag, label, text).
- Culling, before or after import: similar shots are grouped, the sharpest is suggested, and single keys keep or drop. Keys are rebindable in Settings > Keyboard; ⌘/ shows them all.
- EXIF, GPS and XMP read on import; XMP sidecars written on demand (Library > Write XMP for Selection, ⌘S, or automatically via Settings > Metadata), including current Develop settings, masks, retained history and snapshots, which are recovered when the photo is imported again. Virtual copies, stacks and provenance still require catalog backups.
- The last session (view, sidebar item, filter, photo, zoom and grid scroll) comes back on the next launch.

**Develop** (non-destructive)
- RAW default look matched to the camera's embedded preview (Nikon Zf and Z6 tuned), plus a Profile menu.
- Basic, Tone Curve, HSL / Color and B&W, Color Grading, Detail, Lens Corrections, Transform (Upright and Guided) and Effects (vignette, glow, grain) panels, each with an on/off switch; Tone Curve and Color Grading have their own preset menus.
- Masking: brush, linear and radial gradients, luminance range, Select Subject, Select Object and Select People (face, body skin, lips, eyes, hair, clothes from a model built into the app), with Grow, Refine Edge and optional Fine Edges (a BiRefNet download in Settings).
- Match Look: match the color and tone of a reference picture, including Rosh's built-in studies, with Protect Skin Tones.
- Crop and straighten, histogram with clipping, Before/After (side by side or slider), history and snapshots, presets with a built-in lookbook, zoom Fit, Fill, 100% and 200%.
- One slider everywhere: double-click the name to reset, click the value to type, ⌥-drag to see what it affects, arrow keys to nudge.

**Output and integrations**
- Export to JPEG, HEIC, TIFF or PNG with export presets (Website, Full-Size JPEG, Full-Size TIFF, plus your own) and a text or logo watermark.
- Edit In external apps through the Processor contract; edited files come back stacked with the original.
- Single-image HDR as a view of Atelier (Photo > HDR…, ⌃H), with presets; results are saved as 16-bit TIFFs stacked on the original.
- Experimental AI tools through a headless ComfyUI server (Remove Object, Replace Background, Upscale), set up in Settings > AI. Nothing generative is bundled.
- Chat agents over MCP (AT-050): chat apps can read the library (search, photo details, Develop settings, cull groups, menu commands) and, with Organize, select, rate, flag, label, keyword and collect photos with Undo, through the `atelier-mcp` helper, with access granted per app in Settings > Agents. With Edit they also adjust Develop sliders, run Auto, apply presets, sync and reset settings, crop and straighten, add masks and match a look. Several changes can go in one batch, all or nothing with one Undo. A chat app such as Docent can dock Atelier's window beside it and show found photos as a carousel (an MCP Apps view). Export follows in a later step; menus, keys and the photo menu are built from one action registry, so every command will reach chat apps with no extra porting. [Connect a chat app](Sources/AtelierApp/Help/chat-apps.html) shows setup for OpenCode, Cherry Studio, Ollama (ollmcp), LM Studio, Open WebUI, Claude and Codex.
- Themes: System, Light, Dark, Graphite, Darkroom, Neutral Gray (Settings > Appearance). Settings has a sidebar of panes and a keyboard map.
- Atelier Help (Help > Atelier Help, ⌘?): every tool explained with drawn controls and interactive before/after pictures, in `Sources/AtelierApp/Help`. The pages also open in a browser.

## Documentation

| Where | What it covers |
| --- | --- |
| [Requirements/Atelier-PRD.md](Requirements/Atelier-PRD.md) | The product spec, the single source of truth |
| [BACKLOG.md](BACKLOG.md) | Every action item and its status |
| [AGENTS.md](AGENTS.md) | Rules for coding agents: design principles, git, PRs, checks |
| Atelier Help, [`Sources/AtelierApp/Help`](Sources/AtelierApp/Help) | The user guide, shown in the app (⌘?) |
| [Docs/Atelier-Architecture.html](Docs/Atelier-Architecture.html) | How the app is built: targets, catalog, render pipeline and threads, models, agents, and where code and PRD differ (as of c146785) |
| [Docs/Automated-Testing.md](Docs/Automated-Testing.md) | Running the local checks and reading their reports |
| [Docs/Atelier-Agent-Actions.md](Docs/Atelier-Agent-Actions.md) | Design of the MCP server, action registry and agent access (AT-050) |
| [Docs/agent-actions-catalog.json](Docs/agent-actions-catalog.json) | Every command agents can reach, generated by `Scripts/agent_catalog.py` |

## Run in Xcode

1. Xcode > File > Open…, pick `Package.swift` in the project folder.
2. Choose the **AtelierApp** scheme and **My Mac** as the destination in the toolbar.
3. Product > Run (⌘R).

From a terminal: `swift build`, `swift test`, `swift run AtelierApp`.

## Release builds for Apple Silicon and Intel

`Scripts/build_macos_app.py` builds a movable, ad-hoc-signed `Atelier.app` (HDR is part of
it) in the Release configuration. `--arch` picks the processor:

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

Smart collections, perceptual-hash duplicates, watch folders, App Sandbox, model registry and license gate for AI outputs, PSD round-trip, Core ML and MLX AI backends (only the selection-mask models run in the app today), bracketed HDR and panorama merge, and chat agents that export or run AI recipes (AT-050e onward; reading, organizing and Develop edits work today). See the PRD for the phase plan and [BACKLOG.md](BACKLOG.md) for status.

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
coverage or visual layout. Use the UI checks in the [Automated testing guide](Docs/Automated-Testing.md) for app interactions and screenshots.
This local check requires no GitHub configuration and leaves the existing Actions workflow intact.
Use `--base <ref>` to check against a different fetched PR base. Agent workspace and environment
rules are in [AGENTS.md](AGENTS.md#where-you-work). Cloud Claude cannot execute this Mac-only
command; its PR must disclose that and receive a Mac check before validation is complete.


## Automated testing

See the [Automated testing guide](Docs/Automated-Testing.md) for the full suite, repeatable
group selectors, suggested checks by change type, and how to read the reports.

## Single-image HDR

HDR is a view of Atelier, next to Grid, Loupe and Develop (there is no separate HDR app
any more). Select one photo and choose **Photo > HDR… (⌃H)**, or right-click > **Edit in HDR**.
HDR reads the original's pixels rather than baking Atelier Develop adjustments, and has its
own presets with thumbnails. **Save HDR** (⌘S in HDR) writes a full-resolution profiled
16-bit sRGB TIFF stacked with the original and creates an HDR project (`.atelierhdr`)
beside it on first Save. Leaving without saving asks first; nothing is written before a Save,
and saves keep only the current and previous generations. **Photo > HDR…** on the HDR TIFF
reopens its project; **File > Save HDR As New… (⇧⌘S)** forks a new project and result.
Help > Atelier Help > Single-image HDR explains every control.

Bracket processing and batch are not built yet. Back up the project package and TIFF as
well as the catalog. HDR engine tests run without opening the app:

~~~sh
swift test --filter AtelierHDRCoreTests
~~~

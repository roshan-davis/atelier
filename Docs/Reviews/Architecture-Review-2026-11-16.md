# Atelier architecture review (November 16, 2026)

Reviewed at `main` `c146785` by Claude (cloud, source only). Nothing here was built, run or timed: every finding is from reading the code, with `file:line` evidence. A finding marked "measure first" needs a Mac timing (Frame Diagnostics, Instruments, `DevelopTimingLog`) before anyone fixes it, per AGENTS.md "Measure before optimizing".

This is a list of proposals, not approved work. BACKLOG AT-076 tracks it; each item gets its own scope talk with Rosh before it is built.

**Scale:** 271 Swift files, about 69,600 lines in `Sources`; about 15,800 lines of tests (72 Core test files, 13 App test files).

**Severity:** High = can lose edits, freeze the app or use gigabytes; Medium = noticeable slowness or a pattern that keeps causing bugs; Low = cleanup. **Effort:** S = under a day, M = a few days, L = a week or more.

## Top 10, in the order I'd do them

| # | Item | Area | Severity | Effort |
|---|---|---|---|---|
| 1 | [M1](#m1) Free full-size images, sessions and Core Image caches when they're not needed, and on memory pressure | Memory | High | S–M |
| 2 | [P1](#p1) Develop history stores up to 500 full copies of the settings, written on the main thread every save | Performance, memory | High | M |
| 3 | [C1](#c1) Fine Edges/Depth: a model run holds a lock that the main thread also takes (up to ~22 s beachball), and status strings are read without it | Concurrency | High | S |
| 4 | [P2](#p2) Batch edits (Sync, presets on a selection, Match Look, agents) write one transaction per photo, and each one re-runs the whole Grid query | Performance | Medium–High | S–M |
| 5 | [D1](#d1) Develop's tools are six separate on/off flags that switch each other off by hand; make it one "active tool" value | Design | Medium | M |
| 6 | [E1](#e1) Catalog writes that fail silently (`try?`) can drop an edit or a note with no message | Reliability | Medium | S |
| 7 | [R1](#r1) One ONNX model host instead of three copies of session, lock, Core ML fallback and status code | Reuse | Medium | M |
| 8 | [M2](#m2) One shared Core Image context (or a small fixed set) instead of eleven, including one per HDR decode | Memory, performance | Medium | S |
| 9 | [D2](#d2) Split `DevelopController` (3,720 lines, 87 published properties) into per-tool models; move to `@Observable` | Modularity, performance | Medium | L (stepwise) |
| 10 | [C2](#c2) Turn on Swift 6 strict concurrency one module at a time, starting with the app-neutral ones | Concurrency | Medium | M–L |

The rest are below by topic. A short list of what is already good is at the end, so nobody "fixes" it.

---

## Memory and resource lifetimes

<a id="m1"></a>

### M1 — Full-size images and caches live until the next photo opens

**Severity High, effort S–M, measure first (peak memory in Activity Monitor or Instruments > Allocations).**

- Zooming past Fit renders `fullImage` and `fullBeforeImage` at full size and keeps a `fullSession` with its own step-1 cache (`DevelopController.swift:591-610`). They are cleared only when another photo opens (`DevelopController.swift:903-908`). Zooming back to Fit, leaving Develop for the Grid, or closing an inline app leaves them in memory. A 45 MP photo is about 180 MB per RGBA8 `NSImage`, and the step-1 intermediate is half-float RGBA (about 360 MB), so one zoomed photo can hold well over half a gigabyte after you've moved on.
- The interactive caches rely on Core Image keeping `insertingIntermediate(cache: true)` images (`DevelopRenderer.swift:530-532`, `716-731`; Lens Blur at `LensBlur.swift:230`). Nothing ever calls `CIContext.clearCaches()`, and nothing in the app listens for memory pressure (no `DispatchSource.makeMemoryPressureSource` anywhere in `Sources`).
- ONNX sessions stay loaded for the life of the process once used: Fine Edges Hair Detail is "about 1 GB in memory" by its own comment (`FineEdges.swift:176-177`), plus the depth model (`DepthMap.swift:156-158`) and PMRID (`AIDenoise.swift:497-499`).

**Proposal:**
1. When the view goes back to Fit for a few seconds, or Develop is left, drop `fullImage`, `fullBeforeImage` and `fullSession` (the proxy stays). Re-zooming re-renders, which is the same cost as the first zoom today.
2. One small `MemoryPressure` helper in `AtelierCore` that, on `.warning`, clears `DevelopRenderer.shared.context` caches, `PreviewImages`, the thumbnail cache's oldest half, the Fine Edges/Depth/Denoise sessions and the matte caches; on `.critical` also the full-size images. Every cache registers with it, so a new cache can't forget.
3. Unload an ONNX session after a few minutes unused (the Core ML compile cache on disk makes the reload cheap; CPU-only reloads cost the session build time, so measure it).

<a id="m2"></a>

### M2 — Eleven Core Image contexts

**Severity Medium, effort S.**

Each `CIContext` has its own Metal command queue, caches and compiled kernels. Atelier makes them in `DevelopRenderer.swift:25` (main), `ClippingOverlay.swift:16`, `PeopleSkin.swift:920`, `DisplaySurfaces.swift:96`, `AIImaging.swift:28`, `ExportSheet.swift:33`, `DevelopController.swift:349`, `SplashView.swift:53` (a new one per call), `HDRPreviewRenderer.swift:25`, and `HDRImageIO.swift:8`, which is an instance property, so every `HDRImageIO()` makes a new context: `HDRController.swift:150`, `173` and `455` each make one per decode.

**Proposal:** keep `DevelopRenderer.shared.context` for working-space renders and one pass-through context (`DisplaySurfaces.passthroughContext`) for color-unmanaged work; give `HDRImageIO` a static context like `HDRPreviewRenderer`; render the splash and crop thumbnails through the shared ones. Contexts that truly need different options stay, but as static singletons, never per call.

<a id="m3"></a>

### M3 — Thumbnail cache has a count limit but no size limit

**Severity Low–Medium, effort S.** `ThumbnailLoader` keeps up to 4,000 decoded `NSImage`s with no `totalCostLimit` (`GridView.swift:381-388`). At 256 px that's up to about 700 MB. Its decode queue is concurrent with no width limit (`GridView.swift:384`), so a fast scroll can start many threads at once (GCD caps it, but each blocks on file I/O). **Proposal:** set `totalCostLimit` (pixel bytes as cost) and use an `OperationQueue` with a fixed width, like `PreviewScheduler` already does (`PreviewScheduler.swift:30-34`).

<a id="m4"></a>

### M4 — Small unbounded or never-removed items

**Severity Low, effort S.**
- `ShootingInfoCache` grows by one entry per file ever shown, never trimmed (`PhotoInfoViews.swift:10`). Small entries, but use `NSCache`.
- Block-based observers in `DevelopController.init` are never removed (`DevelopController.swift:796-825`); `DepthModelDownload` and `FineEdgesDownload` likewise. They capture `[weak self]`, and these objects live for the whole app, so nothing leaks today. It becomes a leak (and double handling) the day a second `DevelopController` exists, for example if an inline app gets its own. Keep the tokens and remove them in `deinit`, or use `NotificationCenter.notifications(named:)` in a task that ends with the object.

Retain cycles: I found none. Back-references to `LibraryModel` are `weak` throughout (`HDRController.swift:51`, `CullModel.swift:152`, `MatchLook.swift:139`, `ImportFlow.swift:67`, `AIController.swift:34`, `AgentServer.swift:47`), and action handlers receive the model as a parameter instead of capturing it (`LibraryModel+Actions.swift:40` onward). That's good; keep it.

---

## Performance

<a id="p1"></a>

### P1 — Develop history: 500 full snapshots, saved on the main thread

**Severity High for heavily edited photos, effort M, measure first (`DevelopTimingLog` already logs the save time and step count).**

- Each history step stores a complete `DevelopSettings` (`DevelopHistory.swift:9-12`), up to 500 steps (`DevelopHistory.swift:36`). Settings include brush strokes as point arrays (`Masks.swift:452`), spots and masks, so a photo with a lot of brushing carries hundreds of near-identical copies.
- `flushSave` runs on the main thread 400 ms after an edit settles (`DevelopController.swift:2795-2826`) and JSON-encodes the whole history every time (`Catalog+Develop.swift:111-120`), then rewrites the whole `historyJson` column. The cost grows with every step: the 300th edit pays for all 300.
- The full history also lives in memory as `@Published history`.

**Proposal (pick after measuring):**
1. Store steps as differences from the previous step (only the changed keys of the settings JSON), with a full copy every 25 steps so undo and "jump to step" stay fast.
2. Or move history to its own table, one row per step, so a save appends one row instead of rewriting all of them.
3. Either way, encode off the main thread (AGENTS.md already names this as AT-039 D5 "pending-save layer").

Needs a catalog migration that reads old `historyJson` as-is (backward compatible, per AGENTS.md).

<a id="p2"></a>

### P2 — Batch edits: one transaction and one Grid refetch per photo

**Severity Medium–High on large selections, effort S–M.**

- `applyDevelopSettings` loops `saveDevelopSettings` per photo (`Catalog+Develop.swift:131-133`); each does two separate reads and then a write (`Catalog+Develop.swift:123-128`), so it's three round trips and one commit per photo. Same pattern in Match Look (`MatchLook.swift:540`, `666`) and Develop's preset/sync paths (`DevelopController.swift:1812`, `1837`, `1918`).
- The Grid's rows come from a `ValueObservation` that tracks `developSettings` and `metadata` (`LibraryModel.swift:292-305`, query at `LibraryFilter.swift:122-146`). Every commit re-runs the whole Grid query, which parses each photo's develop JSON (`json_each`, `json_type`, `json_array_length` at `LibraryFilter.swift:135-136`, `232-234`) and runs several correlated subqueries per row. Syncing 500 photos means up to 500 full Grid queries. A single slider save in Develop also re-runs it.
- The read-then-write is also not atomic: an agent edit landing between the read and the write of `saveDevelopSettings` is lost.

**Proposal:**
1. `Catalog.updateDevelop(_ ids:, step:, change:)` that reads, records history and writes inside one `writer.write` for the whole batch. One commit, one Grid refetch, no lost update.
2. Keep `hasEdits`, `isCropped` and `hasMasks` as real columns on `developSettings` (set when saving) instead of parsing JSON per row per refetch.
3. Optionally exclude `historyJson`-only changes from the rows observation.

<a id="p3"></a>

### P3 — Export is serial

**Severity Medium for big exports, effort M, measure first.** `Exporter` renders and writes one photo at a time (`Exporter.swift:144`). The GPU audit (GPU-n list, Nov 7) noted it; still true. Two renders in flight (GPU render of one while the CPU encodes and writes the previous) usually gives most of the gain without memory blowing up.

<a id="p4"></a>

### P4 — HDR hashes the whole original on every open

**Severity Medium on the NAS, effort S.** `openOriginal` reads the whole file for SHA-256 before showing anything (`HDRController.swift:145`). On "megham" that's the full RAW over the network each time. The hash is only needed at the first Save (the PRD says the project copy is made then). **Proposal:** hash at Save, or reuse the import-time `contentHash` (`asset.contentHash`, indexed at `Catalog.swift:94`) when the file's size and date are unchanged.

<a id="p5"></a>

### P5 — Every `DevelopController` change refreshes every view that watches it

**Severity Medium, effort L (see D2), measure first.** `DevelopController` is one `ObservableObject` with 87 `@Published` properties (`DevelopController.swift:105-1318`), observed by 44 views in 15 files. With `ObservableObject`, setting any of them (a status message, `isFindingLines`, `spotGenerations`) re-evaluates all 44. The slider work (AT-039, `DevelopMeasures` at `DevelopController.swift:50`, equatable rows) already took the hottest values out; what's left is the long tail. macOS 15 is the minimum, so the Observation framework (`@Observable`) is available and tracks per property; there are zero uses of it today.

---

## Concurrency and thread safety

<a id="c1"></a>

### C1 — Model locks held for the whole run; status read without the lock

**Severity High (main-thread hang), effort S.**

- `FineEdges.matte` takes `lock` and holds it for the whole model run (`FineEdges.swift:262-264`), which is about 22 s for Hair Detail on the CPU (BACKLOG AT-074). `FineEdges.remove` and `install` call `forgetSession()`, which takes the same lock (`FineEdges.swift:196-203`, called at `136` and `162`), and Settings calls `remove` on the main actor (`FineEdgesDownload.swift:85-87`). Removing or re-downloading a model while a matte is being found freezes the app until the run ends. `DepthMap` has the same shape (`DepthMap.swift:160-165`, `224`).
- `failure`, `lastRun`, `isWorking` and `runs` are `nonisolated(unsafe) static var`s written on the model's thread and read on the main thread with no lock (`FineEdges.swift:179-185`; read at `DevelopController.swift:3162-3163`, `3409` and `FineEdgesDownload.swift:34`). A `String` read while another thread writes it is a data race that can crash.

**Proposal:** split the lock in two: one for the session handle (held only to get or replace it; runs keep their own reference), one for status. Publish status as one `Sendable` struct behind the status lock (or an actor) and read it through that. Part of R1.

<a id="c2"></a>

### C2 — Swift 5 language mode with many manual escapes

**Severity Medium, effort M–L, stepwise.** The package builds in Swift 5 mode (`Package.swift:68`), so the compiler checks none of the cross-thread code. Today there are 44 `@unchecked Sendable` types, 21 `nonisolated(unsafe)` statics, 76 `MainActor.assumeIsolated`, 36 `NSLock`s, 14 private `DispatchQueue`s and 43 `Task.detached` (counted in `Sources`). C1's race is the kind of bug strict checking finds at compile time.

**Proposal:** turn on Swift 6 mode per target with `swiftSettings: [.swiftLanguageMode(.v6)]`, in this order: `AgentActions`, `AgentMCP`, `AtelierActions` (small, app-neutral, already Sendable-minded), then `AtelierHDRCore`, then `AtelierCore`, then the app. Fix what each step reports; don't convert everything to actors at once.

<a id="c3"></a>

### C3 — Five ways to run background work

**Severity Low–Medium, effort ongoing.** GCD queues, `OperationQueue` (`PreviewScheduler`), `Task.detached`, `NSCondition` (`FineMatteCache.swift:47`) and `LockedValue`/`LatestJob` all coexist. Each is fine on its own; the mix makes cancellation and priority inconsistent (an `OperationQueue` job isn't cancelled by a Swift task's cancel). **Proposal:** a short "how background work is written" note in AGENTS.md: `LatestJob` for "latest wins" renders, `OperationQueue` for bounded pools, structured `Task` for one-off work with Cancel, nothing new on bare GCD.

---

## Design choices

<a id="d1"></a>

### D1 — Develop's tools are six flags that switch each other off

**Severity Medium, effort M.** `isCropping`, `isAIOpen`, `isMasking`, `isGuiding`, `isRemoving` and `isLensBlurring` are separate `@Published` Booleans whose `didSet`s turn the others off by hand (`DevelopController.swift:331-455`, and `lensBlurModeChanged` at `3050-3075` turns off five more plus `picker`, `showingBefore`, `compareMode`). Each flag change fires more `didSet`s, each its own view refresh. Adding a tool means editing every other tool's `didSet`; forgetting one gives two tools open at once. Rosh's Nov 16 reports (closing the inline app hid main's Navigator; Presets showing in the mode) are this class of bug: a mode's state leaking into another because there's no single owner.

**Proposal:** one `@Published var tool: DevelopTool?` (`.crop`, `.ai`, `.masking(scope)`, `.guided`, `.remove`, `.lensBlur`) with `enter`/`leave` hooks per tool and a list of what each tool hides (Filmstrip, Navigator, Presets, histogram). Keep `isCropping` and friends as computed properties at first so views don't all change in one PR. It also makes "which panels does this tool show" a property of the tool, which is what the inline-app rule needs.

<a id="d2"></a>

### D2 — `DevelopController` holds every tool

**Severity Medium, effort L, do it in steps.** 3,720 lines (`DevelopController.swift`) plus six extension files; it owns rendering, saving, history, presets, white balance, color grading, lens/transform, masks, spots, Lens Blur mode and Lens Blur Refine (MARK sections at `849` to `3420`). Extensions split the file but not the state: everything still lives on one object. LibraryModel (1,240 lines, 27 published) has the same shape on a smaller scale.

**Proposal, one PR each, no behaviour change:**
1. `DevelopRenderPipeline` (sessions, queues, `LiveFrameSink`, full-size render): no `@Published` at all.
2. `DevelopDocument` (settings, history, save): the one place edits go through.
3. One small `@Observable` model per tool (Masking, Spots, Lens Blur, Crop/Guided), owned by the controller, which the tool's views watch instead of the whole controller. This is also what P5 needs.

The rule "reusable components take show/hide options from the caller" (MasksPanel shared by Masking and Lens Blur Refine) stays: the per-tool models are what the caller passes in.

<a id="d3"></a>

### D3 — The Processor contract exists in the PRD but not in code

**Severity Medium (spec drift), effort M.** The PRD says every outside tool and AI model goes through one Processor contract and a Processor host with a job queue (`Atelier-PRD.md:529`, `594`, `651-653`, `685`). In code, `ProcessorDocument` is HDR-only (`processorID = "atelier.hdr"` hard-coded at `ProcessorDocument.swift:21`, checked at `34`), and Edit In, ComfyUI (`AIRunner`), Generative Fill, AI Denoise, Depth, Fine Edges and Lens Blur each have their own request, progress, cancel and result path. BACKLOG AT-008 already proposes this; it's still open. The PRD should either say what exists today or AT-008 should get scheduled, so new AI features stop adding paths. **Proposal:** the smallest useful step is a `Processor` protocol with request, progress, cancel and result types, adopted first by Edit In and ComfyUI (the two outside processors), leaving in-process mask models out of it until agreed.

<a id="d4"></a>

### D4 — HDR has two engines that must match

**Severity Low–Medium, effort M.** The GPU preview kernel copies the CPU tone mapper's arithmetic (`HDRPreviewRenderer.swift:6-15`); Save and 100% zoom use the CPU path (`HDRToneMapper.swift`, loops at `246-247`, `294-306`). Any change to one has to be made by hand in the other. **Proposal:** a test that renders the same photo through both and fails past a set difference (if there isn't one already), and long-term one GPU path for Save too, with the CPU version kept only as the test reference.

---

## Reusability and duplication

<a id="r1"></a>

### R1 — Three copies of the ONNX model host

**Severity Medium, effort M.** `DepthMap.swift:156-215`, `FineEdges.swift:174-252` and `AIDenoise.swift:497-545` each have their own `ORTEnv`, session, lock, Core ML provider attempt, CPU fallback, `NSLog`, failure string and status notification. Each got its own Core ML crash workaround on Nov 16 (comments at `DepthMap.swift:166-171`, `FineEdges.swift:205-210`, `AIDenoise.swift:530-534`). **Proposal:** one `ONNXModelHost` in Core (environment shared by all, session load with provider choice and fallback, lock split as in C1, status struct, unload on idle or memory pressure as in M1). Each model keeps only its pre- and post-processing. The next model (Sky, a scene model, an upscaler) then costs a few lines.

<a id="r2"></a>

### R2 — Model download UI twice

**Severity Low, effort S.** `DepthModelDownload.swift` (100 lines) and `FineEdgesDownload.swift` (210 lines) are two `@MainActor` singletons with the same installed/progress/error/cancel shape over `ModelDownload` (`ModelDownload.swift`). **Proposal:** one generic `ModelDownloadState` for any downloadable model, with Fine Edges' two-model choice as a parameter.

<a id="r3"></a>

### R3 — Develop edits outside the open photo take different paths

**Severity Medium, effort S (comes with P2).** Agents, Match Look, presets on a selection, Generative Fill finishing on a photo that's no longer open (`DevelopController+SpotGeneration.swift:92-99`) and Sync each read, change and save settings their own way. One `Catalog.updateDevelop` (P2) gives them one path with history, one transaction and one error.

---

## Consistency

<a id="e1"></a>

### E1 — Catalog writes that fail silently

**Severity Medium, effort S.** 13 catalog writes in the app use `try?` and drop the error. The ones that lose user work without a word: Generative Fill's saved patch on a photo not open (`DevelopController+SpotGeneration.swift:99`, its reads at `92-94` too), Match Look's per-photo save (`MatchLook.swift:540`), and notes add/update/delete (`PhotoNotesModel.swift:115-169`). Develop's own save shows "Could not save" (`DevelopController.swift:2828-2830`); these should do the same (status line, or a problem in `problems`). **Proposal:** a small `report(_ error:, while:)` on `LibraryModel` and a check in the existing source tests that fails on a new `try? catalog.` write, like `ClickGestureTests` does for double-clicks.

<a id="e2"></a>

### E2 — Settings keys as loose strings

**Severity Low–Medium, effort S–M.** 169 `UserDefaults.standard` uses in 31 files plus 84 `@AppStorage`s, all with string keys (for example `DevelopController.swift:458-513`, `563-570`). A typo makes a setting silently not stick; two files can read the same key with different defaults. `LibraryModel` also re-checks a filter on every `UserDefaults` change in the app (`LibraryModel.swift:259-265`), including every brush-size tick. **Proposal:** one `Preferences` file with typed keys and defaults (`static let brushSize = Key<Double>("masks.brushSize", default: 0.06)`) used by both `UserDefaults` and `@AppStorage`.

<a id="e3"></a>

### E3 — Logging

**Severity Low, effort S.** `NSLog` (11), `print` (46, in `LayoutSnapshots.swift` and `AgentsSettings.swift`), one `Logger`, and the custom `DevelopTimingLog`. **Proposal:** `os.Logger` with one subsystem and a category per area (render, catalog, models, agents), so Console.app can filter, and keep `DevelopTimingLog` for its trace files.

<a id="e4"></a>

### E4 — Core's `Develop` folder holds everything

**Severity Low, effort S.** `Sources/AtelierCore/Develop` is one flat folder of 62 files: the renderer, masks, Match Look, four ML models, downloads, presets, history and catalog extensions. **Proposal:** subfolders (`Render`, `Masks`, `LookMatch`, `Models`, `Presets`, `History`). No code change, only moves, so do it in a quiet moment to avoid conflicts with open PRs.

---

## Modularity and build

<a id="b1"></a>

### B1 — ONNX Runtime linked into all of Core

**Severity Low–Medium, effort M.** `onnxruntime` is a dependency of `AtelierCore` (`Package.swift:43-45`), so every Core test, `PresetQualification` and anything else that only needs the catalog or the renderer links it (tens of MB, slower links). **Proposal:** move the model code (R1's host plus Depth, Fine Edges, Denoise) into an `AtelierModels` target that Core's render code reaches through a small protocol, or at least keep it in its own folder (E4) so the split is cheap later.

<a id="b2"></a>

### B2 — Test hooks compiled into the shipping app

**Severity Low, effort S.** `LayoutSnapshots.swift` (1,199 lines) and the `ATELIER_SNAPSHOTS`, `ATELIER_UI_SMOKE` and related environment switches are in the app target, with 12 references from app code (for example `SessionRestore.swift:12`). **Proposal:** wrap them in `#if DEBUG` or a `SNAPSHOTS` compilation condition so Release builds (`build_macos_app.py`) leave them out.

<a id="b3"></a>

### B3 — `-O` in Debug through `unsafeFlags`

**Severity Low, effort S.** `AtelierCore` and `AtelierHDRCore` use `.unsafeFlags(["-O"])` in Debug (`Package.swift:38`, `51`), because per-pixel Swift loops are slow unoptimized. It works, but it hides those loops' cost in Debug and SwiftPM refuses unsafe flags if Core is ever used as a remote dependency (Easel). **Proposal:** none needed now; note it, and as loops move to the GPU (AGENTS.md "Pixels stay on the GPU"), drop the flag.

---

## Already good: keep these

- **Action registry** (`Sources/AgentActions`, `LibraryModel+Actions.swift`): menus, keys and MCP tools from one declaration, handlers receive the model instead of capturing it, and a test enforces it.
- **Live render path**: "latest wins" coalescing (`LatestJob`), frames straight to IOSurfaces (`DisplaySurfaces`, `LiveFrameSink`), histogram on its own object (`DevelopMeasures`), step-1 cache by `CorrectedKey`.
- **Catalog**: GRDB `DatabasePool` in WAL mode (`Catalog.swift:48-49`), migrations never edited, Grid fed by a `ValueObservation` off the main thread.
- **Bounded caches where it matters**: `PreviewImages` (8 previews, LRU), `FineMatteCache` (6), `SubjectMaskCache` (8), `ColorLUT` (4, locked), `correctedCache` and `lensBlurCache` (2 each).
- **Weak back-references** to `LibraryModel` everywhere, and `PreviewScheduler`'s bounded, cancellable queues.
- **Shared pieces table** in AGENTS.md (zoom, cursors, clicks, sliders, delete feedback): the right tool against the "same bug in every tool" problem; D1 and R1 extend the same idea.

## What I didn't check

Not built, run or profiled; no Mac. I didn't review the image math (look, color accuracy), the agent socket's security model, Import on the NAS (separate report, `atelier-nas-read-path`), or the UI against the PRD's UX principles. Earlier reviews this builds on: Codex's Oct 30 review (BACKLOG evidence baseline) and the Nov 7 GPU audit (project files `reports/gpu-performance-audit-2026-11-07.md`); items those found that are since fixed aren't repeated.

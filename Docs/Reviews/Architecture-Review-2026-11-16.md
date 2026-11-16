# Atelier architecture review (November 16, 2026)

Reviewed at `main` `c146785` by Claude (cloud, source only). Nothing here was built, run or timed: every finding is from reading the code, with `file:line` evidence. Sizes are pixel payloads worked out from dimensions, not measured resident memory, and counts of call sites or watchers are source counts, not runtime counts. A finding marked "measure first" needs a Mac timing or memory capture (Frame Diagnostics, `DevelopTimingLog`, Instruments) before anyone fixes it, per AGENTS.md "Measure before optimizing".

**Revised** after Rosh's review on PR #155 (head `90abdd8`), which checked each finding against the source and qualified severity, effort and several claims. Those qualifications are folded in below.

This is a list of proposals, not approved work. BACKLOG AT-076 tracks it; each item gets its own scope talk with Rosh before it is built.

**Scale:** 271 Swift files, about 69,600 lines in `Sources`; about 15,800 lines of tests (72 Core test files, 13 App test files).

**Severity:** High = can lose edits, freeze the app or use gigabytes; Medium = noticeable slowness or a pattern that keeps causing bugs; Low = cleanup. **Effort:** S = under a day, M = a few days, L = a week or more.

## Order of work (agreed in review)

1. **Fix first:** [C1](#c1) (Remove stalls on a running model; status read without the lock), then [E1](#e1) (silent catalog write failures).
2. **Measure in parallel**, on the same representative heavy edits: [M1](#m1) (full-size retention, caches) and [P1](#p1) (history size and main-thread save time).
3. **Next:** [P2](#p2)'s write boundary (one transaction per batch), and measure its observation cost.
4. **Then:** [D1](#d1) (one tool-state model), keeping Lens Blur Refine nested inside Lens Blur.

| Item | Area | Severity | Effort |
|---|---|---|---|
| [C1](#c1) Model lock held through inference; main-actor Remove waits; status strings race | Concurrency | High | S narrow fix; M host redesign |
| [E1](#e1) Catalog writes that fail silently (`try?`) | Reliability | Medium | S per path |
| [M1](#m1) Full-size images/session kept until the next open; no memory-pressure handling | Memory | High on large RAWs (plausible, measure) | S–M shedding; M+ coordinated eviction |
| [P1](#p1) History: up to 500 full settings copies, encoded and written on main | Performance | High if timings confirm | M background save; M–L schema change |
| [P2](#p2) Batch edits: one transaction per photo, partial completion, non-atomic read-write | Performance, reliability | Medium | S–M bulk transform; M+ schema/background |
| [D1](#d1) Six tool flags switched off by hand | Design | Medium | M |
| [R1](#r1) Three copies of ONNX session setup | Reuse | Medium | M narrow; M+ with C1/M1 policy |
| [M2](#m2) Ten `CIContext` construction sites, some per call | Memory, performance | Medium | S for per-call churn, if measured |
| [D2](#d2) `DevelopController` holds every tool | Modularity | Medium | L, only for concrete ownership problems |
| [C2](#c2) Swift 6 language mode, one module at a time | Concurrency | Medium | M–L |

The rest are below by topic. A list of what is already good is at the end, so nobody "fixes" it.

---

## Memory and resource lifetimes

<a id="m1"></a>

### M1 — Full-size images and caches live until the next photo opens

**Severity High on large RAWs (plausible, not measured); effort S–M for measured full-size shedding, M or more for coordinated eviction that also prevents stale work. Measure first.**

- Zooming past Fit renders `fullImage` and `fullBeforeImage` at full size and keeps a `fullSession` with its own step-1 cache (`DevelopController.swift:591-610`). Going back to Fit or leaving Develop clears neither the full session nor the two full-frame slots; only opening another photo does (`DevelopController.swift:903-908`; Fit only resets `wantsFullResolution`, `LibraryModel.swift:114`). Lens Blur's Close can put back the previous unblurred frame and clears its saved return bundle, but leaves the normal full-session lifetime as it is (`DevelopController.swift:3051-3099`, `3185-3214`).
- Payload sizes at 45 MP: about 180 MB per RGBA8 frame and about 360 MB per half-float RGBA frame. These are what the dimensions imply, not a measured resident total.
- The interactive caches rely on Core Image keeping `insertingIntermediate(cache: true)` images (`DevelopRenderer.swift:530-532`, `716-731`; Lens Blur at `LensBlur.swift:230`). Nothing calls `CIContext.clearCaches()`, and there is no memory-pressure handler in the app (no `DispatchSource.makeMemoryPressureSource` in `Sources`).
- ONNX sessions are cached with no idle eviction (`DepthMap.swift:156-165`, `FineEdges.swift:174-249`, `AIDenoise.swift:497-499`). Fine Edges does replace its session when the model changes and can forget it explicitly, and Depth can forget its session. The "about 1 GB" for Hair Detail is the code's own comment (`FineEdges.swift:176`), not a measurement.

**Proposal:**
1. Measure peak and settled memory on one heavy 45 MP edit: zoom in, back to Fit, leave Develop.
2. If it's as large as the payloads suggest, drop `fullImage`, `fullBeforeImage` and `fullSession` a few seconds after returning to Fit or leaving Develop (the proxy stays; re-zooming re-renders). Make sure a full-size render still in flight can't land after the drop.
3. Separately, a memory-pressure policy that clears registered caches (Core Image, `PreviewImages`, thumbnails, model sessions, mattes). This one needs care about stale work, so it is the M+ part.

<a id="m2"></a>

### M2 — Core Image contexts made per call

**Severity Medium; effort S for obvious per-call churn, once measured.** There are ten `CIContext` construction sites in `Sources`, with mixed lifetimes, not ten permanent contexts: static or shared ones in `DevelopRenderer.swift:25`, `ClippingOverlay.swift:16`, `PeopleSkin.swift:920`, `DisplaySurfaces.swift:96`, `AIImaging.swift:28`, `ExportSheet.swift:33`, `DevelopController.swift:349` and `HDRPreviewRenderer.swift:25` (a shared optional instance, `18-27`). The per-call ones are `SplashView.swift:53` (a new context per call) and `HDRImageIO.swift:8`, an instance property: HDR keeps one retained `previewIO` per controller (`HDRController.swift:75`) and makes a new `HDRImageIO`, so a new context, for each transient decode (`HDRController.swift:150`, `173`, `455`). How many Metal queues this means can't be told from the initializers.

**Proposal:** fix the per-call ones first (a static context for `HDRImageIO`'s decodes; the splash through a shared context). Merging contexts that differ in working or output color space, priority or cache policy needs its own qualification, so don't do that as part of this.

<a id="m3"></a>

### M3 — Thumbnail cache has a count limit but no size limit

**Severity Low–Medium, effort S.** `ThumbnailLoader` keeps up to 4,000 decoded `NSImage`s with no `totalCostLimit` (`GridView.swift:381-410`). If every one were a full 256 × 256 RGBA8 image, that would be about 700 MB; that's a worst-case estimate, not what the cache actually holds. Its decode queue is concurrent with no width limit (`GridView.swift:384`). **Proposal:** set `totalCostLimit` (pixel bytes as cost) and give decodes a fixed width, as `PreviewScheduler` does (`PreviewScheduler.swift:30-34`).

<a id="m4"></a>

### M4 — Small unbounded maps and registrations

**Severity Low, effort S each.**
- `ShootingInfoCache` grows by one entry per file ever shown (`PhotoInfoViews.swift:10`).
- AI Denoise's residual cache already has a 1.2 GB cost limit, but its status and failure dictionaries have no bound (`AIDenoise.swift:117-131`, `167-197`).
- Preview failures accumulate in `PreviewScheduler.failed` until an explicit retry (`PreviewScheduler.swift:22`, `119-147`).
- Inside a long-lived `DevelopSession`, the per-session subject-mask and Fine Edges matte maps can grow across regions on one photo, even though the shared caches behind them are bounded (`DevelopRenderer.swift:513-519`, `941-956`, `1015-1049`).
- Block-based observers in `DevelopController.init` (`DevelopController.swift:796-825`), `LibraryModel` (`LibraryModel.swift:259-285`) and the download singletons keep tokens that are never removed. The captures are `weak`, so a dead owner leaves registrations behind, not live duplicate callbacks. It matters only if these owners ever stop being app-lifetime objects.

<a id="lifecycle"></a>

### Retain cycles and teardown

The weak back-references to `LibraryModel` (`HDRController.swift:51`, `CullModel.swift:152`, `MatchLook.swift:139`, `ImportFlow.swift:67`, `AIController.swift:34`, `AgentServer.swift:47`) and the action handlers that receive the model as a parameter (`LibraryModel+Actions.swift:40` onward) check out. That is not an app-wide "no retain cycles" result; these are lifecycle points to keep in mind, not evidence of a current leak:
- The MCP socket server's accept thread captures `self` weakly but upgrades it for the whole accept/serve call, so `stop()` has to be called; owner teardown doesn't do it (`MCPSocketServer.swift:43-71`, `85-115`; `AgentServer.swift:73-107`, `299-309`).
- `LibraryModel`'s database observations hold weak captures but still need cancelling on owner teardown (`LibraryModel.swift:292-367`), and it discards its block observer tokens (`259-285`).
- Private Photos tears down its repeating timer, event monitor and observers on a normal reset, but has no teardown in `deinit` (`PrivatePhotos.swift:123-161`).

---

## Performance

<a id="p1"></a>

### P1 — Develop history: full snapshots, saved on the main thread

**Severity High if timings confirm; effort M for a background save that keeps read-after-write behaviour; M–L for a history format change. Measure first (`DevelopTimingLog` already logs save time and step count).**

- Each history step stores a complete `DevelopSettings` (`DevelopHistory.swift:9-12`). `record` caps the normal step list at 500 (`DevelopHistory.swift:36-95`); named snapshots are separate, and decoding does not enforce the cap. In memory, Swift's copy-on-write shares storage where values are shared, so the in-memory cost is lower than 500 independent copies.
- Every dirty flush of the open photo encodes the entire history and writes it on the main thread (`Catalog+Develop.swift:111-119`; `DevelopController.swift:2795-2826`). 400 ms is the scheduled delay; some paths flush at once (`DevelopController.swift:1938-1955`). The encode cost grows with the number of steps and with what each step holds (brush points, spots, masks).

**Proposal, two separate jobs:**
1. Move the encode and write off the main thread while keeping read-after-write behaviour (a read right after an edit must see it). This needs no migration. M.
2. Only if measurements justify it: a delta or one-row-per-step history format. M–L, because undo position, redo truncation, preset Amount rewriting its last step, named snapshots, and XMP/recovery all depend on the current shape.

<a id="p2"></a>

### P2 — Batch edits: one transaction per photo

**Severity Medium; effort S–M for bounded synchronous bulk transforms in one transaction; M+ for schema changes, background fits, partial-failure handling and previews.**

- Sync, presets on a selection and Match Look write per photo: `applyDevelopSettings` loops `saveDevelopSettings` (`Catalog+Develop.swift:111-133`), which does two reads and a write, each its own database call. Same pattern in `DevelopController.swift:1812-1846`, `1910-1934` and `MatchLook.swift:528-545`, `645-674`. A failure part way leaves the batch partly applied.
- The Grid's rows come from a `ValueObservation` on the filtered query, which tracks `developSettings` and `metadata` (`LibraryModel.swift:292-315`, query at `LibraryFilter.swift:122-146`, JSON parsing at `232-234`). A relevant commit can re-run that filtered query. How many of a batch's commits actually lead to a query run or a publication isn't established from source.
- The Catalog API's read-read-write isn't atomic against concurrent writers. In practice, ordinary MCP edits and these save paths all run on the main actor (`AgentServer.swift:346-359`, `AgentOrganizeTools.swift:377-435`), and Match Look's per-photo save re-checks its baseline on main first, so a lost edit from interleaving is unproven. Other catalog writers and stale whole-settings inputs deserve their own audit.

**Proposal:** a `Catalog.updateDevelop(ids:step:change:)` that reads, records history and writes the whole batch in one `writer.write`, with a defined result for partial failures. Then measure the observation cost before changing anything there; tweaking the observation alone won't stop invalidation from metadata and settings writes. Stored `hasEdits`/`isCropped`/`hasMasks` columns are a later schema step, only if measurements point there.

<a id="p3"></a>

### P3 — Export is serial

**Severity Medium; effort M, pending throughput and peak-memory measurement.** `Exporter` renders and writes one photo at a time (`Exporter.swift:134-159`). Two in flight (render one while the previous is encoded and written) is the obvious first step, but only with memory measured.

<a id="p4"></a>

### P4 — HDR waits for a full-file hash before showing the photo

**Severity Medium; effort S for diagnosis, S–M to keep the check while not making display wait for it.** `openOriginal` reads the whole original for SHA-256 before the proxy is shown (`HDRController.swift:141-154`); on the NAS that is a full read each time. The hash identifies the exact source that was opened, which Save later relies on (`HDRController.swift:485-501`, `542-549`), so it can't simply move to Save, and size plus modification date is not equivalent to a content check. **Proposal:** show the proxy first and finish the hash in the background, with Save waiting on (and verifying) that hash.

<a id="p5"></a>

### P5 — Every `DevelopController` change can refresh every view that watches it

**Severity conditional on measurement; effort L (see D2).** `DevelopController` is one `ObservableObject` with 87 `@Published` properties (`DevelopController.swift:105-1318`). 44 view declarations in 15 files observe it; that's a source count, not 44 body evaluations per change, since only mounted views re-evaluate. The slider work (AT-039, `DevelopMeasures` at `DevelopController.swift:50`, equatable rows) already took the hottest values out. macOS 15 allows `@Observable` (per-property tracking), unused today. Worth doing only where Frame Diagnostics shows view updates costing time.

---

## Concurrency and thread safety

<a id="c1"></a>

### C1 — Model locks held through inference; status read without the lock

**Severity High; effort S for removing main-thread lock waits and synchronizing status; M for a lifecycle/host redesign (R1).**

- Fine Edges and Depth hold their locks for the whole model run (`FineEdges.swift:262-304`; `DepthMap.swift:224-258`). `FineEdges.remove` calls `forgetSession()`, which takes the same lock (`FineEdges.swift:130-163`, `174-216`), and Settings calls `remove` synchronously on the main actor (`FineEdgesDownload.swift:85-92`). So removing a model while a matte is being found blocks the main thread until the run ends. How long depends on the run; the roughly 22 s Hair Detail CPU run reported in AT-074 is one earlier data point, not a bound or a measurement of the stall. Depth's `forgetSession` has the same shape (`DepthMap.swift:43-64`, `160-165`). Install is async: its internal lock wait doesn't stall main by itself, but any synchronous removal before a download does.
- `failure`, `lastRun` and `isWorking` are `nonisolated(unsafe) static var`s written on the model's thread and read by the UI on main without the lock (`FineEdges.swift:179-185`; reads at `DevelopController.swift:3162-3163`, `3409`, `FineEdgesDownload.swift:30-34`, `DepthModelDownload.swift:57-64`). A `String` read during a write is a data race. (`runs` is a diagnostic counter, not one of these UI reads.)

**Proposal (narrow, S):** never take the inference lock from the main actor (do Remove's forget on a background task and update the UI when it returns), and publish status as one `Sendable` value behind its own small lock. A shorter session-handle lock alone isn't enough: inference still has to be serialized, and results and status from a run that started before a model was replaced must not be shown as the new model's. Those two belong in R1's host.

<a id="c2"></a>

### C2 — Swift 5 language mode with many manual escapes

**Severity Medium; effort M–L, stepwise.** The package builds in Swift 5 mode (`Package.swift:68`). The compiler still checks actor isolation there, but not full Sendable/data-race safety. There are 44 `@unchecked Sendable` types, 21 `nonisolated(unsafe)` statics, 76 `MainActor.assumeIsolated`, 36 `NSLock`s, 14 private `DispatchQueue`s and 43 `Task.detached` in `Sources`. Switching modes won't check code that is explicitly marked unsafe (C1's statics are), so this complements C1 rather than replacing it.

**Proposal:** enable Swift 6 mode per target in dependency order: `AgentActions`, `AgentMCP`, then `AtelierActions` (photo-specific, unlike the first two), then `AtelierHDRCore`, `AtelierCore`, the app. Fix what each step reports.

<a id="c3"></a>

### C3 — Several ways to run background work

**Severity Low–Medium.** GCD queues, `OperationQueue` (`PreviewScheduler.swift:18-34`, `Importer.swift:186-225`), `Task.detached`, `NSCondition` (`FineMatteCache.swift:47`) and `LockedValue`/`LatestJob` coexist, and they have different semantics (bounded pools, latest-wins, structured cancellation). **Proposal:** keep them; write down concrete cancellation or priority problems where they occur, and only then propose a rule. No blanket ban on GCD.

---

## Design choices

<a id="d1"></a>

### D1 — Develop's tools are six flags that switch each other off

**Severity Medium; effort M.** `isCropping`, `isAIOpen`, `isMasking`, `isGuiding`, `isRemoving` and `isLensBlurring` are separate `@Published` Booleans whose `didSet`s turn the others off by hand (`DevelopController.swift:105-185`, `331-455`; `lensBlurModeChanged` at `3051-3099` also resets `picker`, `showingBefore` and `compareMode`). Adding a tool means editing every other tool's `didSet`. Not every combination is exclusive: `isMasking` intentionally stays on alongside Lens Blur for the `.lensBlur` mask scope (Lens Blur Refine).

**Proposal:** one tool-state value with a root mode and a nested Lens Blur Refine (or an enum that represents both), with enter/leave hooks per tool. Keep `isCropping` and the rest as computed properties at first so views change gradually. Tests must cover the picker, compare views, Save/Cancel and open-generation transitions. (This is a maintainability proposal; the earlier Navigator/sidebar reports are not evidence that these flags caused them.)

<a id="d2"></a>

### D2 — `DevelopController` holds every tool

**Severity Medium; effort L.** 3,720 lines (`DevelopController.swift`) plus six extension files, owning rendering, saving, history, presets, white balance, color grading, lens/transform, masks, spots and Lens Blur (MARK sections `849` to `3420`). `LibraryModel` (1,240 lines) has the same shape on a smaller scale. **Proposal:** split only along a concrete ownership problem or a measured cost (for example, D1's tool state, or a render pipeline object with no published state), one PR at a time. Shared components keep taking show/hide options from the caller (MasksPanel for Masking and Lens Blur Refine).

<a id="d3"></a>

### D3 — The Processor contract is in the PRD, not in code

**Severity Medium (spec drift); effort M for an initial adapter.** The PRD describes one Processor contract and host (`Atelier-PRD.md:529-560`, `594`, `651-653`, `685`). In code, `ProcessorDocument` is HDR-only (`ProcessorDocument.swift:21`, `34`), and Edit In, ComfyUI (`AIRunner.swift:55-227`), Generative Fill and the in-process models each have their own request/progress/cancel/result path. This is BACKLOG AT-008, which stays related work; it is not a prerequisite for the correctness fixes here. **Proposal:** an initial `Processor` adapter for Edit In and ComfyUI only, not a replacement of every path.

<a id="d4"></a>

### D4 — HDR has two implementations that must match

**Severity Low–Medium; effort M for parity coverage.** The GPU preview kernel repeats the CPU tone mapper's arithmetic (`HDRPreviewRenderer.swift:6-25`); detail at 100% and Save use the CPU (`HDRController.swift:362-430`, `446-456`, `501`; `HDRToneMapper.swift:246-247`, `294-306`). **Proposal:** a parity test across both paths. A full-size GPU Save is a larger, separate job that needs its own quality and memory validation.

---

## Reusability and duplication

<a id="r1"></a>

### R1 — Three copies of ONNX session setup

**Severity Medium; effort M for narrowly extracting the common setup, M+ together with C1/M1 policies.** `DepthMap.swift:156-215`, `FineEdges.swift:174-252` and `AIDenoise.swift:497-545` each build their own `ORTEnv`, session, Core ML attempt, CPU fallback and logging. Their policies differ: Depth and PMRID run on the CPU by default and Fine Edges defaults to the CPU too; AI Denoise already has synchronized per-file status (`AIDenoise.swift:117-197`) and a different session lifetime. **Proposal:** extract only the common setup first (environment, options, provider fallback, logging), leaving each model's run and status policy in place; fold in C1's serialization and M1's eviction when those are agreed.

<a id="r2"></a>

### R2 — Model download state twice

**Severity Low, effort S.** `DepthModelDownload.swift:10-64` and `FineEdgesDownload.swift:11-93` share the installed/progress/error/cancel shape. **Proposal:** one shared download state, keeping each UI and Fine Edges' model choice exactly as they are.

<a id="r3"></a>

### R3 — Develop edits outside the open photo take different paths

**Severity Medium, effort S (comes with P2).** Match Look, presets on a selection, Sync and Generative Fill finishing on a photo that's no longer open (`DevelopController+SpotGeneration.swift:92-99`) each read, change and save settings their own way. P2's `Catalog.updateDevelop` gives them one path.

---

## Consistency

<a id="e1"></a>

### E1 — Catalog writes that fail silently

**Severity Medium; effort S, path by path.** Several catalog writes in the app use `try?` and drop the error. The ones that can lose user work without a word: Generative Fill's saved patch on a photo not open (`DevelopController+SpotGeneration.swift:92-99`), Match Look's per-photo save (`MatchLook.swift:535-544`), and notes add/update/delete (`PhotoNotesModel.swift:115-169`). Develop's own save shows "Could not save" (`DevelopController.swift:2828-2832`). **Proposal:** propagate and report the error on each of these paths. Reads that fall back to a default and partial batch outcomes each need their own handling. No blanket source-pattern test: it can't tell a best-effort write from an important one.

<a id="e2"></a>

### E2 — Settings keys as loose strings

**Severity Low–Medium.** 169 `UserDefaults.standard` uses in 31 files plus 84 `@AppStorage`s with string keys (for example `DevelopController.swift:458-513`), and a global `UserDefaults` change observer in `LibraryModel.swift:259-265` that runs on every defaults write. **Proposal:** split a targeted cleanup (S–M: narrow that observer; typed keys for keys read in more than one place) from any wholesale preferences migration.

<a id="e3"></a>

### E3 — Logging

**Severity Low, effort S if scoped.** `NSLog` (for example `FineEdges.swift:292-304`), `print` (in `LayoutSnapshots.swift` and `AgentsSettings.swift`), one `Logger` and `DevelopTimingLog`. **Proposal:** `os.Logger` for a few domains (render, catalog, models, agents); keep `DevelopTimingLog`.

<a id="e4"></a>

### E4 — Core's `Develop` folder holds everything

**Severity Low, effort S.** `Sources/AtelierCore/Develop` is one flat folder of 62 files. Mechanical subfolders only, timed to avoid conflicts with open PRs.

---

## Modularity and build

<a id="b1"></a>

### B1 — ONNX Runtime in Core's dependency graph

**Severity Low–Medium; effort M+.** `onnxruntime` is a dependency of `AtelierCore` (`Package.swift:38-56`). Link size and time overhead are unmeasured. A separate models target only helps if consumers' dependency graphs actually stop reaching it, and Core's renderer calls the models today (`DevelopRenderer.swift:630-640`), so the split needs an interface in between.

<a id="b2"></a>

### B2 — Test hooks in the shipping app

**Severity Low, effort S.** `LayoutSnapshots.swift` and the `ATELIER_SNAPSHOTS`/`ATELIER_UI_SMOKE` switches are in the app target (`LayoutSnapshots.swift:7-31`, `15-80`). If they go behind a compilation condition, check release packaging (`build_macos_app.py`) and how the UI harness launches the app together.

<a id="b3"></a>

### B3 — `-O` in Debug through `unsafeFlags`

**Severity Low, observation only.** `AtelierCore` and `AtelierHDRCore` use `.unsafeFlags(["-O"])` in Debug (`Package.swift:38`, `51`) because per-pixel Swift loops are slow unoptimized. Keep it until measurements show it's no longer needed.

---

## Already good: keep these

- **Action registry** (`Sources/AgentActions`, `LibraryModel+Actions.swift`): menus, keys and MCP tools from one declaration, handlers receive the model instead of capturing it, and a test enforces it.
- **Live render path**: "latest wins" coalescing (`LatestJob`), frames straight to IOSurfaces (`DisplaySurfaces`, `LiveFrameSink`), histogram on its own object (`DevelopMeasures`), step-1 cache by `CorrectedKey`.
- **Catalog**: GRDB `DatabasePool` in WAL mode (`Catalog.swift:48-49`), migrations never edited, Grid fed by a `ValueObservation` off the main thread.
- **Bounded shared caches**: `PreviewImages` (8, LRU), `FineMatteCache` (6), `SubjectMaskCache` (8), `ColorLUT` (4, locked), AI Denoise residuals (1.2 GB cost limit), `correctedCache` and `lensBlurCache` (2 each).
- **Weak back-references** to `LibraryModel`, and `PreviewScheduler`'s bounded, cancellable queues.
- **Shared pieces table** in AGENTS.md: the right tool against the "same bug in every tool" problem.

## What I didn't check

Not built, run or profiled; no Mac. Not reviewed: image math, the agent socket's security model, Import on the NAS, and the UI against the PRD's UX principles. Earlier reviews this builds on: Codex's Oct 30 review (BACKLOG evidence baseline) and the Nov 7 GPU audit (project files `reports/gpu-performance-audit-2026-11-07.md`).

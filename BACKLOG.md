# Atelier action list

This is the canonical action/status list in Git. [The PRD](Requirements/Atelier-PRD.md) remains the product specification. A proposal here is not implementation approval. Co = Codex; Cl = Claude. Cl reviewed PR #61's local-check work only; this list does not claim Cl approved the architecture recommendations.

## Status and evidence

- **Done:** the bounded change merged; the entry states what was actually validated.
- **Approved / ready:** Rosh approved the stated scope; implementation and acceptance remain open.
- **In progress:** an owner is working within the stated scope.
- **Proposed / discuss:** review recommendation or known acceptance gap; discuss scope with Rosh before implementation.
- Source inspection, automated checks and user acceptance are separate evidence. Keep IDs stable and update entries in the same PR as the work, including validation and deferred work.

Evidence baseline, October 30, 2026:

- Architecture review: `Atelier-Architecture-and-Implementation-Review.md`, with adjacent `Atelier-Verification-Log.txt`, in Rosh's local archive `/Users/rosh/Documents/Codex/2026-10-30/referenced-chatgpt-conversation-this-is-an-2/outputs/`. These are historical local evidence, not portable repository files. Relevant findings and limits are summarized below.
- Review baseline `81559f3` has the same tracked tree as its tested `c042e81`. That isolated test attempt failed compiling TransformTests and ColorToolsTests; no completed test pass or runtime acceptance was established.
- Rechecked at `9ed894a`: `git diff 81559f3 9ed894a -- Sources Requirements` is empty. Thus source findings below carry forward; test/build findings must use the later PR evidence, not the old compile failure.
- Review did not exercise live UI, ComfyUI, real-library recovery, licensing terms or production benchmarks. Report priorities in the review were recommendations, not confirmed defect severities.
- Source discussion/authorization: [Rosh's review chat](codex://threads/01a18eaf-0df0-7ee0-afcb-04884e64a825). No blanket implementation approval was given for the proposals below.

## AT-001 — Shared local pre-PR checks

**Status:** Done — merged [PR #61](https://github.com/roshan-davis/atelier/pull/61), `dcb530e`. **Owner:** Co; Cl reviewed this PR only. **Dependencies:** none.

**Scope/evidence:** `Scripts/check_pr.py`, script tests, non-mutating Help check, agent/environment reporting, plus the two test compilation fixes identified by the review. README documents the command and limitations.

**Acceptance/limits:** runner and reporting landed; this does not certify a passing app suite, GUI or real RAW coverage. PR #62 separately addresses the subsequent test baseline. PR #61 reports build/Help/whitespace/script checks passing, but 206 XCTest tests with 2 RAW skips and 20 assertion failures; logs under `/Users/rosh/.codex/worktrees/local-pr-checks/App/.build/local-checks/20261030-131314-462548/`. This is historical PR evidence, not a fresh run.

## AT-002 — Restore a passing Mac test baseline

**Status:** Done — merged [PR #62](https://github.com/roshan-davis/atelier/pull/62), `9ed894a`. **Owner:** Co. **Dependencies:** AT-001.

**Scope/evidence:** test-only fixes to color, defringe, local contrast, pair, slider-preview and stack fixtures/assertions; commit title records a restored passing Mac baseline. No app source changed.

**Acceptance/limits:** PR #62 reports `python3 Scripts/check_pr.py` exit 0 at tested commit `a0c5102608db2e6a141d2d10501f0d7206bd2e02`: build/Help/whitespace/seven script tests and 206 XCTest tests passing, with 2 RAW tests skipped; logs under `/Users/rosh/.codex/worktrees/test-baseline/App/.build/local-checks/20261030-132415-868823/`. This is historical PR evidence, not a fresh certification of the merged SHA. The PR body also mentions a new-file runner fix absent from the merged diff; see AT-017. A passing synthetic baseline does not establish real RAW, live UI, AI, recovery or performance acceptance. This documentation PR's check is recorded in its own PR validation.

## AT-003 — Native catalog-open failure screen

**Status:** Done — merged in PR #64 (`17ea9c3`); manual acceptance limits below remain.  **Owner:** Co. **Chat:** catalog-open recovery in Codex (session `01a18eaf-0df0-7ee0-afcb-04884e64a825`; app-specific reference). **Branch:** `codex/catalog-open-recovery`. **PR:** [#64](https://github.com/roshan-davis/atelier/pull/64). **Dependencies:** use AT-001 checks.

**Evidence:** `LibraryModel.swift` at `9ed894a` still calls `fatalError` on catalog-open failure (line 168). **Scope:** native “Couldn't Open Catalog” screen naming the path and reason, with Try Again / Show in Finder / Quit. Preserve files: no delete, replace, reset or automatic restore. Disable library commands until successful opening; avoid quit backup after failed opening.

**Validation:** PR #64 records exact checked revisions and check logs. Baseline head `67f97e7` passed full-Xcode local checks: 211 XCTest tests (210 Core + 1 app), 2 missing-RAW-fixture skips, zero failures; toolchain, whitespace, script regressions, Help and build passed. Tests cover failure/retry/success, database/backup preservation, missing-database protection and no library/quit backup after failed launch. Light/Graphite snapshots and the Help page were inspected at that revision; a disposable native smoke check verified retry, Finder and Quit. Cl’s review follow-up adds interrupted-first-launch tests, preserves all non-Finder contents, clarifies the Backups message and moves Help to the workspace page. Follow-up checks and UI-review limitations are recorded in the PR. No render/cache/schema change. Final tested head `ad8493a` passed 214 XCTest tests (213 Core + 1 app), 2 missing-RAW skips, zero failures. Normal-library/session acceptance and latest native visuals remain for Rosh. Broader restore tooling remains AT-006/AT-012.

## AT-004 — Develop settings and masks in XMP recovery

**Status:** Done — merged PR #67 at `5fec14fd2aa0b0ceff41e6a717a3f9772730725b`; acceptance limits below remain open. **Owner:** Co (Codex). **Chat:** [Develop and mask XMP recovery](codex://threads/01a18ee6-6bd5-7ec3-a719-478c7424b395). **Branch:** `codex/xmp-develop-recovery`. **PR:** [#67](https://github.com/roshan-davis/atelier/pull/67). **Dependencies:** format and conflict policy agreed in this chat; wider recovery remains AT-005.

**Evidence:** review §3.3, unchanged source baseline: XMPFields stores metadata, while Develop settings/masks are catalog JSON. **Scope:** versioned Develop/mask sidecar round trip, preserving foreign tags and old catalogs; RAW+JPEG same-stem behavior. Keep history, relationships and provenance separate (AT-005).

**Approved scope:** current settings/masks only; exact-filename entries for shared RAW/JPEG sidecars; restore only new imports, recovered settings win over import presets; regenerate Vision subject/object masks. History, relationships, provenance and exact segmentation bitmap recovery are deferred.

**Acceptance:** recover settings/masks after catalog loss, old/new sidecar compatibility, unknown tags preserved, paired-file conflict fixtures, unchanged originals and equivalent rendered results. No full-catalog recovery claim from this work alone.

**Review follow-up:** Cl reviewed `64ad79e` without a macOS toolchain. Addressed never-edited vs reset recovery, import auto-write targets, unreadable foreign metadata and preservation of earlier import problems. Existing reference assets already skip recovery reads; regression added. Coalescing auto-writes is deferred pending measured NAS evidence (AT-011), with no NAS throughput claim. Copy imports with filename collisions retain the source-keyed sidecar entry until XMP writes add the destination key; documented limit. AGENTS.md now defines same-revision cross-environment validation attribution. Follow-up full Mac check at `64ad79e` plus the review patch passed: 227 XCTest tests, 2 missing-RAW skips, zero failures; script regressions, Help, build and whitespace passed. Logs `/private/tmp/atelier-at-004/.build/local-checks/20261030-170525-267348`. Committed-head check and CI evidence are recorded in PR #67.

**Final merged evidence:** Mac check PASS at pre-merge head `f35496cfb0e3334c52932ce44ec692dc7fd04fa7`: ten script regressions, Help/index/build/whitespace, 227 XCTest tests, 2 missing-RAW skips, zero failures; logs `/private/tmp/atelier-at-004/.build/local-checks/20261030-170601-807036`. Exact-head Actions run `41148345930` failed before starting due to account payments/spending limits (also capacity annotation); CI did not pass. Existing manual/UI/RAW limits below remain.

**Validation/limits:** full Mac check at `5086f3d` plus this implementation passed (223 XCTest tests, 2 missing-RAW skips, zero failures; ten script regressions, Help, build and whitespace passed), logs `/private/tmp/atelier-at-004/.build/local-checks/20261030-152834-451080`. Nine recovery tests exercise fresh-catalog reconstruction, equivalent synthetic rendering, original preservation, old/future/corrupt data, foreign tags, paired/concurrent writes, resets, copied imports and failed/offline dirty state. Committed-head check `dca751d` passed with the same totals, logs `/private/tmp/atelier-at-004/.build/local-checks/20261030-165438-379453`; catalog-free Light/Graphite Metadata snapshots were generated and inspected at that head with no clipping. PR #67 records final-head validation and CI status. Help index has no problems; browser visual review is blocked by the computer-use tool's local-file URL policy. No rendering math, cache version or catalog schema changes. Earlier edits need an explicit XMP write; renamed-file recovery and exact Vision segmentation are not supported. Real RAW, live auto-write/reconnect and real-library recovery acceptance remain open.

## AT-005 — History, relationships and provenance recovery

**Status:** Partially in progress; parent remains open until AT-005a/b/c are complete. **Dependencies:** AT-004 format boundary; AT-007 provenance requirements. Rosh approved splitting the original item and the bounded AT-005a policy in the linked chat. Original AT-005 through AT-015 retain priority over AT-018+ unless Rosh directs otherwise.

**Evidence:** review §3.3; source investigation at `5fec14f`: SQLite holds history, version/stack/virtual-copy relationships and AI provenance; portable reconstruction is incomplete. Sub-items preserve the original scope and missing-file/duplicate acceptance requirements.

### AT-005a — Develop history and snapshots recovery

**Status:** In progress — approved by Rosh. **Owner:** Co (Codex). **Chat:** [history recovery planning](codex://threads/01a18f4b-6d4b-7e32-9d0f-380b67601f4d). **Branch:** `codex/at-005a-history-recovery`. **PR:** [#68](https://github.com/roshan-davis/atelier/pull/68) (draft; Help visual review blocked). **Dependencies:** AT-004.

**Approved scope/policy:** recover retained named steps, selected position, redo steps and named snapshots alongside current settings. Separate versioned history representation bound to current settings; exact-filename identity, no hash merging or automatic rename recovery. Existing catalog assets keep their state. New imports recover ahead of presets. Settings-only sidecars retain the single “Recovered from XMP” step. Invalid/future/inconsistent history fails visibly and preserves the sidecar. Save/write comparisons include history-only changes. Virtual copies remain excluded.

**Acceptance:** fresh-catalog round trip preserves history/snapshot names, dates, snapshot IDs, selected position and redo; old/settings-only packets, paired filenames, copied imports, corrupt historical settings and conflicting packets have fixtures; originals remain unchanged. Source/tests do not substitute for real-library/RAW and live automatic-write acceptance. Recover only retained history: existing code caps steps at 500 despite PRD unlimited wording; changing retention is deferred for discussion.

**Validation/limits:** full Mac checks PASS at `292b97518eca5576fd1e3a986b3879ccc13de64e`: ten script regressions, Help/index/build/whitespace, 234 XCTest tests with 2 missing-RAW skips and zero failures. Logs `/private/tmp/atelier-at-005a/.build/local-checks/20261030-172604-472709`; only task-worktree untracked `Package.resolved` at start/end. Final-head evidence and CI status are recorded in PR #68. Initial build and 233 tests passed (2 missing-RAW skips), but that run was correctly invalidated because a collision fixture was added during checks; it is not a full-check PASS. Help index has no problems; Rosh approved browser visual review, but the local-file URL policy blocked it; no workaround attempted. Desktop attempt finished. No new controls/screens/pictures, rendering or catalog schema change. Relationships/provenance remain AT-005b/c; wider restore tooling and file backups remain AT-006/012.

### AT-005b — Virtual copies, stacks and parent/derived relationships recovery

**Status:** Proposed / discuss — not approved for implementation by AT-005a. **Owner/chat/branch/PR:** unassigned. **Dependencies:** AT-004/005a format boundaries; coordinate AT-007/008 and AT-006 restore design.

**Evidence at `5fec14f`:** virtual copies are separate asset rows sharing originals; version rows link parent and derived assets using catalog-local integers, with rendered file paths. Those IDs/paths are not portable identity.

**Scope to agree:** durable portable identities and remapping, virtual-copy metadata/settings/history, stack ordering/names, parent/derived graph, duplicate/ambiguous file matches, missing/offline rendered files, partial restore and conflict policy. No automatic graph reconstruction is implied by this entry.

**Acceptance to agree:** restore masters, several virtual copies and external/AI derived relationships into a fresh catalog; missing-file, duplicate-content, renamed-file and conflicting-existing-catalog fixtures; repeat restore does not duplicate versions or overwrite existing work. Document unrecoverable state and separate original/derived-pixel backup requirements.

### AT-005c — AI provenance recovery

**Status:** Proposed / discuss — not approved for implementation by AT-005a. **Owner/chat/branch/PR:** unassigned. **Dependencies:** AT-007 provenance/license requirements; AT-005b portable relationship identities; coordinate AT-008.

**Evidence at `5fec14f`:** AIRunner records recipe, workflow label, model/license declarations, prompt, seed, generation size, region, server and creation time in version provenance JSON; XMP does not carry it. Current records are not a complete reproducibility bundle.

**Scope to agree:** portable, versioned provenance and attachment to the correct recovered result/source; preserve known/unknown declarations without inventing license approval, model hashes or missing workflow data. Agree AT-007 requirements before expanding the record.

**Acceptance to agree:** provenance survives catalog-loss recovery and repeated restore, including missing derived/source files, duplicates, corrupt/future records and unknown/restricted models. Preserve provenance verbatim where supported; document what cannot reproduce pixels and which files/workflows/models require separate backups. No license-gate or reproducibility acceptance from a JSON round trip alone.

## AT-006 — Catalog and wider backup recovery design

**Status:** Proposed / discuss. **Owner/chat/branch/PR:** unassigned. **Dependencies:** AT-003 safe failure entry point; coordinate AT-004/005 and AT-012.

**Evidence:** review §3: timestamped SQLite backups do not include originals, derived pixels, user presets or preferences. **Scope to discuss:** explicit user-directed restore and backup coverage; no automatic destructive recovery implied.

**Acceptance to agree:** documented recovery inventory, restore from a known backup with files preserved, handling missing presets/derived files, explicit limitations and tested failure paths.

## AT-007 — AI registry, provenance and license policy

**Status:** Proposed / discuss. **Owner/chat/branch/PR:** unassigned. **Dependencies:** confirm license terms and desired policy with Rosh; coordinate AT-005/008.

**Evidence:** review §8.3: model/license declarations exist, but full registry, export gate and reproducibility bundle are incomplete. License strings were not an independent terms audit. **Scope to discuss:** model/workflow identity, hashes/backend versions, permissive vs experimental output policy and unknown-license handling. Existing permissive website/shop rule remains binding.

**Acceptance to agree:** permissive, restricted and unknown model fixtures exercise the agreed output policy; provenance survives round trips; live ComfyUI evidence recorded. Saved 16-bit TIFF must not be described as recovering precision absent from generated pixels.

## AT-008 — One Processor contract

**Status:** Proposed / discuss implementation scope; the single-contract product rule already applies. **Owner/chat/branch/PR:** unassigned. **Dependencies:** agree one bounded adapter slice; coordinate AT-007/009.

**Evidence:** review §8.4: Edit In and AIRunner have separate orchestration with shared export/stack helpers. **Scope to discuss:** incremental request/result/progress/cancel adapters, preserving current workflows; no broad controller rewrite.

**Acceptance to agree:** app and AI adapters demonstrate shared cancellation, progress, errors, output registration and stacking with regression tests and actual round trips. Preserve ComfyUI → Core ML → MLX backend order and no bundled models.

## AT-009 — Offline editing and deferred work

**Status:** Proposed / discuss. **Owner/chat/branch/PR:** unassigned. **Dependencies:** agree smart-preview/deferred-job design; coordinate AT-008.

**Evidence:** review §4/8: cached browsing and metadata exist; Develop/export/AI require originals; durable AI queue and smart-preview editing are incomplete. **Scope to discuss:** explicit offline availability, reconnect and deferred work behavior.

**Acceptance to agree:** offline browse/rate/reconnect tests, missing-preview/original errors, queue cancellation/restart semantics and no silent loss or duplicate output. Measure NAS behavior with AT-011.

## AT-010 — Color, film and grain visual acceptance

**Status:** Proposed / discuss; acceptance unverified. **Owner/chat/branch/PR:** unassigned. **Dependencies:** fixed reference images and Rosh's acceptance criteria.

**Evidence:** review §5/6: editable film-inspired presets and grain types exist; measured stock calibration and multi-camera visual acceptance are not established. Grain cache-version concern was an inference, not a reproduced stale-preview bug. Match Look coverage wording differs (~1% source vs 2% PRD); resolve intent before changing either.

**Scope/acceptance to agree:** skin, foliage, sky, artwork, grayscale and low-light reference set across cameras; full images plus 100% grain crops; display/export consistency and mask geometry. Reproduce cache issues before deciding a fix; bump PreviewCache.version if rendering changes. Do not claim measured film matching without evidence.

## AT-011 — Performance and concurrency measurements

**Status:** Proposed / discuss; targets unverified. **Owner/chat/branch/PR:** unassigned. **Dependencies:** agreed hardware/library/NAS fixtures and measurement protocol.

**Evidence:** review §5/9: coalesced rendering and preview scheduling exist; under-50-ms proxy response, real 100k scrolling and full-resolution memory budget are unverified. Historical warnings include async locks and captured mutable state.

**Scope/acceptance to agree:** record exact SHA/toolchain, proxy latency, NAS timing, large-library scrolling, peak memory and concurrency diagnostics. Measure before optimization; follow with bounded fixes. Controller decomposition is a review suggestion, not an approved rewrite.

## AT-012 — Recovery drills

**Status:** Proposed / discuss; acceptance unverified. **Owner/chat/branch/PR:** unassigned. **Dependencies:** agree disposable fixtures and coverage; AT-003/004/005/006 as relevant.

**Evidence:** review §9/10: unit coverage is not a real-library restore drill. **Scope/acceptance to agree:** interrupted import, damaged catalog, missing derived files/presets and backup restoration on disposable copies; document original-file preservation, recovered/lost state and manual steps. Do not test destructively on Rosh's library.

## AT-013 — Search and organization gaps

**Status:** Proposed / discuss. **Owner/chat/branch/PR:** unassigned. **Dependencies:** prioritize one feature against PRD.

**Evidence:** review §4/10: existing scope/rating/flag/label and SQL LIKE text filters are not a general query builder. Smart collections, duplicate workflows, broader queries and relink-by-hash require scoped review.

**Acceptance to agree:** one selected workflow with realistic fixtures, exact query/membership/relink semantics, non-destructive behavior, Help and PRD; defer remaining features explicitly.

## AT-014 — UI, gestures and accessibility acceptance

**Status:** Proposed / discuss; acceptance unverified. **Owner/chat/branch/PR:** unassigned. **Dependencies:** agree screens, themes and interaction matrix.

**Evidence:** review §7: shared controls and snapshot infrastructure exist; source wireframes are not screenshots. Real gestures, contrast, keyboard focus, VoiceOver and live spacing were not exercised.

**Scope/acceptance to agree:** inspect current-revision snapshots, then real gesture/keyboard/VoiceOver checks across relevant modes/themes. For fixes, search sibling controls and list exact retest paths per AGENTS.md; keep shared viewport and control patterns.

## AT-015 — Publishing and extensibility

**Status:** Proposed / discuss. **Owner/chat/branch/PR:** unassigned. **Dependencies:** prioritize one bounded capability; AT-007/008 for AI/integrations.

**Evidence:** review §8/10 lists watermarks, WebP, named export presets, plugins, batch AI, PSD, Core ML and MLX as remaining work, not a single approved project.

**Acceptance to agree:** selected feature has a PRD scope, output/interoperability fixtures, Help and runtime acceptance. Preserve one Processor contract and backend order; explicitly defer the other capabilities. Export features are now itemized in AT-022 and plugins/HDR in AT-021.

## AT-016 — Track this list and the working agreement

**Status:** Done — documentation merged in PR #63 (`5781c54`). **Owner:** Co. **Chat:** [this documentation chat](codex://threads/01a18eb2-5536-7c20-bd4b-3e8b8f528f14). **Branch:** `codex/backlog-working-agreement`. **PR:** [#63](https://github.com/roshan-davis/atelier/pull/63). **Dependencies:** none.

**Scope:** establish this list and AGENTS.md rules for keeping status/evidence current, bounded approved work, one App-project Codex chat per PR and no merges without instruction.

**Acceptance:** `python3 Scripts/check_pr.py` passed on full Xcode at base `9ed894a` plus the staged documentation (206 tests, 2 missing-RAW skips, zero failures); logs under `.build/local-checks/20261030-142918-754419/`. The final PR validation records the follow-up check and CI status. No app behavior, product decision, Help, rendering or UI changes; implementation of AT-003 and all proposals is deferred to separate scoped PRs. Merged documentation establishes the working agreement; it does not accept app behavior.

## AT-017 — Local-check false failure on clean untracked files

**Status:** Done — merged PR #65 at `5086f3df871e49efde85ed4c6f922593f8690905` (verified on fetched main). **Owner:** Co (Codex). **Chat:** [AT-017](codex://threads/01a18edb-1f08-7550-9c6a-0ee25e4503bc). **Branch:** `codex/at-017-new-file-whitespace`. **PR:** [#65](https://github.com/roshan-davis/atelier/pull/65). **Dependencies:** AT-001.

**Evidence:** reproduced against `17ea9c3`: a clean untracked new file yields exit 1 with empty stdout/stderr from `git diff --no-index --check`. The runner treated every nonzero exit as failure. Search found one no-index execution path; ordinary tracked checks must retain their existing exit semantics.

**Scope:** accept only a silent exit 1 from the generated no-index whitespace command. Preserve diagnostics and all other failures. Regression coverage checks clean/dirty committed, staged, working and untracked files, including names with spaces, plus missing-file errors and silent non-difference error statuses. No app behavior, rendering, data or UI changes.

**Validation/limits:** ten script regressions pass. Full Mac check passed at base `17ea9c3` plus this four-file patch: Help/build/whitespace and 214 XCTest tests, 2 missing-RAW skips, zero failures. Final committed-head validation and CI status are recorded in the PR. No desktop/UI actions needed or authorized; do not take over the desktop without asking Rosh and receiving explicit approval. Manual app/session acceptance is outside this script-only item.

## AT-018 — Filmstrip: source menu, thumbnail overlays and toolbar

**Status:** Done — accepted by Rosh on October 31, 2026 after building and testing in Xcode (design: Antigravity's Google Stitch screens and spec in `~/RoshProjects/Atelier/design/filmstrip/`; scope confirmed by Rosh: four bottom-right status badges, no "in a collection" badge, no Filmstrip size slider, a grid size slider, compact badges under 64 pt). Follow-ups from Rosh's review folded in: 3:2 filled cells and the design's spacing, no scrolling when the photo is already in view (grid too), header menus open upward, five stars has no "and Higher". CI was billing-blocked, no `Scripts/check_pr.py` run was recorded, and layout snapshots were added but not rendered. **Owner/chat/branch/PR:** Claude (project thread "Build filmstrip source menu and overlays"), branch `claude/project-thread-lbc3dp`, PR #70. **Requested:** Rosh, October 30, 2026. **Dependencies:** none; coordinate AT-014 for focus and keyboard behaviour.

**Implemented (branch above):** `FilmstripHeader` (source pop-up, position readout, Filters pop-up with clear, Sort pop-up and direction button); `LibraryFilter.sort`/`ascending`/`edited` with SQL ordering that keeps stacks together, saved in the session; `AssetRow` status flags (`hasEdits`, `isCropped`, `hasMasks`, `isOffline`) from the catalog query; shared `ThumbnailState` rings and `ThumbnailBadges` in `ThumbnailCell.swift`, used by the Filmstrip and grid (via a click-through `NSHostingView`), and the ring and pill by Cull; grid size slider and Edits filter in `FilterBar`. Tests: `LibraryOrderTests`. Deferred: saved custom filters; pickers outside Library (Import wizard wall, Match Look reference) still draw their own cells; grid scrolling with hosted badges not yet measured on 100k photos.

**Evidence at `5086f3d`:** the Filmstrip header (`FilmstripView.swift`) shows source name, count, "N of M" and filename only; there is no source menu, filter or sort control. Filmstrip and grid cells show rating, flag and stack as one text badge (`ThumbnailItem.badge` in `GridView.swift`); the focused photo has a 2 pt border and the rest of the selection a faint one. Thumbnail size is set by dragging the Filmstrip's top edge.

**Scope to design:**

1. **Source menu.** The source title becomes a pop-up, as Lightroom Classic's Filmstrip source indicator: All Photographs, recent import entries, collections and folders, plus the current filter. Choosing one changes the Library source.
2. **Clearer focus and selection, everywhere a thumbnail can be selected** (grid, Filmstrip, Cull, pickers). One shared thumbnail cell, not per-view fixes. Overlays on the thumbnail:
   - group indication: stack count/kind, RAW+JPEG pair, virtual copy;
   - star rating, flag and color label as icons, not text;
   - other candidates to agree: has Develop edits, has masks or AI/external edit, offline original, cropped, badge for "in a collection". Lightroom Classic's grid cell badges are the reference.
   - Focused vs selected vs unselected must read clearly in every theme.
3. **Right-side toolbar.** A Filter pop-up (Flagged, rated, color label, edited, custom saved filters; same rules as the Library filter bar) and a sort control (Capture Time, Import Order, File Name, Rating, Edit Time, with ascending/descending).
4. **The magnifier −/+ slider** seen in Lightroom is a thumbnail-size slider. Atelier already resizes Filmstrip thumbnails by dragging its top edge, so a slider is redundant here. Recommendation: leave it out of the Filmstrip; reconsider only for the grid toolbar.

**Acceptance to agree:** approved mockups first; then layout snapshots for each theme and Filmstrip height; keyboard selection and ⌘/⇧-click unchanged; one cell component reused by grid, Filmstrip and Cull; PRD and Help updated.

## AT-019 — Photo lags when selected: background shows before the image

**Status:** In review — fix on branch `claude/project-thread-e9rjh8` (PR opened October 31, 2026), not compiled in the cloud and CI billing-blocked; needs Rosh's Xcode build and test. Timings not measured yet. **Owner/chat/branch/PR:** Claude (project thread "Fix photo lag and zoom cursor bugs"), branch `claude/project-thread-e9rjh8`, same PR as AT-020. **Dependencies:** AT-011 measurement protocol for before/after timings.

**Symptom:** selecting a photo (Filmstrip, arrow keys) first draws the empty main panel background, then the photo.

**Evidence at `5086f3d` (source inspection, not reproduced):**

- Loupe (`LoupeView.load()`): on a new photo it sets `image = nil` before loading, so the panel shows the surround (and a `ProgressView`) until the 2560 px preview arrives. `NSImage(contentsOf:)` runs on a detached task but decodes lazily, so the JPEG is decoded on the main thread when `ZoomCanvasView.setImage` asks for its `CGImage`.
- Develop (`DevelopController.open`): clears `image`, then sets it synchronously from `NSImage(contentsOf:)` of the cached preview (again decoded on the main thread at draw time); if no preview is cached, the panel is empty until the proxy session renders.
- No in-memory cache or prefetch of neighbouring previews.

**Scope:** keep the previous photo on screen until the next one is decoded (never clear to background); show the cached grid thumbnail immediately, then swap to the preview; decode off the main thread (`CGImageSource` with `kCGImageSourceShouldCacheImmediately`); a small LRU of decoded previews and prefetch of the next/previous photo in the current order. Apply to Loupe and Develop, and check Compare/Before-After and Cull for the same pattern.

**Implemented (branch above):** `PreviewImages` (new, `Sources/AtelierApp/PreviewImages.swift`): decodes 2560 px previews off the main thread with `ThumbnailLoader.decode` (`kCGImageSourceShouldCacheImmediately`), keeps the last eight (re-decoded when the preview file's date changes), and `LibraryModel` prefetches the previous and next photo in the current order in Loupe and Develop. Loupe keeps the last photo until the next is ready and shows the in-memory grid thumbnail at once; it clears only when the photo has no preview or thumbnail yet. Develop shows the decoded preview at once, else the thumbnail (also for photos with no 2560 px preview yet), else holds the previous photo (not while Masking), until the preview is decoded or the proxy renders; a late preview never replaces a proxy render. The next photo is drawn and flushed before the window's SwiftUI update. Missing previews of the photo and its neighbours are queued in Loupe/Develop. The Develop spinner shows over a photo only after 0.6 s (slow NAS loads). Decoded previews check the file date before and after decoding.

**Measured (temporary trace on Rosh's Mac, Debug build, October 31, 2026; trace removed before merge):** 16 of 23 photos clicked in Develop had no 2560 px preview, so Develop showed nothing until the proxy rendered (0.3–0.6 s): the reported background flash. After the fix the photo is on screen ~150 ms after the click and sharp at ~450 ms. The remaining ~130–300 ms is one main-thread SwiftUI update of the whole window per photo change (Debug); reducing it is a separate item. Not changed: Cull and the Before/After panes (they come from the Develop render).

**Acceptance:** stepping through 50 photos with arrow keys never shows the empty background; time from selection to first photo frame measured before/after on Rosh's Mac (target to agree, e.g. under 100 ms from a cached preview); no change to rendered look, so no `PreviewCache.version` bump.

## AT-020 — Zoom cursor shows when the photo can't zoom or pan

**Status:** In review — fix on branch `claude/project-thread-e9rjh8`, same PR as AT-019; not compiled in the cloud, needs Rosh's Xcode test. Decision: no magnifier at any zoom (zoom is double-click; the hint line says so). **Owner/chat/branch/PR:** Claude (project thread "Fix photo lag and zoom cursor bugs"). **Dependencies:** none.

**Implemented:** `ZoomScrollView.canPan` now measures whether part of the photo is out of view (more than 1 screen point) instead of trusting the zoom level, so just past Fit or Fill with a matching shape counts as nothing to pan; `cursorShape` returns the arrow then, the hand otherwise. The cursor refreshes after a window resize and after a pinch. PRD principle 11 updated.

**Evidence at `5086f3d`:** `ZoomCanvasView.cursorShape` in `ZoomableImageView.swift` returns `.grab` when `canPan`, otherwise always `.zoomIn`. Zoom is double-click only since PR #44, so a magnifier over a fitted photo suggests a single click zooms. It also shows when double-click would not change anything (for example a small photo whose click-zoom size, `LibraryModel.clickZoomPercent`, is not larger than fit).

**Scope:** arrow cursor when the photo fits and nothing can be panned; hand when it can be panned; eyedropper/tool cursors unchanged. Keep the change in `cursorShape` (one place, used by Loupe, Develop and Compare). Confirm with Rosh whether a magnifier should ever show (proposal: no, since the hint line already says "Double-click the photo to zoom").

**Acceptance:** at Fit, Fill, below-fit and zoomed-in levels the cursor matches what a drag or double-click does, in Loupe, Develop, Compare and with Masking open; updates without moving the mouse after zoom changes (`Cursors.shared.refresh()`).

## AT-021 — Plugin architecture, with HDR Merge as the first plugin

**Status:** Proposed / discuss. **Owner/chat/branch/PR:** unassigned. **Requested:** Rosh, October 30, 2026. **Dependencies:** AT-008 (plugins must use the one Processor contract, not a second path); AT-005/007 for provenance of merged files.

**Plugin requirements to agree:** plugins are Processors (input photos plus settings, progress, cancel, output files registered and stacked); discovery and enable/disable in Settings; a plugin can add a menu item (Photo > Merge to HDR…) and its own dialog with preview; versioned API; failures never touch originals.

**HDR Merge requirements (Lightroom Classic Photo Merge > HDR is the reference):**

1. Select 2+ bracketed photos (Photo > Photo Merge > HDR…, ⌃H); optional automatic detection of brackets by capture time and exposure bias for Rosh's Nikon Zf/Z6 bracket sequences.
2. Dialog with a preview: **Auto Align** (handheld brackets), **Auto Settings** (tone the result), **Deghost Amount** None/Low/Medium/High with **Show Deghost Overlay**, **Create Stack** with the sources.
3. Merge RAW data in linear space before tone mapping, so the result stays fully editable in Develop with an extended Exposure range (Lightroom gives ±10 EV on merged HDRs).
4. Output an editable high-bit file next to the sources: floating-point DNG like Lightroom, or 32-bit float TIFF/OpenEXR if DNG writing needs a third-party SDK (check license and macOS encoder support first). Copy metadata from the reference frame; record sources in provenance.
5. Headless merge with last settings (Lightroom: ⇧⌃H), background progress with cancel, and batch merge of several bracket groups.
6. Edge cases: mismatched sizes or orientations, mixed RAW/JPEG, missing originals, moving subjects (deghost), clipped highlights in every frame.

**Acceptance to agree:** bracket fixtures from Rosh's cameras; aligned, ghost-free result; Develop edits on the merged file; stack and provenance survive restart; PRD and Help.

## AT-022 — Richer Export: watermark, presets, batch

**Status:** Proposed / discuss — pick a first slice with Rosh. Takes the export part of AT-015. **Owner/chat/branch/PR:** unassigned. **Requested:** Rosh, October 30, 2026. **Dependencies:** AT-009 for exports of offline originals; AT-007 output policy for AI-derived photos.

**Today (PRD Export row, `Exporter.swift` at `5086f3d`):** JPEG, HEIC, 16-bit TIFF, PNG; long edge; sharpen for screen; sRGB, Display P3, Adobe RGB, ProPhoto; metadata all / without location / none; quick settings for website and full size. PRD already lists watermark, metadata rules, named presets and publish to folder as later; U9 needs long edge 2048, sRGB, watermark, no GPS, WebP and JPEG.

**Candidate features (from Lightroom Classic and Capture One):**

1. **Watermark:** text or image (PNG logo), opacity, size (proportional/fit/fill), anchor and inset, shadow; saved watermark styles; live preview in the dialog.
2. **Named export presets** (Lightroom) and **several at once** (Capture One process recipes; Lightroom batch export): one run produces, for example, website JPEG + full-size TIFF + social crop.
3. **File naming templates** with tokens (filename, date, sequence, title, custom text, virtual copy name) and conflict handling (ask, unique name, overwrite, skip).
4. **Destination:** chosen folder, same folder as original, subfolder, ask each time; add the export back to the catalog and stack it with the original.
5. **Sizing:** long edge, short edge, width × height, megapixels, percentage, "don't enlarge", resolution (ppi); limit file size to N KB (Lightroom).
6. **Output sharpening:** Screen, Matte or Glossy paper, Low/Standard/High.
7. **Metadata rules:** copyright only, copyright and contact, all except camera and location, remove people; keywords; title/caption.
8. **Formats:** WebP (needs an encoder; ImageIO can't write it), AVIF/JPEG XL as available on macOS, HDR output with gain map later.
9. **Batch and background:** export queue with progress and cancel, "Export with previous" with no dialog, after-export action (Show in Finder, open in app).
10. **Publish services:** publish-to-folder that re-exports changed photos (later: WooCommerce, Instagram per PRD).

**Acceptance to agree:** chosen slice in the PRD; output fixtures (size, color profile, metadata, watermark position); background export does not block editing; Help page. Remaining features stay listed here, deferred explicitly.

**Sources (secondary unless noted):** Adobe Help, "Export files to disk or CD" (primary, Lightroom Classic) https://helpx.adobe.com/lightroom-classic/help/export-files-disk-or-cd.html; Adobe Help, "HDR photo merge" (primary) https://helpx.adobe.com/ie/lightroom-classic/desktop/process-and-develop-photos/hdr-photo-merge.html; Julieanne Kost, "Exporting Photos from Lightroom Classic" https://jkost.com/blog/2024/09/export-and-batch-exporting-photos-from-lightroom-classic.html; Julieanne Kost, "Creating HDR images in Lightroom Classic" https://jkost.com/blog/2024/09/creating-high-dynamic-range-images-hdr-in-lightroom-classic.html; CreativeLive (David Grover), Capture One process recipes https://phoenix.creativelive.com/class/quick-start-to-capture-one-david-grover/lessons/overview-of-process-recipes; Have Camera Will Travel, Lightroom HDR deghost https://havecamerawilltravel.com/lightroom/hdr-photo-merge/.

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

**Status:** Partially complete; AT-005a merged, parent remains open until AT-005b/c are complete. **Dependencies:** AT-004 format boundary; AT-007 provenance requirements. Rosh approved splitting the original item and the bounded AT-005a policy in the linked chat. Original AT-005 through AT-015 retain priority over AT-018+ unless Rosh directs otherwise.

**Evidence:** review §3.3; source investigation at `5fec14f`: SQLite holds history, version/stack/virtual-copy relationships and AI provenance; portable reconstruction is incomplete. Sub-items preserve the original scope and missing-file/duplicate acceptance requirements.

### AT-005a — Develop history and snapshots recovery

**Status:** Done — merged PR #68 at `8700f853bb9d5d06c906e9d8800b5137b5581a33`; smoke test/manual acceptance deferred by Rosh. **Owner:** Co (Codex). **Chat:** [history recovery planning](codex://threads/01a18f4b-6d4b-7e32-9d0f-380b67601f4d). **Branch:** `codex/at-005a-history-recovery`. **PR:** [#68](https://github.com/roshan-davis/atelier/pull/68). **Dependencies:** AT-004.

**Approved scope/policy:** recover retained named steps, selected position, redo steps and named snapshots alongside current settings. Separate versioned history representation bound to current settings; exact-filename identity, no hash merging or automatic rename recovery. Existing catalog assets keep their state. New imports recover ahead of presets. Settings-only sidecars retain the single “Recovered from XMP” step. Invalid/future/inconsistent history fails visibly and preserves the sidecar. Save/write comparisons include history-only changes. Virtual copies remain excluded.

**Acceptance:** fresh-catalog round trip preserves history/snapshot names, dates, snapshot IDs, selected position and redo; old/settings-only packets, paired filenames, copied imports, corrupt historical settings and conflicting packets have fixtures; originals remain unchanged. Source/tests do not substitute for real-library/RAW and live automatic-write acceptance. Recover only retained history: existing code caps steps at 500 despite PRD unlimited wording; changing retention is deferred for discussion.

**Validation/limits:** final-head full Mac checks PASS at `100ed8a65d0bfd2a103fd0901d8a2ffc3c044495`: ten script regressions, Help/index/build/whitespace, 234 XCTest tests with 2 missing-RAW skips and zero failures. Logs `/private/tmp/atelier-at-005a/.build/local-checks/20261030-172738-691004`; only task-worktree untracked `Package.resolved` at start/end. Exact-head Actions run `41150329815` / job `124385074378` failed before starting because of account payments/spending limits (also an arm64-capacity annotation); this is not a code-test failure or CI pass. Final-head evidence is recorded in PR #68. No live auto-write, NAS, normal-library or real-RAW acceptance; Rosh deferred the complete smoke test. Initial build and 233 tests passed (2 missing-RAW skips), but that run was correctly invalidated because a collision fixture was added during checks; it is not a full-check PASS. Help index has no problems; Rosh approved browser visual review, but the local-file URL policy blocked it; no workaround attempted. Desktop attempt finished. No new controls/screens/pictures, rendering or catalog schema change. Relationships/provenance remain AT-005b/c; wider restore tooling and file backups remain AT-006/012.

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

### AT-011a — Local Develop drag responsiveness

**Status:** Draft PR open, manual acceptance pending. **Owner:** Codex. **Chat:** [Develop drag responsiveness](codex://threads/01a1be20-7376-7233-81f8-dedd921f36a4). **Branch:** `codex/develop-drag-latency`. **PR:** [#81](https://github.com/roshan-davis/atelier/pull/81). **Dependencies:** AT-011 measurement protocol and an isolated macOS catalog and preference domain.

**Evidence:** At `e19599a`, scripted local Nikon Z6 Point Curve updates in Debug took 78 ms median to graph draw, 144 ms to publish the photo and 11 ms to render the proxy. The single-toolbar probe measured 36 ms, 63 ms and 11 ms respectively. Real mouse drags and paused saves require separate measurement.

**Scope:** Select one adaptive bar layout at a time in Develop, Loupe and Filter. Trace saves, row updates and stored previews during paused drags before changing those paths. Limit observation changes to demonstrated remaining cost. HSL photo latency is reported separately, and HSL rendering optimization is deferred.

**Acceptance:** On repeated local Release drags, target graph draw at or below 16.7 ms median and 33 ms p95. For representative warm Tone Curve and Basic edits at Fit, target visible photo updates under 50 ms median and at or below 100 ms p95. Time live feedback and the final sharp frame separately at 100%. A paused drag yields one history step, one undo to the starting value and no main-thread stall over 100 ms. Check all Develop drag controls and resize the three bars with Slider Compare included.

**Validation:** Matched instrumented Release runs used a local Nikon Z6 NEF in a disposable backup of the Mac catalog with isolated preferences. In three scripted drags at Fit, settings-to-graph moved from 79.1/95.7 ms (median/p95) to 10.2/17.6 ms. Settings-to-photo publication moved from 152.0/185.9 ms to 37.5/55.4 ms. The actual screen-presentation and real paused-drag criteria remain pending. The baseline logged a write with the pointer down. The app regression test exercises a held pointer through the debounce and verifies one persisted curve step and one undo. Resize snapshots cover narrow and wide Slider Compare, with the Grid Filter and Loupe bars inspected separately. HSL render timings are reported separately in the PR. Mac checks at `da4af75314da740eac7bb7816f2befed19107ad9` passed with 268 XCTest tests and no skips. Logs: `/private/tmp/atelier-develop-pr.VDwYKK/.build/local-checks/20261108-200822-841946`.

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

**Status:** Done — PR #71 merged at Rosh's instruction on October 31, 2026, after Rosh tested `7348bb6` in Xcode (no background flash; cursor fixed). Codex's Mac check passed at `800aa2a`; the final review-fix commit `b0f7e69` was not built before merge. Follow-up: the 130–300 ms whole-window SwiftUI update per photo change (Debug) is not addressed. **Owner/chat/branch/PR:** Claude (project thread "Fix photo lag and zoom cursor bugs"), branch `claude/project-thread-e9rjh8`, same PR as AT-020. **Dependencies:** AT-011 measurement protocol for before/after timings.

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

**Status:** Done — PR #71 merged October 31, 2026; Rosh confirmed the cursor in Xcode. Decision: no magnifier at any zoom (zoom is double-click; the hint line says so). **Owner/chat/branch/PR:** Claude (project thread "Fix photo lag and zoom cursor bugs"). **Dependencies:** none.

**Implemented:** `ZoomScrollView.canPan` now measures whether part of the photo is out of view (more than 1 screen point) instead of trusting the zoom level, so just past Fit or Fill with a matching shape counts as nothing to pan; `cursorShape` returns the arrow then, the hand otherwise. The cursor refreshes after a window resize and after a pinch. PRD principle 11 updated.

**Evidence at `5086f3d`:** `ZoomCanvasView.cursorShape` in `ZoomableImageView.swift` returns `.grab` when `canPan`, otherwise always `.zoomIn`. Zoom is double-click only since PR #44, so a magnifier over a fitted photo suggests a single click zooms. It also shows when double-click would not change anything (for example a small photo whose click-zoom size, `LibraryModel.clickZoomPercent`, is not larger than fit).

**Scope:** arrow cursor when the photo fits and nothing can be panned; hand when it can be panned; eyedropper/tool cursors unchanged. Keep the change in `cursorShape` (one place, used by Loupe, Develop and Compare). Confirm with Rosh whether a magnifier should ever show (proposal: no, since the hint line already says "Double-click the photo to zoom").

**Acceptance:** at Fit, Fill, below-fit and zoomed-in levels the cursor matches what a drag or double-click does, in Loupe, Develop, Compare and with Masking open; updates without moving the mouse after zoom changes (`Cursors.shared.refresh()`).

## AT-021 — Standalone HDR editor and Atelier round trip; general plugins deferred

**Status:** Design complete — PR #69 squash-merged at `9b684c2dcf316c517d7b7af2ff16df79b2790890`. HDR implementation and acceptance remain open. Rosh approved the trimmed standalone direction and feasibility-first sequence. This retains Rosh's explicit priority override of the usual AT-005–015 order. **Owner:** Co (Codex). **Chat:** [HDR architecture planning](codex://threads/01a18f63-deff-7660-ac5f-e18f8866636b). **Branch:** `codex/at-021-processor-design`. **PR:** [#69](https://github.com/roshan-davis/atelier/pull/69). **Requested/revised:** Rosh, October 30, 2026.

**Direction:** standalone native Mac HDR app inspired by Machinery HDR, with a reusable engine, single-image tone/detail processing and bracket merge/alignment/deghost. Atelier supplies one photo or one bracket group through a focused desktop Processor connection; returned files are validated and registered with every source recorded and an agreed stack policy. HDR app owns its interactive UI, presets and revisitable projects. Keep one shared Processor contract; do not build a second HDR catalog path.

**Design/evidence:** [revised draft and three diagrams](Requirements/Design/AT-021-Processor-Architecture.md), inspected source baseline `8700f853bb9d5d06c906e9d8800b5137b5581a33`, primary research including [Machinery manual](https://www.machineryhdr.com/manual/). Supersedes the previous full-plugin-platform-first plan. Current Edit In opens each input separately and records one parent; grouped handoff, all-source relationships and project/result identity need bounded extensions. HDR math, float encoders and isolation are not validated capabilities.

**Delivery:** image/project/handoff feasibility → one small end-to-end HDR editor plus Atelier round trip → re-edit/recovery completion → richer effects after acceptance. First return is 16-bit tone-mapped TIFF; re-edit opens the saved HDR project. Same repository, second app product. Design the small contract alongside the app; no prerequisite ComfyUI migration. General manifests, discovery/enable-disable, CLI/HTTP adapters, generated forms and plugin menu contributions are deferred for a separate proposal. Future platform scope retains a versioned manifest/API, discovery/enable-disable, declared file/network trust, execution isolation, common progress/cancel/errors, parameter forms and menu contributions; none is approved for implementation by this pivot. Automatic bracket detection/batch, arbitrary embedded plugin UI and new AI backends remain deferred.

**Dependencies:** AT-008 one-contract boundary and bounded desktop adapter; AT-005b/c portable many-source/project relationships and provenance recovery; AT-007 identity/license policy; AT-009 durable/offline queues later. Preserve existing Edit In and AI behavior, ComfyUI → Core ML → MLX and nothing bundled.

**Remaining decisions:** first-release effects and native UX, single-image/bracket reference fixtures, engine/dependency licensing, input representations, project source ownership, exact Save/Return commands and receipt details, output color/precision and visual stack policy. Then verify original preservation, interactive preview/undo/project reopen, grouped round trip, all-source recording, cancel/close/crash/restart and duplicate prevention. Source/build checks do not supply visual or product acceptance. No runtime, rendering, schema, provenance/license-policy implementation or desktop/UI tests in this design PR. Exact-head Mac/CI evidence is recorded in PR #69; every desktop test requires fresh explicit permission.

**Deferred Lightroom-style asks (retained):** ⌃H Photo Merge HDR; Auto Align/Auto Settings; four deghost levels + overlay; Create Stack; float DNG/TIFF/EXR and Develop ±10 EV; ⇧⌃H last-settings/headless; automatic bracket detection and batch. First-release creative HDR re-edit happens in the HDR app's project, not by recovering its settings from the returned TIFF.

### AT-021a — HDR image-path and handoff feasibility

**Status:** Done — bounded feasibility evidence accepted by Rosh for merge in PR #72. This completes the research deliverable, not HDR image quality, real-bracket, desktop-transport or runtime/manual acceptance. Those gates carry forward under AT-021. **Owner:** Codex. **Chat:** [HDR feasibility](codex://threads/01a19033-f20a-7f32-b35e-1306ed4e21b3). **Branch:** `codex/at-021a-hdr-feasibility`. **PR:** [#72](https://github.com/roshan-davis/atelier/pull/72). **Baseline:** freshly fetched `9b684c2dcf316c517d7b7af2ff16df79b2790890` (design PR #69 merged; design substep complete, parent runtime/acceptance open). **Scope:** disposable one-image/Nikon bracket fixtures; validate decode, alignment/basic merge, profiled 16-bit TIFF, time/memory and dependency terms; prove durable project sources and grouped job-document/receipt design. No full editor, new plugin platform or ComfyUI rewrite. **Acceptance:** exact revision, numeric/image evidence, proposed initial controls and a scoped next implementation slice; original files unchanged. No desktop tests without fresh permission. Parent AT-021 remains open.

**Evidence/validation:** [AT-021a report](Requirements/Design/AT-021a-HDR-Feasibility.md), measured probe hashes and numerical logs committed under `Requirements/Design/Evidence/AT-021a/`. Real Nikon Z f/Z6 II single-image decoding retains >1 RGB and −1 EV midtone ratio 0.5; profiled 16-bit proxy TIFF roundtrips pass, originals unchanged. Synthetic basic radiance merge maximum error 4.77e−7; same-exposure Vision translation succeeds but clipped +2 EV fails by 183.71 px. Final measured run 1.73 s / 1,357,266,944 B peak RSS, not a full bracket benchmark. Five disposable filesystem protocol model tests pass; no live app launch/catalog/crash proof. Mac check at `75cff101b8e51cf8205be807983fe965d0021ec0` passed: ten script regressions, Help/index/build/whitespace and 238 XCTest tests with zero failures/skips using the two Nikon fixtures; logs `/private/tmp/atelier-at-021a/.build/local-checks/20261030-213404-623650`. Final-head/actual CI evidence recorded in PR #72.

**Limits/next gate:** inspected library contains Nikon single images but no confirmed bracket; a known fixture folder requested. Rosh authorized generated-image inspection; completed comparison found both photographic proxies too dark against camera previews (Z6 II motion blur also exists in the preview); synthetic gradient appears smooth. No app/desktop interactions performed. Rosh clarified single-image creative HDR is the primary use case, describing MachineryHDR’s three generated exposures. Prioritize single-image tone/detail versus virtual-exposure fusion qualification and minimal document transport; real-bracket alignment remains a separate gate for bracket support. Next PR selected by Rosh: single-image HDR editor planning, with UX references from Antigravity/Claude via Google Stitch to be discussed in its own chat before implementation scope is agreed. Six controls, owned source copies, reference-frame stack and Save As New fork semantics remain proposals for agreement. No app runtime, catalog migration, rendering/preview-cache or Help controls changed. Deferred parent requirements remain intact.

### AT-021b — Single-image HDR MVP and independently testable engine

**Status:** In progress — Rosh approved implementation in this chat, including the usable Atelier-launched MVP. **Owner:** Codex. **Chat:** [HDR MVP](codex://threads/01a1904c-1b60-7672-b1c8-6bb32d4129db). **Branch:** `codex/at-021b-single-image-hdr`. **PR:** [#74](https://github.com/roshan-davis/atelier/pull/74). **Baseline:** `a8459a9`; AT-021a merged in [PR #72](https://github.com/roshan-davis/atelier/pull/72) at `1da194e7d0babcc24f61adec729b85124ff6676c`.

**Approved direction:** independently testable HDR engine, followed by a native single-image editor usable from Atelier through the Processor boundary. UX reference: Rosh's `design/hdr-app/mvp` package; source-left / compare-canvas / tone-detail-artifact inspector. Treat algorithms, performance claims and synthetic exposure recovery illustrations as proposals, not evidence. Durable projects, re-edit, Save/New identities and validated return remain required. No special HDR catalog path, broad plugin rewrite or bracket support in this slice.

**Acceptance pending:** Rosh’s single-image visual acceptance and broader fixture coverage; measured single-image look comparison, meaningful numeric tests, original preservation, full-resolution profiled 16-bit TIFF, preview/undo/project reopen and actual Atelier return/re-edit/cancel/recovery checks. Native UI/image inspection needs fresh explicit permission. Parent AT-021 remains open. Build/source inspection alone does not close image quality or runtime acceptance.

**Implementation/test handoff:** independently testable AtelierHDRCore, a second native app product, shared-source native sliders/panels/cursors/zoom/Help, original-pixel Edit In, durable owned sources, same-output Save, project-fork Save As New, full-resolution profiled sRGB TIFF and transactional Processor registration. Initial subtle global compression did not satisfy Rosh’s MachineryHDR reference; replaced with log-luminance guided-base compression, black protection and multi-scale texture. The simple synthetic-exposure weighted baseline remains a research comparison, not a qualified Mertens/pyramid implementation or a claim about Machinery’s internals. No bracket UI, presets, batch, broad plugin platform or ComfyUI rewrite.

**Evidence/limits:** nine focused engine/project/catalog tests pass in the working revision; TIFF return, typed input/undo/redo, same-output saves and independent Save As New were exercised with a disposable Nikon catalog. A 24 MP optimized desktop save completed in roughly three seconds versus an unoptimized trial exceeding two minutes; these are observed desktop action bounds, not controlled cold/warm benchmarks. Initial native layout and Help were inspected; final-head evidence belongs in the PR. Current full suite has an unrelated Export watermark scaling assertion failure, reproduced on unchanged origin/main at a8459a9 in /private/tmp/atelier-at021b-main-check; diagnostic output /private/tmp/at021b-main-watermark.log. Do not claim a passing full suite. RAW fixtures used are the same two verified disposable Nikon copies from AT-021a; new looks are not accepted as MachineryHDR parity. Desktop permission was explicitly granted for generated images and disposable tests; announce completion when finished. App crash/power-loss, macOS 15, NAS, full gesture coverage and Rosh’s final image acceptance remain separate.

**Cl review follow-up (PR #74, reviewed fc4840a):** confirmed stale thumbnails after ordinary Save, a reopened project being reported as a new save, and project-owned images leaking into re-import when no UTI is registered. Added a forced preview refresh with ordering against older in-flight jobs, exact-output/revision/hash no-op detection across job IDs, explicit case-insensitive project/descendant exclusion in import discovery, and consumed-receipt memoization. New sessions create no project or RAW copy before first Save; failed/cancelled first saves remove their uncommitted private project, while committed work is preserved. Successful publication retains only current plus previous generations. Rosh's recorded MVP exception keeps the HDR-specific connection; generalization waits for a second desktop processor. A shared UI library refactor and durable closed-job metadata archiving are deferred; live job JSON is still needed for later saves. Thirteen focused headless tests pass before final-head checks (the twelve HDR/review tests plus existing failed-preview behavior). Rosh explicitly requested headless-only checks for this review update; no new desktop or browser checks are authorized or performed. Final check revision/logs and actual CI belong in the PR.


### AT-021c — Research HDR presets and implement an agreed preset library

**Status:** Approved research follow-up, requested by Rosh in the HDR MVP chat. Record the research and subsequent preset implementation under this stable item; agree the first implementation slice from the findings before building it. **Owner:** unassigned for execution; Codex recorded the item in [PR #74](https://github.com/roshan-davis/atelier/pull/74). **Chat:** [HDR MVP](codex://threads/01a1904c-1b60-7672-b1c8-6bb32d4129db). **Research/implementation branch and PR:** not started; each new PR gets its own planning chat. **Dependencies:** AT-021b engine/project/settings boundary and a fixed single-image reference set.

**Why/evidence:** Rosh supplied [MachineryHDR samples](https://www.machineryhdr.com/samples/) and asked about its presets and algorithms. At PR #74 head 1491b26, Codex had inspected gallery results and the public manual, but had not inspected actual Machinery preset files or established its proprietary algorithms. Atelier's current guided tone/detail engine is an independent implementation, not a verified MachineryHDR equivalent. The initial global shoulder was too subtle for Rosh's intended creative-HDR look.

**Research scope:**
- Study MachineryHDR's actual available preset definitions/sample projects and documented controls, with versions and provenance recorded. Compare preset families, parameter combinations and their visible effect; distinguish published descriptions, directly observed behavior and hypotheses about algorithms.
- Compare other HDR programs' preset approaches. Candidate tools to confirm during research include Photomatix Pro, Luminance HDR and Affinity Photo's tone-mapping workflow. Use primary manuals, documented/open implementations and legitimately available preset/sample files; record what was and was not accessible rather than claiming knowledge of proprietary internals.
- Explain which effects require illumination compression, local contrast at several spatial scales, detail enhancement, smoothing/noise control, softness/depth restoration and color handling. Compare direct single-image processing with virtual-exposure approaches without claiming synthesized exposures add captured information.
- Use the same owned/licensed fixtures for every comparison: sharp textured architecture, foliage/sky boundaries, portraits, deep shadows/noise and bright highlights, with both natural and dramatic target looks. Separate captured brackets from the single-image use case.
- Produce full-image and 100% before/after comparisons, a preset/control/algorithm evidence matrix, known halo/noise/color tradeoffs, preview/full-resolution consistency checks, and measured latency/memory. Record exact engine/program versions, source hashes and output profiles.
- Propose the smallest useful engine additions and an original preset set for Atelier, with parameter mappings, default/range choices, preset-file/dependency licensing and explicit acceptance examples for Rosh. Desktop/program interaction and image inspection follow the permission scope in effect when this work starts.

**Implementation phase, after the research gate:** agree a bounded first slice with Rosh, then implement original natural-to-dramatic HDR presets and any justified engine controls in the independently testable HDR module. Reuse shared native controls and the established project/return workflow. Presets must remain editable, non-destructive and reopen consistently, preserve old projects, and apply as one named undo step. Update PRD, Help with generated before/after examples, backlog and snapshots in the implementation PR.

**Acceptance:** Rosh approves the comparison targets and first preset set; every preset has reproducible settings and meaningful engine/project compatibility tests; UI previews and profiled 16-bit TIFF exports agree at relevant scales; halos, noise and hue changes are assessed on the fixed fixtures. Source/build checks alone do not establish the intended Machinery-inspired look. Record remaining uncertainty and deferred effects. This item adds no preset code to PR #74 and does not close AT-021's existing runtime/visual acceptance gates.

## AT-022 — Richer Export: watermark, presets, batch

**Status:** In progress — first slice (AT-022a below) picked by Rosh on October 31, 2026; the other candidates stay proposed. Takes the export part of AT-015. **Owner/chat/branch/PR:** AT-022a: Claude (project thread "Add export presets and watermark"), branch `claude/project-thread-1w1qoi`, [PR #73](https://github.com/roshan-davis/atelier/pull/73). **Requested:** Rosh, October 30, 2026. **Dependencies:** AT-009 for exports of offline originals; AT-007 output policy for AI-derived photos.

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

### AT-022a — Export presets and watermark

**Status:** Merged at Rosh's instruction on October 31, 2026 (PR #73) without a Mac build: CI was billing-blocked and the cloud thread can't run Swift. Codex's Mac check (recorded on PR #74) built main at `a8459a9` with one failing test, `ExportPresetTests.testWatermarkScalesWithThePhoto`: text came out 205 px instead of 200 because the system font's width isn't proportional to point size. Text is now corrected to the wanted width in a follow-up PR. Still open: a passing `python3 Scripts/check_pr.py` with that fix, the layout snapshots, and Rosh's acceptance in Xcode. **Scope (Rosh, October 31, 2026, "go ahead on your pick"):** candidates 1 and 2 without "several at once": a Lightroom-style preset list in the Export dialog (built-in Website, Full-Size JPEG, Full-Size TIFF; user presets saved, updated, deleted; shared by every catalog) and a text or logo watermark with size, opacity, nine positions, inset and shadow, previewed on the first photo. **Validation planned:** `ExportPresetTests` (placement, scaling, export pixels, preset apply/match, store round trip and unreadable files, old settings decode); layout snapshots `export-website.png` and `export-watermark.png`. **Deferred:** several presets in one run, saved watermark styles separate from presets, tiling/rotation, and candidates 3–10.

## AT-023 — Private imports and collections

**Status:** Merged at Rosh's instruction on October 31, 2026 (PR #77), to be refined later. Rosh's Xcode builds found two compile errors, both fixed; the final head was not Mac-built, `PrivateListTests` and the layout snapshots were not run (CI billing-blocked). Still open: a passing `python3 Scripts/check_pr.py` and Rosh's acceptance in Xcode. **Owner/chat/branch:** Claude (project thread "Add private imports and collections"), branch `claude/project-thread-mc0j05`. **Requested:** Rosh, October 31, 2026. **Dependencies:** none.

**Why:** some shoots (model photoshoots) should be opened on purpose, not seen while browsing. Deliberate access, not security: no encryption of files or previews; the folder on disk is Rosh's concern.

**Scope (PRD, Catalog and library management > Private imports and collections):** a per-list property (Make Private… / Make Not Private on an import entry or collection) separate from seeing private photos (View > Show Private Photos… / Show Only Private Photos… with Touch ID or the Mac's login password, View > Hide Private Photos; listed only when something is private). Never asked at launch; every launch starts hidden; hides again after idle time in Atelier (Settings, default 10 minutes), on sleep, screen lock and screen saver. Hidden photos are left out of every list, count, search and sidebar item; private wins over ordinary lists; copies, stacked edits and RAW+JPEG siblings follow.

**Implemented:** catalog migration `v9-private-lists` (`isPrivate` on `importGroup` and `collection`); `Catalog.privateCondition`, `LibraryFilter.showsPrivate` (default hidden, never saved in the session), private-aware sidebar queries (`fetchFolders`, `fetchCollections`, import summaries, photo count); `PrivatePhotos` (LocalAuthentication, idle/sleep/lock watching) and `LibraryModel.putAwayPrivatePhotos`; sidebar menu items and lock marks; Settings > General > Private Photos; Help (Library > Private imports and collections). Tests: `PrivateListTests`. Snapshots: `private-shown.png`, `private-hidden.png`, `settings-general.png`.

**Names to confirm with Rosh:** property "Make Private…" / "Make Not Private"; viewing, in the View menu, "Hide Private Photos" / "Show Private Photos…" / "Show Only Private Photos…" (moved from Library and Show Only added at Rosh's request, Oct 31).

**Acceptance:** a passing Mac build and `python3 Scripts/check_pr.py`; Rosh checks in Xcode that a private import disappears from everywhere, Touch ID shows it, and it hides after the idle time and on sleep. **Deferred:** photos open in other apps, Finder, Match Look recent files from disk; a separate Atelier password (not wanted).

## AT-024 — Release builds for Apple Silicon and Intel

**Status:** Merged at Rosh's instruction on November 6, 2026 (PR #78); the build script itself not yet run on a Mac. **Owner/chat/branch:** Claude (project thread "Add Intel and Apple Silicon release builds"), branch `claude/project-thread-0rsh8h`. **Requested:** Rosh, November 6, 2026. **Dependencies:** none.

**Scope (PRD, Non-functional requirements > Compatibility: Apple Silicon and Intel):** Release builds for arm64, x86_64 and universal from `Scripts/build_macos_app.py --arch` and from Xcode (Release build configuration, Any Mac destination, My Mac (Rosetta) to run the Intel build). PRD, README and AGENTS.md no longer say Apple Silicon only.

**Implemented:** `--arch native|arm64|x86_64|universal|all` in `Scripts/build_macos_app.py` (one `swift build --triple <arch>-apple-macosx15.0` per arch, `lipo -create` for universal, resource bundles from the arm64 build). Source audit: no `Float16`, MLX, `#if arch` or direct Metal device code; runtime Metal Core Image kernels and Vision requests are available on Intel Macs that run macOS 15.

**Validation so far:** script logic exercised in the cloud with stand-in `swift`/`lipo`/`codesign` commands only (all four arch choices, default and custom output). GitHub Actions ran again on head `a3ad0cf` (run 42237725954, twice): `swift build` and 263 tests passed with 0 failures; the layout snapshot step timed out after 180 s both times, hanging at `develop-fringe-picker-1280x800.png` in `snapshotTransform` (existing main code, not touched by this PR). That run does not exercise `--arch` or an x86_64 build.

**Acceptance:** on Rosh's Mac, `python3 Scripts/build_macos_app.py --arch all` succeeds; `lipo -archs` shows `arm64`, `x86_64` and `x86_64 arm64`; the universal and arm64 apps open natively and the x86_64 app opens under Rosetta, each showing the catalog and rendering a photo in Develop. Xcode Any Mac build succeeds. **Deferred:** a test on a real Intel Mac, notarization/distribution, guarding MLX when it is built.

## AT-025 — Faster Develop sliders (GPU audit items GPU-0 to GPU-3) and the app icon in built apps

**Status:** In progress; PR [#79](https://github.com/roshan-davis/atelier/pull/79) open. CI built it and ran the tests at c3834f3; not yet built, timed or tested by hand on a Mac. **Owner/chat/branch:** Claude (project thread "Audit GPU use for performance"), branch `claude/project-thread-c8f3pt`. **Requested:** Rosh, November 7, 2026, after the GPU/performance audit (`reports/gpu-performance-audit-2026-11-07.md` in project files and in `~/RoshProjects/Atelier/reports/`). Part of AT-011's performance work. **Dependencies:** none.

**Scope:** (1) GPU-1: an interactive `DevelopSession` (Develop's proxy, full-size and Navigator sessions) keeps pipeline step 1 (RAW decode, white balance, exposure, profile, Remove CA, Defringe, lens vignetting and distortion, Upright/Transform) as a Core Image cached intermediate, keyed by `DevelopSession.CorrectedKey`; sliders on later panels reuse it. One-off sessions (previews, export) are unchanged. (2) GPU-2: the clipping overlay (J) is painted in the same render (`ClippingOverlay.apply(to:shadows:highlights:shownIn:)`) instead of a second upload and readback; the histogram and color scope are counted on their own queue after the photo is published. (3) GPU-3: `ColorLUT.build` runs its 32 blue slices in parallel. (4) GPU-0: `RenderSignposts` intervals (Proxy render, Full-size render, Histogram, Color cube) in Instruments' Points of Interest. (5) `Scripts/build_macos_app.py` copies `AppIcon.icns` into Atelier.app and the HDR helper and sets `CFBundleIconFile`, so Finder shows the icon.

**Performance improvement (PR [#79](https://github.com/roshan-davis/atelier/pull/79)):** measured with `SliderPerformanceTests` on CI's Nikon Z6 and Zf NEFs at commit c3834f3 (GitHub Actions macos-15 VM, Debug build, virtual GPU; a real M4 Pro will be much faster in absolute terms). Median ms per slider tick, 6 ticks after a warm-up; "before" is the old render-queue work per tick (no step-1 cache, one-core color cube, J as a second round trip, histogram and scope before the photo is shown), "after" is the new render plus the histogram work it no longer blocks on.

| Slider (2560 px proxy) | Z6 before → after | Zf before → after |
|---|---:|---:|
| Basic > Contrast | 177 → 149 | 155 → 119 |
| Other non-step-1 sliders (Highlights … Glow) | ~150–185 → ~140–170 | ~150–170 → ~112–132 |
| HSL > Saturation Red | 291 → 219 | 263 → 194 |
| HSL > Hue Blue | 279 → 230 | 256 → 199 |
| Color Grading > Midtones wheel | 265 → 173 | 236 → 145 |
| Contrast, J on | 205 → 125 | 185 → 97 |
| HSL Saturation Red, J on | 307 → 204 | 291 → 177 |
| Exposure, Temp, Distortion, Transform (step 1) | ~150–182, unchanged | unchanged |
| HSL Saturation Red, full size (Z6) | 115 → 79 | – |

Findings: about 15–25% faster on most sliders, 25–35% on HSL and Color Grading, 40–50% with J on; step-1 sliders unchanged as expected. The histogram and color scope take about 95–150 ms per tick in this Debug build, so moving them off the render queue is most of the win (candidate next fix: count them on the GPU). The run also showed `createCGImage` deferring the render until first draw (full-size Contrast "took" 7 ms), i.e. on the main thread; commit ae8b282 forces `deferred: false`. Timings at ae8b282 are pending: CI for that head failed to get a runner (re-run once), so they need a run on a Mac (`ATELIER_SAMPLE_RAWS=<folder of NEFs> ATELIER_SAMPLE_OUT=<folder> swift test --filter SliderPerformanceTests`).

**Acceptance:** Mac build and tests pass; Develop sliders on every panel update correctly (no stale photo after Exposure, Temp/Tint, Profile, Lens Corrections, Defringe or Transform changes); J overlay marks the same pixels as before and the histogram is unchanged by it; Instruments numbers before/after for an HSL drag, a Contrast drag and a Clarity drag on a Z6 NEF; Atelier.app shows its icon in Finder. **Deferred:** GPU-4 to GPU-13 from the audit.

## AT-026 — Keyboard focus in Develop, icon bars, key combos in Settings

**Status:** In progress; implementation pushed, not yet built on a Mac. **Owner/chat/branch:** Claude (project thread "Add keyboard focus navigation in Develop"), branch `claude/project-thread-ea7lwj`. **Requested:** Rosh, November 9, 2026 (seven items, one PR); Rosh chose the Mac behaviour for ←/→ on a focused slider. Part of AT-014's keyboard acceptance. **Dependencies:** builds on PR #81's bar layout (merged).

**Scope:** (1) arrow keys on a focused slider, ⇧ for bigger steps; (2) ↑/↓ through the Presets list with Navigator preview, Return applies; (3) Tab between controls; (4) ⌃Tab/⌃⇧Tab between areas (not F6, which is Show Filmstrip); (5) a quiet focus mark instead of the system ring; (6) Before/After and Fit/Fill as icons with per-segment tooltips at every width; (7) Settings > Keyboard records ⌃/⌥/⇧ combos, and ⇧W, ⇧M, ⇧T and the area keys become customizable. PRD: "Keyboard focus in Develop".

**Acceptance:** Mac build and tests pass (new `KeyboardTests`); Rosh checks each item by hand, including that ←/→ still change photos when nothing is focused, typing in the slider value and Search Presets fields is unaffected, and existing custom keys still work. **Rosh's first tests (Nov 9):** ⌃Tab stuck at Presets, then ← → still changed photo with the right panel "focused", Tab didn't move within an area, and the histogram spun for a long time. Fixed by moving keyboard focus off SwiftUI's focus system onto `KeyboardFocus` (the window key handler routes keys, Tab steps within the area by on-screen order) and by counting the histogram latest-wins (`LatestJob`; the per-render queue from PR #79 built a backlog). **Second test (Nov 9):** after ⌃Tab neither Tab nor the arrows did anything, even on the Filmstrip stop. Cause: with no SwiftUI-focusable views left, SwiftUI gave the empty Search Presets field the keyboard on its own, and the key handler steps aside for any text field. Now an empty field nobody clicked or tabbed into gives the keys back, and ⌃Tab, Tab and a click on a control or the photo end typing in a field. **Third test (Nov 9):** plain Tab hopped between Search Presets and the Library search field, and the photo and histogram still took long to load after moving through photos. Tab now always stays in the focused area (Search Presets is a Tab stop of Presets; ⌃Tab still lands on the list). Opening a photo is latest-wins too: each photo passed with ← → had queued its RAW decode, plus a preview render for unedited RAWs, on the render queue ahead of the photo you stopped on; now only the newest waits and passed photos are skipped (`LatestJob`, `LockedValue`). Rosh then asked that a mouse click select an area for the keyboard as ⌃Tab does: each area reports its frame (`AreaFocusFlash`), and the window's click monitor calls `KeyboardFocus.clicked(at:)`. **Fourth test (Nov 9):** the photo and histogram still loaded seconds late after fast ← → on the Filmstrip, and Tab seemed to jump straight to Tone Curve. Opening now waits until ← → rest for 0.15 s when they come faster than that (the cached preview shows meanwhile) and decodes on its own concurrent queue, so the photo stopped on never waits behind a decode for one passed. Panel headers are now Tab stops (with Basic closed, Tab had skipped straight to Tone Curve's sliders), and Tab order uses each column's content coordinates, so scrolling can't leave stale positions. A decode for a new photo includes the camera-match analysis, which was not measured here; if a single photo still takes seconds after resting, that needs an Instruments trace on the Mac. **Fifth test (Nov 9):** Tab still skipped Basic and jumped around, and the histogram and photo still loaded late, mostly on ← from the last photo. Causes found in the code: (1) a control's position was dropped when SwiftUI reported it before the control registered (`setPosition` wrote into the not-yet-created entry), so it sorted last; after the switch to column coordinates positions were never reported again, so Tab order fell to dictionary order. Positions are now stored apart from registration. (2) A photo passed while moving fast (like the one before the last) was never decoded, and decoding a RAW for the first time (camera match plus the proxy decode and first render) is the wait. The neighbours of the open photo are now decoded and rendered once in the background after its first render (Lightroom does the same), the photo just left keeps its decoded proxy, and the histogram is counted from the cached preview at once until the first render's replaces it. **Sixth test (Nov 9):** dragging on the histogram no longer moved it, and the spinner came up over photos already showing. Likely causes from the code: a click in the right panel focused the last-used control and scrolled the panel to it under the drag, and neighbour preloading shared the CPU and GPU with the first edits. A click now focuses the stop just above where you clicked, without scrolling; preloading waits until the photo has gone 0.8 s without a render; the spinner over the photo's own preview waits 2 s (600 ms over a thumbnail or the last photo). Rosh rejected the 2 s as a band-aid: the spinner followed the background decode, not what was on screen. It now shows only while the image is a stand-in (thumbnail or previous photo, `DevelopController.showsStandIn`), never over the photo's own preview or a render. `DevelopTimingLog` writes each open step's timing to ~/Documents/Atelier Traces/ for real numbers. **Seventh test (Nov 9):** in Side by Side the Before pane spun much longer than before. The Before photo is rendered on the render queue after the photo's first render, and neighbour preloading (new in this PR) could start beside it. Preloading now waits until the Before photo is shown, and the Before render's timing is in the log. Rosh then pointed out the slider view showed both at once: it doesn't, it draws the After over the whole frame until the Before arrives, so the same wait is hidden there; preloading the neighbours' Before is proposed, not built. Rosh also saw B&W and slider edits not reaching the photo; the cause was not found by reading the code, so every edit made before the editable copy is ready, every render over 300 ms or failed, and any edit stuck behind a render running over 2 s are now written to the timing log. **Codex review of 52b5fa9 (Nov 9), all fixed:** saved edits refresh Grid and Loupe previews even after moving on (only the optional first-open RAW preview is skipped); each open carries its own token, so a decode from an earlier open of the same photo (A, B, A, or `reopen()` after Edit In) is dropped; Edit In and HDR returns drop the changed photo's kept or preloading proxy (`DevelopController.sourceChanged`); a late histogram request for a photo already left can't replace the open photo's (`LatestJob.submit(_:if:)`), and the preview/render origin travels with each request; the spinner over a stand-in stays until the first render (not just the decode); a click inside the focused panel moves focus unless a control took it from that click; the Before wait ends when its render finishes or fails; the timing log reads file size and volume on its own queue. **Codex follow-up review of 25169a7 (Nov 9), fixed:** edits saved while the editable copy is still decoding now refresh Grid and Loupe (when the copy is ready, or from the saved settings if you leave first); proxy renders and their histograms carry the open's token, so a render from before `reopen()` can't show the old file or end the spinner; a render's histogram outranks the cached preview's for the same open, whichever arrives first. **Known limits:** sliders in sheets (Export) and the HDR editor show the focus mark but don't take keys (no window key handler there); the compare views (Side by Side, Slider) don't release focus on click (Esc does); Tone Curve and Color Grading wheels keep their hover-and-arrow keys rather than Tab focus.

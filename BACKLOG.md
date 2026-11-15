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

**Evidence:** review §5/6: editable film-inspired presets and grain types exist; measured stock calibration and multi-camera visual acceptance are not established. Grain cache-version concern was an inference, not a reproduced stale-preview bug. Match Look coverage wording differs (~1% source vs 2% PRD); resolve intent before changing either. AT-029 (Nov 9, 2026) aligned the PRD to the code's 0.8%, the threshold Rosh's matches have used since Phase 2; the code was not changed.

**Scope/acceptance to agree:** skin, foliage, sky, artwork, grayscale and low-light reference set across cameras; full images plus 100% grain crops; display/export consistency and mask geometry. Reproduce cache issues before deciding a fix; bump PreviewCache.version if rendering changes. Do not claim measured film matching without evidence.

### AT-010a — Curate and qualify the built-in Develop presets

**Status:** Implemented, manual acceptance open. Rosh approved auditing every built-in Develop look, removing overlap, retuning and documenting the result on November 9, 2026. **Owner:** Codex. **Chat:** [PR planning: Develop preset audit](codex://threads/01a1c0c9-32df-7b50-a968-b9056ebc9a74). **Branch:** `codex/develop-preset-audit`. **PR:** [#86](https://github.com/roshan-davis/atelier/pull/86). **Base:** `4b7adb3`. **Dependencies:** fixed photo fixtures and Atelier's existing Develop renderer.

**Acceptance:** every shipped look has a named target, a suitable example and a reproducible native before/after pair in Help. Check redundant looks, visually compare each preset on representative scenes, preserve previously applied settings and saved import selections, and verify the curated list in Develop, the photo menu and Import. Rosh's visual acceptance remains open. Measured stock calibration, RAW camera/profile comparisons, export parity and the rest of AT-010 remain separate. Native JPEG audit evidence covers 54 baseline and 45 shipped looks across ten fixed scenes, with selected 100% crops and measurable clipping reductions. Reference and regeneration steps are in [Preset qualification](Scripts/presets/README.md). The Mac check at `9e62e51` passed with 284 XCTest tests, both Nikon samples and no skips. See the PR for local logs, native layout review and GitHub Actions status.

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

**Lightroom gap list (Nov 15, 2026, Rosh: "lets add these in the backlog"):** the Lightroom Classic 16 comparison (`reports/lightroom-classic-16-vs-atelier-2026-11-15.md` in project files, gap 5) puts these under this item: smart collections, exact duplicate detection (Lightroom 15.4) and near-duplicates (PRD), Map view and People view (face recognition), both PRD "Later". Still proposed; pick one with Rosh.

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

## AT-021 — HDR editor (a view of Atelier since AT-052) and round trip; general plugins deferred

**Status:** Design complete — PR #69 squash-merged at `9b684c2dcf316c517d7b7af2ff16df79b2790890`. HDR implementation and acceptance remain open. Rosh approved the trimmed standalone direction and feasibility-first sequence. This retains Rosh's explicit priority override of the usual AT-005–015 order. **Owner:** Co (Codex). **Chat:** [HDR architecture planning](codex://threads/01a18f63-deff-7660-ac5f-e18f8866636b). **Branch:** `codex/at-021-processor-design`. **PR:** [#69](https://github.com/roshan-davis/atelier/pull/69). **Requested/revised:** Rosh, October 30, 2026.

**Direction update (Rosh, Nov 12, 2026):** HDR is a view inside Atelier, not a second app; see AT-052. The text below is the October 2026 record.

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

**Step 2 as built (branch `claude/project-thread-mp3ctg`, PR #139):**
- Core: `DevelopSettings.Spot` and `SpotSource` (`Develop/Spots.swift`): 16 candidate sources around the spot (8 directions, 2 distances, kept on the photo), ranked by how alike the ring around each is to the ring around the spot, read from a small gray copy of the proxy. `SpotRenderer` (`Develop/SpotRenderer.swift`): Clone and Heal as Core Image Metal kernels over each spot's own area; Heal spreads the photo-minus-source difference from a thin ring outside the spot over the inside with normalized blurs at two sizes (a fast stand-in for a Poisson membrane). Brush shapes are cached per photo (`SpotShapeCache`). Visualize Spots is a `SliderPreview` case (Laplacian edges, black on white).
- App: tool strip button, Q, Develop > Remove Tool (Q) and Develop > Clear All Spots; `SpotEditorView` overlay (click, stroke, drag source, drag spot, Space-pan, brush circle); Remove panel; keys [ ] ⇧[ ⇧] / A Delete Esc. Agent actions `develop.remove`, `develop.visualizeSpots`, `develop.clearSpots`. Help page `remove.html`. Layout snapshots `develop-remove`, `panel-remove`, `develop-remove-visualize`.
- No `PreviewCache.version` bump: photos without spots render as before.
- Left out: XMP writing of spots, the Spot Removal paste checkbox, agent Sync carrying spots, Content-Aware (step 3), Generative AI (step 4). Not measured yet: Heal time on a 45 MP NEF with many dust spots.
- Tests: `SpotTests` (encoding, defaults, presets, source candidates and ranking, hit-testing, Clone, Heal, Opacity, Visualize). Nothing compiled in the cloud.
- Fixed during Rosh's test: a spot first turned the photo into the spot's area stretched over the frame (each spot was a small piece composited over the photo). Each spot is now one kernel pass over the whole photo that leaves pixels outside its area unchanged (`c640040`). `swift test` and the layout snapshots were not run separately before the merge.

**Acceptance:** Mac build and tests pass; Develop sliders on every panel update correctly (no stale photo after Exposure, Temp/Tint, Profile, Lens Corrections, Defringe or Transform changes); J overlay marks the same pixels as before and the histogram is unchanged by it; Instruments numbers before/after for an HSL drag, a Contrast drag and a Clarity drag on a Z6 NEF; Atelier.app shows its icon in Finder. **Deferred:** GPU-4 to GPU-13 from the audit.

## AT-026 — Keyboard focus in Develop, icon bars, key combos in Settings

**Status:** In progress; implementation pushed, not yet built on a Mac. **Owner/chat/branch:** Claude (project thread "Add keyboard focus navigation in Develop"), branch `claude/project-thread-ea7lwj`. **Requested:** Rosh, November 9, 2026 (seven items, one PR); Rosh chose the Mac behaviour for ←/→ on a focused slider. Part of AT-014's keyboard acceptance. **Dependencies:** builds on PR #81's bar layout (merged).

**Scope:** (1) arrow keys on a focused slider, ⇧ for bigger steps; (2) ↑/↓ through the Presets list with Navigator preview, Return applies; (3) Tab between controls; (4) ⌃Tab/⌃⇧Tab between areas (not F6, which is Show Filmstrip); (5) a quiet focus mark instead of the system ring; (6) Before/After and Fit/Fill as icons with per-segment tooltips at every width; (7) Settings > Keyboard records ⌃/⌥/⇧ combos, and ⇧W, ⇧M, ⇧T and the area keys become customizable. PRD: "Keyboard focus in Develop".

**Acceptance:** Mac build and tests pass (new `KeyboardTests`); Rosh checks each item by hand, including that ←/→ still change photos when nothing is focused, typing in the slider value and Search Presets fields is unaffected, and existing custom keys still work. **Rosh's first tests (Nov 9):** ⌃Tab stuck at Presets, then ← → still changed photo with the right panel "focused", Tab didn't move within an area, and the histogram spun for a long time. Fixed by moving keyboard focus off SwiftUI's focus system onto `KeyboardFocus` (the window key handler routes keys, Tab steps within the area by on-screen order) and by counting the histogram latest-wins (`LatestJob`; the per-render queue from PR #79 built a backlog). **Second test (Nov 9):** after ⌃Tab neither Tab nor the arrows did anything, even on the Filmstrip stop. Cause: with no SwiftUI-focusable views left, SwiftUI gave the empty Search Presets field the keyboard on its own, and the key handler steps aside for any text field. Now an empty field nobody clicked or tabbed into gives the keys back, and ⌃Tab, Tab and a click on a control or the photo end typing in a field. **Third test (Nov 9):** plain Tab hopped between Search Presets and the Library search field, and the photo and histogram still took long to load after moving through photos. Tab now always stays in the focused area (Search Presets is a Tab stop of Presets; ⌃Tab still lands on the list). Opening a photo is latest-wins too: each photo passed with ← → had queued its RAW decode, plus a preview render for unedited RAWs, on the render queue ahead of the photo you stopped on; now only the newest waits and passed photos are skipped (`LatestJob`, `LockedValue`). Rosh then asked that a mouse click select an area for the keyboard as ⌃Tab does: each area reports its frame (`AreaFocusFlash`), and the window's click monitor calls `KeyboardFocus.clicked(at:)`. **Fourth test (Nov 9):** the photo and histogram still loaded seconds late after fast ← → on the Filmstrip, and Tab seemed to jump straight to Tone Curve. Opening now waits until ← → rest for 0.15 s when they come faster than that (the cached preview shows meanwhile) and decodes on its own concurrent queue, so the photo stopped on never waits behind a decode for one passed. Panel headers are now Tab stops (with Basic closed, Tab had skipped straight to Tone Curve's sliders), and Tab order uses each column's content coordinates, so scrolling can't leave stale positions. A decode for a new photo includes the camera-match analysis, which was not measured here; if a single photo still takes seconds after resting, that needs an Instruments trace on the Mac. **Fifth test (Nov 9):** Tab still skipped Basic and jumped around, and the histogram and photo still loaded late, mostly on ← from the last photo. Causes found in the code: (1) a control's position was dropped when SwiftUI reported it before the control registered (`setPosition` wrote into the not-yet-created entry), so it sorted last; after the switch to column coordinates positions were never reported again, so Tab order fell to dictionary order. Positions are now stored apart from registration. (2) A photo passed while moving fast (like the one before the last) was never decoded, and decoding a RAW for the first time (camera match plus the proxy decode and first render) is the wait. The neighbours of the open photo are now decoded and rendered once in the background after its first render (Lightroom does the same), the photo just left keeps its decoded proxy, and the histogram is counted from the cached preview at once until the first render's replaces it. **Sixth test (Nov 9):** dragging on the histogram no longer moved it, and the spinner came up over photos already showing. Likely causes from the code: a click in the right panel focused the last-used control and scrolled the panel to it under the drag, and neighbour preloading shared the CPU and GPU with the first edits. A click now focuses the stop just above where you clicked, without scrolling; preloading waits until the photo has gone 0.8 s without a render; the spinner over the photo's own preview waits 2 s (600 ms over a thumbnail or the last photo). Rosh rejected the 2 s as a band-aid: the spinner followed the background decode, not what was on screen. It now shows only while the image is a stand-in (thumbnail or previous photo, `DevelopController.showsStandIn`), never over the photo's own preview or a render. `DevelopTimingLog` writes each open step's timing to ~/Documents/Atelier Traces/ for real numbers. **Seventh test (Nov 9):** in Side by Side the Before pane spun much longer than before. The Before photo is rendered on the render queue after the photo's first render, and neighbour preloading (new in this PR) could start beside it. Preloading now waits until the Before photo is shown, and the Before render's timing is in the log. Rosh then pointed out the slider view showed both at once: it doesn't, it draws the After over the whole frame until the Before arrives, so the same wait is hidden there; preloading the neighbours' Before is proposed, not built. Rosh also saw B&W and slider edits not reaching the photo; the cause was not found by reading the code, so every edit made before the editable copy is ready, every render over 300 ms or failed, and any edit stuck behind a render running over 2 s are now written to the timing log. **Codex review of 52b5fa9 (Nov 9), all fixed:** saved edits refresh Grid and Loupe previews even after moving on (only the optional first-open RAW preview is skipped); each open carries its own token, so a decode from an earlier open of the same photo (A, B, A, or `reopen()` after Edit In) is dropped; Edit In and HDR returns drop the changed photo's kept or preloading proxy (`DevelopController.sourceChanged`); a late histogram request for a photo already left can't replace the open photo's (`LatestJob.submit(_:if:)`), and the preview/render origin travels with each request; the spinner over a stand-in stays until the first render (not just the decode); a click inside the focused panel moves focus unless a control took it from that click; the Before wait ends when its render finishes or fails; the timing log reads file size and volume on its own queue. **Codex follow-up review of 25169a7 (Nov 9), fixed:** edits saved while the editable copy is still decoding now refresh Grid and Loupe (when the copy is ready, or from the saved settings if you leave first); proxy renders and their histograms carry the open's token, so a render from before `reopen()` can't show the old file or end the spinner; a render's histogram outranks the cached preview's for the same open, whichever arrives first; preview writes carry a per-photo revision, so an older write finishing last can't overwrite a newer saved look. **Known limits:** sliders in sheets (Export) and the HDR editor show the focus mark but don't take keys (no window key handler there); the compare views (Side by Side, Slider) don't release focus on click (Esc does); Tone Curve and Color Grading wheels keep their hover-and-arrow keys rather than Tab focus.

## AT-027 — Before pane waits behind obsolete renders

**Status:** Implementation in review. **Owner:** Codex. **Chat:** [PR #82 follow-up on Side by Side loading](codex://threads/01a1bf1b-049e-7f91-9107-2fbba69e01c0). **Branch:** `codex/before-render-queue`. **PR:** [#83](https://github.com/roshan-davis/atelier/pull/83). **Dependencies:** PR #82, merged at `33fc9f5`.

**Evidence and scope:** The November 8 post-merge Develop trace recorded 18,685 ms waiting on the serial render queue and 255 ms rendering Before. Several Before requests for photos already left ran immediately afterward. Side by Side exposes the wait with a spinner. Slider draws the edited image until the shared Before render arrives. Keep one queued or running Before proxy render and the latest request, drop obsolete results, and request the foreground comparison before preview-cache writes.

**Acceptance:** Both layouts show the current photo's aligned Before image after rapid navigation and geometry edits. Turning compare off clears waiting work. Review the timing trace for avoided renders on passed photos. A native check and manual timing comparison are separate. **Deferred:** determine why the preceding proxy and concurrent full-size Core Image renders stalled, and profile the full-size path separately.

**Validation:** Mac build and 277 Swift tests, including the Nikon Z6 RAW tests, passed on implementation commit `eb75990` with zero skips. Whitespace, 10 script tests and Help index checks passed. Logs: `/private/tmp/atelier-before.ZW2gai/.build/local-checks/20261108-235247-715403`. The updated Help section was visually reviewed in Chrome’s print rendering. Live comparison timing and manual acceptance remain pending.

**Follow-up evidence:** Rosh still saw seconds-long waits on local RAWs while testing PR #83 at `2e2a718`. One Before render waited 368 ms and took 20,464 ms; another waited 18,419 ms behind a slow foreground render. Full-size renders in the same trace also took 17–22 seconds. Fit now discards stale zoom reports, and full-size comparison work waits for both foreground render attempts. Slider shows the shared loading indicator over its Before region instead of exposing After on both sides. Profiling the underlying Core Image stalls remains open.

**Cause isolated:** Rosh reproduced waits on `05daa83`. A local 6048×4024 Nikon RAW with Transform > Aspect at +13 repeatedly stalled full-size rendering for about 21 seconds in the app. A read-only probe reproduced a 10,152 ms Core Image output stage with the saved settings, and an independent control took 127 ms with Aspect reset. Requesting the mapped source rectangle per affine tile reduced the same full-size render to 130 ms. The tested 2560 px proxy matched exactly and 39 of 97,353,728 full-size bytes differed by one level. The neighboring render matched exactly. Live acceptance on the affected photos remains pending.

**Claude review follow-up:** Bounds now cover perspective and radial distortion, with a full-source fallback near the projective horizon. On the same Nikon RAW, full-size output for Vertical +20, Distortion −50, Distortion +50, and Vertical +20 combined with Distortion +50 took 11,685 / 10,321 / 10,133 / 10,456 ms on `50c883e` and 122 / 204 / 172 / 171 ms with the new bounds. All four proxy buffers and the earlier affine proxy matched byte for byte, so cache version 8 is retained. AppKit republishes the committed pinch report even when its magnification was reported mid-gesture. Tile and pinch regression coverage added. The cached Before stand-in remains a separate UX proposal.

## AT-028 — Restore Option-drag previews in Develop

**Status:** Implementation in review. **Owner:** Codex. **Chat:** [Develop follow-up](codex://threads/01a1bf1b-049e-7f91-9107-2fbba69e01c0). **Branch:** `codex/detail-option-preview`. **PR:** [#85](https://github.com/roshan-davis/atelier/pull/85). **Dependencies:** PR #82 merged at `33fc9f5`.

**Evidence and scope:** Rosh reported that the Sharpening Option-drag views did not show. The shared drag controls only polled Option on mouse movement, and pointer focus could scroll the panel during a drag. Keep the controls stationary, listen for modifier transitions during the drag, and give the temporary preview priority over full-size work.

**Acceptance:** Amount shows grayscale, Radius and Detail show halos, and Masking shows its black and white mask. Press and release Option with the mouse held still, then release the mouse. Check Basic clipping, Color Grading and Lens Corrections > Defringe as shared callers.

**Validation:** Mac build, all 278 Swift tests including the Nikon RAW fixture, Help and script checks passed at `a1b95ba` with zero skips. Logs: `/private/tmp/atelier-option.KES5VC/.build/local-checks/20261109-010613-850250`. Reviewed the grayscale, halo and mask snapshots plus the updated Help section. Manual Option-drag verification remains pending.

## AT-029 — Match Look Phase 3: Protect Skin Tones and Subject & Background

**Status:** Implementation in review, with manual acceptance pending. **Owner/chat/branch:** Claude (project threads "Plan Match Look to Reference phase 3" and "Fix Match Look Phase 3 PR"), branch `claude/project-thread-tjngdm`. Codex resolved conflicts and reviewed the PR in the App chat for PR #84. **PR:** [#84](https://github.com/roshan-davis/atelier/pull/84). Renumbered from AT-027, which PR #83 also used. **Requested:** Rosh, November 9, 2026; Rosh approved the plan and chose the full scope (skin protection plus the automatic subject mask) over skin only. **Dependencies:** Match Look Phases 1 and 2 (PRs #18 and #20, merged); Select Subject masks (Masking).

**Scope:** (1) Protect Skin Tones checkbox, on by default when Vision finds a face in the photo; skin on the faces is left out of the fit and the match may move its Oklab hue at most 5° and its chroma at most 15% (HSL skin bands first, then a minimal pull-back of White Balance, Saturation, Vibrance, grading saturation and the subject mask's color); (2) Match Areas becomes a pop-up: Whole Photo, Subject & Background (global sliders fitted background to background, plus a "Match Look: Subject" Select Subject mask with Temp, Tint, Exposure and Saturation fitted subject to subject, replacing an earlier match's mask), Boxes; (3) notices when no face or subject is found; (4) Show Differences lists the mask's sliders; Strength, Same settings and Match each photo carry the mask. Also aligns the PRD's HSL band threshold with the code (about 1%, not 2%; the review §5/6 discrepancy noted under AT-010 above). PRD: "Match Look to a Reference".

**Acceptance:** Mac build and tests pass (new `LookMatchTests` cases); Rosh checks, on a portrait with a strong teal or film reference, that skin stays natural with Protect Skin Tones on and shifts with it off; that Subject & Background adds one editable mask and re-running replaces it; that a reference or photo without a clear subject falls back with a message; and that Boxes behaves as before. **Known limits:** skin is measured only on faces Vision finds (arms and hands follow the same global sliders but aren't measured); the dialog doesn't show the found subject; the match's own Vision subject mask is computed on the fit render (384 px), so its edge differs slightly from the mask the renderer draws at full size; no new help pictures (the page has a drawn control row); no `PreviewCache.version` bump (rendering is unchanged).

**Cloud review (Nov 9, no Swift toolchain):** rebased onto main after PRs #83 and #85; every API the change calls was checked against main's source. Fixed: the dialog now finds faces on its 1400 px preview instead of the 384 px fit render (small faces were missed, so Protect Skin Tones started off and said "No faces found"); a full skin pull-back restores an As Shot temperature instead of writing the as-shot number; explicit CGFloat-to-Double conversions and a simpler skin-penalty closure, to avoid type-checker trouble.

**Mac validation (Nov 9):** Codex merged main at `624918f` and regenerated the Help index. At `3f510d3`, `python3 Scripts/check_pr.py --samples /private/tmp/preset-raws` passed the build, all 290 Swift tests (Nikon Z6 and Zf, zero skips), script checks and Help checks. Logs: `/private/tmp/atelier-pr84-review/.build/local-checks/20261109-085259-690988`. Reviewed the Help page in Chrome and the Whole Photo, Boxes, Show Differences and Subject & Background snapshots from that revision. The subject snapshot exercises the fallback, so a real portrait and successful automatic mask still need manual acceptance. GitHub Actions assigned no runner.

**Approved review fixes (Nov 9):** Rosh approved all three in the PR #84 Codex chat. Apply and Show Differences wait for the current refit, a repeat match updates checked sliders on the existing subject mask, and skin protection reduces the whole fit when restoring color sliders alone misses the limits. The focused Match Look run passed all 19 tests, including the real portrait, Yosemite landscape, camera product photo, and the dialog debounce. Logs: `/private/tmp/atelier-pr84-artifacts/targeted.log`. Manual acceptance remains pending.

## AT-030 — Run routine UI checks without agent-driven desktop testing

**Status:** Implemented in draft [PR #88](https://github.com/roshan-davis/atelier/pull/88). Validation and acceptance pending. **Owner:** Codex. **Chat:** [PR planning](codex://threads/01a1c1fe-a0b2-7f00-aa05-a3c288cfc592). **Branch:** `codex/pr-ui-automation`. **Approved:** Rosh, November 9, 2026.

**Evidence and scope:** At `5b8bf19`, CI uploaded layout screenshots but did not compare them, and local pre-PR checks excluded GUI snapshots. Build on the existing snapshot generator and require full Xcode and a logged-in Mac desktop session. Use isolated fixture data, compare PR and base pixels on the same runner, and run one native Exposure and Undo smoke test.

**Acceptance:** One scripted command and one concise CI report give the tested revision, test result, and only the changed screenshots for visual review. Manual acceptance remains for intentional design changes and uncovered workflows.

**Validation:** Build, Help, script checks and all 295 Swift tests passed on Mac at `0ace368`, with both Nikon RAW fixtures and zero skips. The native smoke and the initial 98-screen comparison passed on the working patch. The complete one-command run passed at `0ace368`, including the native smoke and a comparison of 98 screenshots. Fifty images were flagged for review against the old snapshot fixtures. Logs: `/private/tmp/atelier-pr-ui-automation/.build/local-checks/20261109-131534-464163`. GitHub Actions reported a billing/spending-limit block before starting a runner.

**Grouping and documentation:** Rosh requested a testing guide with report interpretation and recommended groups. Added selectable checks, build, Swift, smoke and visual groups to the same PR.

**Local packaging fix:** The visual run at `a6aa648` from the App checkout stopped before launch because its existing SwiftPM output contained a stale HDR Help symlink. The UI runner now packages the current revision from a fresh SwiftPM build directory.

**Edit In fixture cleanup:** The App visual run at `555faf8` compared 98 screens but left two documents open in Preview. The snapshot scenario now checks the generated stack without launching Preview, and the runner adapts older baselines so their Edit In TIFF is also cleaned with the run.

## AT-031 — Built-in References for Match Look

**Status:** Implementation in review. Manual acceptance pending. **Owner:** Codex. **Chat:** [Match Look Built-in References](codex://threads/01a1c197-aa52-7d60-be48-b20e2b243b9f). **Branch:** `codex/match-look-built-in-references`. **PR:** [#87](https://github.com/roshan-davis/atelier/pull/87). **Baseline:** freshly fetched `5b8bf1919e3047a125d86a37fbbd3e133ecccd92`. **Dependencies:** AT-029 / PR #84, merged.

**Scope:** Rosh chose four pairs of original, editable vector studies inspired by The Matrix, Game of Thrones, Mad Max: Fury Road and The Dark Knight. Each pairs a portrait with a wider scene. Cards show scene tags, palette descriptions and the main color regions, such as Face & Skin, Clothing, Sky and Ground. The studies use the existing editable Whole Photo fit. Using the labeled regions in a fit is deferred.

**Acceptance:** Qualify all eight through the production fit on real photo fixtures. Verify reference switching, Match Areas, Strength, Protect Skin Tones and normal Apply behavior. Inspect the dialog, picker and Help. Record Mac and GitHub checks for the PR and leave manual acceptance to Rosh.

**Validation:** Implementation commit `dd4a57a15343fcf284f85065f7b2ff27daa3905a` passed the Mac pre-PR checks with Nikon Z6 and Zf RAW fixtures, 297 Swift tests, zero failures or skips, and passing script, Help and whitespace checks. All eight studies improved palette distance on the real fixtures by 48–90%. Maximum measured portrait skin drift was 4.60° hue and 12.8% chroma. Reviewed the eight fits, the updated Help in Chrome and local Match Look snapshots from the implementation commit. Logs: `/private/tmp/atelier-match-look-references/.build/local-checks/20261109-120312-379418`. The PR records final-head checks and CI. Rosh's manual interaction and visual acceptance remain open.

**Conflict resolution:** Merged PR #88's main revision `67931d7` into the PR branch. PR #88 retains AT-030. This item was previously AT-030 on the PR branch.

## AT-032 — Match Skin Tone in Match Look

**Status:** Implementation in review. Manual acceptance pending. **Owner:** Codex. **Chat:** [Match Skin Tone](codex://threads/01a1c2e4-4756-7d71-be00-48275f5eda30), continued from [PR #87](codex://threads/01a1c197-aa52-7d60-be48-b20e2b243b9f). **Branch:** `codex/match-skin-tone`. **PR:** [#89](https://github.com/roshan-davis/atelier/pull/89). **Baseline:** `15f1757ea74ee5b32facebada4595d7d53187414`. **Dependencies:** AT-029 and AT-031, merged.

**Scope:** Rosh requested Match Skin Tone as an alternative to Protect Skin Tones. Measure face color on both images and fit editable local color sliders. Author face samples for the four built-in portraits. Other labeled regions are deferred.

**Acceptance:** Verify both skin treatments on real portraits with different skin tones. Exercise missing skin, switching treatments and references, Strength, Show Differences, one-step Apply and per-photo batch behavior. Record Mac and native UI results and leave visual acceptance to Rosh.

**Missing-skin fallback:** Keep other selected adjustments available when either image lacks face skin. A skin-only batch can continue when the lead photo lacks skin and the reference has usable skin. Skip unchanged photos without adding a history step. The native test checks the visible warning and whether Apply remains available.

**Validation:** Implementation revision `54365dfd5547bef0b10a63449fc3dab9556011c0` passed the Mac build and all 300 Swift tests with Nikon Z6 and Zf RAW fixtures and zero skips. Both native smoke tests passed, including missing skin, Apply and switching back to Off. The model regression covers the face-free lead photo in a skin-only batch. Reviewed the updated Help and face color example in Chrome. Mac logs: `/private/tmp/atelier-match-skin-tone/.build/local-checks/20261109-170936-868837`. UI and CI details are recorded in the PR.

## AT-033 — Select People: face and body skin masks, used by Match Look

**Status:** Merged at Rosh's ask on Nov 10, 2026 (main `4f6f6b8`, PR #90). Rosh ran Match Look from Xcode during review; XCTest not run (CI billing-blocked). Manual acceptance of the merged result open. **Owner:** Claude. **Chat:** [Improve Match Colors quality](https://claude.ai/code/project/chan_01Y9ueFJEbKyPqWn7CWQ5SGK?thread=cmsg_01Y9ueFJEbKyPqWn7CWQ5SGKF2JPu63ZaHgkVxXXo1FmSC). **Branch:** `claude/project-thread-wy1hrj`. **PR:** [#90](https://github.com/roshan-davis/atelier/pull/90). **Baseline:** `20b58c5`. **Dependencies:** AT-029, AT-032 (merged).

**Scope:** Rosh (Nov 10, 2026): Match Look's skin options picked faces badly; asked for better face and body skin selection, and chose a shared Select People mask over a Match Look-only fix. A new Masking part, Select People (Face Skin, Body Skin, Person, Feather), built from Vision face landmarks, per-person instance mattes and a skin color model learned from each face. Protect Skin Tones and Match Skin Tone measure skin through it, and Match Skin Tone's mask becomes a Select People part. Show Skin in the dialog tints the measured skin. Eyes, brows, lips, teeth, hair and clothes parts are deferred. Wider Match Look quality items are in `reports/match-look-quality-2026-11-10.md` (LM-1 to LM-8; LM-1 to LM-4 in AT-034 / PR #91). After Rosh's first test (Body Skin spilled onto a warm hat, scarf and coat; face pushed orange), Match Look uses Face Skin only with capped sliders, and Body Skin is grown from the neck and Vision's wrist/forearm/hand pose points over smooth, edge-free skin-colored pixels (no AI model, Rosh's preference).

**Acceptance:** On real portraits with different skin tones (single person, group, face with hands visible, beige clothes): Face Skin leaves out eyes, brows, lips and hair; Body Skin covers neck, arms and hands with no gap under the jaw; no background or clothes. Person menu picks one person. Match Look's Show Skin matches what the mask covers, and Match Skin Tone changes neck and hands with the face. Time the first Select People search on a Z6/Zf RAW (target under 300 ms in Release; Debug may be slower).

**Validation:** Core unit tests added (`PeopleSkinTests`, drawn portrait, no Vision). A Python port of the face/body skin build was run on the same drawn portrait to check the test thresholds. No Swift build or test run yet; needs a Mac check of the PR head.

## AT-034 — Match Look: lit built-in references, no fading, neutral white balance, light/shadow color

**Status:** Merged at Rosh's ask on Nov 10, 2026 (main `4f6f6b8`, PR #91). Rosh ran Match Look from Xcode during review; XCTest not run (CI billing-blocked). Manual acceptance of the merged result open. **Owner:** Cl. **Chat:** Claude project thread "Match Look quality". **Branch:** `claude/match-look-color`. **PR:** [#91](https://github.com/roshan-davis/atelier/pull/91). **Baseline:** `20b58c5`. **Dependencies:** AT-031, AT-032 merged. PR #90 (AT-033, Select People) touches other Match Look files; no overlap expected.

**Scope:** Rosh (2026-11-10): built-in references "more vectorized and curvy", "colors of light and shadow rightly depicted", and the match must "do a better job". Rosh chose this color PR before the body-skin follow-up in PR #90. Items LM-1 to LM-4 of the Match Look quality audit (`reports/match-look-quality-2026-11-10.md` in project files):
- LM-1: the eight studies redrawn as flat vector art (Catmull-Rom paths; facets kept for buildings, roads, trees). Every area is painted in four flat tones from a key light: highlight rim toward the light (leaning to the look's light color), midtone, shadow and dark crescents away from it (leaning to its shadow color); near-black accents, flat glints, ±2-level grain. Portrait heads in the same four tones (shadow side following brow/cheek/jaw, dark edge band, highlight planes on forehead/cheekbone/nose/chin, sockets, eyes, nose shadow plane, four-tone lips, hair), after Rosh rejected soft-shaded heads on Nov 10. Skin swatch on the lit cheek's plain midtone, derived from the head's geometry.
- LM-1b (Rosh 2026-11-10: "for that only I am asking for this feature"): portrait heads simplified to an oval face, neck and hair in the four tones (wider skin bands), with small marks for eyes, brows, nose, mouth. Each portrait authors three skin samples (shadow, midtone, highlight bands). Match Skin Tone now matches skin tone by tone: photo skin split into luma thirds; Match Look: Skin (midtones), Match Look: Skin Shadows / Skin Highlights (faces ∩ Luminance Range). Portrait studies offer Whole Photo and Subject & Background (default), with the drawn person as the subject mask (`BuiltInLookReference.features(for:)`, `LookReferenceFeatures(image:subjectMask:faces:)`).
- Follow-up asked by Rosh (not started): editable simple study where the user picks each area's tone colors (color wells, maybe eyedropper from a photo) and saves it as a custom reference/preset.
- LM-4: Exposure capped at ±1 EV; shadow lift capped (4% + 40% of the tone) unless the reference is faded. Tone Curve from 7 brightness percentiles instead of full histogram matching; 7 curve points; blacks lift only for a really faded reference (darkest 1% > 6% with dark tones present), whites come down at most to 92%.
- LM-3: White Balance matches the least colorful 30% of midtones (`neutralAB`), falling back to all midtones.
- LM-2: Shadows, Midtones and Highlights wheels fitted together from the neutrals' color in each tonal range, using the renderer's `ColorGrade.weights`, 3 probes + joint solve, 2 rounds, a step kept only if it helps.

**Not in scope:** LM-5 (R/G/B curves), LM-6 (joint refine), LM-7 (content-aware correspondence), LM-8. Subject & Background local white balance still uses mean midtone color. Help before/after pictures (`match-built-in-*.jpg`) still show the old studies and need regenerating on a Mac (`ATELIER_BUILT_IN_LOOK_OUT`, then `Scripts/help/make_help_images.py --built-in-look-from`).

**Acceptance:** Mac build and tests (new: tone curve, neutral cast, Midtones wheel, study tonal range). Rosh: built-in studies look curved and lit; matches no longer fade blacks; shadows and highlights take the study's colors; Color Grading shows Shadows, Midtones and Highlights moved.

**Validation:** Cloud only, no Swift toolchain: source review plus a Python port of the study drawing and curve rule (studies' darkest 1% luma 0.015–0.033 at 384 px, Oklab L 1–99% span 0.55–0.79, largest single color under 4%).

## AT-035 — Match Look: fast fitter on a stand-in of the renderer

**Status:** Merged at Rosh's ask on Nov 10, 2026 (main `4f6f6b8`, PR #92). Rosh ran Match Look from Xcode during review; XCTest not run (CI billing-blocked). Manual acceptance of the merged result open. **Owner:** Cl. **Chat:** Claude project thread "Match Look quality". **Branch:** `claude/match-look-fast-fitter`, stacked on AT-034 (`claude/match-look-color`, PR #91). **PR:** [#92](https://github.com/roshan-davis/atelier/pull/92). **Dependencies:** AT-034.

**Scope:** Rosh (2026-11-10): Match Look "still terribly slow" with poor results; asked for research into a faster, efficient way with skin protected, skin matched or neither. Rosh chose "new fitter PR". The match renders the photo for real only for White Balance and Exposure, one stage render, two renders per Match Look mask weight and a final check; every other try is computed by `LookEmulator` (`Sources/AtelierCore/Develop/LookMatch+Emulator.swift`) from the stage. Final refinement no longer moves Temp/Tint when the stand-in is on. Log line: renders, stand-in tries, seconds, stand-in error. Rosh still found it slow running from Xcode (2026-11-10): AtelierCore was unoptimized in Debug, so every per-pixel Swift loop (Match Look sampling, the stand-in, histograms, color cubes) ran many times slower; AtelierCore now builds with `-O` in Debug like AtelierHDRCore, and the stand-in spreads its pixels over the cores.

**Not in scope:** emulating White Balance and Exposure at decode, Dehaze/Clarity/Texture/Vibrance after the curve, the photo's own masks; a preview on a smaller sample (the stand-in already works at the 384 px sample size).

**Acceptance:** Mac build and tests (`LookEmulatorTests`: stand-in vs renderer within 0.012 mean Oklab difference with curve, saturation, HSL and grading, and with a skin mask; skin match at most 40 renders). Rosh: Match Look feels fast with Protect Skin Tones, Match Skin Tone and Off; results at least as good as before; the Console line shows the render count.

**Validation:** Cloud only, no Swift toolchain: source review.

## AT-036 — Develop: live slider frames straight from the GPU to the photo view

**Status:** Implementation in review. Never compiled (cloud, no Swift toolchain); Mac build, tests, timings and Rosh's manual acceptance pending. **Owner:** Cl. **Chat:** Claude project thread "Make Develop sliders smooth like LightCraft". **Branch:** `claude/project-thread-f7xbz1`. **PR:** [#93](https://github.com/roshan-davis/atelier/pull/93). **Baseline:** `4f6f6b8`. Part of AT-011 (drag responsiveness); follows AT-011a (PR #81).

**Evidence:** `reports/develop-preview-vs-lightcraft-2026-11-10.md` (project files and `~/RoshProjects/Atelier/reports/`), findings F1–F3. A warm proxy render takes ~11 ms (Codex, Release, PR #81), but settings→photo took 37.5 ms median because every frame was read back to the CPU (`createCGImage`), published through SwiftUI, uploaded again by Core Animation, and the next render could only start after the main thread handled the last one. LightCraft draws its renders' GPU textures directly.

**Scope:** Rosh (2026-11-10): "smooth as butter"; one focused change that renders directly with no round trips and no regression. (1) The render queue starts the next proxy render itself, latest-wins (`LatestJob`), one render per queue block so Before and stored previews still interleave. (2) Once the photo is up, a live frame is rendered by Core Image into an IOSurface (`DisplaySurfaces`, tagged Display P3) that the photo view's layer shows directly (`PhotoFeed`, `ZoomCanvasView.showFrame`); no CPU readback, no SwiftUI update per frame. The histogram is counted from a 256 px copy of the surface. (3) 0.12 s after the last edit the ordinary image is rendered and published as before, so the photo at rest, Navigator, crop, compare, AI and everything else that reads `image` are unchanged. Applies to the single-photo view and Masking; compare views, crop, Guided Upright and the AI brush keep the ordinary path. A frame whose shape differs from the photo on screen (Aspect, crop) falls back to the ordinary path until the pointer edit ends.

**Not in scope:** Exposure/Temp/Tint re-decoding the RAW each tick (F4, changes the look), zoomed whole-photo full-size renders mid-drag (F5), stored previews on the live render queue (F6), canvas-sized drafts (F7), moving `settings` observation off the big controller.

**Known difference:** the Navigator thumbnail updates when a drag pauses (0.12 s), not on every frame.

**Acceptance:** Mac build and tests (`DisplaySurfacesTests`: surface frame equals `renderForDisplay` within one level, right way up, with and without the clipping overlay; pool limit). Timings before/after in a Release build: settings→pixels on screen for Basic > Contrast and Tone Curve drags at Fit (target AT-011a: photo < 50 ms median, ≤ 100 ms p95). Rosh: no color shift or flip between a drag and its release; Before (\), J overlay, Masking brush and sliders, zoomed drags, Aspect drag, photo changes during and right after a drag all show the right image.

**Validation:** Cloud only, no Swift toolchain: source review.

## AT-037 — One slider for the whole app: easier-to-grab knob and a left-right arrow

**Status:** Implementation in review. Never compiled (cloud, no Swift toolchain); Mac build, tests, layout snapshots and Rosh's manual acceptance pending. **Owner:** Cl. **Chat:** Claude project thread "Make app-wide slider style with bigger knob". **Branch:** `claude/project-thread-3d1h14`. **PR:** [#94](https://github.com/roshan-davis/atelier/pull/94). **Baseline:** `88b3328`. Part of AT-014 (UI, gestures and accessibility).

**Scope:** Rosh (2026-11-10): a slightly bigger knob with a different cursor, on all sliders, as the app's slider standard. Agreed: 12 pt knob (was 11), then 13 pt (Rosh, same day, after trying it), 20 pt grab zone around it (a press there keeps the knob under the pointer; elsewhere on the track jumps it), the left-right arrow over the knob and through every drag (`CursorShape.slide`), track inset by the knob's radius. `SliderGeometry` (Core, tested) holds the numbers and math; `DevelopSlider`, `SliderKnob` and `HueRangeSlider` use it. The system sliders in Cull (Grouping), Match Look (Strength) and the grid toolbar (thumbnail size) now use `DevelopSlider`. Tone Curve region splits and the histogram drag show the same arrow. `DevelopSlider` gains VoiceOver value and increment/decrement. Help (Develop basics > Sliders) and its drawn sliders updated.

**Not in scope:** keyboard focus (`KeyboardSlider`) for the three formerly-system sliders outside Develop: they never had Atelier's arrow-key focus, and adding it would take the arrows from Cull and grid navigation. Point curve handles and color wheels are not sliders.

**Acceptance:** Mac build and tests (`SliderGeometryTests`), layout snapshots reviewed (every panel's slider rows shift by the knob inset; the Color Grading luminance slider and Presets Amount rows are 4 pt taller). Rosh: knob easy to catch, no jump when grabbing it, arrow over the knob and while dragging, drags as smooth as PR #93, double-click name reset, click-to-type, Tab/arrow keys and ⌥-drag views unchanged.

**Validation:** Cloud only, no Swift toolchain: source review; Help page checked in Chromium (drawn sliders and the live Temp slider's grab/jump behavior).

**Follow-up (2026-11-10, after #94 merged as `0ab8fba`):** Rosh built it and found a knob at the maximum could only be caught (and showed the arrow) on its left half. Cause: the slider's ZStack was sized by its children (the track, now inset, and the knob), so its hit shape stopped 12 pt short of the right end and 8 pt short of the bottom; framed to the full slider in `DevelopSlider` and `HueRangeSlider`. Knob 12 → 13 pt at Rosh's ask. HSL / Color was cut off on the left in a narrow right column (Rosh's screenshot): the Hue / Saturation / Luminance / All bar is wider than the column, and the panel centered its too-wide content. That bar now falls back to Hue / Sat / Lum / All when the full names don't fit, and every panel's content is aligned left, so anything too wide overflows at the value end instead of cutting names. Branch `claude/slider-end-grab`, PR [#95](https://github.com/roshan-davis/atelier/pull/95).

## AT-038 — Develop frame diagnostics (D0)

**Status:** Draft PR open, manual acceptance pending. **Owner:** Claude (handed over by Codex on Nov 10, 2026; Codex reviews). **Chat:** [PR #96 — Develop slider frame HUD (D0)](codex://threads/01a1c5d7-b3a8-79e3-84d6-9faadfd45aee); Claude project thread "Make Develop sliders butter smooth". **Branch:** `codex/develop-frame-hud`. **PR:** [#96](https://github.com/roshan-davis/atelier/pull/96). **Dependencies:** AT-011a, AT-036.

**Scope and evidence:** Rosh requested D0 only, based on Claude's November 10 smoothness report and Codex's PR #93 benchmark. Add opt-in frame diagnostics in single-photo Develop, with once-a-second timing-log summaries in Debug and Release. Run the same real slider gesture on the Z6 and Zf NEFs, including zero-start and 100% zoom, with Basic, Tone Curve, HSL, Detail and Effects open. Record actual display cadence and distinguish a display-link estimate from physical presentation. D1–D5 require separate scope and approval.

**Acceptance:** The overlay reports refresh-estimated photo FPS, synchronous main-thread slider callback time, render time, frame-ready to estimated refresh and longest gap per drag. The overlay leaves the slider and photo gesture paths in place. Confirm native appearance and log output. Attribute frame loss only where evidence supports it.

**Bench evidence:** 64 two-second app-local mouse drags on the real slider controls, from `f1b7e23` plus D0 instrumentation at `4eea481`, 120 Hz reported display-link cadence, Xcode Debug under LLDB with Metal validation and native Release, Z6 and Zf local NEFs. On Z6, first Highlights rendered for 1,485 ms Debug and 1,376 ms Release. Later zero starts were faster and the cause of first-use latency remains open. Zoomed Contrast had 6–14 fewer estimated frames than Fit across the four build/camera comparisons. Fit Exposure had 6–13 fewer than Fit Contrast. Release HSL Hue Blue did not reproduce historical hundreds-of-ms render timings. App-local input delivery, geometry probes, variable changed-tick counts, concurrent Debug build/test activity and the display-link estimate limit attribution. Raw logs `/private/tmp/atelier-d0-gesture/logs`.

**Validation and deferred work:** Standard Mac checks at `4eea481` built with Xcode 26.3 and ran 324 XCTest tests with no skips and 39 assertion failures across six cases. All six cases reproduced the same 39 failures on the unchanged `f1b7e23` source tree with the same GRDB dependency and RAW fixtures. The focused native HUD menu test passed after identifying the overlay by its accessibility identifier. Check logs and visual acceptance are tracked in PR #96. D0 changes diagnostics only. D1–D5, physical scan-out verification and per-cause frame-loss attribution remain deferred.

**PR #96 follow-up:** Rosh requested main run-loop busy time, reasoned CGImage fallback counts, and the same diagnostics for Tone Curve point and Color Grading wheel drags. The Debug 120 Hz rerun used 3 two-second Fit gestures per slider and RAW with the original expanded panels. Contrast had 30.8/32.4 ms median mean busy passes on Z6/Zf, with worst passes of 54.9/56.2 ms. Exposure had 37.0/32.5 ms means and 97.2/74.5 ms worst passes. No CGImage fallbacks from either tracked cause occurred across the 12 drags. A busy pass measures total elapsed main-thread work and does not isolate SwiftUI. Logs under `/private/tmp/atelier-d0-gesture/logs/run-loop-*`. Exact revision and validation are in the PR.

**Claude handover revision:** Each completed drag also logs how many main passes exceeded one display refresh (frames held back by main) and how many histogram/scope updates were published (S2 in the smoothness report), and every main pass during a drag is a "Main pass" signpost interval, so an Instruments trace can attribute long passes to SwiftUI or other work. Source-only review in the cloud; not built or run by Claude. Needs a Mac check of the pushed head.

## AT-039 — Develop: smooth slider drags (D1–D5 except D3b)

**Status:** In progress, approved by Rosh on Nov 10, 2026 (one PR, one commit per step, each step benchmarked by Codex with AT-038's Frame Diagnostics at its own SHA). **Owner:** Claude. **Chat:** Claude project thread "Make Develop sliders butter smooth". **Branch:** `claude/project-thread-l04ezc`. **PR:** to be opened. **Dependencies:** AT-038 (merged in #96), AT-036.

**Scope and evidence:** The steps from `reports/develop-slider-smoothness-design-2026-11-10.md`, in order: D1 photo frames reach the screen without the main thread; D2 a tick updates only the views that show it; D3a fixed pipeline shape, warm-up and stage cache; D5 saves and previews off the live render queue; D4 zoomed drags render only the visible area. D3b (Exposure and white balance after a cached decode, GPU color cube) changes how photos look and stays a separate item. AT-038's Debug rerun: main run-loop passes 31–37 ms mean, 97 ms worst, while the gesture callback took 0.1 ms; frame ready → layer 14–19 ms against a ~6 ms render.

**Acceptance:** Per step, Frame Diagnostics before/after on the Z6 and Zf NEFs (Fit Contrast and Exposure, 100% Contrast, Debug and Release, Rosh's usual panels): no fewer frames per drag and no longer worst gap than the step before, and the step's own target metric improves. No change to how any photo looks (renders identical, no `PreviewCache.version` bump). Rosh's manual acceptance of the final head.

**D1 (commit 1):** The render queue puts each live frame on the photo view's frame layer itself, in its own Core Animation transaction (`LiveFrameSink` in `PhotoFeed.swift`); the main thread only does bookkeeping afterwards. Frames requested for another photo, the Before view, crop or an Option view are dropped by an epoch. The histogram's small copy is made after the frame is on screen instead of before. Expected: Frame Diagnostics' "ready to layer" near 0 ms and more frames per drag while main passes stay long. Not compiled in the cloud.

**D2 (commit 2):** A drag tick updates only what shows it. The histogram and color scope moved to their own `DevelopMeasures` object, read through `MeasuresReader` by the histogram, the Tone Curve backdrops and the Color Grading wheels' scope, so a new count no longer updates the whole Develop window (S2). Every `ParameterSlider` compares what it shows (value, range, default, RAW-ness, tint hue) and skips its row when unchanged, so panels rebuilding on a tick no longer rebuild every slider row (part of S1). `changed()` no longer republishes an unchanged Preset Amount or Before image. Not done here: panels still re-run their bodies on each tick (they read `settings`); splitting `settings` per panel would be a bigger change, proposed only if Codex's D2 numbers still show long main passes. Expected: Frame Diagnostics' main pass mean and long-pass count fall; histogram updates no longer show up as extra long passes. Not compiled in the cloud.

**D3a (commit 3):** The first frame of a tool that was at zero no longer waits for Core Image to compile. When a photo opens, `DevelopRenderer.warmUp` (`PipelineWarmUp.swift`) runs a 64 × 48 stand-in through the photo's own settings once per idle tool (Highlights/Shadows, Contrast curve, Texture, Clarity, Dehaze, Vibrance, Saturation, the color cube, Sharpening with and without Masking, both Noise Reductions, Glow, Vignette, Grain) on a utility-priority queue, at the proxy's scale, and stops when another photo opens; the timing log records `warm-up: N pipelines in T ms`. Stage cache: in live sessions the guided filter's smoothed coefficients for Highlights/Shadows, Clarity and Texture are kept in Core Image's cache (`insertingIntermediate(cache: true)`), so a drag of one of them recomputes only the last per-pixel step. Exposure and white balance (RAW decode settings) can't be warmed without the RAW and are D3b. Instead of a fixed pipeline shape (every tool always in the graph), which would change pixels at zero, the warm-up builds the shapes ahead. The cached coefficients are stored as half floats; a new test checks the result stays within one 8-bit level. Full-size (zoomed) sessions also cache them, which costs memory at 24 MP; Core Image evicts its cache under pressure. Expected: the first Highlights or Contrast frame after opening a photo drops from 0.66–1.4 s to near a warm frame; Highlights/Shadows/Clarity/Texture render times fall. Not compiled in the cloud.

**D5 (commit 4):** Saving no longer shakes the next drag. The Grid/Loupe preview render after a saved edit (28–35 ms) moved from the live render queue to its own utility queue, so a drag started right after the save no longer waits behind it. `LibraryModel.previewRevision` is now kept on `PreviewRevision.shared`, which only Grid, Filmstrip, Loupe and the Info panel watch; before, each bump (one per saved edit) updated every view under the window's `LibraryModel`, Develop panels included. The catalog save itself (settings and history JSON plus the SQLite write) stays on main for now, because several features read the open photo's settings back from the catalog right after it (Copy Settings, Match Look, Edit In, export); the timing log now records `saved: N ms on main, K history steps`, and it moves off main behind a pending-save layer only if that number shows up in Codex's run. Not compiled in the cloud.

**D4 (commit 5):** A zoomed drag no longer races full-size renders. Before, every live frame's finish started a 24 MP full-size render on its own queue, competing with the drag's proxy renders on the GPU, for settings that were never shown (the zoomed photo shows the full-size image only once it matches the current settings). Now live frames skip it and the settled render 0.12 s after the drag rests starts it, as before for keyboard nudges, presets and clicks. While dragging zoomed, the photo shows the proxy as it already did. Not done, proposed as follow-ups if Codex's 100% numbers still trail Fit: a sharp draft of only the visible area during the drag (needs a positioned sublayer for the frame), and a GPU histogram in place of the per-frame readback. Expected: 100% Contrast frames per drag close to Fit, and the 109–228 ms worst gaps gone. Not compiled in the cloud.

## AT-040 — Develop: smooth edits in Before/After compare views; histogram drawn in one pass

**Status:** Merged at Rosh's ask on Nov 10, 2026 after Rosh built and ran it in Xcode (compare views and histogram smooth). XCTest/`check_pr.py` not run (CI billing-blocked; no Codex check). **Owner:** Claude. **Chat:** Claude project thread "Fix Before/After and improve histogram". **Branch:** `claude/project-thread-ubr8f6`. **PR:** [#98](https://github.com/roshan-davis/atelier/pull/98). **Baseline:** `301015d` (AT-039 merged). **Dependencies:** AT-039.

**Evidence:** Rosh (2026-11-10, after #97): with the photo in a Before/After compare view (side by side or the split slider), changing values freezes the photo; the histogram also seems to freeze, with its colors drawing one after another. Source review at `301015d`: `PhotoFeed` attached only to the single-photo and Masking views, so in a compare view every frame took the old path (CPU readback, `image` published on main, a SwiftUI update of the whole window and both photo panes), and each frame's finish also started full-size renders when zoomed (AT-039 D4 applied to live frames only). The histogram was three translucent `plusLighter` fills redrawn by a SwiftUI `Canvas` on the main thread at every render.

**Scope:** (1) The After photo of both compare views takes live frames (`feed: develop.photoFeed` on the After `ComparePane` and the `SliderCompareView`'s After view); the Before photo stays the ordinary image. D4's "no full-size renders mid-drag" follows automatically. Frame Diagnostics shows in compare views too. (2) `HistogramPicture` (Core, tested) draws red, green and blue in one pass into one image, additive where they overlap (Lightroom's yellow/cyan/magenta/gray), from 128 bins (was 64) with a 1-2-1 blur and smooth steps between bins, antialiased top edge. Develop makes it on the measure queue beside the counting (`DevelopMeasures.histogramPicture`); the Library histogram makes it once per photo. `HistogramGraph` shows that image and is `Equatable`, so panel redraws skip it. Help's drawn histogram uses the same drawing.

**Follow-up (Rosh, same day, after building `9e7ec4d`):** the compare-view freeze is fixed; the histogram still felt sticky. The picture was made off main but still reached the screen through a SwiftUI publish on the busy main thread. Now the measure queue puts it on the graph's own layer itself (`HistogramSink`, `HistogramLayerView`, the D1 pattern), dropping pictures from an older render or an earlier open; `DevelopMeasures.histogramPicture` is gone. The counts (clipping triangles, Tone Curve backdrops, wheels' scope) reach SwiftUI at most every 0.1 s during a drag, the newest at its end and a photo's first count at once, which also takes one SwiftUI update per frame off the main thread.

**Not in scope:** crop, Guided Upright and the AI brush still take the ordinary path (shape changes / their own views). The Before photo isn't re-rendered during a drag (it doesn't change, except for Lens Corrections / Transform edits, unchanged). A GPU histogram (no per-frame 256 px readback) stays an AT-039 D4 follow-up.

**Acceptance:** Mac build and tests (`HistogramPictureTests`; `DevelopTests.testHistogramOfGrayImage` with 128 bins). Frame Diagnostics in Side by Side and the split slider at Fit and zoomed: frames per drag close to the single-photo view, no CG fallbacks. Rosh: no freeze editing in either compare view; the divider and panning still work; the After side updates live under the Before side of the split; the histogram updates smoothly with the Lightroom-style colors; no change to how photos look (no `PreviewCache.version` bump).

**Validation:** Cloud only, no Swift toolchain: source review; the histogram drawing ported to Python and checked on a real photo; Help page checked in Chromium.

## AT-041 — Build: `build_macos_app.py` works with the Command Line Tools toolchain

**Status:** PR open, never compiled (cloud has no Swift toolchain); needs Rosh's or a Mac agent's build. **Owner:** Claude. **Chat:** Claude project thread "Fix command-line release build". **Branch:** `claude/project-thread-3a1y7r`. **Baseline:** main after AT-040.

**Evidence:** Rosh (2026-11-10): `python3 Scripts/build_macos_app.py` failed with `external macro implementation type 'SwiftUIMacros.EntryMacro' could not be found` at `DevelopFrameHUD.swift:272` (`@Entry`, from AT-038). `swift build` ran from `/Library/Developer/CommandLineTools`, which has no SwiftUI macro plugins; Xcode does.

**Scope:** (1) `developFrameHUD` environment value uses a hand-written `EnvironmentKey` instead of `@Entry` (the only SwiftUI macro in the app). (2) `DevelopController.previewWriteLock` is `nonisolated` so the nonisolated preview writer can use it (Swift 6 warning). (3) The build script resolves the toolchain like `check_pr.py` (keeps `DEVELOPER_DIR`, else `xcode-select`, else Xcode.app over the Command Line Tools), runs `xcrun swift build`, and prints the toolchain it used.

**Not in scope:** the other Swift 6 concurrency warnings (`EditIn.swift`, `ImportFlow.swift`, `NSEvent` monitors, `SettingsView` enumerator).

**Acceptance:** `python3 Scripts/build_macos_app.py` builds with Xcode selected and with only the Command Line Tools selected; Develop > Frame Diagnostics still shows its overlay and slider timings.

## AT-042 — Masking: Select People parts in any combination, facial features, shared Grow / Refine Edge

**Status:** Merged at Rosh's ask (2026-11-10). Rosh built and ran `428bdf0` in Xcode (new parts and sliders show); the follow-up `cc2d78e` (keep faces whose skin color can't be learned) was not built. Tests not run; Rosh's acceptance open. **Owner:** Claude. **Chat:** Claude project thread "Improve people and object selection masks". **PR:** [#100](https://github.com/roshan-davis/atelier/pull/100). **Branch:** `claude/project-thread-m96qwc`. **Baseline:** `89edcd1`. **Dependencies:** AT-033 (merged).

**Evidence:** Rosh (2026-11-10): Select People's Face/Body checkboxes force one or two parts, lips are left out, clothes are taken for body skin, and Feather is the only detail control; Select Object is weak. Analysis and model licenses: `reports/people-object-selection-2026-11-10.md` (project files).

**Scope (step 1 of 5, Vision only, no model):** part checkboxes in any combination (two columns); new parts Eyebrows, Eye Sclera, Iris and Pupil, Lips, Teeth from Vision face landmarks; Face Skin's lip cut-out tightened (1.35× to 1.1×) so Face Skin + Lips leave no gap (`PreviewCache.version` 9); Grow and Refine Edge (CIGuidedFilter with the photo as guide) beside Feather on Select Subject, Select Object and Select People, as one shared piece. Old parts decode with the new sliders at 0. A face whose skin color can't be learned (sunglasses, scarf, small face) is no longer dropped: the skin color is learned from the whole outline, or the loose skin test is used (Rosh's first test missed a woman in sunglasses).

**Next steps Rosh chose (not in this PR):** 2) Select People Hair, Clothes, Face/Body Skin from MediaPipe Multiclass Selfie Segmentation (Apache 2.0), built into the app (TFLite to Core ML conversion spike first); 3) Select Object click to add / ⌥-click to remove with SAM 2.1 Small (Apple's Core ML, Apache 2.0, 93.6 MB) as an optional download offered in the mask panel and Settings > AI; 4) Brush Auto Mask; 5) BiRefNet (MIT) Fine Edges as an optional download (no Core ML build exists; hosting for a converted file unresolved).

**Acceptance:** Mac build and `PeopleSkinTests` pass. Rosh, on real portraits: untick both skin parts without the panel refusing; Lips and Teeth (open mouth) select only the mouth; Iris and Pupil and Eye Sclera on a close portrait; Face Skin + Lips has no ring around the mouth; Grow shrinks/grows, Refine Edge pulls Select Subject's edge onto hair; an old catalog's masks look the same (apart from the small lip edge change).

**Validation:** source review only. If `CIGuidedFilter` is missing at run time, Refine Edge does nothing (no crash).

## AT-043 — Select People: skin, hair and clothes from a built-in MediaPipe model

**Status:** Merged in PR #101 (`cdf6530`) at Rosh's ask after Rosh ran `0dac016`: both people found, Clothes works. Was: PR open, never compiled (cloud has no Swift toolchain); needs a Mac build and tests (`PeoplePartsTests` runs the real model), then Rosh's acceptance. **Owner:** Claude. **Chat:** Claude project thread "Improve people and object selection masks". **Branch:** `claude/project-thread-m96qwc` (restarted from main after #100 merged). **PR:** [#101](https://github.com/roshan-davis/atelier/pull/101). **Baseline:** `464d5bf`. **Dependencies:** AT-042 (merged).

**Evidence:** Rosh (2026-11-10): Body Skin takes clothes; wants the AI model built into the app, no download (report `reports/people-object-selection-2026-11-10.md`). Step 2 of 5.

**Scope:** Google's MediaPipe Multiclass Selfie Segmentation (Apache 2.0) converted to Core ML (`Sources/AtelierCore/Models/PeopleParts.mlpackage`, 8.0 MB, fp16, softmax output) by `Scripts/models/convert_mediapipe_multiclass.py` (rebuilds the TFLite graph op by op with coremltools' MIL builder; `--check` runs the same graph in NumPy against Google's TFLite runtime: max difference 2.8e-5, identical classes on random input and a real portrait). License and change notice next to the model. `PeopleParts` loads it from AtelierCore's resource bundle, compiles it once into Caches, runs it per person on a box around their matte; Face Skin, Body Skin, Hair, Clothes and Entire Person come from it (eyes/brows/lips still cut out of Face Skin; the color method stays as the fallback). Entire Person checkbox above the parts. People also come from Vision's person outlines (up to 4) when their face isn't found at 1024 px: the head is searched again enlarged to ~640 px, else guessed from the outline's top. A line under the People checkboxes says whether the built-in model ran (orange warning with the reason on hover when it didn't load). `build_macos_app.py` copies `Atelier_AtelierCore.bundle` into both apps. `PreviewCache.version` 10.

**Acceptance:** Mac build; `PeoplePartsTests` (model found in the bundle, loads, class shares on the Help portrait within tolerance of TFLite's) and `PeopleSkinTests` pass; `python3 Scripts/build_macos_app.py` app also finds the model. Rosh: on the Louvre photo, the woman in sunglasses is found; Body Skin no longer takes beige/orange coats or scarves; Hair and Clothes select hair and clothes; Entire Person selects the whole person. Time the first Select People on a Z6 RAW.

**Not in scope:** SAM 2.1 / BiRefNet downloads (steps 3 and 5).

## AT-044 — Masking: Fine Edges (BiRefNet) for Select Subject, Select Object and Select People

**Status:** PR open, never compiled (cloud has no Swift toolchain); needs a Mac build, tests, a first run of the downloaded model, and Rosh's acceptance. **Owner:** Claude. **Chat:** Claude project thread "Improve people and object selection masks". **Branch:** `claude/project-thread-m96qwc` (restarted from main after #101 merged). **PR:** [#102](https://github.com/roshan-davis/atelier/pull/102). **Baseline:** `cdf6530`. **Dependencies:** AT-042, AT-043 (merged).

**Evidence:** Rosh (2026-11-10): asked for the model that is good at hair; chose ONNX Runtime in the app ("try that 30mb approach") over converting BiRefNet to Core ML and hosting it, since nobody publishes a Core ML BiRefNet and the repo is private. Step 5 of the plan, done before SAM (step 3).

**Scope:** `onnxruntime-swift-package-manager` 1.24.2 (MIT, static) linked into AtelierCore. `FineEdges` downloads onnx-community's `BiRefNet_lite-ONNX/onnx/model_fp16.onnx` (MIT, ~115 MB, SHA-256 `d39b897c…f402` checked before install) to Application Support/Atelier/Models, runs it at 1024 × 1024 (ImageNet mean/std, sigmoid on logits) with the Core ML execution provider (ML Program, all compute units) and CPU fallback. `DevelopRenderer` keeps the matte per lens geometry. `MaskRenderer.fineEdged` changes only a band 1.5% of the long edge around Vision's edge, with the model run on a square around the selection (see PRD). New `fineEdges` on `Selection`/`PeopleSelection` (decodes false: old edits unchanged, no `PreviewCache` bump). Fine Edges checkbox (or Get button with progress/Cancel) at the top of the shared edge controls; Settings > AI > Masking Models with Download / Remove.

**Acceptance:** Mac build (the package resolves and links on arm64 and x86_64); `FineEdgesTests` pass; the downloaded model loads and runs (no orange error under the checkbox); time the first matte on a Z6 RAW and with/without Core ML; app size before/after. Rosh: hair against sky and a busy background with Select Subject and Select People Hair/Entire Person, Fine Edges on vs off; Face Skin doesn't creep into Hair; Remove in Settings deletes it.

**Fixes in this PR (Rosh, 2026-11-10, testing 2984f9d):** Refine Edge above 0 emptied every AI selection: `CIGuidedFilter` replaced by `MaskGuidedFilter` (own Metal kernels, fast guided filter at ≤2048 px). Fine Edges showed no change: the panel now shows each run's time and foreground share, or its error (it didn't refresh before), and the log has the model's input/output names; fp16 outputs are read too.

**Model switch (Rosh, 2026-11-11):** BiRefNet lite at 1024 missed loose strands even on the selection's square (tested `ac49561`: "Fine Edges ran in 2.5 s"). Switched to BiRefNet HR-matting (MIT), Pink Pixel's fp16 ONNX export (`PinkPixel/birefnet-hr-matting-onnx` @ `792518b`, `model_fp16.onnx`, ~470 MB, SHA-256 `c0216070…70f0`; input `image` 1×3×2048×2048 float32 ImageNet-normalized, output `alpha` with sigmoid in the graph). Band widened to 3%. Old model files are deleted on install/remove. Core ML session failure falls back to CPU. Rosh's run of `e5241c8`: 32.4 s, no visible strands with Feather 20 / Refine Edge 52; Fine Edges now applies after Grow/Refine/Feather, and Core ML gets a model cache directory (compile once).

**Two models (Rosh, 2026-11-11, after testing `7e6154c` at 200%: some strands near the edge picked up, far loose strands still missed, 34.9 s CPU):** "keeping 115 and 400+ models so user can download whatever they want and select". `FineEdges.Model` (`fast` = BiRefNet lite 1024, `hairDetail` = HR-matting 2048), each downloaded/removed on its own; `FineEdges.chosen` (UserDefaults `fineEdges.model`, set by a download) and `active` (chosen if downloaded, else the other). Mask panel: Get menu with both, and a Fast / Hair Detail menu beside the checkbox when both are in; Settings > AI > Masking Models: a row per model, "Fine Edges uses", Show Last Result. One ONNX session at a time; the renderer's matte cache is keyed by the active model. Rosh's existing HR file is kept (same name). Needs a Mac build and Rosh's test.

**Known risks:** the fp16 model's inputs are assumed float32 (onnx-community's usual keep-IO-types export); if not, the error shows under the checkbox. BiRefNet may contain ops Core ML can't run; those run on the CPU (slower).

**Not in scope:** SAM 2.1 clicks (step 3), Brush Auto Mask (step 4), the full (non-lite) BiRefNet.

## AT-045 — Match Look: Rosh's eight vector color studies as the Built-in References

**Status:** Merged at Rosh's ask on Nov 10, 2026 after Rosh built and ran `e0cc209` in Xcode ("waaay better"). XCTest/`check_pr.py` not run (CI billing-blocked); Help before/after pictures still to regenerate on a Mac. **Owner:** Claude. **PR:** [#103](https://github.com/roshan-davis/atelier/pull/103). **Chat:** [Improve Match Colors quality](https://claude.ai/code/project/chan_01Y9ueFJEbKyPqWn7CWQ5SGK?thread=cmsg_01Y9ueFJEbKyPqWn7CWQ5SGKF2JPu63ZaHgkVxXXo1FmSC). **Branch:** `claude/match-look-svg-studies` (from main `e84c5fd`). **Dependencies:** AT-034, AT-035 (merged).

**Evidence:** Rosh (2026-11-10/11) shared a gallery of eight flat SVG studies ("make sure to keep it the way you keep the images, but the color reference and pattern is prominent"; "just keep your organization, but I wanted these images and its color theme while applying"; "use my 8 images to replace those crappy images").

**Scope:** The eight SVGs in `Sources/AtelierApp/Resources/Studies/<case>.svg`, one per existing `BuiltInLookReference` case (names, pairs, picker unchanged; palette lines rewritten for the new colors). Shapes of the person are marked `data-part` (skin, hair, clothes, features). `FlatSVG` (AtelierCore) reads and draws flat SVG (rect, circle, ellipse, line, polygon, polyline, path without arcs, `g` translate, inherited fill and part) and draws gray part masks. Subject & Background's person mask and Show Skin come from the parts; skin samples are fixed boxes in the shared face (verified one flat color each in all four portraits). The generated drawing code (StudyCanvas, StudyHead, StudyLight) is deleted. `LookTarget(colorStudy:)` makes a study color only: no Exposure, Tone Curve or subject Exposure, and the dialog's Tone checkbox is off and unavailable for studies.

**Fixes after Rosh's test (2026-11-11, their Paris portrait with The Matrix portrait study: "protect skin tone on the first one is not even working, and the colors produced are terrible"):** measured in the cloud (no renderer) on Rosh's photo: the study's median lightness is 0.34 against the photo's 0.51 and its subject's 0.24, so Tone pulled the photo down a full stop (the cap), the Tone Curve took the median from 40% to 22% luma, and the subject mask darkened the person further. Protect only holds skin hue and saturation, and its skin masks were capped at ±35, below the global Temp/Tint they had to undo, so the pull-back weakened the whole match. Now: studies give color only; Protect's skin masks may use their whole range (`protectSkinShift`), Match Skin Tone stays at 35.

**Acceptance:** Mac build; `FlatSVGTests` and `BuiltInLookReferenceTests` pass; the picker shows the eight drawings; each study matches a photo toward its palette without lifting blacks; Show Skin tints the drawn skin. Regenerate the Help before/after pictures with `ATELIER_BUILT_IN_LOOK_OUT` and `ATELIER_SKIN_LOOK_OUT` and `Scripts/help/make_help_images.py` (the reference pictures are updated; before/after still show the old studies' result).

**Not in scope:** part-by-part matching (hair to hair, clothes to clothes) with fast Select People parts; it follows in its own PR.

## AT-046 — New app icon (glowing film canister on navy)

**Status:** Merged at Rosh's instruction on November 11, 2026 (PR [#106](https://github.com/roshan-davis/atelier/pull/106)); not yet built or seen on a Mac (CI blocked by the Actions account block). **Owner/chat/branch:** Claude (project thread "Replace Atelier app icon"), branch `claude/project-thread-dda2z7`. **Requested:** Rosh, November 11, 2026, with the icon art attached; replaced the same day by a second design (film canister on sage) and then a third (glowing film canister and door on navy), which is the one in the PR. The third came as a flat JPEG with a drawn checkerboard, so `Scripts/icon/cut_out_flat_icon.py` cuts the shape out (the outer glow onto the checkerboard is dropped). **Dependencies:** none.

**Scope:** replace the app icon everywhere it comes from: the Dock icon set at launch from `Sources/AtelierApp/Resources/AppIcon.icns` (Xcode runs), the same `.icns` copied into Atelier.app and the HDR helper by `Scripts/build_macos_app.py` (`CFBundleIconFile`), the `AppIcon.appiconset` in `Assets.xcassets`, and the icon shown in the Remove Photos and Delete Import sheets (`NSApp.applicationIconImage`). `Scripts/icon/make_app_icon.py` rebuilds all of them from `Scripts/icon/AppIcon-source.png`; the art keeps its own rounded square (no extra mask) and is placed on Apple's 824-on-1024 px grid so it matches other Dock icons.

**Acceptance:** on Rosh's Mac, Product > Run shows the new icon in the Dock and in Remove Photos; a `build_macos_app.py` build shows it in Finder. **Deferred:** none.

## AT-047 — Match Look: skin masks cover the lips; Protect Skin Tones holds brightness

**Status:** Merged at Rosh's ask on Nov 11, 2026 after Rosh built and ran it in Xcode ("looks good"). XCTest/`check_pr.py` not run (CI billing-blocked). **Owner:** Claude. **Chat:** [Improve Match Colors quality](https://claude.ai/code/project/chan_01Y9ueFJEbKyPqWn7CWQ5SGK?thread=cmsg_01Y9ueFJEbKyPqWn7CWQ5SGKF2JPu63ZaHgkVxXXo1FmSC). **Branch:** `claude/match-look-skin-lips`. **PR:** [#107](https://github.com/roshan-davis/atelier/pull/107). **Baseline:** `2747aea`. **Dependencies:** AT-045 (merged).

**Evidence:** Rosh (2026-11-11), a smiling portrait in the rain: with Match Skin Tone or Protect Skin Tones "the lip area is weird, and the color is making pale". Source review: the skin masks used Select People's Face Skin, which leaves holes at lips, teeth, eyes and brows (AT-042), so the masks held or matched the skin while the lips kept the global look, with a hard edge (feather 0). Protect held only hue and saturation, and only past its 5°/15% limits, so a lighter, slightly greyer face was left alone.

**Scope:** Match Skin Tone's masks use Face Skin + Lips; Protect's use Face Skin, Lips, Teeth, Eyebrows, Eye Sclera, Iris. Skin is still measured on Face Skin. Protect fits each skin mask's Exposure to hold the tone's Oklab lightness and runs whenever skin drifts visibly (`LookSkin.holds`: 1.5° hue, 4% chroma, 0.015 lightness); the 5°/15% pull-back stays the fallback.

**Acceptance:** Mac build; `LookMatchTests` (holds, mask parts) and existing Match Look tests pass; Rosh: the same portrait with Protect and with Match Skin Tone, lips and skin consistent, skin not pale.

## AT-048 — Match Look: one base color over the whole face, skin tones blend seamlessly

**Status:** PR #108 was closed unmerged (no reason given); its commit is carried, rebased, as the first commit of AT-063's PR #136 (branch `claude/match-look-skin-gaps`). Never compiled. **Owner:** Claude. **Chat:** [Improve Match Colors quality](https://claude.ai/code/project/chan_01Y9ueFJEbKyPqWn7CWQ5SGK?thread=cmsg_01Y9ueFJEbKyPqWn7CWQ5SGKF2JPu63ZaHgkVxXXo1FmSC). **Branch:** `claude/match-look-face-base`. **PR:** [#108](https://github.com/roshan-davis/atelier/pull/108) (closed). **Baseline:** `b19a792`. **Dependencies:** AT-047 (merged).

**Evidence:** Rosh (2026-11-11), after AT-047: the skin masks take some shaded teeth and the eyebrow area for the color change ("we would need a base color and the matching colors on top instead of leaving something unattended"; "overlap has to be gradual and seamless instead of disjointed colors"). Source review: the masks were unions of separate parts (Face Skin minus grown feature holes, Lips, Teeth by a lightness/chroma test, Vision brow bands); shaded teeth fail the Teeth test and fall in the Face Skin hole, misplaced brows likewise, so patches were left out or in. The tone masks' Luminance Range smoothness 30 gave visible steps.

**Scope:** New Select People part **Entire Face** (face outline ×1.04 less hair/clothes/background, unioned with every feature map, Face Skin and the mouth opening, guided-filtered). Match Skin Tone and Protect masks use Entire Face, Feather 20. Skin Shadows/Highlights Luminance Range smoothness 70. Skin is still measured on Face Skin. Not in scope: neck/body skin, part-by-part hair/clothes matching (next iteration).

**Acceptance:** Mac build; `PeopleSkinTests.testEntireFaceHasNoHoles`, `LookMatchTests.testSkinMasksCoverTheEntireFace` and existing Match Look tests pass; Rosh: the same smiling portrait, no patches at teeth or brows, tone masks blend without steps.

## AT-049 — Settings: sidebar navigation, larger window

**Status:** Merged at Rosh's ask on Nov 12, 2026 after Rosh built and ran `f2e2470` in Xcode ("looks good"). XCTest/`check_pr.py` not run (CI blocked by the Actions account); layout snapshots not seen. **Owner:** Claude. **Chat:** [Redesign Settings with sidebar navigation](https://claude.ai/code/project/chan_01Y9ueFJEbKyPqWn7CWQ5SGK?thread=cmsg_01Y9ueFJEbKyPqWn7CWQ5SGK96vYtiqFFZfdV1x1AhDsuA). **Branch:** `claude/project-thread-u3fvye`. **Baseline:** `b19a792`. **Dependencies:** none.

**Evidence:** Rosh (2026-11-12): "can the settings dialog be with left navigation and the settings on right side and have bit more real estate and have bit more elegant aligns with our design system?"

**Scope:** `SettingsView` replaces the toolbar tabs with a sidebar (`SettingsPane`, grouped Atelier / Photos / Editors & AI; drawn rows with their own ↑ ↓ Home End keys, since the first build's `List` selection ignored clicks on Rosh's Mac) and a pane header (accent icon tile, title, one-line summary) over the existing panes, unchanged. Window 640 pt wide (height varied per tab) → fixed 900 × 660 pt. Round 2 (Rosh, Nov 12, 2026): colored icon tiles (accent icons vanished on dark themes) and 14 pt sidebar names; `SettingsSection` puts the main window's `SectionBand` on every Settings section (collapsible, remembered in `settings.collapsedSections`); Keyboard gets a keyboard map, key caps, group glyphs and search (`Views/KeyboardSettingsView.swift`); Edit In shows each app as its own section of standard rows (its single combined row was cut off). Appearance moves into the same grouped Form as the other panes; Keyboard drops its fixed 520 pt height. Last pane remembered (`settings.pane`); Help > Keyboard Shortcuts > Change Keys… opens the Keyboard pane. Layout snapshots `settings-window-*.png` added.

**Acceptance:** Mac build; Rosh opens Settings (⌘,), clicks every pane, checks Masking Models download/status lines in AI, key recording in Keyboard, themes in Appearance, and Change Keys… from ⌘/. **Deferred:** a search field in the sidebar (System Settings has one); not asked for.

## AT-050 — Agent Actions: MCP server for chat clients (Atelier and Easel)

**Status:** Direction approved by Rosh on Nov 13, 2026 ("add one section in the backlog for mcp … so the next PRs can pick one by one"). The design is done. Implementation is split into AT-050a to AT-050g below (plus AT-050h, docking beside Docent, and AT-050i, the photo carousel for chat apps, both added Nov 13), one PR each, taken in order. AT-050a is ready to start. **Design owner:** Claude. **Design chat:** [Design an MCP server for Atelier actions](https://claude.ai/code/project/chan_01Y9ueFJEbKyPqWn7CWQ5SGK?thread=cmsg_01Y9ueFJEbKyPqWn7CWQ5SGKLw4mNvV9wQDgMyFLnzx5sL). **Design PRs:** [#110](https://github.com/roshan-davis/atelier/pull/110) (merged `fa4239b`), [#115](https://github.com/roshan-davis/atelier/pull/115).

**Evidence:**
- Rosh (Nov 11, 2026): "Can my app setup an MCP and many of the menu function there as actions that can be conversationally execute from the chat that connect to this MCP?"
- Rosh (Nov 12): compare with tools that already do it, especially VectorCraft.
- Rosh (Nov 13): Easel must take the exact same approach.
- Rosh (Nov 13): new or removed menu commands must update the MCP lists automatically, and new features must be available by default under the rules, with no porting.
- The PRD lists the MCP server under AI, Later ("Agent access (later)").

**Design:** [Docs/Atelier-Agent-Actions.md](Docs/Atelier-Agent-Actions.md) is the reference for every sub-item. The working rules are in AGENTS.md under "Agent Actions". In short:
- The MCP server lives inside Atelier.app (one catalog writer). A bundled stdio helper, `atelier-mcp`, relays to it over a private Unix socket.
- One action registry builds the menus, keys, the right-click photo menu and the MCP catalog.
- Every action declares a kind, which sets its tier: reads run; undoable edits run as one named undo step; file writes, jobs and launching another app ask first in Atelier's window; deletes are never exposed.
- Two tool layers go through one policy check: typed front-door tools, and `command_list` / `command_run` / `command_batch` over the whole registry.
- The app grants each client a profile (Look, Organize, Edit, Everything), and profiles are ceilings.
- The plumbing is an app-neutral module that Easel reuses.
- Codex's review rules ([PR #115 comment](https://github.com/roshan-davis/atelier/pull/115#issuecomment-6842233533)) are part of the design, with the counters recorded in the doc. Rosh's exposed-by-default rule overrides Codex's review-before-expose suggestion.

**Defaults until Rosh says otherwise:**
- Remote access waits for AT-050f.
- Photo previews and location are off by default, with a switch.
- The shared module is built inside Atelier and extracted when Easel starts (AT-050g).

**Every sub-item:**
- Updates the PRD, Help (an "Agents" page from AT-050b on), this backlog entry and, if a rule changes, AGENTS.md.
- Regenerates `Docs/agent-actions-catalog.json` once it exists.
- Is checked on a Mac with `python3 Scripts/check_pr.py` at the PR head.
- Cloud agents follow AGENTS.md "Cloud review when macOS is unavailable".

### AT-050a — Action registry, kinds and catalog check (A0)

**Status:** Merged ([#116](https://github.com/roshan-davis/atelier/pull/116), c3515fd); Rosh built it on the Mac (Nov 13, 2026). **Owner:** Claude. **Chat:** [Design an MCP server for Atelier actions](https://claude.ai/code/project/chan_01Y9ueFJEbKyPqWn7CWQ5SGK?thread=cmsg_01Y9ueFJEbKyPqWn7CWQ5SGKLw4mNvV9wQDgMyFLnzx5sL). **Branch:** `claude/project-thread-eecdru`. **PR:** [#116](https://github.com/roshan-davis/atelier/pull/116). **Depends on:** nothing.

**Done so far (not yet accepted):** `Sources/AgentActions` (app-neutral: `ActionKind` → `AgentTier`, `Action<P>`/`ActionDescriptor`, schemas read from `ActionParameters` types, `ActionCatalog` with its problems check and JSON, `ActionRegistry` with resolved targets, and the menu builders `button`/`toggle`/`menuItem`); `Sources/AtelierActions` (64 actions, catalog without handlers); `LibraryModel+Actions.swift` (every handler); the menu bar, `KeyAction` keys and the photo menu now run through the registry; `Docs/agent-actions-catalog.json` and `Scripts/agent_catalog.py`. Validation: `AgentActionsTests` (Easel-shaped host) and `AtelierActionsTests` pass on Linux with Swift 6.1 (cloud). The app target, `ActionMenus.swift` and `AtelierAppTests/ActionRegistryTests` were not built in the cloud; they need a Mac `check_pr.py` run and Rosh's menu re-test.

**Left out:** panel menus that aren't commands (Filmstrip source, filter and sort menus; Tone Curve and Color Grading preset menus) keep `ClosureMenuItem`; the Help > Atelier Help item stays outside the registry because it must work before a catalog opens. Some handlers still read `targetIDs` and are run under `withTargets(ids)`, which changes nothing for menus and keys; AT-050c to e convert them as each tool is exposed.

**Scope:**
- An app-neutral Swift target (no imports from AtelierApp or Atelier's catalog types). It holds the action type: id, title, kind, a parameter type, target kinds, opt-out reason and version. It also holds the kind-to-tier rules and menu, key and context-menu builders.
- Move every command in `AtelierApp.swift` menus, `KeyBindings`/`KeyAction` and `PhotoMenu.swift` onto registry actions whose handlers take resolved ids. Keep `KeyBindings` as the key layer that maps to action ids.
- Generate parameter schemas from the Swift parameter types.
- A script writes `Docs/agent-actions-catalog.json`, and `check_pr.py` fails when it is stale.
- A tiny in-memory test host with Easel-shaped targets (documents, layers).

**Not in scope:** no MCP server, socket, helper or Settings pane; no visible change.

**Acceptance:**
- Menus, keys and right-click items behave exactly as before. Rosh re-tests the menus he uses most, with click paths given in the PR.
- Tests fail if a menu item has no action, an action has no kind, or two actions share an id.
- The shared target builds without Atelier.
- Catalog file committed.
- A0 size and risky commands (view-state toggles, tool modes) listed in the PR.

### AT-050b — Read-only MCP, client grants and Settings > Agents (A1)

**Status:** Merged ([#118](https://github.com/roshan-davis/atelier/pull/118), `9388131`, Nov 13, 2026) at Rosh's ask, after Rosh built it in Xcode and connected OpenCode and Cherry Studio (Gemma 4): both listed the tools, answered library questions and called `get_preview` (Cherry Studio shows the images as "Image blocked", its own limit). Claude Desktop, Codex, ollmcp and LM Studio not yet tried; `check_pr.py` not run. **Owner:** Claude. **Chat:** [Design an MCP server for Atelier actions](https://claude.ai/code/project/chan_01Y9ueFJEbKyPqWn7CWQ5SGK?thread=cmsg_01Y9ueFJEbKyPqWn7CWQ5SGKLw4mNvV9wQDgMyFLnzx5sL). **Branch:** `claude/project-thread-eecdru`. **PR:** [#118](https://github.com/roshan-davis/atelier/pull/118). **Depends on:** AT-050a (merged, #116).

**Done so far (not yet accepted):** `Sources/AgentMCP` (app-neutral: JSON-RPC sessions for 2025-06-18, 2025-03-26 and 2024-11-05; the private socket server that names each peer from its process tree and code signature and never takes over a live socket; the helper relay with the "Atelier isn't running" answer; profiles, grants with "asking for more never raises it", the grant store and the activity log; `command_list` from the registry). `Sources/AtelierMCPHelper` (the `atelier-mcp` product, copied into Contents/MacOS by `Scripts/build_macos_app.py`). App: `Agents/AgentServer.swift` (host, approval questions, get_context and the window's lists), `Agents/AgentLookTools.swift` (search_photos, get_photo, get_preview, list_items, cull_groups, get_develop; private photos never shown), `Agents/AgentApproval.swift`, `Views/AgentsSettings.swift` (Settings > Agents). PRD and Help (Settings > Agents) updated. Validation: `AgentMCPTests` (36 tests with the AT-050a ones: sessions, denial and revocation, the socket end to end through the relay, disconnect and stop, a second server, grants) pass on Linux with Swift 6.1 (cloud). The app files were not built in the cloud.

**Left out:** the 2026-07-28 response shapes (clients that ask for it are answered with 2025-06-18, which the spec allows); the Allow question's half-second hardening (chat apps can't click Atelier's window in this version); `chat-apps.html` (PR #117) still says "coming soon" until both land.

**Scope:**
- The MCP server (2025-06-18 protocol, plus 2026-07-28 response shapes when a client asks for them), the `atelier-mcp` helper in the app bundle and the private socket.
- First-connect approval in Atelier: grants per client, identified by the launching app's code signature (Terminal clients are per launcher). Grants are checked on every request.
- Look tools (`get_context`, `search_photos`, `get_photo`, `get_preview` off by default, `list_items`, `cull_groups`, `get_develop`) and a profile-filtered `command_list`.
- Settings > Agents: on/off (closes connections), grants, preview and location switches, Copy config for Claude Desktop, Claude Code, Codex and ollmcp, and the activity log.
- The PRD: move the MCP server out of Later, and add the Privacy and Sandboxing lines.

**Acceptance:**
- Claude Desktop, Codex, OpenCode (with a free model; Rosh wants to try this first), Cherry Studio and one Ollama client (ollmcp) each connect after Rosh's Allow, list tools and answer a catalog question. The PR records the protocol version each one used.
- Nothing writes to the catalog.
- Changing helper arguments can't raise a grant. Turning access off drops connections.
- Help "Agents" page with the setup steps from the design doc's "Connect a chat app" (OpenCode, Cherry Studio, ollmcp, LM Studio, Open WebUI, Claude Desktop, Claude Code, Codex), re-checked against each app.

### AT-050c — Organize: library and cull writes (A2)

**Status:** Merged at Rosh's ask on Nov 13, 2026 (`dd2381f`) before a Mac build; a Mac build, `check_pr.py` and Rosh's acceptance are still open. Started Nov 13, 2026 at Rosh's ask ("continue to pick up next mcp work here for atelier"). **Owner:** Claude. **Chat:** [Design an MCP server for Atelier actions](https://claude.ai/code/project/chan_01Y9ueFJEbKyPqWn7CWQ5SGK?thread=cmsg_01Y9ueFJEbKyPqWn7CWQ5SGKLw4mNvV9wQDgMyFLnzx5sL). **Branch:** `claude/project-thread-eecdru`. **PR:** [#121](https://github.com/roshan-davis/atelier/pull/121). **Depends on:** AT-050b (merged, #118).

**Done so far (not yet accepted):** shared, in `Sources/AgentMCP`: `ParameterCheck` (checks an agent's parameters against the generated schema, with "did you mean" for names and choices), `AgentChangeLog` (each change's states before and after; undo only while it is still the latest on its items, by owner or by the person), `CommandRunTool` (exists, exposed, profile, this version's ceiling, parameters). `Sources/AtelierActions/AtelierAgentTools.swift`: the typed tools' parameter types and schemas, and `editProfile` (Photo > Reset All Settings and Match Look now need Edit, as Develop changes). AtelierCore `Catalog+LibraryState.swift`: library state snapshot and one-transaction restore, set or clear a color label, remove keywords, set title or caption alone. App: `Agents/AgentOrganizeTools.swift` (the tools, the guard, the confirmation), `Views/AgentNoticeView.swift` (the notice with Undo), Settings > Agents' "Ask before one change touches more than" (50). Validation: on Linux (Swift 6.1, cloud) the shared and catalog targets build and 57 tests pass (`AgentChangeTests`, `ParameterCheckTests`, `CommandRunToolTests`, `AtelierAgentToolsTests` among them, including "both layers agree" for every catalog action). The app target and `AtelierCoreTests.testLibraryStatesSnapshotAndRestore` were not built in the cloud.

**Left out:** `stack` (the design table lists it; Atelier's stacks are made by Edit In and AI, not by a command); ⌘Z for agent changes (library edits have no ⌘Z in Atelier yet, for the person either; the notice's Undo and `undo_change` cover agents); undoing virtual copies (that would delete photos); waiting for a slider drag (AT-050d, with Develop edits).

**Scope:**
- Typed `show`, `set_metadata` and `organize`, plus `command_run` for exposed library and cull commands.
- The guard: one named undo step per call ("Rate 3 stars (Claude)"), an Undo toast, and "ask before more than N photos" counted across a whole batch.
- Catalog-bound ids. Implicit targets are resolved once and echoed.
- "Did you mean" parameter errors.
- `undo_change`, which works only while the agent's change is the latest on those photos.

**Acceptance:**
- Multi-photo and RAW+JPEG pair edits undo in one step.
- A photo removed mid-call returns "target changed".
- A later manual edit blocks `undo_change`.
- Both tool layers agree on every exposed action.

### AT-050d — Edit: Develop, presets, masks, Match Look and batches (A3)

**Status:** In progress: first part merged (#123), second part in review (below), `command_batch` split out as AT-050j. Rosh asked for it on Nov 13, 2026 ("can you continue on the mcp work here - wanted to see develop works"). Source and Linux tests only; needs a Mac build, `check_pr.py` and Rosh's test. **Owner:** Claude. **Chat:** [Design an MCP server for Atelier actions](https://claude.ai/code/project/chan_01Y9ueFJEbKyPqWn7CWQ5SGK?thread=cmsg_01Y9ueFJEbKyPqWn7CWQ5SGKLw4mNvV9wQDgMyFLnzx5sL). **Branch:** `claude/project-thread-eecdru`. **PR:** [#123](https://github.com/roshan-davis/atelier/pull/123). **Baseline:** `80ee453`. **Depends on:** AT-050c (merged).

**Built in the first part:**
- Typed `adjust` (Basic sliders by name plus any slider in `other`, `mode` set or add, clamped at the slider's ends, panels turned on as by hand), `apply_preset` (id or name, did-you-mean), `sync` (from one photo, by part; Lightroom's default parts) and `reset` (all or by part), for the Edit profile.
- `command_run` reaches Develop commands (ceiling raised to Edit); Develop-menu commands act on the photo open in Develop.
- Each call is one Develop history step per photo, named "<change> (<app>)"; `undo_change` and the notice's Undo restore the settings as an "Undo …" step only while nothing changed them since (`PhotoState` in the change log).
- Agent Develop edits wait up to 10 s for a drag in progress (`DevelopController.isEditingByHand`).

**Second part, in review (Nov 13, 2026):** Rosh asked for the next MCP item in parallel with batching ("Also have another next item for the mcp in parallel"); `command_batch` is split out as AT-050j (its own thread). **Owner:** Claude. **Chat:** [Add typed Edit tools to Atelier MCP](https://claude.ai/code/project/chan_01Y9ueFJEbKyPqWn7CWQ5SGK?thread=cmsg_01Y9ueFJEbKyPqWn7CWQ5SGK9uaaukxpZa2VDAXzk8k6dd). **Branch:** `claude/project-thread-p4fuug`. **PR:** [#126](https://github.com/roshan-davis/atelier/pull/126). **Baseline:** `0fd59e6`.
- Typed `crop` (reset, rotate, flip, straighten, aspect with orientation, or a box; the crop tool's own steps, kept on the photo), `add_mask` (Select Subject, Object, People, Linear, Radial, Luminance Range as a new mask with its sliders, or added, subtracted or intersected into a mask by name; agent positions are the shown, cropped photo's, mapped with `MaskSpace`), `auto` (Basic > Auto and Auto White Balance at the Auto button's proxy size) and `match_look` (catalog photo or built-in study; the dialog's options, Same settings or Match each photo, sharing the dialog's target and fit code).
- `auto` and `match_look` measure off the main thread with progress and Cancel in the status bar, one job at a time, then write through the guard; photos changed meanwhile are skipped and named.
- Other photos' preview refreshes (`DevelopController.refreshPreviews`, used by agent edits, Paste, presets and Match each photo) run two at a time and skip a look that a newer save superseded; before, each was its own global-queue block.
- The timed render check is `AgentEditToolsTests` (AtelierAppTests): 40 agent edits on the open photo of a 24 MP JPEG and 3 rounds on 8 other photos, printing `AGENT-RENDER-CHECK` lines with the numbers; it asserts no more renders than the burst had time for and settling within about two renders. Numbers need a Mac run.
- Validation so far: 90 Linux tests pass (Swift 6.1, cloud; `AgentActions`, `AgentMCP`, `AtelierActions`, including the new `AtelierEditToolsTests`). The app target and `AgentEditToolsTests` were not compiled or run in the cloud: they need a Mac build, `check_pr.py` and Rosh's test.
- Left out: Brush masks (manual by design), Select Sky (Atelier has none), arbitrary image files as Match Look references (agents name a catalog photo or a study), Match Areas boxes, Fine Edges on agent masks. `auto` and `match_look` can't be steps of `command_batch` (they measure first).

**Still to do in AT-050d:** nothing; `command_batch` with `atomic` is AT-050j ([#125](https://github.com/roshan-davis/atelier/pull/125)).

**Scope:**
- Typed `adjust`, `auto`, `apply_preset`, `sync`, `reset`, `crop`, `add_mask` (Brush stays manual) and `match_look`.
- `command_batch` (now AT-050j), with `atomic: true` allowed only for catalog and Develop changes that roll back in one transaction.
- Agent edits wait for an active slider drag to end, then recheck targets.
- Develop history names carry the client.

**Acceptance:**
- Renders stay coalesced during agent edits (timed, numbers in the PR).
- An atomic batch is one undo step and rolls back fully on failure.
- A non-atomic batch reports each step.

### AT-050j — Batches: command_batch, all or nothing with one Undo

**Status:** In progress. Rosh asked for it on Nov 13, 2026 ("how about batching things and its commands? … If atelier don't have it in the backlog then add it and start working"); it was AT-050d's `command_batch` item, split out so the rest of AT-050d runs in parallel. **Owner:** Claude. **Chat:** [Design an MCP server for Atelier actions](https://claude.ai/code/project/chan_01Y9ueFJEbKyPqWn7CWQ5SGK?thread=cmsg_01Y9ueFJEbKyPqWn7CWQ5SGKLw4mNvV9wQDgMyFLnzx5sL). **Branch:** `claude/project-thread-eecdru`. **PR:** [#125](https://github.com/roshan-davis/atelier/pull/125). **Baseline:** `0fd59e6`. **Depends on:** AT-050c, AT-050d's first part (merged).

**Scope:**
- Shared `command_batch` in `AgentMCP` (`CommandBatchTool`: steps as write tools or `command_run` shorthand, `atomic`, `label`, `keep_going`, at most 50 steps, no nesting), so Easel gets the same tool with AT-050g.
- Atelier: which tools a batch takes per profile and which steps can be atomic (`AtelierActions/AtelierBatchTool.swift`); running it (`Agents/AgentBatch.swift`): without `atomic`, each step its own change; with it, one change in the change log (`PhotoState` now holds library fields, Develop settings or both), one notice and Undo, Develop steps held by `DevelopController.beginStaging` and saved as one history step per photo, library steps put back on failure, asking counted across the batch.

**Acceptance:**
- An atomic batch of `set_metadata` + `adjust` on 3 photos: one notice with Undo; History shows one step "<label> (<app>)" per photo; Undo (or `undo_change`) puts back both rating and sliders.
- A failing step in an atomic batch (an unknown id in step 2) leaves ratings and sliders as they were, and the reply names step 2.
- A non-atomic batch reports each step and stops at the first failure (or continues with `keep_going`).
- A batch over the ask limit asks once.

**Validation so far:** Linux (Swift 6.1, cloud): 88 tests pass, including `CommandBatchTests` (shared, Easel-shaped tools) and `AtelierBatchToolTests`. The app target was not built in the cloud.

**Left out:** reads inside a batch; Develop menu commands and virtual copies in atomic batches (they can't be put back with the rest); export and other apps in batches (AT-050e).

### AT-050i — Photo carousel for chat apps (MCP App)

**Status:** In review: approved by Rosh on Nov 13, 2026 ("do the photo carosel and edit commands"), after AT-050d's first part. Source, Linux tests and a browser check with a pretend host; needs a Mac build and a try in Docent once Docent shows MCP Apps views. **Owner:** Claude. **Chat:** [Design an MCP server for Atelier actions](https://claude.ai/code/project/chan_01Y9ueFJEbKyPqWn7CWQ5SGK?thread=cmsg_01Y9ueFJEbKyPqWn7CWQ5SGKLw4mNvV9wQDgMyFLnzx5sL). **Branch:** `claude/project-thread-eecdru`. **PR:** [#124](https://github.com/roshan-davis/atelier/pull/124). **Baseline:** `11e5783`. **Depends on:** AT-050b (Look tools); Docent's MCP Apps host for the full view.

**Evidence:** The Docent proposal (Nov 12–13) planned `ui://atelier/photos` after the read-only server so search results show as photos in Docent; it was missing from AT-050a–h. Rosh (Nov 13): "something missing in the priority order in mcp", then confirmed the carousel.

**Scope:**
- An MCP App resource (`ui://atelier/photos`, the MCP Apps extension) that shows `search_photos` and `show` results as a carousel of thumbnails with rating, flag and label, linked from those tools' results.
- Thumbnails from Atelier's previews, private photos never included, previews obeying Settings > Agents > Let agents see photo previews.
- Clients without MCP Apps get the same results as today.

**Acceptance:** in Docent, a search shows a carousel of the found photos; Cherry Studio and OpenCode still get the plain result.

**Done so far (not yet accepted):** Shared `AgentMCP`: `MCPApps` (client detection from `initialize`), `MCPToolUI` (`_meta.ui.resourceUri` and `visibility`, plus the older flat `ui/resourceUri` key), `MCPResource` and `MCPResourceHost` (`resources/list`, `resources/read`); sessions hide view links, views and view-only tools from clients that don't declare MCP Apps. Atelier: `AtelierActions/AtelierPhotoCarousel.swift` (the view's HTML, inline, and `get_thumbnails`), `search_photos` and `cull_groups` linked to it, `get_thumbnails` in `AgentLookTools` (320 px, previews setting, private photos left out). The view uses `show` rather than a new tool. Validation: 80 Linux tests pass (Swift 6.1, cloud), including `MCPAppsTests` (Easel-shaped host) and `AtelierPhotoCarouselTests`; the view was run in Chromium inside a sandboxed iframe with a pretend host, light and dark, with thumbnails, Show, and previews off: no console errors. The app target was not built in the cloud.

**Left out:** a bigger single-photo view (Docent can open get_preview); showing the carousel for `get_context`'s selection.

### AT-050e — Everything: export, Edit In and AI recipes with Allow (A4)

**Status:** Approved, waits for AT-050d. **Owner/chat/branch/PR:** unassigned. **Depends on:** AT-050d; AT-022 export presets; the Processor host (AT-021) for AI recipes.

**Scope:**
- Typed `export`, `edit_in` and `run_recipe` (Upscale, Replace Background; Remove Object opens the tool), plus `command_run` for exposed "asks first" commands.
- An Allow sheet bound to the exact operation (client, photos, preset or recipe, destination, options), with a fresh Allow for any change.
- Folder roots for writes. Destination, overwrite and license gate rechecked at run time.
- Jobs with progress, Cancel and a list of files written so far.
- None of these may be in an atomic batch.
- **"This app asks for me" (Rosh, Nov 13, 2026, Docent project thread):** a switch on a client's grant in Settings > Agents, offered only for a client whose code signature is Rosh's own Docent. With it on, Atelier skips its Allow sheet and takes the approval Docent's own card got from Rosh: Docent sends the exact operation it showed (photos, preset or recipe, destination, options), and Atelier runs only that operation, rechecking folders, overwrite and the license gate as usual. Other clients (OpenCode, ollmcp, Cherry Studio, Claude Desktop) always get the sheet. Profiles still cap what Docent may call, edits keep their toast and named undo step, and deletes stay never. Docent's side: [Docent PRD, Approvals](https://github.com/roshan-davis/docent/blob/main/Requirements/Docent-PRD.md#approvals). Update `Docs/Atelier-Agent-Actions.md` ("Approving an export, AI job or Edit In") in the same PR.

**Acceptance:**
- No agent tool can approve its own Allow.
- "This app asks for me" can't be turned on for a client that isn't signed as Docent, and a call whose operation differs from what Docent approved is refused.
- A changed destination or preset needs a new Allow.
- Cancel mid-export reports partial output.
- Provenance and the license gate are unchanged from the AI panel.

### AT-050f — Optional reach: HTTP over Tailscale, App Intents, prompts (A5)

**Status:** Proposed / discuss (Rosh decides remote access). **Owner/chat/branch/PR:** unassigned. **Depends on:** AT-050e.

**Scope candidates:**
- A Streamable HTTP listener (off by default, loopback or tailnet, token), with request keys so retries don't run twice.
- App Intents for Shortcuts from the same registry.
- MCP prompts ("Cull this import", "Export the picks for the website", "Match these to a reference").
- A claude.ai connector would need public HTTPS with OAuth and is not planned.

### AT-050g — Easel adopts the shared module

**Status:** Proposed / discuss (timing is Rosh's call). **Owner/chat/branch/PR:** unassigned. **Depends on:** AT-050b at least.

**Scope:**
- Move the app-neutral target into its own Swift package, which both apps depend on.
- Easel supplies its own actions, targets, typed tools, `easel-mcp` helper and Allow presentation, under the same tool names, profiles, tiers and catalog check.
- Easel's AGENTS.md gets the same "Agent Actions" rules (Easel's repo, not this one).

**Acceptance:** one client config pattern works for both apps; Atelier unchanged after the extraction.

### AT-050h — Docking protocol: Atelier docks beside Docent

**Status:** Merged at Rosh's ask on Nov 13, 2026 (`80ee453`) before a Mac build; a Mac build and acceptance with Docent's DO-007 are still open. Rosh asked for it on Nov 13, 2026 ("can you take up the work of docking backlog item that docent added next?"). **Owner:** Claude. **Chat:** [Design an MCP server for Atelier actions](https://claude.ai/code/project/chan_01Y9ueFJEbKyPqWn7CWQ5SGK?thread=cmsg_01Y9ueFJEbKyPqWn7CWQ5SGKLw4mNvV9wQDgMyFLnzx5sL). **Branch:** `claude/project-thread-eecdru`. **PR:** [#122](https://github.com/roshan-davis/atelier/pull/122). **Baseline:** `dd2381f`. **Depends on:** AT-050b (the MCP connection it rides on). **Docent side:** [Docent PRD, Docking](https://github.com/roshan-davis/docent/blob/main/Requirements/Docent-PRD.md#docking) ([docent#2](https://github.com/roshan-davis/docent/pull/2)), Docent's DO-007.

**Evidence:** Rosh (Nov 13, 2026, Docent project thread): Docent "can stay on the left side and the other apps which is selected from the mcp list in the chat aligns correctly on the right", through "some docking protocol with our apps"; "add it to atelier only, easel don't have any mcp work yet".

**Scope:**
- In the app-neutral `Sources/AgentMCP`: advertise `capabilities.experimental.docking` (with a version) in the `initialize` result, and handle the client-only requests `docking/dock` (a frame: screen, x, y, width, height in points; answers with the frame taken, or refuses below the minimum width and names it), `docking/update` (a new frame while Docent moves or resizes) and `docking/undock`. Send the notifications `docking/moved` (Rosh dragged the window away), `docking/closed` (the window closed or Atelier quit) and `docking/minWidth`.
- These are JSON-RPC methods outside `tools/list`: not registry actions, never in the MCP catalog or `command_list`, so no model can call them. This keeps "No driving the window" for agents.
- Only a granted client can dock (any profile, Look included); revoking the grant undocks.
- Atelier's side: place the main window at the frame, beside Docent; while docked, keep the photo and collapse side panels first when the width is narrow; restore Atelier's own size, place and panels on undock.
- Tests in `AgentMCPTests` with the Easel-shaped host: the capability, the requests, refusal below the minimum width, and no docking method showing in `tools/list`.

**Left out:** Easel (it has no MCP work yet; it gets the protocol with AT-050g). Accessibility-based docking for other apps (Docent's own later item).

**Built (protocol version 1; reference in [Docs/Atelier-Agent-Actions.md](Docs/Atelier-Agent-Actions.md#docking-beside-a-chat-app)):**
- `Sources/AgentMCP/Docking.swift`: `DockingCoordinator` (one holder per window, newest dock wins and the previous holder is told, refusal below the minimum width with `data.minWidth`), `DockingWindows` (what an app supplies), `MCPChannel` (notifications back down the connection), `MCPDockingHost`. `MCPSession` advertises the capability and routes `docking/*` after the grant check; the socket server writes replies and notifications one whole line at a time and lets go of a closed connection's docks.
- Frames are AppKit global coordinates in points. `docking/undock` takes `restore` (default false: the window stays, as the Docent PRD's request says; true: Atelier's own size and place come back).
- Atelier: `Agents/AgentDocking.swift` places the main window, never takes the keyboard from the chat app, and treats only a drag or resize by hand as moved. `DockLayout` (AtelierCore) collapses the left panel, then the right, and brings them back once they fit. Settings > Agents shows the docked app with Undock. Quitting sends `docking/closed` (`quit`).
- Tests: `DockingTests` (9) and a socket test in `MCPSocketTests` with the Easel-shaped host; `DockLayoutTests` in AtelierCoreTests. All pass on Linux (Swift 6.1); the app target is not built in the cloud.

**Acceptance:** with Docent's DO-007 on a Mac, switching Atelier on in a Docent chat docks Atelier's window on Docent's right; moving or resizing Docent keeps it aligned; dragging Atelier away undocks; undocking restores Atelier's layout.

## AT-051 — Menus: no New Window, no window tabs

**Status:** Merged at Rosh's ask on Nov 12, 2026 ([PR #111](https://github.com/roshan-davis/atelier/pull/111)) before a Mac build; source-reviewed only, CI blocked by the Actions account. Rosh's menu check (Acceptance) still open. **Owner:** Claude. **Chat:** [Clean up irrelevant app menu items](https://claude.ai/code/project/chan_01Y9ueFJEbKyPqWn7CWQ5SGK?thread=cmsg_01Y9ueFJEbKyPqWn7CWQ5SGK8yLyZp2y8uhxZfgWkUGoe1). **Branch:** `claude/project-thread-74eiwt`. **Baseline:** `fa4239b`. **Dependencies:** none.

**Evidence:** Rosh (2026-11-12): "Please review the menus and see if there are any items are not relevant or not implemented? e.g. Writing tools? What is Show tab bar and its usecase". Source audit of `AtelierApp.swift` and `AtelierHDRApp.swift`: every Atelier-defined menu item calls a real action; the stray items come from SwiftUI's `WindowGroup` (File > New Window opens a second window on the same `LibraryModel`, whose key monitor and `mainWindow` assume one window) and AppKit's automatic window tabbing.

**Scope:** `CommandGroup(replacing: .newItem) {}` in Atelier (the HDR editor already replaces it); `NSWindow.allowsAutomaticWindowTabbing = false` in both apps' `applicationWillFinishLaunching`. Kept: Writing Tools, AutoFill, Start Dictation, Emoji & Symbols (useful in text fields), Enter Full Screen, window tiling, View > Hide Sidebar / Toolbar.

**Acceptance:** Mac build; Rosh checks File (no New Window, ⌘N does nothing), View (no Show Tab Bar / Show All Tabs), Window (no Merge All Windows / Move Tab to New Window / tab switching), in Atelier and the HDR editor. **Deferred:** none.

## AT-052 — HDR as a view of Atelier (fold the standalone HDR app in)

**Status:** In progress — implementation pushed for review; needs a Mac build and Rosh's acceptance. **Owner:** Claude (Cl). **Chat:** [Make HDR a mode inside Atelier](https://claude.ai/code/project/chan_01Y9ueFJEbKyPqWn7CWQ5SGK?thread=cmsg_01Y9ueFJEbKyPqWn7CWQ5SGKFjburLm27Q2zKojcL87QQR). **Branch:** `claude/project-thread-pusioe`. **PR:** [#112](https://github.com/roshan-davis/atelier/pull/112). **Baseline:** `9e1a9b5`.

**Evidence:** Rosh (2026-11-12): "i have been thinking the HDR as a separate app was a poor choice, can we make that into atelier as a separate module?" Plan posted in the chat; Rosh chose "Yes, but keep a Save button" (no auto-save; leaving with unsaved changes asks). This reverses AT-021's standalone-app direction; PRD AT-021 section updated.

**Scope:** HDR opens in the library window like Develop but only from Photo > HDR… ⌃H and right-click Edit in HDR (Rosh, Nov 12, 2026: not a toolbar view or Library menu item; "people don't do that much HDR anymore"), using Develop's shared photo view, zoom, Before/After, panel headers, sliders, keys and Filmstrip. Save HDR (⌘S in HDR only) / Save HDR As New… (⇧⌘S) render in the background with Cancel and register the TIFF directly through `Catalog.acceptProcessorResult` (no job files, receipts, polling or second process). Save / Cancel / Don't Save before another photo, another view or quitting. Removed: the AtelierHDRApp target and scheme, its helper app in `build_macos_app.py`, `ProcessorDesktopSessions`, the `ATELIER_HDR_APP` conditionals. Kept: AtelierHDRCore, its tests, HDRQualification, `.atelierhdr` projects (old ones reopen), the Core processor result checks. Old receipts in ProcessorJobs are imported once at launch and the folder renamed `ProcessorJobs (old HDR app)`. HDR slider smoothness (Rosh, same day: "make all the sliders as much smooth as possible"): the tone mapper keeps its exposure-dependent analysis between renders (only Exposure recomputes it) and runs its per-pixel and blur passes on all cores, with identical output; preview packing no longer appends pixel by pixel. Second round (Rosh, same day: Shadows and Highlights "seems to be having NO effect", photo "still bit laggy"): live slider frames drawn on the GPU straight into the photo view (`HDRPreviewRenderer`, `HDRLiveFrames`); Rosh chose Lightroom-style Highlights and Shadows tone sliders in Tone Mapping, replacing the Artifacts protection sliders (protection kept built in). Third round: a Done button beside Save, and Done/Esc return to the view HDR was opened from (Esc used to always go to Grid).

**Acceptance:** Mac build of the exact head (`Scripts/check_pr.py`), new layout snapshots `hdr-1280x800` and `hdr-slider-1000x584` reviewed, then Rosh: open a RAW in HDR, compare/zoom across Develop, Save, re-edit from the TIFF, Save As New, the unsaved-changes prompt on photo/view change and ⌘Q, Esc cancel, an HDR TIFF made by the old app reopening. Not changed: HDR look/engine (AT-021b acceptance still open), brackets (AT-021).

## AT-053 — HDR: presets with thumbnails, Color, Fusion method and an Exposures strip (single photo)

**Status:** In progress — implementation pushed for review; needs a Mac build and Rosh's acceptance. **Owner:** Claude (Cl). **Chat:** [Improve HDR with bracket merging](https://claude.ai/code/project/chan_01Y9ueFJEbKyPqWn7CWQ5SGK?thread=cmsg_01Y9ueFJEbKyPqWn7CWQ5SGKEokdF8SYAc5BXTVci78c1E). **Branch:** `claude/project-thread-vd6owl`. **Baseline:** `6a9375f`.

**Evidence:** Rosh (2026-11-12) asked whether HDR opens several exposures (no: one photo only), whether HDR should show the photo at three exposures to merge them, and about parity with Machinery HDR. Claude recommended bracket merge (A) or more merge modes (C); Rosh: "I like A and C - is there a way to achieve both?" Plan: one stack-of-exposures design, this PR on single photos first, brackets next.

**Evidence, round 2:** Rosh (2026-11-12): "is that all it? look at other famous hdr tools ... Machinery HRD gives great presets on the left panels with thumbnail previews"; then chose color sliders plus toning/LUTs later ("A and B"; Claude recommended A now, toning and LUTs next, WB/curves stay in Develop). Comparison: https://claude.ai/artifact/JrRCLArua9C2XexZXSai1a.

**Scope:** HDR's left panel gets a Presets section (thumbnails of the open photo per preset, 17 built-ins in six groups, User Presets, Favorites, hover preview, click applies, + saves, right-click rename/delete; `HDRPreset`, `HDRPresetStore`, `HDRController+Presets`, `HDRPresetViews`); Tone Mapping gets a Color group (Temperature, Vibrance, Saturation; `HDRToneMapper.color`, the same in the GPU kernel). Tone Mapping gets a Method menu (Natural, Fusion) and a Spacing slider for Fusion; an Exposures strip (−Spacing, 0, +Spacing EV) shows under Spacing with Fusion only, and clicking the darker or brighter picture leaves it out of the blend (`fusionUsesDarker`/`fusionUsesBrighter`). `HDRMethod.fusion`, `HDRSettings.fusionSpacing` (decodes as 2), `HDRToneMapper.fusion`/`plate`/`exposurePlates`, the same math in the GPU preview kernel. Prototyped in numpy first; an Edge-aware method was dropped (outlines along strong edges). Help page, PRD AT-021 section updated.

**Acceptance:** Mac build of the exact head (`Scripts/check_pr.py`, incl. `HDRFusionTests`, `HDRToneMapperSpeedTests` CPU/GPU parity for Fusion), the HDR layout snapshots, then Rosh: hover and apply presets (thumbnails follow Exposure), favorites, save/rename/delete a preset, the Color sliders, switch Method on a RAW, drag Spacing and Exposure (strip follows, sliders stay smooth), undo/redo, Reset All, save and reopen a Fusion project. Not in scope: brackets (AT-054), color toning and 3D LUTs, Glow/Blacks/Whites/Smoothing, batch.

## AT-054 — HDR: merge bracketed photos

**Status:** Approved (Rosh, 2026-11-12), not started; blocked on bracket fixtures. **Owner:** Claude (Cl). **Chat:** as AT-053.

**Scope:** 2–9 selected photos + ⌃H; frames fill the Exposures strip and feed Natural/Fusion; alignment that tolerates exposure differences; Deghost None/Low/Medium/High with an overlay; project stores all sources; result stacked with the reference frame. **Dependencies:** AT-053; a real handheld and a tripod bracket (with motion) from Rosh.

## AT-055 — Develop: Tone Curve and Color Grading presets (panel Preset menus)

**Status:** Done — Rosh built and tested `a7fc3ee` in Xcode and asked to merge (2026-11-12, "this is good, merge it"). No Codex `check_pr.py` run or snapshot review recorded; CI did not run (billing). **Owner:** Claude (Cl). **Chat:** [Add Tone Curve and Color Grading presets](https://claude.ai/code/project/chan_01Y9ueFJEbKyPqWn7CWQ5SGK?thread=cmsg_01Y9ueFJEbKyPqWn7CWQ5SGK72WTFWffG4o8f2nXFkwkcG). **Branch:** `claude/project-thread-qk0le7`. **PR:** #114. **Baseline:** `c458544`.

**Evidence:** Rosh (2026-11-12) asked whether Tone Curve presets (as in Easel) and Color Grading presets based on color-harmony patterns ("Y", triangle and others) are a good idea and real, and said to go ahead. Research: reports/color-harmony-grading-2026-11-12.md (project files). Easel: Curves has a Photoshop-style Preset menu with Easel's own named curves plus Save/Load .acv (`EaselCore/Adjustments/AdjustmentPresets.swift`).

**Scope:** `SectionPresetKind` (AtelierCore, `Develop/SectionPresets.swift`): 20 Tone Curve and 18 Color Grading built-ins (bold set after Rosh's Nov 13 feedback that the first ones were "blah", tuned on fixtures with develop_sim.py) with fixed IDs, match detection, user presets in their own JSON files through `PresetStore`. `DevelopController+SectionPresets.swift` applies (one history step), saves, deletes. `SectionPresetRow` (AppKit pull-down so a highlighted item previews in the Navigator) at the top of both panels. Help (tone-curve, color-grading, presets pages), PRD, layout snapshots (`tone-curve-preset-320`, `color-grading-preset-320`; taller panel captures). No rendering change, no PreviewCache bump, no catalog change.

**Acceptance:** Mac build and tests of the exact head (`Scripts/check_pr.py`, incl. `SectionPresetTests`), the layout snapshots, then Rosh: hover presets in both menus (Navigator preview, photo unchanged), apply (one undo step, the name shows; Custom after a tweak), save/replace/delete a user preset, apply while the panel is off (turns on). Not in scope: presets for other panels, .acv import/export, preset Amount for panel presets, a harmony-rotation tool.

## AT-056 — Clicks: a single click never waits for a double-click (Cull tiles, Filmstrip, everywhere)

**Status:** Done — Rosh built and tested it in Xcode and asked to merge (2026-11-14, "tested, you can merge 127"). No Codex `check_pr.py` run recorded; CI did not run (billing). **Owner:** Claude (Cl). **Chat:** [Fix slow single click on Cull tiles](https://claude.ai/code/project/chan_01Y9ueFJEbKyPqWn7CWQ5SGK?thread=cmsg_01Y9ueFJEbKyPqWn7CWQ5SGK8Uii7hj45nyXwr6vLYGdf5). **Branch:** `claude/project-thread-14w45e`. **PR:** #127. **Baseline:** `9d62808`.

**Evidence:** Rosh relayed a report from Easel (its PR #60): Cull tiles had `.onTapGesture(count: 2)` before `.onTapGesture`, so SwiftUI held every single click for the double-click time (about 0.3 s). The Filmstrip, Develop group headings (⌥-click) and the mask name in the Masks list had the same delay.

**Scope:** shared `onClick(perform:doubleClick:)` / `onDoubleClick(perform:)` (`Views/ClickGestures.swift`, double-tap as a simultaneous gesture); every `.onTapGesture(count: 2)` in the app moved onto them except the histogram's spatial double-click (no single click there); `ClickGestureTests` fails on a new one; AGENTS.md rule; PRD Culling and Filmstrip lines.

**Acceptance:** Mac build and tests of the exact head, then Rosh: Cull tiles and Filmstrip cells respond at once to a click, double-click still keeps/drops and opens Loupe; double-click to reset slider names, group headings, Color Grading labels, Effects/HDR row names, preset Amount; double-click a mask name renames (and selects it). Not in scope: AppKit views (Grid already uses `clickCount`).

## AT-057 — Import with presets and section presets, from the UI and over MCP

**Status:** Steps 1 and 2 in review (Rosh, Nov 14, 2026: "do you wanna pick it now?"); step 3 next; step 4 later. Source and Linux tests only; needs a Mac build, `check_pr.py` and Rosh's test. **Owner:** Claude (Cl). **Chat:** [Plan field imports with presets over MCP](https://claude.ai/code/project/chan_01Y9ueFJEbKyPqWn7CWQ5SGK?thread=cmsg_01Y9ueFJEbKyPqWn7CWQ5SGKXQv1cazVRfR98PNVAP8z7A). **Branch:** `claude/project-thread-kbohj6`. **Depends on:** AT-055 (section presets), AT-050d (edit tools); step 4 on AT-050e and AT-050f.

**Evidence:** Rosh (Nov 14, 2026): "calling import with processing with presets or certain sectional presets - so while I am in the field, I can remotely do this operations through mcp. before that, from the UI there has to be able to do that and that can be part of the mcp command list." Then, on the proposal: culling keeps the other grouped photos as today ("more room to improve which is the best photo by automation"), and "listening to folder and polling can be taken out for now - all those can be through calls (either in the future phone app and mcp to desktop or a home machine)." Report: project files `reports/batch-import-presets-mcp-2026-11-14.md` (Easel's Actions and Batch, Lightroom Classic, Capture One, Photo Mechanic, Narrative, Aftershoot and others, with sources).

**Today (main at `b0c8297`):** Apply During Import takes one Develop preset and keywords. The PRD's metadata preset on import isn't built. `file.importPhotos` only opens the dialog; `apply_preset` doesn't reach Tone Curve or Color Grading presets; there are no job tools for long work.

**Steps 1 and 2, built together (branch `claude/project-thread-kbohj6`):**
- Core `ImportPreset` and `ImportPresetStore` ("Import Presets.json", lossy load, never overwrites a file it can't read); `ImportOptions.toneCurvePreset` / `colorGradingPreset`, `developSteps` and `initialDevelop()` (one history step per preset, in order); the importer records them. Tests `ImportPresetTests` (AtelierCoreTests).
- App: Apply During Import's Tone Curve and Color Grading menus (`ImportSheet`), the Import Preset menu in the footer (`Views/ImportPresetMenu.swift`, `ImportFlow+Presets.swift`), snapshot `import-section-presets.png`; Help `import.html#apply`, `#import-presets`; PRD Import flow; watch folder marked not planned.
- Agents: `apply_preset` takes `kind` (develop, tone_curve, color_grading) and finds panel presets (`PresetLookup` in AtelierActions, tests in `AtelierDevelopToolsTests`); `list_items` kind `presets` lists all three with their kind. No new action, so the catalog is unchanged.
- Left out of step 1: Auto Settings during import (needs a render of each photo; a background job after import, follow-up) and the metadata preset's creator and copyright (no catalog fields yet; follow-up with XMP and export).

**Plan (one PR each):**
1. **Import Presets (UI).** Save the Import dialog's right column as a named preset. Apply During Import becomes a fixed-order stack: Auto Settings, Develop preset, Tone Curve preset, Color Grading preset (one history step each), plus a metadata preset (creator, copyright, keywords). Culling unchanged: none, or Cull before importing. The PRD's watch folder (Import modes, 3) is marked "not planned for now" in the same PR.
2. **`apply_preset` reaches section presets,** plus `list_presets` by kind (develop, tone curve, color grading). Independent of step 1.
3. **`import_photos` over MCP as a job:** source folder, Import Preset, optional overrides (name, develop, tone curve and color grading presets, keywords); asks first in Atelier's window; returns a job id. Shared `get_job` / `cancel_job` in `AgentMCP` (Easel and AT-050e's export reuse them), and `list_import_presets`. Needs step 1.

**Later:** 4. Calls from outside the Mac with nobody at it: AT-050f's HTTP listener behind Tailscale Serve (tailnet only, never Funnel) with a token and request keys, and a standing "Agents may run this" Allow per Import Preset. That changes the AT-050 rule that file writes always ask in Atelier's window, so it is Rosh's call with AT-050f. A future phone app calls the same tools.

**Not planned (Rosh, Nov 14, 2026):** automatic Pick/Reject on import (Auto-Cull); Auto Import watch folders and polling a NAS folder.

**Easel (AT-050g):** its Actions and Batch (EA-049) become `play_action` and `run_batch`, using the same shared jobs.

**Acceptance (per step, once started):** step 1, an Import Preset with Film + a Tone Curve preset + a Color Grading preset imports a folder with one history step per preset and the metadata set; step 2, a chat app applies a Tone Curve preset by name with one undo; step 3, a chat app imports a folder with an Import Preset after Rosh's Allow, follows the job and cancels it, keeping the photos already in.

## AT-058 — Photo notes: a sticky note on each photo, with culling's reasons

**Status:** In progress. Approved by Rosh (Nov 14, 2026: "can you start on this? I merged 130") with the proposed picks: notes per virtual copy, XMP in `atelier:Notes`, Cull notes on rejected photos only. First build PR (steps 1, 2 and most of 4) open; needs a Mac build and Rosh's acceptance. Step 3 (Cull reasons, eye openness) later. **Owner:** Claude, chat [Add photo sticky notes requirement](https://claude.ai/code/project/chan_01Y9ueFJEbKyPqWn7CWQ5SGK?thread=cmsg_01Y9ueFJEbKyPqWn7CWQ5SGKWkRUXPM7xxcv1bPGTT7uWg), branch `claude/project-thread-zyfp36`, PR: see the branch's open PR. **Depends on:** nothing for steps 1 and 2; step 3 on the Cull view; step 4 on AT-050c/d (Organize and edit tools). **Step 3 (Nov 14, 2026):** Cull reason notes built with AT-059 on branch `claude/project-thread-2n3y8e` (chat [Build smarter Cull photo picking](https://claude.ai/code/project/chan_01Y9ueFJEbKyPqWn7CWQ5SGK?thread=cmsg_01Y9ueFJEbKyPqWn7CWQ5SGKBeo6kR8NWm4EtvF5wDHZjJ)); `Catalog.writeCullNotes`, "Write reasons to notes" in the Cull footer, `cull_groups` returns `cull_note`. Not compiled in the cloud; needs a Mac build and Rosh's acceptance.

**Evidence:** Rosh (Nov 14, 2026): "would it be a good idea to have a notes section hideable and showable in each image (like a sticky note section - may be that type of font too), may be i can put my notes on so far on that image (may be culling can add the rejection reasons says eyes closed on blurrier in the set etc). does any of the tools like lightroom has it?"

**Today (main at `dadb39b`):** a photo has a Title and Caption (Inspector > Title and Caption, written to XMP as `dc:title` / `dc:description`, and into exported files). There is nowhere private to write "why". Culling measures sharpness (variance of the Laplacian) and Vision face capture quality per photo (`AtelierCore/Cull/Culling.swift`) and shows them for the focused photo, but forgets them once the cull is done, so a rejected photo never says why it was rejected. Nothing measures eyes closed on its own: face capture quality mixes focus, pose and blinks.

### What other tools offer (the gap)

| Tool | Per-photo notes | Why a photo was rejected |
|---|---|---|
| Lightroom Classic | None. A per-photo notes request has been open for voting since May 2011; people misuse the IPTC Instructions, EXIF User Comment or Caption fields. | Assisted Culling (2026 early access) flags eyes closed, eye and subject focus, exposure, severe blur and misfires, with several reject reasons per photo; Adobe's page doesn't say the reason stays on the photo or reaches metadata. |
| Capture One | None; users keep a document in the session folder or use IPTC fields. | No culling reasons. |
| Photo Mechanic | IPTC fields only (Caption, Special Instructions); public, travel with the file. | No AI culling reasons. |
| Aftershoot | None. | Groups duplicates, flags closed eyes and blur by genre, with a Warning label; no written per-photo reason. |
| Excire Foto / Search | None; it writes keywords. | Sharpness, Eyes Open and Smile filters and an aesthetic score in a Culling Project; no note of why. |

So no tool has a private note per photo, and none leaves a readable, editable reason on a rejected photo. Atelier would have both.

### Requirement

**1. Notes on a photo**
- A photo has a list of notes. Each note has its text, the time it was written and, if edited, when; and who wrote it: You, Cull, or a chat app by name ("Claude"). Newest first.
- **Minimal formatting (Rosh, Nov 14, 2026: "the notes can have bullet points and minimal formatting right?"):** bullet lists, numbered lists, checkboxes, **bold**, *italic* and links; nothing else (no headings, fonts, colors, tables or pictures). A note is stored as plain text in a small Markdown subset (`- ` bullet, `1. ` numbered, `- [ ] ` / `- [x] ` checkbox, `**bold**`, `*italic*`, URLs), so XMP, search and chat apps read and write ordinary text, and a note still reads well where the formatting isn't drawn.
  - **Shown formatted, typed naturally:** the panel draws bullets, numbers, checkboxes and bold/italic, never the raw markers (as Apple Notes does). Typing `- ` or `* ` at a line's start begins a bullet, `1. ` a numbered list, `[] ` a checkbox; Return continues the list, Return on an empty item ends it; Tab and ⇧Tab indent and outdent one level (two levels at most). ⌘B and ⌘I bold and italicize the selection; Format > List (⌘⇧7 bullet, ⌘⇧L checkbox, as in Notes) does the same from the menu. Clicking a checkbox ticks it without entering edit mode.
  - **Pasting** keeps only these: bullets and numbered lists, bold, italic and links survive, everything else becomes plain text.
  - **Search** matches the words, not the markers (searching "eyes" finds "**eyes** closed"); Library's Notes filter adds "Has unticked checkboxes" for to-do notes.
  - Cull's reason notes use a bullet per reason.
- **Per virtual copy (decision proposed):** each catalog photo, virtual copies included, has its own notes, and a new virtual copy starts with a copy of the original's notes, as it does with title, caption and keywords (PRD Virtual copies). Why: a copy is a separate treatment ("B&W version for the shop, crop tighter") and the PRD already makes rating, keywords and develop independent per copy; sharing would make a note about one treatment show on all of them. A RAW+JPEG pair shown as one photo keeps its notes on the RAW, like its other edits. Stacked Edit In and AI results start with the source's notes, like title and caption.
- Notes are private: they are never written into exported files, Edit In or AI renders, or the IPTC/Dublin Core fields (Caption, Instructions, User Comment). Notes of private photos are hidden whenever private photos are.

**2. The notes panel**
- **Look:** a sticky note: pale yellow paper with a soft shadow and a folded corner, one per photo, toned down in the dark theme so it doesn't glare. Text uses Noteworthy, the handwriting-style font that ships with macOS (nothing bundled, no license), at a size that reads at a glance; Settings > Appearance > Notes Font: Handwriting (default) or System, for anyone who finds it harder to read. Times and author are in the system font, small and gray, under each note.
- **Where:** the same panel in Library (Grid and Loupe), Cull and Develop, for the selected photo (Grid, Filmstrip: the primary selection; Cull: the focused photo). It floats over the corner of the photo area as an overlay, so showing, hiding, resizing or moving it never changes the photo view's size, zoom, pan or the zoomed spot (`ZoomViewport`), nor the grid's scroll position. Drag it by its top strip to any corner; drag its edge to resize; it remembers its corner, size and shown or hidden state in one place for every view (PRD UX principle 10), and across launches with session restore.
- **Show and hide:** View > Show Notes / Hide Notes, ⌥⌘N, customizable in Settings > Keyboard; also a note button in the toolbar. Hidden, a photo with notes shows a small folded-note badge on its thumbnail (Grid, Filmstrip, Cull) and in the photo's corner, and clicking the badge shows the panel. Hiding the panel never deletes anything.
- **Writing:** Photo > Add Note… (⇧⌥⌘N; not ⌥⌘M, which is macOS Minimize All) and right-click photo > Add Note… show the panel with a new empty note focused. Click a note to edit it in place; the edit is saved as you type (no Save button). Return adds a line; ⌘Return or Esc finishes and gives the keyboard back to the photo, so P, X, arrows and the Cull keys work again (PRD Keyboard focus in Develop). While a note is being typed in, single-letter keys type, never rate or flag.
- **Selections:** with several photos selected, Add Note adds the same note to each (one note per photo, so each can be edited later), and the panel says "Adding to 12 photos". Showing notes for several photos lists only the primary photo's.
- **Delete:** a note's ⋯ menu > Delete Note, or select it and press Delete; no confirmation, `DeleteFeedback.play(.remove)`, and Edit > Undo puts it back while the panel has focus.
- **Lightroom-or-better checks:** the panel uses the shared pieces (cursors from `Cursors.swift`, clicks from `ClickGestures.swift`, actions from the registry); a single click acts at once; works the same in all four views.

**3. Culling writes its reasons**
- When a cull finishes (Done, or Import N Photos), each photo not kept gets one note by Cull with the measured reasons, compared with the keeper of its group, for example: "Not kept in a group of 6 (Similar shots). Softer than DSC_0102, the keeper (42% of its sharpness). Eyes closed." Only what was measured is written: sharpness relative to the keeper, eyes closed, face quality lower than the keeper's, "you dropped it" when the person dropped a photo Atelier suggested keeping. Kept photos get no note.
- **Eyes closed** is a new measurement: eye openness from Vision face landmarks (the eye outline's height against its width, as `PeopleSkin` already reads landmarks), per face, so a group of people can say "one face has eyes closed". Below a tested threshold it is reported; otherwise the note doesn't mention eyes. Needs test photos (open, closed, half-closed, sunglasses, profile) from Rosh's shoots.
- Culling again replaces Cull's earlier note on that photo with the new one, unless the person edited it: then the edited note stays and the new one is added. Re-review from Show Cull Group (⇧⌘G) does the same. A photo kept on re-review keeps its old note, marked "Kept later".
- The Cull view gets a checkbox "Write reasons to notes" (on by default, remembered). The focused photo's reasons also show in the Cull view's notes panel while culling, before anything is written.

**4. Finding photos by notes**
- Library's filter bar gets a Notes field: Has Notes, No Notes, Text contains…, Written by (You, Cull, a chat app). Full-text search (PRD Search) covers notes with keywords, titles and captions. A smart collection can use the same rules.

**5. XMP (decision proposed)**
- Notes go to XMP sidecars only in Atelier's own namespace, `atelier:Notes`: a format-version-1 JSON list of notes (text as written, Markdown subset included; created, edited, author) keyed by exact filename, like `atelier:DevelopRecovery`. They are never mapped onto Caption (`dc:description`), IPTC Instructions or EXIF User Comment, so other apps and exports never see or overwrite them, and Rosh's real captions stay untouched. Written with the rest of the metadata (on demand or automatically per Settings > Metadata) and read back on import into a new catalog, so the sidecar is the recovery path as for everything else. Virtual copies' notes stay in the catalog only, as with their develop settings (sidecars are written for the original only).

**6. Chat apps (MCP)**
- Notes are commands in the action registry, so the menus and the MCP catalog get them together: `photo.addNote` (kind `edit`), `view.toggleNotes` (kind `view`), `photo.editNote` (edit; changes a note's text). Delete Note is kind `deletes`, so it is never offered to agents.
- Agent tools: `get_photo` / `search_photos` return each photo's notes (text in the same Markdown subset, times, author; text outside the subset that an app sends is kept as plain text) and take a `notes` filter (has notes, text contains, author); `add_note` (photo ids, text) for Organize or more; `edit_note` only on notes the same app wrote. Each call is one change with Undo in the agent notice, as other Organize tools. A chat app's note says its name as author. Notes of private photos are never returned while they are hidden.

### Steps (one PR each, once approved)
1. **Core:** `notes` table (GRDB migration: id, assetId, text, author, createdAt, editedAt, source cull/manual/agent), `Catalog+Notes.swift`, copy rules for virtual copies, stacks and pairs, search and filter, `atelier:Notes` XMP write and read. Tests in AtelierCoreTests.
2. **Panel:** the overlay in Library, Loupe, Cull and Develop; menu items, keys, badges; Settings > Appearance font choice; layout snapshots; Help page `notes.html`; PRD "Photo notes" section.
3. **Cull reasons:** keep each photo's measurements until the cull finishes, eye openness from landmarks, the reason note, re-cull rules, "Write reasons to notes"; tests on fixtures.
4. **Agents:** the actions and tools above, regenerated `agent-actions-catalog.json`, Help > Connect a chat app.

### First build (steps 1, 2 and part of 4), as built
- **Built:** `note` table (migration `v10-notes`), copied to virtual copies, stacks and processor results; search and Library filter (Has Notes, No Notes, Unticked Checkboxes; Filter bar and Filmstrip Filter pop-up); `atelier:Notes` in sidecars keyed by filename, read back on import; the sticky panel over the photo in Grid, Loupe, Develop and Cull (drag to a corner, resize, remembered); thumbnail note mark; View > Show Notes (⌥⌘N), Photo > Add Note… (⌥⇧⌘N) and right-click > Add Note…; Settings > Appearance > Notes font, color (six sticky presets or custom) and opacity (85% default, Rosh Nov 14, 2026); a format strip (Bullets, Numbered list, Checkboxes, Bold, Italic) while typing; agent tools: `get_photo` returns notes, `search_photos` takes `has_notes` and searches note text, `set_metadata` takes `add_note` (one Undo with the rest).
- **Changed from the requirement while building (to confirm with Rosh):** while a note is being typed its markers show dimmed rather than hidden (formatted once typing ends); delete is ⋯ / right-click > Delete with an Undo row in the panel for 10 seconds, not Edit > Undo or the Delete key; ⌥⌘N and ⌥⇧⌘N are menu shortcuts, not yet in Settings > Keyboard; no toolbar button; the thumbnail mark is not clickable; `photo.addNote` is hidden from agents (it opens a note for the person to type) and agents use `set_metadata` `add_note` instead of a separate `add_note` tool.
- **Left for later:** Format > List menu items (⌘⇧7, ⌘⇧L); pasting keeps lists (pastes are plain text today); notes filter by author and in smart collections; `edit_note` for agents; step 3 (Cull reasons and eye openness).

### Open questions for Rosh
- Per virtual copy (proposed) or one set of notes shared by the original and its copies?
- XMP in `atelier:Notes` (proposed), or keep notes in the catalog only?
- Should Cull also write a short note on kept photos ("Keeper of 6, sharpest"), or only on rejected ones (proposed)?

**Acceptance (once built):** notes added in Grid show in Loupe, Cull and Develop; ⌥⌘N toggles the panel in each view without moving zoom, pan or grid scroll (checked at 100% and Fit, and while zoomed into a corner); the panel's place and state survive a mode switch and relaunch; a cull of a burst writes reasons that match the measured sharpness and eyes; Library finds photos by note text; a new catalog importing the folder gets the notes back from XMP; an export contains no note text; a chat app reads and adds a note with one Undo and can't delete one.

**Sources (secondary, user forums and reviews):** [Adobe: Add text notes to photos (feature request, open since 2011)](https://community.adobe.com/t5/lightroom-classic-ideas/p-add-text-notes-to-photos-stacks-folders-directories-collections/idi-p/12249965/page/3); [Adobe: Assisted Culling early access (Lightroom Classic)](https://community.adobe.com/questions-675/early-access-assisted-culling-lrclassic-983825); [Capture One community: Notes attached to sessions or images](https://support.captureone.com/hc/es/community/posts/360009407477-Notes-attached-to-sessions-or-images); [Photo Mechanic: IPTC template map](https://docs.camerabits.com/support/solutions/articles/48001174616) (vendor docs); [Aftershoot: culling genres](https://support.aftershoot.com/en/articles/10570203-aftershoot-culling-genres) (vendor docs); [Digital Camera World: Excire Foto 2025 review](https://www.digitalcameraworld.com/tech/software/excire-foto-2025-review).

## AT-059 — Cull: Pick By (smarter keeper suggestions) and Advanced checks

**Status:** In progress. Approved by Rosh (Nov 14, 2026: "go"), after the report `reports/cull-selection-algorithms-2026-11-14.md` in project files. Part 1 (Vision only) built on branch `claude/project-thread-2n3y8e`; not compiled in the cloud (no macOS); needs a Mac build, the fixture test run and Rosh's acceptance. Part 1 merged as PR #132 (`84bdc79`), built by Rosh on their Mac. Part 2 (MediaPipe Face Landmarker, Best Expression) built on branch `claude/project-thread-2n3y8e`: models converted and checked against Google's TFLite runtime in the cloud (max difference 3e-4 px on the mesh, 3e-6 on the blendshapes), not compiled in Swift; needs a Mac build, `FaceLandmarkerTests` and `CullFixtureTests`, and Rosh's acceptance. **Owner:** Claude, chat [Build smarter Cull photo picking](https://claude.ai/code/project/chan_01Y9ueFJEbKyPqWn7CWQ5SGK?thread=cmsg_01Y9ueFJEbKyPqWn7CWQ5SGKBeo6kR8NWm4EtvF5wDHZjJ). **Depends on:** AT-058 (notes) for the reason notes.

**Evidence:** Rosh (Nov 14, 2026): "can the cull have multiple selection algorithms, and more enhanced ones (which would be selected default if they are time consuming) I really wanted to have picture selection based on better clarity, number of people closed their eyes etc (advanced item only if they are time consuming)". Read as: slow checks are opt-in. Decisions the same day: grouping stays as it is (no change to Match or Grouping); Balanced replaces the old suggestion as default with Classic kept; MediaPipe Face Landmarker (3.76 MB, model cards Apache 2.0) built into the app, no download ("use it within"); two PRs (Vision first). Test photos: 19 Gemini-generated photos, `~/RoshProjects/Atelier/TestPhotos/Cull/` (labels in `labels.md`), copy in project files `test-photos/cull/`.

**Cause found (main at `51b64da`):** `Culling.suggestedKeeper` added whole-frame sharpness to the **best** face's capture quality, so one sharp open-eyed face hid other people's blinks, and a sharp background or noise could beat a sharp subject; the measurements were thrown away when the cull ended.

**Part 1 (PR #132, merged):** per-face eye openness from Vision landmarks compared per person across the group; per-face capture quality; subject sharpness (faces, else salient object); blur direction; exposure; Apple aesthetics score; Pick By (Balanced, Sharpest Subject, Everyone's Eyes Open, Best Exposure, Classic); Advanced checks (eyes from a copy up to 4096 px, grouped photos only); caption and reasons in the Cull view; AT-058 step 3 notes. Core in `AtelierCore/Cull/CullFaces.swift`, `CullMeasure.swift`, `CullPick.swift`, `Catalog/Catalog+CullNotes.swift`.

**Part 2 (this PR):** MediaPipe Face Landmarker's mesh and blendshape models converted (`Scripts/models/convert_mediapipe_face_landmarker.py`) and built in (`Models/FaceMesh.mlpackage`, `FaceBlendshapes.mlpackage`, 4.5 MB; NOTICE and LICENSE beside them), run by the Advanced checks on Vision's face boxes (`AtelierCore/Cull/FaceLandmarker.swift`); blink scores decide eyes open, half closed, closed (each person against their lowest in the group); smile counts in the caption and reasons; Pick By Best Expression (turns the Advanced checks on). Built-in model loading shared with PeopleParts (`AtelierCore/AI/BundledModel.swift`). Blink thresholds come from the Gemini test photos run through Google's runtime with OpenCV face boxes (open 0.1 to 0.3, closed 0.5 to 0.8); Vision's boxes may shift them a little. Not done: the crop isn't turned to the face's roll, so strongly tilted heads read less well.

**Acceptance:** fixture test `CullFixtureTests` passes on a Mac (group of five: right people closed; portraits, narrow eyes and glasses: open vs closed; kids: middle child closed), and its printed timings are recorded; one real NEF shoot culled with each Pick By (Rosh): the suggested keeper is the one Rosh would pick in most groups, notes read correctly; Advanced on a group shot finishes with progress and Cancel by unticking; the old suggestion is available as Classic. Thresholds in `CullEyes` are provisional until then.

**Deferred:** a learned image-quality model (sizes and dataset licenses), animal eyes, learning Rosh's own picks; reasons shown in the notes panel while culling (shown in the preview caption instead).

## AT-060 — Cull preview: zoom like Loupe, and note markers

**Status:** Built, not compiled in the cloud (no macOS); needs a Mac build and Rosh's acceptance. Approved by Rosh in words (Nov 14, 2026, below). **Owner:** Claude, chat [Build smarter Cull photo picking](https://claude.ai/code/project/chan_01Y9ueFJEbKyPqWn7CWQ5SGK?thread=cmsg_01Y9ueFJEbKyPqWn7CWQ5SGKBeo6kR8NWm4EtvF5wDHZjJ), branch `claude/project-thread-2n3y8e` (after PR #133). **Depends on:** AT-058 (notes), AT-059 (Cull reasons).

**Evidence:** Rosh (Nov 14, 2026): "when the cull preview is shown, can we able to zoom that just like other places? also the notes can have annotation locations which preview can show the annotations there itself?"; "just an approximate coordinates, and that annotations can be turned off or on, and it will only on preview"; "cull preview while culling or opening the culled group".

**Today (main at `84bdc79`):** the Cull preview is a plain SwiftUI `Image` (1800 px), with no zoom; notes have no position.

**Built:** the preview is `ZoomableImageView` with its own `ZoomState` in `CullModel` (kept across photos), the zoom key, `ZoomControls`, full-size read past Fit; a display-only overlay mode in the shared photo view (`overlayPassesClicks`: clicks, drags and cursor stay the photo view's) for `NoteMarkersOverlay`; `PhotoNote.spotX/spotY` (migration `v11-note-spots`, `Catalog.setNoteSpot`, copied to virtual copies, in the XMP notes packet as `x`/`y`); Pin to Photo / Remove Pin in the notes panel only when the Cull view passes `NotePins`; Note Markers checkbox (`cull.noteMarkers`); Cull reason notes pinned by `Culling.reasonSpots`.

**Acceptance:** in Cull and in Show Cull Group, double-click, Z, pinch, ⌥-scroll, drag and the zoom buttons work as in Loupe, and the zoom stays when moving to the next photo; Loupe's zoom is unchanged after; Pin to Photo then a click places a numbered marker that follows zoom and pan; Remove Pin and the Note Markers switch work; markers never show in Grid, Loupe, Develop or exports; a culled group's dropped photo with closed eyes shows its reason marker on that face.

**Deferred:** dragging a marker to move it (Pin to Photo again moves it); markers in other views (Rosh chose Cull only).

## AT-061 — Cull preview: Show Subject (what sharpness was measured on)

**Status:** Built, not compiled in the cloud; needs a Mac build and Rosh's acceptance. Approved by Rosh in words (Nov 14, 2026). **Owner:** Claude, chat [Build smarter Cull photo picking](https://claude.ai/code/project/chan_01Y9ueFJEbKyPqWn7CWQ5SGK?thread=cmsg_01Y9ueFJEbKyPqWn7CWQ5SGKBeo6kR8NWm4EtvF5wDHZjJ), branch `claude/project-thread-2n3y8e`. **Depends on:** AT-059, AT-060.

**Evidence:** Rosh (Nov 14, 2026, after testing #133): "Still I see some of the very same images are not in the group and saying subject is this % not sharp and seeing all the shots are sharp - I don't understand what it identified as subject. When it says subject, can it annotate on the preview of cull which one is picked as subject it will help me to test it as well."

**Built:** `CullSignals.subject` (`CullSubject`: faces, Vision's main object, or whole frame, with its box) kept from analysis; Show Subject checkbox (`cull.showSubject`) draws it and each face's eye state on the Cull preview (`CullSubjectOverlay`), with the sharpness against the group's best.

**Cause found (Rosh's screenshot, Nov 14, 2026):** Vision found no face (sunglasses), so each photo fell back to its own most salient object, a different region in near-identical shots. **Fixed (same PR):** people from Vision's body detector before the main object; groups not all measured on faces are measured on one shared region (union of subjects) from a per-photo 16 × 16 sharpness grid (`CullSharpnessGrid`); overlay boxes cut to the visible photo and the overlay host clips; Show Subject and Note Markers side by side in an `AdaptiveControlBar` like Loupe's. **Find Faces (Rosh approved Nov 14, 2026: "yes, run that… or have an option… just algorithm name"):** menu Apple Vision / MediaPipe / Both (default); MediaPipe = BlazeFace short range from the Face Landmarker task, converted (`Models/FaceDetector.mlpackage`, 0.3 MB; NumPy translation matches Google's runtime within 6e-4) and run on the whole frame and the top half of each person; each finder's faces, subject and sharpness kept (`CullSignals.faceSets`), so switching only picks again. Cloud check on Rosh's screenshot photo: BlazeFace found the sunglasses face Vision missed (0.88 on the photo crop; 0.78 to 0.87 inside the person box with the face 24 to 60 px), nothing on the blurry background people; on the 19 test photos it found every face. Vision's own result can't be run in the cloud: `CullFixtureTests.testFaceFindersPrint` prints both finders' face counts per test photo on a Mac.

**Acceptance:** Show Subject draws the dashed subject box and face boxes in the right places at Fit and zoomed, never past the photo, labels say what the subject is and the sharpness, and it never shows outside the Cull preview.

## AT-062 — Cull: blurred background faces aren't the subject

**Status:** Built, not compiled in the cloud (no macOS); needs a Mac build and Rosh's acceptance. Approved by Rosh in words (Nov 14, 2026, below). **Owner:** Claude, chat [Drop blurred background faces from Cull subject](https://claude.ai/code/project/chan_01Y9ueFJEbKyPqWn7CWQ5SGK?thread=cmsg_01Y9ueFJEbKyPqWn7CWQ5SGKLs4UjcQgNuZSvu1stFiC5d), branch `claude/cull-background-faces`. **Depends on:** AT-059, AT-061.

**Evidence:** Rosh (Nov 14, 2026, screenshot of Z62_9227 in a 12-shot group, Find Faces Both, Advanced on): "subject is just me but it is picking up the blurred background person too. if the blur difference is more for one of the detection. can it drop that from the subject selection? otherwise it picks up eveyone in the background - see a threshold value if it below from that it is not meant to be focused anyway - photographer knows what he/she is taking". The shot was dropped for "Eyes half closed: 1 of 2 people", the second person being a blurred passer-by MediaPipe took for a face; the subject box spanned both.

**Cause (main at `9dbe5dd`):** every face found counted equally: the subject box was the union of all faces, its sharpness their size-weighted mean, and every face's eyes were judged.

**Built:** `AtelierCore/Cull/CullBackground.swift`: per photo, a face under 20% of the sharpest face's sharpness (or under 35% and at most half its width) is background; per group, a person is background when that holds in more than half their shots. `Culling.assess` drops them before measuring (subject, sharpness, eyes, smiles, face quality); `Culling.eyes` returns `.background` for them, so reasons, note pins and Show Subject follow. Show Subject draws them faint and dotted; the subject line counts them. Measured thresholds (cloud, OpenCV boxes, same Laplacian as `GrayPlane`): in focus 0.41 to 1 of the sharpest (group-5-outdoor, kids-group, crowd, profile couple); background 0.002 (Z62_9227, from the Cull preview in the screenshot), 0.065 to 0.24 (profile.jpg café). Tests: `CullPickTests` (screenshot case, thresholds, missed-focus shot), `CullFixtureTests` (no background face among the in-focus test photos).

**Acceptance:** Mac build and tests; Z62_9225 to Z62_9227 group: the passer-by is faint and dotted, the subject box is around Rosh only, no "Eyes half closed: 1 of 2 people"; group-5, kids and crowd test photos show no background faces.

**Deferred:** a setting for the threshold (fixed for now); whole people (body boxes) aren't filtered by focus (clothing texture misleads); the motion-blur check (`coherence`) is still read on the subject box from analysis, which can include the background face's area.

## AT-063 — Match Look: skin covers the neck, has no holes, and reaches the study's color

**Status:** Merged as `850a588` on Nov 14, 2026 at Rosh's ask after four rounds of Rosh's Xcode tests ("slightly better, merge it"). XCTest/`check_pr.py` not run (cloud; CI billing-blocked). **Owner:** Claude. **Chat:** [Analyze Match Look skin matching gaps](https://claude.ai/code/project/chan_01Y9ueFJEbKyPqWn7CWQ5SGK?thread=cmsg_01Y9ueFJEbKyPqWn7CWQ5SGKNa3pxZsTY6t8uNKnYc1sgY). **Branch:** `claude/match-look-skin-gaps`. **PR:** [#136](https://github.com/roshan-davis/atelier/pull/136). **Baseline:** `9dbe5dd`. **Dependencies:** AT-047 (merged), AT-048 (carried in this PR).

**Evidence:** Rosh (Nov 14, 2026), Match Look to a built-in study: the skin selection sometimes covers the face but not the neck; some skin areas are missed; the skin color doesn't reach the reference. Report `reports/match-look-skin-gaps-2026-11-14.md` (project files): masks were Face Skin + Lips only (Body Skin dropped in AT-033 when it was color-only); eye/brow holes cut 1.35× wide were never added back; target was the study's absolute Oklab a/b while the face kept its own brightness (Fury Road shadows +44%, Thrones mids +32% too saturated on a test portrait); tone masks fitted in sequence, cuts measured on a different luma than the Luminance Range; sliders capped ±35, 2 rounds, no notice when short; fit only on the stand-in.

**Scope (Rosh: "fix all you found", one PR, separate commits):** 1) AT-048's Entire Face part (rebased); 2) skin masks add Body Skin when the parts model is loaded, Match subtracts Eye Sclera + Iris, agents get `entire_face`; 3) color relative to brightness (`LookSkin.relativeAB`, `relativeToneColors`); 4) joint damped-least-squares fit of the three masks (`SkinSolver`), thirds cut on `rangeLuma`; 5) full range for built-in studies (±35 for photos), four rounds, real-render check (`settleSkin`), `skinMatchPartial` notice. Not in scope (need Rosh's decision): pulling skin brightness toward a study (studies are color only, AT-045); a Hue slider for masks. 9) after Rosh's third test (gray Matrix/Thrones faces, mustard Fury Road with clipped blue): study target leans the photo's own skin (half the hue difference, kept in Oklab 40–70°; saturation × √(study/baseline) in 0.85–1.2, kept in 0.07–0.17) plus a touch of warmth, more on a cool background. 10) after Rosh's fourth test (Fury Road: one cheek still orange with blue clipped, forehead pale): Match Skin Tone leaves the skin out of the global fit and holds it within Protect's limits there (penalty), as Protect does.

**Acceptance:** Mac build; `LookMatchTests` (entire face and body, relative color, range luma cuts, solver), `PeopleSkinTests.testEntireFaceHasNoHoles`, `BuiltInLookReferenceTests.testPortraitStudiesMatchFaceColorWithEditableMasks`, `LookEmulatorTests.testSkinMatchRendersLittle` pass; Rosh: a portrait with a visible neck matched to each portrait study, neck follows face, no rings at eyes or brows, skin reads like the study's.

## AT-064 — Match Look: hair (and later clothes) matched part by part

**Status:** Dropped for built-in studies (Nov 14, 2026, Rosh: "anything other than skin can go along with the tone of the background … why need to do overly complicated thing?"): with a study, hair and clothes take the background's look and no Subject mask is added (AT-065). Still possible for photo references only if Rosh asks; not planned. **Owner:** none (Claude drafted the plan). **Chat:** [Match hair and clothes in Match Look](https://claude.ai/code/project/chan_01Y9ueFJEbKyPqWn7CWQ5SGK?thread=cmsg_01Y9ueFJEbKyPqWn7CWQ5SGKSTwLJe5ECeSvSnytwc1uGi). **Baseline:** `850a588`. **Dependencies:** AT-063 (merged), AT-043 (parts model, merged).

**How hair and clothes are matched today (at `850a588`):** nothing aims at them. Whole Photo: the global sliders are fitted on every pixel of both images except the skin (left out with either skin option), so drawn hair and clothes count like any other area and the global look lands on the photo's hair and clothes. Subject & Background: the global sliders are fitted background to background; then one "Match Look: Subject" mask (the person minus the skin) gets one Temp/Tint/Exposure/Saturation correction toward the study's drawn person (hair, clothes and features averaged together), so hair and clothes share one correction.

**Evidence on the studies:** each portrait's hair is one flat near-black fill (`data-part="hair"`), a faint tint over very low saturation (Oklab C/L): Fury Road warm brown-black (54°, 0.066), Thrones warm (34°, 0.047), Dark Knight blue-black (−74°, 0.035), Matrix green-black (159°, 0.045). Real dark brown hair is about 0.09, so copying the drawing would desaturate it and dye it blue or green (the same trap as AT-063's skin).

**Proposed scope (hair first, clothes in their own item later):**
1. Hair on both images: the photo's from Select People > Hair (built-in MediaPipe parts model); a study's from its `data-part="hair"` shapes (`FlatSVG.mask`); a photo reference's from Select People > Hair.
2. A "Match Look: Hair" mask (Select People > Hair, feather 20) moving only Temp, Tint and Saturation, solved with AT-063's `SkinSolver` (one tone, color relative to brightness); hair brightness left alone (studies give color only).
3. Target = the photo's own hair leaned toward the reference's in the Oklab a/b-over-L plane: a third of the way for a study, 0.6 for a photo; saturation kept within 0.6–1.15× its own (near-gray hair may take a 0.03 cast; nothing past 0.15); sliders capped ±40. Effect: Matrix slightly olive and less brown, Dark Knight more neutral inky black, Fury Road a touch warmer; never dyed.
4. Hair left out of the global and Subject measurements on both images when on; the Subject mask still covers it (so Exposure stays even), and the hair mask takes back what the global and Subject fits did to it.
5. Dialog: a Hair checkbox on the Match row (on for portrait studies when the parts model is loaded); Show Skin becomes Show Skin & Hair (hair tinted blue); notice when the reference has hair and the photo has none. Strength blends the hair mask as it does the skin masks; a match with a hair mask fits each photo. Agents' `match_look` gets a `hair` option (catalog regenerated). PRD, Help, tests.

**Done meanwhile (PR #137, Rosh: "fix that"):** after Rosh's screenshot (Fury Road, Subject & Background: Match Look: Subject at Temp +60 (its limit), Tint +30; denim jacket still blue, hair maroon), the Subject mask for a built-in study leans the photo's own subject color (measured on the unedited photo) a third of the way toward the drawn person's, with Temp, Tint and Saturation within ±20 (`LookMatcher.studySubjectLean`, `maxStudySubjectShift`); photo references unchanged (±60). Never compiled; needs a Mac build, `LookMatchTests.testStudySubjectIsANudgeNotACopy` and Rosh's test on the same photo.

**Work in progress kept:** an unfinished, never-compiled patch of steps 1–3 (core only: `LookHair`, `fitHair`, the solver loop shared as `solveMasks`, `LookMatch.hairMaskName`, `LookTargets`' hair) is in project files at `handoff/at064-match-hair/match-hair-wip.patch` (against `850a588`).

**Acceptance (when picked up):** Mac build and tests; Rosh: a portrait with visible hair matched to each portrait study in Whole Photo and Subject & Background; hair takes a slight lean toward the study, never an unnatural color; skin results unchanged.

## AT-065 — Match Look: a built-in study's hair and clothes take the background's look (no Subject mask)

**Status:** In review; never compiled (cloud, no macOS toolchain; CI billing-blocked). Needs a Mac build, tests and Rosh's test. **Owner:** Claude. **Chat:** [Match hair and clothes in Match Look](https://claude.ai/code/project/chan_01Y9ueFJEbKyPqWn7CWQ5SGK?thread=cmsg_01Y9ueFJEbKyPqWn7CWQ5SGKSTwLJe5ECeSvSnytwc1uGi). **Branch:** `claude/project-thread-so20kh`. **PR:** see the branch's open PR. **Baseline:** `eaf0b05`. **Dependencies:** AT-063 (merged).

**Evidence:** Rosh's Z62_9184 with Fury Road, Subject & Background: Match Look: Subject at Temp +60 (its limit), Tint +30; denim jacket still blue, hair maroon. PR #137 (merged `eaf0b05`) made the study's subject mask a nudge (a third of the way, ±20); Rosh found it good, then asked why hair and clothes don't simply take the background's tone.

**Scope:** with a built-in study, Subject & Background still fits the global sliders background to background but adds no "Match Look: Subject" mask (`LookMatcher.match` skips `fitSubject` when `target.whole.isColorStudy`); PR #137's nudge (`studySubjectLean`, `maxStudySubjectShift`, `fitSubject(own:)`) removed. File and catalog references unchanged. Dialog hint for studies, PRD, Help updated. A subject mask left by an earlier match is kept untouched.

**Acceptance:** Mac build; `LookMatchTests.testStudySubjectTakesTheBackgroundLookWithoutASubjectMask`, `BuiltInLookReferenceTests`, `MatchLookModelTests` pass; Rosh: Z62_9184 (earlier match undone) with each portrait study in Subject & Background, no Subject mask in Masking, hair and jacket keep natural colors under the study's look.

## Lightroom Classic 16 gaps (Nov 15, 2026)

Rosh (Nov 15, 2026): "lets add these in the backlog and we can start with 1 first", after the comparison `reports/lightroom-classic-16-vs-atelier-2026-11-15.md` (project files; Lightroom Classic 16.0 and 15.x against `main` at `e71d7d5`). Six gaps, ranked by the report. Gap 5 (smart collections, duplicates, Map, People) goes under AT-013. AT-066 is approved to start. The rest are proposals to discuss before building.

## AT-066 — Develop: Remove tool (Content-Aware Remove, Heal, Clone)

**Status:** Approved (Rosh, Nov 15, 2026: "start with 1 first", then "OK" to this design and to the engine recommendation: PatchMatch built in, a model later only if it falls short). Step 2 (Clone and Heal) built and run by Rosh on the Mac; Rosh asked to merge PR #139 (Nov 14, 2026, 10:18 PM PT). See "Step 2 as built" below. Step 3 (Content-Aware Remove) merged in PR #140 (`77eddb3`, Rosh: "merge it and pick the next", Nov 15, 2026), not yet built on a Mac at merge; see "Step 3 as built". Step 4 (Generative AI) is implemented on `claude/project-thread-mp3ctg`, **not yet built or tested on a Mac**; see "Step 4 as built". **Owner:** Claude (Cl). **Chat:** [Compare Lightroom 2025-26 with Atelier](https://claude.ai/code/project/chan_01Y9ueFJEbKyPqWn7CWQ5SGK?thread=cmsg_01Y9ueFJEbKyPqWn7CWQ5SGKQjWyjEX331a5FG3gyZMjyK). **Branch:** `claude/project-thread-mp3ctg`. **Baseline:** `e71d7d5`. **Dependencies:** none for steps 2–3; step 4 uses the ComfyUI Remove Object recipe (AT-008 Processor contract).

**Evidence:** Atelier has no spot tool. The only way to remove something is the AI tool's Remove Object (ComfyUI, Qwen-Image-Edit-2511, about 91 s at 768 px), which is too slow for dust, blemishes or a stray wire, and it writes a new version instead of a setting. Lightroom's Remove tool (Q) does Content-Aware Remove, Heal and Clone in place, and 15.0–16.0 built Dust Removal, Reflection Removal and AI Blemish removal on top of it.

**Design (Lightroom Classic as the floor; approved Nov 15, 2026):**
- **Open:** a Remove button (bandage) in the tool strip under the histogram, between Crop and Masking, and Q (a `KeyAction`, customizable in Settings > Keyboard). Opening it closes Crop, Masking and AI, as those close each other. Esc or Q again closes it, Return applies (same as Done).
- **Panel** under the tool strip: Mode buttons **Content-Aware Remove** (the default once step 3 lands; Heal until then), **Heal** and **Clone**; **Size**, **Feather** (Heal and Clone only) and **Opacity**, all `SliderRow`; **Visualize Spots** (A in Lightroom; here the same key) with its threshold slider, which shows a black-and-white edge view so sensor dust stands out; **Show Overlay** (spot outlines, on by default while the tool is open); Reset and Done.
- **On the photo** (an overlay on the Develop photo view, like Masking; never a second photo view): click for a round spot, drag to paint a stroke. Heal and Clone pick a source next to the spot automatically and show it as a second outline joined by a line; drag the source outline to move it, or press / for a new automatic source (Lightroom's key). Click a spot to select it; Delete removes it and plays `DeleteFeedback.play(.remove)` (PRD UX principle 12). [ and ] resize, ⇧[ and ⇧] feather, as in Masking. Cursors come from `CursorShape` (a brush circle at the brush size, a move cursor over a source). The photo zooms and pans as everywhere (`ZoomViewport`, Space-drag, pinch, Navigator).
- **What each mode does:** Clone copies the source with a feathered edge. Heal copies the source's texture and matches the colors and brightness around the spot's edge (a smooth membrane fill of the edge difference, as in Poisson healing). Content-Aware Remove fills the spot from texture found anywhere nearby, not from one source (PatchMatch, Barnes et al. 2009), then blends the edge like Heal.
- **Stored as settings:** `DevelopSettings.spots`, a list of spots (mode, stroke points and size in the same uncropped source coordinates as masks, feather, opacity, source offset, and the Content-Aware fill's random seed so every render matches). Decoded with `decodeIfPresent` and an empty default, so old catalogs, presets and history load unchanged. Written to XMP with the other settings (AT-004 path). Paste Settings and Sync keep each photo's own spots (Lightroom's default; a **Spot Removal** checkbox to paste them anyway is deferred). Presets never carry spots.
- **Pipeline:** spots apply to the corrected photo (after RAW decode, lens corrections, Defringe and Transform, before crop and every tone and color step). So they stay put when tone or color changes, and a tone slider drag never refills a spot. Clone and Heal fills are cheap GPU passes. A Content-Aware fill is computed once in the background, per spot, from the pre-tone image, cached by spot and upstream settings, and reused in every frame and export. While one computes, the spot shows the Heal result.
- **History:** each spot, move, resize, mode change and delete is one step ("Add Spot", "Move Spot Source", "Delete Spot"), and Undo works while the tool is open.
- **Agent actions** (the registry, regenerated catalog): Show Remove Tool (`view`), Visualize Spots (`view`, toggle), Clear All Spots (`edit`, one Undo). Painting spots stays manual for now (same reason Brush masks are left out for agents in AT-050d); a `remove_spots` tool with round spots at given points could follow for dust.
- **Preview cache:** adding the `spots` field changes nothing for photos without spots, so no `PreviewCache.version` bump unless the pipeline order changes how existing photos render. Check before merging.
- **Help:** a new Remove tool page with drawn controls and before/after pictures for each mode (from `make_help_images.py`), listed in `GROUPS`.

**Steps (one PR each):**
1. This design, PRD section and Help outline (docs only).
2. Clone and Heal: click and stroke spots, automatic and draggable source, Visualize Spots, history, Copy/Paste checkbox, XMP, actions, Help.
3. Content-Aware Remove (PatchMatch, background fill with cache). Measure fill time on a 45 MP Nikon NEF for a dust-size spot and a 300 px stroke before deciding on GPU work.
4. **Generative AI** checkbox under Content-Aware (as in Lightroom): the stroke goes to the existing ComfyUI Remove Object recipe and the result is stored as that spot's fill (a patch file next to the catalog), so large objects use the same tool. The AI tool's Remove Object stays until Rosh decides whether to fold it in.

**Later, separate items once this lands:** Detect Dust (find and fill sensor spots automatically, Lightroom 15.0), Blemishes (spots found on the Face Skin mask from Select People, Lightroom 16.0), Reflection Removal.

**Decided (Rosh, Nov 15, 2026):** the Content-Aware engine is built-in PatchMatch (no model, no download, fine for dust, blemishes and small objects), with a small permissively licensed inpainting model as an optional Settings download later if PatchMatch falls short on larger areas. Generative AI (step 4) covers big removals.

**Step 3 as built (branch `claude/project-thread-mp3ctg`):**
- Core: `ContentAwareFill` (`Develop/ContentAwareFill.swift`): PatchMatch image completion on plain arrays, 7 × 7 patches, a pyramid down to about a patch across the hole, 12 / 6 / 4 search-and-vote rounds coarse to fine, weighted voting, then a sharp last pass (each pixel from the center of its best match). Seeded (SplitMix64), so every render matches; the spot's `variation` (new field, written only when not 0) picks the seed, and / adds one.
- `SpotFills` (`Develop/SpotFills.swift`): renders the area around the spot (twice its radius on every side, at most 1,024 px across, 32-bit float), fills the brush, and keeps the result by corrected photo (`DevelopSession.upstreamID`), earlier spots, path, size and variation; feather, opacity and every later slider reuse it. The editor finds fills in the background and posts `ContentAwareFill.fillReady` (the controller renders again, as for Fine Edges); export sessions wait.
- `SpotRenderer`: `.contentAware` spots draw the fill through the feathered brush (`atelierSpotFill`), one pass over the whole photo like Heal and Clone; while the fill is missing they show Heal.
- App: Content-Aware is first in the mode switch and the default for new spots; no source outline for it; the hint and tool tip name it. Help: Content-Aware section and before/after (`Scripts/help/patchmatch_fill.py`, the same algorithm in NumPy).
- Tests: `ContentAwareFillTests` (flat fill, stripes carried through, same seed same fill, no hole, a Content-Aware spot clears a speck and outside it nothing changes, decoding). The Swift fill's logic was checked in the cloud by a line-by-line Python port passing the same flat, stripe and seed checks; the Swift itself was not compiled.
- Measured with the NumPy prototype only: a 250 × 280 area with a 12,000-pixel hole takes about 5 s in Python; the Swift port should be far faster but is not measured. Needs a Mac timing on a 45 MP NEF (a dust spot at full size and a 300 px stroke).
- Known limits: large objects in busy scenes come out smudged (the forest hiker test); a spot larger than about 1,024 px across is filled at reduced size and comes out softer.

**Step 4 as built (branch `claude/project-thread-mp3ctg`):**
- Panel: a **Generative AI** switch under the Mode buttons while Content-Aware is chosen (Lightroom's checkbox). It is remembered, applies to new Content-Aware spots and, like the sliders, to the selected one. While ComfyUI works, the panel shows the selected spot's progress with Cancel (or how many fills are being made), and a failure (ComfyUI not running, original offline) in red. The hint names it.
- What happens: a new Generative spot renders the photo at full size as the spot sees it (corrected, with the spots before it, before tone and color: `DevelopSession.imageUnderSpot`), takes the area around the spot with the same context rule as Remove Object (`AIImaging.contextRegion`), and sends it to the Remove Object recipe (built-in workflow or the user's, Settings > AI edit model and generation size) with the brush, 10% larger plus 2 px, as the mask. Meanwhile the spot shows the Content-Aware fill. The result is the spot's `patch` (new field: id, region as fractions of the photo, the area's average color, seed), one history step "Generative Fill". / asks ComfyUI for another (new seed); the old fill stays until the new one is in. Moving or resizing the spot drops its fill and asks again once the drag or slider has been still for 0.8 s.
- Storage: `SpotPatches` keeps each fill as `~/Library/Application Support/Atelier/Spot Patches/<id>.png`, with `<id>.json` recording recipe, workflow, models and licenses (the same list as Remove Object's provenance), seed and size. The original is never written. If the file is missing, the spot shows Content-Aware.
- Color: the fill was made under the White Balance and Exposure of the moment; it is multiplied by how much the area's average color has changed since (per channel, held to 1/4–4×), so a later WB or Exposure change moves it with the photo.
- Code: `SpotGeneration` (Core, `AI/SpotGeneration.swift`: `prepare`, `AIRunner.generateFill`), `AIRunner.generate` (the queue, progress and download step, now shared by `run` and `generateFill`), `SpotPatches` (`Develop/SpotPatches.swift`), `DevelopController+SpotGeneration.swift`. Tests: `SpotGenerationTests` (encoding and old spots, the patch drawn only on the spot, following a doubled exposure, a missing file falling back to Content-Aware, Generative off ignoring the patch, the input region and hole, the image under a spot). ComfyUI itself is not run in tests.
- Known limits: a fill finished after you moved to another photo is saved into that photo's settings but its Grid thumbnail updates only when the photo is next edited. A Lens Corrections, Transform or earlier-spot change after generating is not detected (press / to make a new fill). Fills don't pass the license gate yet (the JSON records the models for it). Patch files of deleted spots stay on disk (no clean-up yet). Highlights above white in the area are clipped in what the model sees. The AI tool's Remove Object is unchanged.

**Acceptance:** Mac build and tests (spot geometry and encoding in `AtelierCoreTests`, Heal edge-match and Content-Aware determinism checks on fixtures); layout snapshot of the tool panel; Rosh on a NEF: remove sensor dust with Visualize Spots, a skin blemish with Heal, a wire with a Clone stroke, then change Exposure and crop. Spots stay put and the fills don't redo themselves during the drag.

## AT-067 — Develop > Detail: AI Denoise

**Status:** Approved (Rosh, Nov 15, 2026: "pick up the next one", then after a side-by-side on Rosh's own NEFs, "PMRID, built into the app"). Implemented on `claude/ai-denoise-pmrid`, **not yet built or tested on a Mac**; see "As built". **Owner:** Claude (Cl). **Chat:** [Compare Lightroom 2025-26 with Atelier](https://claude.ai/code/project/chan_01Y9ueFJEbKyPqWn7CWQ5SGK?thread=cmsg_01Y9ueFJEbKyPqWn7CWQ5SGKQjWyjEX331a5FG3gyZMjyK). **Branch:** `claude/ai-denoise-pmrid`. **Baseline:** `8e7d0ab`. **Dependencies:** none (ONNX Runtime is already linked for Fine Edges).

**Evidence:** the comparison's gap 2. Atelier has only classic Luminance and Color noise reduction. Lightroom's Denoise runs a model on the demosaiced RAW (Apple Neural Engine on a Mac) and keeps the original.

**Model choice (Nov 15, 2026):** candidates had to be Apache 2.0 or MIT and small. Tried on Rosh's `DSC_0348.NEF` and `DSC_0358.NEF` (12 MP Nikon, 2011; crops in project files `denoise-at067/results/`):
- **PMRID** (Wang et al., "Practical Deep Raw Image Denoising on Mobile Devices", ECCV 2020, arXiv:2010.06935; megvii-research/PMRID, Apache 2.0): 1.03 M parameters, 4.1 MB ONNX, raw Bayer domain. Clearly cleanest on the noisy photo with fine detail kept; 1.8 s for 12 MP with ONNX Runtime on a cloud CPU. **Chosen, built in.**
- NAFNet-SIDD width 32 (MIT, 117 MB, sRGB domain): waxy, lifted blacks, streaks, 117 s on CPU. Rejected.
- RawNIND models: GPL-3.0. Excluded.
- On the clean photo (`DSC_0358`) neither changes much, as expected.

**How it gets the raw data:** Apple's RAW engine (CIRAWFilter) doesn't hand out the sensor mosaic. Instead the full-size, linear decode (no tone curve, no noise reduction) is sampled back onto a 2 × 2 R, G, G, B grid; each site keeps its own noise, so PMRID sees raw-like data. Its output is subtracted, spread back to every pixel with a small bilinear kernel. Checked in the cloud with rawpy on Rosh's NEF, including a one-pixel grid shift: works either way. The same path works for Nikon HE/HE* files that LibRaw can't read.

**As built (branch `claude/ai-denoise-pmrid`):**
- Panel: Detail > Noise Reduction gets **AI Denoise** (0–100, default 0) above Luminance, a standard `ParameterSlider` (double-click resets, click to type, group reset). A line under it shows **Finding the noise…** with a spinner the first time on a photo, then how long it took and whether Core ML or the CPU ran it, **works on RAW photos only** on other files, or why it failed (red).
- Pipeline (PRD step 1): `AIDenoise` (`Develop/AIDenoise.swift`). Per file and lens-profile setting, once: small linear and boosted decodes fit Apple's tone curve per channel; the full-size linear decode is read in strips into four planes; the noise is measured on the photo (Laplacian residual in 16 × 16 blocks, the flattest tenth per brightness bin, fitted as variance = a × level + b, so no per-camera calibration); PMRID runs on 512 × 512 tiles with a 32 px overlap after its k-sigma transform; what it removed at each site goes through the fitted tone curve and is spread to every pixel. The result is the photo's noise picture (half-float, about 190 MB for 24 MP, kept in memory, up to about 1.2 GB). A render subtracts Amount × that picture from the decode, before the camera match, scaled by how much each channel's average has changed since (White Balance, Exposure) and resized for smaller decodes. While AI Denoise is above 0 and the picture is ready, Apple's own luminance and color noise reduction are off.
- Background and export: the editor finds the picture in the background and shows the photo with Apple's noise reduction meanwhile (`AIDenoise.ready` renders again; `CorrectedKey` includes the Amount and whether the picture is in). Export, preview refresh and other one-off sessions wait for it. One photo at a time.
- Model: `Sources/AtelierCore/Models/PMRID.onnx` (4.1 MB, fixed 1 × 4 × 512 × 512 input for Core ML), with `PMRID-LICENSE.txt` and `PMRID-NOTICE.txt`; rebuilt reproducibly, without PyTorch, by `Scripts/models/convert_pmrid_onnx.py` (byte-identical, SHA-256 `2c76727c…`). ONNX Runtime with the Core ML execution provider (cached in Caches/Atelier/Models), checked once against the CPU on a test tile; the CPU is used if Core ML fails or disagrees. No `Float16` type, so Intel builds work.
- Agents: `ai_denoise` joins the Develop sliders that `adjust` sets (generated from `Parameter`, no catalog change).
- Old photos: the field is absent until set, so old catalogs, presets and history look the same; no `PreviewCache.version` bump.
- Help: Detail page, AI Denoise section, drawn slider and before/after (`make_help_images.py`, own random generator so other pictures don't change).
- Tests: `AIDenoiseTests` (half floats, mirroring, the noise measurement recovering known noise on three levels, the model removing most noise across tile edges on a 600 × 520 plane, the tone-curve fit, spreading, the noise picture drawn right side up, scaled and following Exposure, old settings, non-RAW no effect), `RenderCacheTests` and `DevelopTests` updated. `testARealRAWGetsLessNoisy` runs end to end on a NEF when `ATELIER_DENOISE_RAW` is set and writes crops to `ATELIER_SAMPLE_OUT`. The algorithm was checked in the cloud with a Python port on Rosh's NEF (same tiling, measurement, curve mapping); the Swift was not compiled.

**Known limits:** the first run on a 24 MP photo should take a few seconds (not measured on a Mac yet). The noise picture is kept in memory only, so it is found again after a relaunch (a disk cache can follow). A large Exposure or White Balance change after denoising scales the noise picture by the average color change, an approximation through Apple's tone curve. Apple's decode may sharpen or smooth before the mosaic is rebuilt; how much that costs is unmeasured. Non-RAW photos aren't denoised.

**Acceptance:** Mac build and tests (`AIDenoiseTests`, with `ATELIER_DENOISE_RAW=~/RoshProjects/Atelier/TestPhotos/Denoise/DSC_0348.NEF`); timing on a 24 MP Zf/Z6 NEF and a 45 MP NEF; Rosh at 100% on a high-ISO NEF: AI Denoise 50 and 100 against Luminance, then change Exposure and White Balance, export, and reopen.

## AT-068 — Masking: Sky, Background, Landscape, Color Range, Depth Range; more mask sliders

**Status:** Approved in steps (Rosh, Nov 15, 2026: "pick the next item from your found list", then chose **Color Range, then Background**; Sky and Depth Range later). Step 1, Color Range: PR #144, merged `a36e38a` (Rosh, Nov 15, 2026: "merge it"), a type-check fix from Rosh's Xcode build included; not yet tested by Rosh. Step 2, Select Background: PR #146, merged `dc313b1`, **not yet built or tested on a Mac**. Step 3, Hue, Moiré and Defringe mask sliders: PR #148, merged `ba06fec`. Step 4, mask Color Grading: PR #149, merged `5a9812a`. Step 5a, Depth Range: `claude/masking-depth-range` (Rosh chose "Both, Depth first", Nov 15, 2026). **Owner:** Claude (Cl). **Chat:** [Compare Lightroom 2025-26 with Atelier](https://claude.ai/code/project/chan_01Y9ueFJEbKyPqWn7CWQ5SGK?thread=cmsg_01Y9ueFJEbKyPqWn7CWQ5SGKQjWyjEX331a5FG3gyZMjyK). **Branch:** `claude/masking-color-range`. **Baseline:** `a9ba090`. **Dependencies:** AT-042 to AT-044 (selection masks, merged).

**Steps:**
1. **Color Range** (this branch): click, drag, ⇧ add (up to five), ⌥-click remove, Refine, markers and swatches, ⇧J. See the PRD's Masking section.
2. **Select Background** (`claude/masking-select-background`): its own part in New Mask / Add / Subtract and for agents (`add_mask` kind `background`); `Selection.background` (decodes false), rendered as the Vision subject inverted after the edge controls, Grow negated so it grows the background. Tests: `SelectBackgroundTests`. Help: masking.html#background.
3. **Hue, Moiré and Defringe mask sliders** (Rosh, Nov 15, 2026: "merge it and pick the next"; branch `claude/masking-more-sliders`): `LocalParameter.hue` (−180…180°, Oklab hue turn, kernel `atelierMaskHue`), `.moire` and `.defringe` (0…100, remove only) in `MaskSliders.swift`, applied in `applyLocal` (Defringe and Moiré first, Hue last). Agents set them through `add_mask` settings (`hue`, `moire`, `defringe`). Tests: `MaskSlidersTests`. Help: masking.html#adjust. **Not yet built or tested on a Mac.** Not done: Lightroom's negative Moiré/Defringe (protect), Use Fine Adjustment for Hue, mask Color Grading (16.0).
4. **Mask Color Grading** (Rosh, Nov 15, 2026: "merge it and pick the next"; branch `claude/masking-color-grading`): `Mask[grade:]` (Color Grading panel parameters, saved only when changed, key `grade`), rendered in `applyLocal` through the same color cube; `ColorGradingPanel`/`WheelBlock`/`ColorWheel` take a `GradeTarget` (`.photo` or `.mask(id)`) so the panel's wheels serve masks unchanged; `ColorLUT` keeps four cubes instead of one so the panel's and a mask's cube don't rebuild each other every frame. Agents: `add_mask` settings `grade_*`. Tests: `MaskColorGradingTests`. Help: masking.html#mask-grade. **Not yet built or tested on a Mac.** Left out: the panel's Preset menu, color picker and eye buttons in masks.
5. **Depth Range** (5a, branch `claude/masking-depth-range`), then **Sky and Landscape** (5b). Rosh chose "Both, Depth first" (Nov 15, 2026) from: Depth Anything V2 Small (Apache 2.0, 50 MB) for depth; EoMT-L on ADE20K (MIT code, third-party MIT weights, several hundred MB) for sky and landscape, both Settings downloads.
   - 5a as built: `DepthMap` (download pinned by revision and SHA-256, ONNX Runtime run, input with a 518-pixel short edge in multiples of 14, output spread to 0 near…1 far); `DevelopSettings.DepthRange` (From, To, Smoothness; picking); `atelierDepthRange` kernel; `DevelopSession.depthMap` (once per lens geometry, background while editing, guided-filtered to the photo's edges) and `depths(in:)` for picks; `DevelopController.pickDepthRange`; `DepthModelDownload` / `DepthModelGate`; Settings > AI row. Fine Edges' download moved into the shared `ModelDownload`. Agents: `add_mask` kind `depth`. Tests: `DepthRangeTests`, `AtelierEditToolsTests.testDepthMaskTakesARangeOfDepths`. Help: masking.html#depth (no before/after picture yet: the cloud can't run the model). **Not yet built or tested on a Mac.**
   - 5a merged in PR #150 (`8dd3891`, Rosh: "merge this first"); Rosh's first run hit ONNX Runtime's layer-norm fusion on the half-precision model, fixed in the same PR by loading with basic optimizations (untested).
   - 5b **Select Sky** (branch `claude/masking-sky-landscape`): no permissive ready-to-run scene model was found (NVIDIA SegFormer ADE20K ONNX files are non-commercial; EoMT/UperNet are MIT but PyTorch only; the MIT-tagged 176 MB U-2-Net sky ONNX is a re-upload whose author kept the weights private). Rosh chose "Sky from depth model, no Landscape" (Nov 15, 2026): `DepthMap.Field.sky` in SkyMask.swift (certain sky from the farthest depths touching the top, then the sky's colors band by band decide; first version, depth alone, took Rosh's Paris skyline and missed sky through the Eiffel Tower), `MaskComponent.Shape.sky(SkySelection)` with Grow / Refine Edge (60) / Feather, `DevelopSession.skyMask` / `findsSky`, `DevelopController.checkSky`, agents `add_mask` kind `sky`. Tests: `SelectSkyTests`, `AtelierEditToolsTests.testSkyMaskTakesTheEdgeControls`. Help: masking.html#sky. **Not yet built or tested on a Mac.**
   - Select Landscape: waits for a permissive scene model (or an ONNX export of an MIT one that Rosh agrees to host).

**Step 1 as built:** `DevelopSettings.ColorRange` / `ColorSample` (Masks.swift) with `weight(of:)`; the `atelierColorRange` Metal kernel and `colorRangeMask` in MaskRenderer.swift, run on the same source image as Select Subject; picking in ColorRangeMask.swift (`DevelopSession.colorSample`, read from `maskSourceImage`); `DevelopController.pickColorRange` / `removeColorSample` (one history step each: "Pick Color", "Add Color", "Remove Color"); `MaskOverlay` `.pickColor` / `.removeColor` actions with the eyedropper cursor; `AtelierAction.colorRange` (⇧J, `KeyAction.colorRange`). Tests: `ColorRangeMaskTests`. Help: masking.html#color, shortcuts.html. Layout snapshot `develop-masking-color-1280x800.png`. Not done: agents' `add_mask` has no color kind; XMP keeps it only inside Atelier's own settings (as other masks).

**Validation:** source only, in the cloud (no Swift toolchain). The mask and pick math was checked with a Python port (the help picture uses the same formula). Needs a Mac build, `swift test --filter ColorRangeMaskTests`, and Rosh's manual check.

**Evidence:** the comparison's gap 3. Atelier has Brush, Linear, Radial, Luminance Range, Select Subject, Select Object and Select People. Missing compared with Lightroom: Select Sky, Select Background (today only by inverting Subject), Select Landscape (with 15.0's snow), Color Range, Depth Range (16.0 estimates depth when the file has none). Mask sliders lack Hue, Moiré, Defringe and Color Grading (16.0). The selection plan's Brush Auto Mask (step 4) and SAM 2.1 clicks for Select Object (step 3) stay planned there.

**Questions to agree:** order (Color Range needs no model; Sky and Background may come from Vision or a small segmentation model; Depth Range needs a depth model with a permissive license), and which mask sliders first.

## AT-069 — Develop: Calibration panel

**Status:** Approved (Rosh, Nov 15, 2026: "pick the next", Calibration recommended on the decision card) / PR #147 merged `8198486` (Rosh: "merge it"), not yet built or accepted. **Owner:** Claude (project thread "Lightroom gaps"). **Branch:** `claude/develop-calibration`. **PR:** #147. **Dependencies:** camera-matched RAW look (PRD).

**Evidence:** the comparison's gap 4. The PRD listed Calibration as "Next" with no ID. Lightroom's Calibration has Shadows Tint and Red, Green and Blue Primary Hue and Saturation, and sits last in the panel stack with an on/off switch.

**As built:** seven parameters (`calibrationShadowsTint`, `calibration{Red,Green,Blue}{Hue,Sat}`) in a new `Panel.calibration` (last, with the shared switch, groups Shadows / Red / Green / Blue Primary, colored tracks). `Calibration.swift`: primaries turned around the gray axis in linear Rec. 2020 (±30°) and scaled from gray (±60%), one white-preserving 3 × 3 matrix; Shadows Tint green/magenta with a cube-root shadow weight, brightness kept; one Metal kernel. Applied first in `applyAdjustments` (after `corrected()`), so the corrected cache, mask source and Color Range are untouched and no `PreviewCache.version` bump is needed. Preset part `Calibration` (default on), agent `DevelopPart.calibration`; agents set the sliders through AdjustParameters `other` (e.g. `calibration_blue_sat=50`). Help page `calibration.html`.

**Validation:** Swift unbuilt (cloud); math checked with a Python port; `CalibrationTests` added. Needs a Mac build, `swift test` and Rosh's acceptance.

**Limits / later:** Lightroom's exact primaries math isn't published, so the same numbers won't give exactly Lightroom's result; the direction and rough strength match.

## AT-070 — Lens Blur, Adaptive presets and Panorama merge

**Status:** Proposed / discuss. **Owner:** unassigned. **Dependencies:** a depth source (AT-068's Depth Range) for Lens Blur; AT-068's Sky and Background masks for Adaptive presets; AT-054 (HDR bracket merge) for shared alignment code with Panorama.

**Evidence:** the comparison's gap 6. Lightroom has Lens Blur (AI depth, bokeh shapes, focus range), Adaptive presets (presets with Sky, Subject, Portrait or Landscape masks that adapt per photo) and Photo Merge > Panorama and HDR Panorama. Atelier presets can carry masks, but there are no adaptive packs. Panorama is PRD "Later".

**Questions to agree:** which first; each gets its own ID when picked.

## AT-071 — Cull: compare the suggested keeper and runner-up with linked zoom

**Status:** Proposed / discuss. **Owner:** unassigned. **Dependencies:** AT-059 (Pick By ranking), AT-060 (shared Cull zoom and pan).

**Why:** In a portrait burst or group shot, the choice often comes down to one blink, a small expression change, or slightly sharper eyes. Cull shows one large preview at a time, so checking the same detail means switching frames and comparing from memory. Seeing the two finalists together at the same magnification lets the photographer verify the suggestion and decide which frame to keep.

**Scope:** In the existing Cull view, compare the suggested keeper and the next-ranked frame from the same group under the active Pick By setting. Enable Compare for groups with at least two frames. Reuse the shared photo viewport so zooming or panning either preview updates both.

**Acceptance:** In both pre-import Cull and Show Cull Group, open Compare on a group with at least two frames. Zoom to 100% on a face and pan in either pane. Both panes follow at the same magnification and relative image position. Return to the single-photo view and verify that reviewing the pair preserved the current keep/drop choices. On a single-frame group, Compare is unavailable.

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

**Status:** Approved / ready — Rosh approved in the source chat; not implemented by this documentation PR. **Owner/chat/branch/PR:** unassigned. **Dependencies:** use AT-001 checks.

**Evidence:** `LibraryModel.swift` at `9ed894a` still calls `fatalError` on catalog-open failure (line 168). **Scope:** native “Couldn't Open Catalog” screen naming the path and reason, with Try Again / Show in Finder / Quit. Preserve files: no delete, replace, reset or automatic restore. Disable library commands until successful opening; avoid quit backup after failed opening.

**Acceptance:** tests for failure/retry/success, preserved files and command/backup gating; snapshot of the failure state inspected at the PR revision; Help and PRD updated. Recovery UI acceptance remains pending. Broader restore tooling belongs to AT-006/AT-012.

## AT-004 — Develop settings and masks in XMP recovery

**Status:** Proposed / discuss. **Owner/chat/branch/PR:** unassigned. **Dependencies:** agree portable format and compatibility policy before coding; coordinate AT-005.

**Evidence:** review §3.3, unchanged source baseline: XMPFields stores metadata, while Develop settings/masks are catalog JSON. **Scope to discuss:** versioned Develop/mask sidecar round trip, preserving foreign tags and old catalogs; RAW+JPEG same-stem behavior. Keep history, relationships and provenance separate (AT-005).

**Acceptance to agree:** recover settings/masks after catalog loss, old/new sidecar compatibility, unknown tags preserved, paired-file conflict fixtures, unchanged originals and equivalent rendered results. No full-catalog recovery claim from this work alone.

## AT-005 — History, relationships and provenance recovery

**Status:** Proposed / discuss. **Owner/chat/branch/PR:** unassigned. **Dependencies:** AT-004 format boundary; AT-007 provenance requirements.

**Evidence:** review §3.3: SQLite holds history, version/stack/virtual-copy relationships and AI provenance; portable reconstruction is incomplete. **Scope to discuss:** a documented backup/restore representation distinct from settings/masks; identity and conflict policy.

**Acceptance to agree:** restore history, parent/derived relationships, virtual copies and provenance with missing-file/duplicate fixtures. Document what cannot be recovered and which original/derived files require separate backups.

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

**Acceptance to agree:** selected feature has a PRD scope, output/interoperability fixtures, Help and runtime acceptance. Preserve one Processor contract and backend order; explicitly defer the other capabilities.

## AT-016 — Track this list and the working agreement

**Status:** In progress — documentation only, authorized by Rosh. **Owner:** Co. **Chat:** [this documentation chat](codex://threads/01a18eb2-5536-7c20-bd4b-3e8b8f528f14). **Branch:** `codex/backlog-working-agreement`. **PR:** [#63](https://github.com/roshan-davis/atelier/pull/63). **Dependencies:** none.

**Scope:** establish this list and AGENTS.md rules for keeping status/evidence current, bounded approved work, one App-project Codex chat per PR and no merges without instruction.

**Acceptance:** `python3 Scripts/check_pr.py` passed on full Xcode at base `9ed894a` plus the staged documentation (206 tests, 2 missing-RAW skips, zero failures); logs under `.build/local-checks/20261030-142918-754419/`. The final PR validation records the follow-up check and CI status. No app behavior, product decision, Help, rendering or UI changes; implementation of AT-003 and all proposals is deferred to separate scoped PRs. Mark Done only after merge.

## AT-017 — Local-check false failure on clean untracked files

**Status:** Proposed / discuss. **Owner/chat/branch/PR:** unassigned. **Dependencies:** AT-001; keep any runner fix in a separate PR.

**Evidence:** this documentation work at `9ed894a` reproduced `whitespace-new-1: FAIL (exit 1)` for clean untracked BACKLOG.md with an empty diagnostic log. `git diff --no-index --check` returns 1 for the new-file difference. PR #62's body describes a normalization fix and seven regressions, but its merged diff contains only six Swift test files; current runner does not normalize this case.

**Scope/acceptance to agree:** normalize only clean new-file differences while preserving actual whitespace/errors as failures; regression coverage for both. Staging the documentation avoids this case for this PR without changing the runner. Initial restricted build also failed on cache permissions, a separate environment issue; fresh check results belong in this PR's validation.

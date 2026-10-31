# AT-021: one Processor host, with HDR Merge as the first plugin

**Discussion draft, October 30, 2026.** Requested by Rosh as a priority override. Source baseline: `8700f853bb9d5d06c906e9d8800b5137b5581a33`. This proposes architecture, not permission to implement it. The PRD remains authoritative. No runtime, HDR algorithm, license policy, schema migration or UI is changed by this document.

## Recommendation and decisions needed

Use one Core Processor host to prepare inputs, run an adapter, validate results and register derived files. Desktop editors, CLI/HTTP plugins and AI backends implement that same contract; their lifecycle capabilities differ. Preserve existing Edit In and ComfyUI behavior while moving one responsibility at a time. Do not introduce a separate HDR pipeline into the catalog or a general controller rewrite.

Before implementation, agree these product decisions:

1. **Inputs:** extend the PRD's single rendered-image contract to ordered, typed inputs, including read-only original copies and scene-linear float images. HDR cannot satisfy linear RAW merging by receiving today's developed TIFFs. This is a proposed PRD change, not an interpretation of existing approval.
2. **UI ownership:** keep all in-app controls native and host-owned, including an HDR-specific preview dialog. Plugins supply parameter schemas and preview artifacts, not executable SwiftUI, HTML or injected views. The backlog's “own dialog” would mean a host dialog described by the plugin. An independently opened desktop app remains Edit In. Arbitrary plugin-owned embedded UI would need a separate proposal and conflicts with today's headless-plugin/host-owned-AI UX.
3. **Security:** require a demonstrated constrained execution boundary before enabling third-party executable plugins. A child process alone is crash isolation, not a sandbox. A trusted developer-only harness can precede this, but must not ship advertised as safe plugin execution.
4. **HDR scope:** approve an evaluation spike before choosing decoder, merger or output format. Prefer scene-linear float TIFF as the first interoperability candidate, with DNG evaluated alongside it; neither is a verified Atelier HDR output today. Do not promise mosaic-RAW editing, Lightroom-equivalent deghosting or ±10 EV until the complete path passes fixtures.
5. **First implementation slice:** AT-008 host contract and a fake adapter plus compatibility tests, then migrate Edit In and ComfyUI separately. Discovery and HDR follow those gates. Batch grouping, automatic Nikon bracket detection and durable offline queues remain later slices.

## What exists, and what must remain

Paths below are relative to the repository at the baseline revision.

| Concern | Verified source behavior | Design consequence |
| --- | --- | --- |
| Edit In | `Sources/AtelierApp/EditIn.swift`, `LibraryModel.editIn`: detached sequential preparation, `Exporter.export`, `Importer.addStacked`, then `NSWorkspace.open`; per-photo problems; existing external edits reopen directly | Preserve TIFF/JPEG, per-app color/develop options, selection and partial success; opening an editor is a handoff, not a completed pixel computation |
| Live edits | Same file, `EditWatcher`: watches directories, debounces saves, checks modification time; `editedFileChanged` refreshes catalog and previews | A registered editable artifact has an ongoing observation lifecycle after the preparation job ends; cancel must not close another app or delete a registered edit |
| AI | `Sources/AtelierCore/AI/AIRunner.swift`, `run`: render full developed sRGB TIFF, crop/mask/resize, upload, queue ComfyUI, monitor, download, composite, write TIFF, record provenance, `addStacked` | Keep recipe pixel operations together initially; extract preparation/publication at seams, not duplicate the runner in a new host |
| AI control | `Sources/AtelierApp/AIController.swift`, `generate/cancel`: one detached Task, phase/fraction/error UI, select result; `ComfyProgress.swift` learns node timing | Common events must preserve optional/estimated fractions and “Cancelling…”; do not invent a percentage when disconnected |
| Cancellation | `ComfyClient.outputs` checks cancellation while polling, defaults to 900 s timeout; `interrupt` POST stops whatever the server runs | Declare server-wide cancellation honestly; do not claim prompt-scoped cancellation or safely run competing Atelier jobs on that server without further API work |
| Output | `Sources/AtelierCore/Catalog/Catalog+Stacks.swift`, `addStacked`: imports then separately stacks; `Catalog.stack` copies catalog metadata/collections/import entries; `DerivedFiles.folder` chooses source folder or managed Edits | Reuse these semantics, but publication needs idempotency/reconciliation because import + stack + filesystem writes are not one atomic transaction |
| Relationships | `PhotoVersion` records one parent and optional provenance JSON | Many HDR sources and optional visual stack membership cannot be represented merely by repeating today's single-parent call; coordinate AT-005b/c and AT-007 before migrations |
| Precision | `Exporter.swift` renders TIFF as `.RGBA16`, other formats `.RGBA8`; `AIRunner.write` can widen generated samples to 16 bits | Neither path proves scene-linear float retention or creates lost precision; precision metadata must distinguish container from effective source precision |
| Develop | `DevelopRenderer.swift`: extended-linear Rec.2020 working space, half-float context, display conversions to 8-bit, RAW/non-RAW branches; non-RAW positive exposure uses `ExposureRolloff`; `DevelopSettings.Parameter.range` gives Exposure −5…5 | A float encoder alone does not establish an HDR editing path; test decode, pipeline clamps/rolloff, previews and export before offering extended exposure |
| Commands/settings | `AtelierApp.swift` Photo menu and `PhotoMenu.swift` context menu are separate builders; `SettingsView.swift` has Edit In/AI tabs; editors and AI settings use defaults | A shared contribution model must feed both menu builders and `KeyBindings`; retain existing defaults keys during migration |

There is no concrete shared Processor protocol/host in these inspected paths. README's contract wording describes the intended architecture, not completed orchestration. No durable common job queue was found in these flows.

## Responsibilities and one execution path

```text
Photo commands / Edit In / AI panel / HDR dialog
                ↓ same submission API
ProcessorHost (Core)
  preflight → immutable request + staged inputs → adapter
  events/cancel ← adapter → candidate outputs
  validate → publish/reconcile → catalog relationships → previews/UI event
                ↓ one adapter interface
DesktopAppAdapter | CLIAdapter | HTTPAdapter | ComfyAdapter
                                      later: CoreMLAdapter | MLXAdapter
```

Proposed Core files are small units under `AtelierCore/Processors`: contract types, host/state machine, registry/manifest validation, input preparation, output publication, adapters and journal. App code owns native presentation, `NSWorkspace` launching/watching bridge, settings and command routing. Core never depends on AppKit UI. Adapters cannot import into the catalog or select photos. AI recipe preparation/compositing stays a Core service called by its adapter. Export remains available independently and is reused where its rendered output is appropriate.

Conceptual types (not final Swift API):

| Type | Essential fields/meaning |
| --- | --- |
| `ProcessorDescriptor` | stable reverse-domain ID, plugin version, protocol major/minor range, operations, transport, dependencies, permissions, UI schema, licenses and capabilities |
| `ProcessorRequest` | protocol version, UUID job/attempt IDs, operation, immutable ordered source references, reference input ID, settings snapshot + schema version, typed parameters, masks/references, requested output contract and publication policy |
| `InputArtifact` | job-local opaque ID/location, role, original/rendered/linear representation, content hash, dimensions/orientation, integer/float sample type and bits, effective precision if known, color profile/transfer function, exposure time/ISO/aperture/bias with explicit unknowns, decode/profile version and applied-settings identity |
| `ProcessorEvent` | job/attempt ID, monotonically increasing sequence, stage, bounded optional fraction + estimated flag, warning, preview artifact or terminal outcome; no UI objects |
| `ProcessorResult` | candidate artifacts with roles, detected/claimed pixel metadata, reference/source mapping, operation details, dependency versions and provenance declarations; interactive handoff is a distinct outcome |
| `ProcessorFailure` | stable code, affected input IDs, readable reason/recovery action, retriable flag and bounded diagnostics; preserve underlying error in logs without tokens/prompts by default |

One adapter operation starts a request, emits events, and returns an outcome; cancellation uses the same job handle/token. Manifest capabilities describe cardinality, representations, previews, cancellation scope, interactive handoff and reconnect support. The host rejects unsupported combinations before rendering or launching. No “fallback” silently changes precision, color, originals availability or model. AI order stays ComfyUI → Core ML → MLX, no bundled models or worker environments; adding an adapter does not implement backend selection automatically.

## Discovery, manifest and transports

Propose user-installed folders in `~/Library/Application Support/Atelier/Processors`, plus internally registered adapters for current editors and AI recipes. Scan only manifests, without executing code; no recursive search of arbitrary folders. Invalid/incompatible/duplicate IDs remain visible with a reason and cannot run. Disable removes commands and prevents new runs; offer cancellation for active jobs, retain results and settings. Changed package identity/permissions requires reapproval; pin an active job to its exact installed version. Do not replace an executable underneath a run.

A manifest uses `manifestVersion: 1`, plugin ID/name/version/publisher, supported host protocol range, macOS/arm64 minimums, operations, relative executable + argument array **or** endpoint, parameter schema, input/output capabilities, menu contribution IDs, permissions, dependency probes and license/notice references. Reject absolute executable paths, package escapes, duplicate operation IDs, unsupported mandatory features and unknown major versions. Minor additions are optional/negotiated; versioned schema migrations never reinterpret saved parameters silently. Bound manifest/schema size, nesting and control counts. No remote schema references, executable validators or shell fragments.

CLI: launch directly with argument arrays and a minimal environment, never through a shell. Newline-delimited JSON over stdin/stdout; stderr is bounded diagnostics. Handshake negotiates protocol/capabilities before `start`; events carry job/attempt/sequence; a single `complete`, `failed` or `cancelled` ends the attempt. Malformed/oversized events, EOF, duplicate terminal messages or nonzero exit fail the job. Drain both pipes concurrently to avoid deadlock. Exit zero without a valid result is failure. A `cancel` message gets a bounded grace period, then termination of the owned worker/process group, never another user's process.

HTTP: same logical request/event/result schema via an adapter, using create/status/cancel/result resources with an idempotency key; negotiated polling or event stream, bounded timeouts and downloads. The server owns remote job IDs. Local paths are valid only for an explicitly negotiated shared workspace; other endpoints receive uploaded bytes and opaque artifact IDs. Disallow arbitrary result URLs/redirects outside the configured endpoint policy. Store credentials in Keychain, not manifests/journals. Generic remote HTTP is a later PRD capability; do not broaden today's ComfyUI server access as part of discovery.

## Native UX and menu boundaries

Settings > Processors is proposed: name/version, enabled state, compatibility, execution location, dependency/trust status, permissions, Reveal Package, diagnostics; existing Edit In and AI configuration remain where they are. No automatic downloads, package-manager execution or model installation. Installation checks can report what is missing without executing arbitrary dependency probes before trust.

Support a deliberately small form schema: booleans, bounded numbers, enum choices, text, host photo/file pickers, groups, defaults and visibility rules. Reuse `SliderRow`/`DevelopSlider`, `GroupHeading`, pickers, cursors, themes, help and history conventions. Arbitrary JSON Schema does not map automatically to a polished form; unsupported controls fail validation. HDR preview uses a host-provided specialized presentation ID after approval, with a shared photo viewport, not a second zoom state. Preview jobs carry settings revisions; stale previews are discarded and never registered.

Menu contributions are declarative operation IDs under host-approved Photo submenus (HDR: proposed Photo > Photo Merge > HDR…). No arbitrary top-level menus, selectors or code. The host computes availability from current target IDs/RAW+JPEG grouping, cardinality, permissions and original availability. Both main and right-click menus use the same descriptors; keyboard shortcuts go through `KeyBindings`, conflict checked. Job completion never steals focus if the user has moved elsewhere. Exact layout and key choices need mockup/snapshot and Rosh acceptance later.

## Trust, originals and publication

Plugins receive staged copies, never writable original paths, catalog databases, library roots or credentials. No hard links to originals. Canonicalize paths, reject traversal/symlinks and package escapes; use private per-job directories and exclusive output creation. The host publishes only regular validated files inside the job output directory, with size/dimension/count limits, supported decode, finite pixel values where required, expected format/profile and hashes. Claimed metadata is not trusted. Require output files to be closed/stable before publication. Plugins cannot choose an arbitrary final destination.

This prevents accidental mutation through the protocol, but an unrestricted executable can still access the user's files. README explicitly lists App Sandbox as unbuilt. Apple's sandbox inheritance is tied to actual signed entitlements, not the `Process` API. A separate security spike must prove a signed constrained worker/XPC arrangement can run installed arm64 plugins with only staged input access and declared network/dependency rights on macOS 15+. Test denials against originals/catalog/home/network, not just manifest declarations. If that cannot be demonstrated, stop third-party CLI release and discuss trusted-only limitations with Rosh; do not quietly weaken the PRD sandbox requirement. HTTP server trust and desktop app file access are separate, explicit boundaries.

Publication reserves unique names using existing destination rules, validates before promotion, and records a host-generated job→result receipt. A small durable journal tracks validated/promoted/registered states. On failure, retain recoverable outputs with a visible location/action, reconcile rather than duplicate catalog entries, and never remove a registered artifact on cancellation. Import and relationship updates need an idempotent catalog operation/new migration when approved; `addStacked` today is not an atomic multi-output commit. “Create Stack” is presentation policy independent of the required provenance edges. Reference metadata is inherited explicitly; other bracket metadata is preserved in provenance, not falsely copied as one exposure.

## Jobs, cancellation and restart

State machine: preflight → preparing → running (or handedOff for apps) → validating → publishing → completed. Fail/cancel may occur before completion; cancelRequested remains visible until acknowledged or the worker stops. Terminal state occurs once. Check cancellation between preparation steps and immediately before publication; the publication boundary decides whether the result is committed, and reports that fact instead of claiming cancellation removed a completed result.

Start with one expensive plugin job at a time, background work and bounded event delivery; concurrency limits need measurement before expansion. Host previews are cancellable/coalesced, with no render per slider event. Heartbeats distinguish a stalled worker from slow determinate work; lack of progress alone is not proof of failure. Logs are capped and private. A worker crash/timeout produces a per-job error and leaves originals unchanged; a process boundary does not guarantee protection from system-wide memory exhaustion, so memory/disk/large-image stress tests remain necessary.

On relaunch, unfinished jobs are interrupted, not auto-rerun. Reconcile publication receipts first; offer retry with the same immutable request and a new attempt. Remote reattach requires a supported status API and persisted server job ID; do not assume a request failed because the network disconnected. No automatic repeated upload/merge after an ambiguous timeout. Edit In observation resumes through existing catalog/watch behavior. Durable offline waiting, scheduling/reconnect UX and smart previews belong to AT-009; first slice retains current explicit offline errors.

## HDR Merge worked example and feasibility gates

Select two or more explicit bracket photos. Resolve grouped RAW+JPEG to RAW once, preserve input order and choose a documented reference (proposed middle exposure, user-overridable). Preflight dimensions/orientation, camera/lens metadata, exposure data and available originals. Reject mixed RAW/JPEG and unsupported dimensions for the first slice with actionable reasons; do not silently discard frames or infer exposure from bias alone. Bracket auto-detection by capture time/bias is a later convenience needing Nikon Zf/Z6 fixtures, not a prerequisite for explicit selection.

The host supplies staged originals for a qualified decoder, or a specified scene-linear demosaiced float representation after a separately validated RAW preparation stage. Scene-linear RGB is not untouched sensor mosaic data. Agree whether that satisfies the desired “RAW merge” promise before building; otherwise require a qualified RAW merger. Today's `Exporter(develop: false)` still runs a renderer with neutral settings and writes integer TIFF: it is not this contract.

Proposed HDR parameters: Auto Align, Auto Settings, Deghost None/Low/Medium/High, Show Deghost Overlay and Create Stack. Align and deghost affect merge pixels; overlay is a preview artifact; stack is host publication policy. Auto Settings should create reversible initial Develop settings, not bake tone mapping into the float master. Preview and final must share algorithm/parameter semantics; low-resolution preview differences must be identified. Cancel discards unpublished candidates. Headless “last settings” uses the same operation/request without presentation; multi-group batch comes later.

| Choice | Verified from primary documentation | Proposed evaluation / limitation |
| --- | --- | --- |
| Lightroom reference | Adobe documents bracket selection, alignment for camera movement, four deghost levels/overlay, stack and DNG output [1] | UX reference only; no claim to Adobe's algorithm or SDK merger |
| OpenCV | Official tutorial separates Debevec/Robertson float HDR from Mertens low-dynamic-range exposure fusion [2]; AlignMTB exposes shift-based alignment [3] | Useful baseline for experiments; tutorial uses 8-bit input + exposure times, not a ready RAW merger or documented Lightroom-style deghost engine. Translation alignment alone is insufficient for all handheld parallax/rotation |
| Float TIFF | Apple's API accepts a CIFormat and compatible RGB/monochrome color space [4]; installed Xcode SDK `CIContext.h` confirms writer API | First format probe: write `.RGBAf` test values above 1, below 0 and fractional values; inspect TIFF tags, round-trip values/profile/metadata and test Develop/export. API existence does not verify encoder precision or end-to-end support |
| DNG | Adobe provides specification and a reading/writing SDK [5] | Obtain exact SDK terms/notices, evaluate build/distribution/dependencies and float linear-DNG tags, validate with independent readers. Download availability is not a license audit or proof of working HDR output |
| OpenEXR | Format defines half/float channels and color/chromaticity attributes [6] | Strong interchange candidate, but encoder/dependency, EXIF/XMP carriage, import/Develop/preview support need proof. A UTType or read capability does not prove native writing |

Recommend the next HDR spike compare an established RAW-capable merger with a linear-RGB approach; require named versions/licenses and reproducible fixtures before selecting either. No HDR math or dependency adoption is authorized here. Separate software/dependency licensing from model/output-use licensing: AT-007 owns the latter. A plugin manifest's license string cannot approve website/shop use.

HDR acceptance fixtures: tripod and handheld Nikon Zf/Z6 brackets, foliage/person movement, clipping in every frame, repeated/unknown exposure, mixed orientation/dimensions, RAW+JPEG grouping, offline sources and read-only source folder. Measure time/peak memory and alignment/ghosting crops on this Mac, recording exact revisions. Verify unaltered originals, values outside SDR retained through save/reopen/Develop/export, no false precision claims, metadata/reference correctness, reversible Auto Settings and no duplicate registration after crash. Any ±10 EV range must be an approved shared parameter change with backward-compatible settings, rendering tests and `PreviewCache.version` bump if rendered behavior changes. HDR radiance preservation and HDR display/gain-map export are separate features.

## Bounded delivery plan and acceptance

Each implementation phase requires its own scoped approval/PR/chat. Passing tests does not supply Rosh's product acceptance.

| Phase | Scope | Gate |
| --- | --- | --- |
| 0 — this design | Architecture, current-source evidence, decisions and dependencies | Rosh agrees input/UI/security boundaries and first slice; no runtime changes |
| 1 — AT-008 foundation | Types, state machine, fake adapter, one-output publication receipt; no new plugin UI | Tests: cancel at every boundary, malformed result, duplicate completion, import/stack failure and crash/restart reconciliation; unchanged existing workflows |
| 2a — Edit In adapter | Route existing editor preparation/handoff through host; retain defaults/watchers/reopen behavior | Actual TIFF/JPEG round trips, existing edit reopen, multi-photo partial failure, saves/relaunch; before/after compatibility fixtures |
| 2b — ComfyUI adapter | Reuse AIRunner services behind host, move catalog publication out once | Existing three recipes, brush compositing, timing progress, cancel scope, server errors/unknown license declarations preserved; live server tests with authorized UI checks |
| 3 — safe plugin host | Manifest registry, constrained CLI execution, forms/commands and transport conformance | Security denial tests, install/version/disable tests, native UX review, invalid/crashing worker tests; HTTP adapter conformance before generic endpoint release |
| 4 — HDR feasibility | Disposable non-UI fixture spike, decoder/align/deghost and float-format comparison | Exact license/dependency review and numerical/interoperability evidence; Rosh chooses actual HDR scope |
| 5 — HDR first plugin | Explicit bracket selection, host preview, approved merge engine, one result | Real camera/image acceptance, restart/provenance/stack fixtures, Help + PRD + latest-head snapshots; automatic grouping/batch deferred |

Dependencies: **AT-005b** portable many-source relationships/stack recovery; **AT-005c** provenance recovery envelope; **AT-007** identity, hashes, workflow/dependency/model records and agreed license enforcement; **AT-008** incremental host migration; **AT-009** durable queues/offline/reconnect. Design reserves these seams without implementing their policy. Provenance should eventually identify all source hashes, reference frame, decode/merge versions, settings and dependency identities; current IDs/JSON alone do not guarantee reproducibility. Existing experimental/permissive restrictions remain binding and ComfyUI → Core ML → MLX order remains unchanged.

Future runtime validation also covers every contributing main/context menu (grid, Loupe, Develop, Filmstrip), Settings > Edit In/AI/Processors, all three AI recipes, output selection/previews, external saves and restart. If the HDR preview adds photo interactions, test click/drag/handles/hover, Space-drag, scroll/pinch/⌘-scroll, zoom buttons, Navigator and keys through the shared viewport. Desktop/UI testing requires fresh explicit permission from Rosh. This documentation performs none.

## Primary research (accessed October 30, 2026)

1. [Adobe: HDR photo merge](https://helpx.adobe.com/lightroom-classic/desktop/process-and-develop-photos/hdr-photo-merge.html).
2. [OpenCV: High Dynamic Range tutorial](https://docs.opencv.org/4.13.0/d2/df0/tutorial_py_hdr.html).
3. [OpenCV: AlignMTB API](https://docs.opencv.org/4.1.0/d7/db6/classcv_1_1AlignMTB.html). Version-specific reference; selected implementation must be pinned and rechecked.
4. [Apple: writeTIFFRepresentation](https://developer.apple.com/documentation/coreimage/cicontext/writetiffrepresentation(of:to:format:colorspace:options:)). Also inspected installed macOS SDK header; no encoder execution in this design.
5. [Adobe: DNG specification and SDK resources](https://helpx.adobe.com/camera-raw/desktop/dng-and-file-formats/digital-negative.html). Exact SDK archive/license not audited in this phase.
6. [OpenEXR: Technical Introduction](https://openexr.com/en/latest/TechnicalIntroduction.html).
7. [Apple: Enabling App Sandbox / inheritance](https://developer.apple.com/library/archive/documentation/Miscellaneous/Reference/EntitlementKeyReference/Chapters/EnablingAppSandbox.html) and [accessing files from the macOS App Sandbox](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox). Architecture constraints; isolation feasibility still requires a signed implementation spike.

# AT-021a — HDR image and project feasibility

October 30, 2026. Codex, [chat](codex://threads/01a19033-f20a-7f32-b35e-1306ed4e21b3), branch `codex/at-021a-hdr-feasibility`. Baseline: fetched `9b684c2dcf316c517d7b7af2ff16df79b2790890`, the merged design PR #69. This is a disposable feasibility probe; no app product, renderer, catalog migration, or live Processor adapter is added. The PRD remains authoritative.

## Finding and gate

Apple RAW decode with explicit tone processing disabled is a viable **candidate** for the next experiment: two real Nikon inputs retain values above 1 and show the expected −1 EV scaling in midtones. Float TIFF and profiled unsigned 16-bit tone-mapped TIFF work numerically. A simple radiance merger succeeds on known synthetic exposures. **The bracket path is not qualified:** no confirmed real bracket fixture was found, and naïve Vision alignment fails a clipped cross-exposure test. Do not start the full bracket editor on this evidence alone. Rosh subsequently clarified that single-image creative HDR was the main MachineryHDR use case, describing its use of three internally generated exposures. Prioritize qualification of that single-image path; real-bracket alignment is a gate for bracket support, not a prerequisite for single-image creative editing. The reported Machinery internals are user experience/context, not independently verified proprietary implementation details.

Project-owned source copies plus immutable save generations and an atomic receipt are a workable filesystem model. Five executable model tests pass, including re-edit identity and duplicate handling. This is **not** proof of NSWorkspace document delivery, a signed app, a real database transaction, power-loss durability, or desktop crash/relaunch. Those remain explicit gates.

## Reproducible evidence

Machine: Apple M4 Pro, 48 GB, macOS 26.0.1 (25A362), Xcode Swift 6.2.4. Apple RAW decoder version `8` for both files. No third-party HDR dependency installed. Exact probe contents are recorded in [probe-sha256.txt](Evidence/AT-021a/probe-sha256.txt); those hashes identify the measured source independently of documentation commits. [Numerical report](Evidence/AT-021a/image-report.json), [process timing/memory](Evidence/AT-021a/time.txt), [protocol tests](Evidence/AT-021a/project-tests.txt). Final-head build/test evidence belongs in the PR; these are separate measurements.

Local media and disposable output are deliberately not committed. Output from the recorded run: `/private/tmp/at021a-recorded-images`; original-source hashes are in the report. The probe copies originals to a **new** output directory, checks copy and original SHA-256 after processing, and never writes originals. It refuses an existing directory. Inventory reads metadata only, skipping hidden staging folders. Image inspection was subsequently explicitly authorized by Rosh and completed for the three generated outputs and two camera-embedded previews; no app/window/desktop interaction was performed. This limited inspection is not product visual acceptance.

```sh
# From this task worktree; output path must not already exist.
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swiftc -O \
  -module-cache-path /private/tmp/hdr-module-cache Scripts/hdr/image_probe.swift \
  -o /private/tmp/hdr-image-probe
/usr/bin/time -l /private/tmp/hdr-image-probe /private/tmp/hdr-new-output \
  '/path/to/disposable-or-readable-Nikon-Zf.NEF' '/path/to/Nikon-Z6II.NEF'
python3 Scripts/hdr/project_probe.py
# Metadata-only inventory, optional (contains local paths; keep private):
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift \
  -module-cache-path /private/tmp/hdr-module-cache Scripts/hdr/inventory.swift \
  '/path/to/photo/folder' /private/tmp/hdr-inventory.json
```

Native Core Image/Vision access was required: restricted execution failed the TIFF write with `Foundation._GenericObjCError.nilError`; rerunning the same probe with native service access succeeded. Compilation itself needs a writable module cache. Early probe attempts also exposed an incorrect expected vertical sign; corrected expectation is the inverse known shift `(−7,+5)`. The final probe records, rather than hides, the +2 EV failure. Numerical checks are assertions; expected candidate failures are report values.

### Fixture availability

Metadata inventory of the visible `Pictures/Atelier Library` tree found 776 NEFs: 702 Nikon Z f and 74 Nikon Z 6_2. A conservative search for three distinct shutter times within four seconds at identical aperture and ISO found zero triplets. This does not establish that no brackets exist elsewhere or with wider spacing. A known bracket folder was requested. No unrelated photos were declared to be a bracket, and no synthetic exposure is presented as captured RAW evidence.

Two single-image files, `_RZF0632.NEF` (6048 × 4032) and `Z62_0210.NEF` (6048 × 4024), were processed from disposable byte copies. These are real camera inputs, not a calibrated color chart or clipped-highlight reference scene. Hashes in the report establish the exact files; later runs must use those hashes to claim the same fixtures.

### RAW preparation and color

Do **not** use `DevelopRenderer.image(with: .neutral)` as a scene-linear input. Source inspection at the baseline: its RAW filter leaves `boostAmount` at 1 and applies the camera match unless Apple Neutral is selected. Later lens/transform/adjustment processing also belongs to Develop, not neutral bracket preparation. “Apple Neutral” alone does not disable RAW's global curve. This spike bypasses the renderer; no existing photo look or preview cache version changes.

Probe settings: `boostAmount = 0`, `baselineExposure = 0`, `shadowBias = 0`, gamut mapping off; supported local tone map, lens correction, luminance/chroma noise reduction, sharpness, contrast and detail set to zero/off. EDR amount 2; native/as-shot WB retained, its values recorded. Working/output master space: extended-linear sRGB, float32 RGBA context and samples. This is demosaiced, white-balanced, camera-converted RGB, **not sensor mosaic or a claim of spectrally accurate scene radiance**. Colorimetric calibration and macOS 15 behavior remain untested. For brackets, lock a common reference white balance and decode parameters; do not normalize each frame independently. Handle orientation before registration and reject mismatched dimensions until explicitly supported.

Both sampled files defaulted to baseline exposure ~0.35, boost 1, shadow bias 3, EDR 0. With the probe configuration:

| Measurement | Z f | Z6 II |
| --- | ---: | ---: |
| 1024-long-edge proxy maximum RGB | 1.81685 | 2.19226 |
| −1 EV / 0 EV median ratio, RGB samples 0.01–0.8 | 0.5 | 0.5 |
| p99 absolute error against half-value | 2.98e−8 | 2.98e−8 |
| Profiled 16-bit proxy roundtrip maximum linear error | 1.12e−5 | 1.19e−5 |
| Proxy decode, recorded warm run | 0.091 s | 0.093 s |
| Full-resolution float TIFF decode/write | 0.282 s | 0.325 s |
| Full float TIFF size | 390,203,646 B | 389,429,412 B |

This proves numeric exposure response in selected midtones, retained out-of-display-white values and TIFF roundtrip for these files/settings. It does not prove recovery of sensor-clipped highlights, hue accuracy under saturation, superior RAW quality, usable moving-subject merge, or photographic appearance. Default highlight recovery was left at the OS behavior (its explicit switch is newer than the macOS 15 minimum); decoder/OS must be recorded in projects and requalification is required across versions.

### Merge and output

Synthetic 512 × 256 scene: RGB ratios 1 : 0.6 : 0.3, radiance ramp across 12 stops up to 8. Exposures 1/16, 1/4, 1, clipped at 1. Weighted merge divides each sample by its exposure scale, excludes frames with **any** RGB channel ≥0.98 or maximum ≤0.001, and weights by distance from the endpoints. It needs a defined shortest-exposure fallback; zero fallback pixels were needed here. Maximum error against ground truth: 4.77e−7. This is a basic known-linear-data proof, not a camera response estimator or deghosting algorithm. ISO/aperture changes, absent/incorrect exposure metadata, moving objects, all-frames-clipped regions and real noise need separate rejection/quality tests.

Luminance compression uses one common RGB gain `0.65 / (1 + Y)` (linear sRGB luminance weights), not independent channel curves. It preserves RGB ratios before display gamut conversion. Tone-mapped TIFF: 16 bits/component, sRGB IEC61966-2.1, 3144-byte ICC profile, max linear roundtrip error 1.52e−5. This was an actual encode → ImageIO decode → linear float comparison, not a filename/depth assertion. Float TIFF retained the synthetic maximum 8 with zero measured error. Float output is probe evidence only; first product return remains tone-mapped profiled 16-bit TIFF. The exposure merge/master must not be stored solely as that rendered output.

The two real proxies also produced profiled 16-bit TIFFs and passed numeric roundtrip. Full-resolution real files were written as float TIFF to force complete native decode; full-resolution real tone-mapped output and independent reader verification remain pending. Authorized proxy comparison against the two camera-embedded previews found both outputs visibly too dark: the fixed `0.65 / (1 + Y)` compression is a numeric encoding probe, not an acceptable initial look. The Z6 II motion blur is also present in its embedded preview. The synthetic gradient appears smooth at the inspected size; this does not establish full-precision banding or calibrated color performance. No conclusion about recovered highlight detail is possible from this comparison alone. Wide-gamut/negative colors, gamut mapping, EXIF orientation and metadata policy need explicit fixture cases; the sRGB probe does not qualify ProPhoto/P3 output. Do not copy reference shutter/aperture/ISO as if a merged TIFF were one capture.

### Alignment: important failed candidate

Seeded blurred texture, 512², known translation `(7,−5)`; Vision `VNTranslationalImageRegistrationRequest`:

| Rendered target | Measured inverse shift | Pixel error | Time |
| --- | --- | ---: | ---: |
| Same exposure | −7,+5 | 0 | 0.0040 s |
| +2 EV, then clipped to display CGImage | +18,−177 | 183.71 | 0.0021 s |

The second target loses much of its texture through clipping; this is intentionally an adverse case. It disqualifies feeding naïvely rendered bracket previews straight to Vision without checks. Translation also cannot correct rotation/parallax. Next: test exposure-normalized, non-clipped registration proxies; compare median-threshold alignment (OpenCV AlignMTB) on actual Nikon brackets, inspect residuals, use a common valid crop and visibly reject unreliable alignment. Homography is a research candidate, not a guarantee. Do not silently accept Vision's returned transform as confidence. Basic alignment is a requirement for the bracket slice, so no automatic-alignment product claim yet.

### Performance limits

Recorded whole optimized probe: 1.73 s wall time, peak resident set 1,357,266,944 B (~1.26 GiB). Includes hashing/copying two NEFs, synthetic operations, proxy renders, two full float TIFF writes; **not** a full-resolution three-frame merge or six-control interactive benchmark. Earlier cold-ish run took 4.30 s, first proxy 1.92 s; warm results are not a cold launch promise. Shared process/GPU caches and simultaneous system activity were uncontrolled. No optimization introduced from these numbers.

A 6048 × 4032 RGBAf buffer alone is 390,168,576 B; three buffers plus output exceed 1.45 GiB before decoder/GPU/intermediate memory. That is arithmetic, not measured bracket peak. Stream/reuse/tile decisions require a measured real bracket. Proposed first implementation benchmark: cold/warm decode, aligned three-frame full merge, 1024/2048 preview update p50/p95, full TIFF, peak RSS/GPU memory and cancellation on the same fixture. Keep one render in flight plus one newest follow-up and bounded memory; never queue slider events.

## Durable project and one Processor connection

**Recommendation for agreement:** default to project-owned verified byte copies, created before removing job staging. A referenced-source mode may follow with explicit relink/offline behavior. Copies cost disk space but make project reopen independent of staging, catalog, removable originals and renamed folders. No hard links. Project deletion must not delete referenced originals. Prototype only uses synthetic byte sources; the image probe independently verifies NEF byte copying and original preservation.

Proposed package next to the public TIFF:

- `project.json`: version, project ID, engine/decoder/OS versions, source IDs/hashes/original metadata, reference ID, WB/decode settings, merge/crop/settings, current output ID and generation.
- `Sources/<source UUID>.<ext>`: verified private copies; all sources recorded regardless of visual stack policy. Original catalog IDs are namespaced associations, never source identity alone.
- `Generations/<generation UUID>/`: immutable settings manifest, result TIFF and hashes. Commit a new generation only after validation; atomic `current.json` replacement is the internal save commit point. Retain old committed generation through recovery.
- Stable sibling `<name>-HDR.tif`: public result for ordinary Save/external watcher compatibility. It is a **published copy** of a committed generation; update by atomic same-volume replacement. Project commit, public TIFF and catalog are not one filesystem transaction. Reconcile discrepancies by generation ID and hash after interruption; never declare those writes atomic together.

First Save creates a stable project/output identity. Re-edit locates the project via catalog association and validates its manifest/sources; missing/corrupt copies require visible relink against expected hash, not filename guessing. Ordinary Save increments revision for the same output and refreshes that TIFF/catalog asset. Save As New allocates a new output identity and destination with its own association. Decide whether that also forks project ID or snapshots the shared project **before implementation**; retaining two results against one mutable current pointer without per-output history is insufficient. The model retains per-output generation manifests, but does not implement a user project browser.

One versioned grouped job document, opened by the desktop adapter via NSWorkspace, carries job UUID, operation, ordered source IDs/representations/hashes, reference ID, settings snapshot, intended project/output identities, allowed completion location, return policy and optional expected previous revision. One selected group opens one session. Originals versus rendered single-image input must be explicit; never silently develop brackets to TIFF. No catalog access is granted to the editor. Existing ordinary Edit In semantics stay intact.

Atomic completion receipt proposal: protocol version, job/project/output IDs, monotonically increasing output revision, all ordered source identities/reference, immutable generation manifest relative path/hash, actual result relative path/hash/dimensions/depth/profile, engine/settings version. Producer writes/flushed temporary files and commits manifest, project pointer, public result, then receipt by same-volume rename; consumer only processes final receipt names. Atomic visibility is not full power-loss durability. Production implementation needs directory sync/appropriate macOS durability semantics, recovery journal and file coordination, not the prototype's JSON helper alone.

Validate against the **persisted request**, not sender-supplied IDs: version, authorized session/job, all-source mapping, intended output, expected prior revision, regular files, containment, no symlink traversal, size bounds, matching hashes, manifest consistency, actual image decode and TIFF profile/depth/dimensions. Paths are job-relative, not arbitrary absolute write permission. Swift implementation must avoid check/open races using safe file handles/coordinated owned directories; the Python model's path checks are not a security boundary. A receipt is correlation/integrity data, not trusted authentication of an arbitrary desktop app.

Consumer journals validated output and publication intent, writes/verifies the public derivative and then records asset + project association + every source relationship + receipt consumption together in one DB transaction. Unique `(jobID, outputID, revision)` and stable output identity prevent duplicate import; replay revalidates existing state. A later revision updates the same asset; stale revisions cannot overwrite newer ones. A registered job/session must explicitly authorize subsequent re-edit saves; no pending-job-only lookup that loses identity on first return. If file publication succeeds but DB commit fails, relaunch reconciles exact output/generation hash rather than imports by filename. `Importer.addStacked` is currently import then stack separately and cannot alone provide this guarantee.

Proposed visual stack policy for agreement: place the returned derivative after the selected reference frame using existing stack semantics; record all-source edges independently. Do not force all originals into one stack or duplicate result rows per source. Inherit descriptive metadata/rating from the reference only, and document it; no misleading single-capture EXIF. Coordinate bounded relation/receipt/project migrations with AT-005b/c; no schema changes in this probe.

### What the protocol model actually tests

`Scripts/hdr/project_probe.py`: five headless tests, all pass. Private copy inode differs from original; durable source hashes survive staging deletion, missing owned source is detected and a verified relink succeeds; original hashes remain unchanged. Same output Save updates one row; Save As New creates a second identity; all three source mappings remain. Interrupted generation has no receipt and leaves the old current pointer. Simulated persisted row reload/replay does not duplicate; stale revisions, foreign/version/source/hash/path/symlink receipts are rejected. Abandoned jobs require explicit recovery.

This is a **model with dictionaries instead of GRDB and synthetic payload bytes instead of image validation**. It does not launch/relaunch an app, terminate a process mid-write, make a true database transaction, prove public sibling TIFF publication, handle concurrent writers, test file permissions/NAS behavior or validate cancellation signaling. Only atomic JSON writes call `fsync`; it is not power-loss qualification. The “relaunch” test reloads serialized rows, not the operating system's app lifecycle. Keep those distinctions in PR/acceptance reporting.

Close without return emits no completion receipt. Cancel during prepare stops copies; after handoff Atelier may abandon import but must not kill the editor or remove a saved project. A late receipt for abandoned jobs is retained for an explicit recovery action. Editor cancellation preserves last committed project/generation. Relaunch reconciles committed receipts and public-file hashes, does not automatically rerun a merge. Live receipt discovery, durable job state, app document registration and real cancel/crash tests remain unproven until a permitted Mac transport slice.

## Dependency terms and candidates

No dependency added; Swift code uses system Core Image, ImageIO, Vision, CoreGraphics and CryptoKit. Apple frameworks are proprietary system APIs under the installed Xcode/SDK and macOS terms, **not Apache/MIT libraries**. No model weights, redistributed Apple framework, RAW SDK or copied proprietary HDR algorithm. The official [Xcode/SDK agreement](https://www.apple.com/legal/sla/docs/xcode.pdf) governs development; shipping/signing/distribution must use applicable Apple terms. This is a dependency inventory, not legal clearance for an unbuilt product.

Primary sources consulted October 30, 2026:

- [Apple boostAmount](https://developer.apple.com/documentation/coreimage/cirawfilter/boostamount): zero disables global tone curve. Installed Xcode `CIRAWFilter.h` additionally documents local tone zero, default baseline/shadow variability and EDR controls. Record decoder version; do not equate the public knob with complete scene-linearity proof.
- [Apple baselineExposure](https://developer.apple.com/documentation/coreimage/cirawfilter/baselineexposure), [translation request](https://developer.apple.com/documentation/vision/vntranslationalimageregistrationrequest), [TIFF writer](https://developer.apple.com/documentation/coreimage/cicontext/writetiffrepresentation(of:to:format:colorspace:options:)): API availability/semantics, not output quality promises.
- [OpenCV license](https://opencv.org/LICENSE/): 4.5+ Apache 2.0. Candidate `photo` module/AlignMTB only; no version adopted or binary audited here. A selected build needs exact tag/commit, LICENSE/NOTICE, its enabled third-party dependency terms, and actual RAW-prepared bracket benchmarks. Do not inherit the whole OpenCV optional dependency graph without auditing it.
- [LibRaw copyright](https://github.com/LibRaw/LibRaw/blob/master/COPYRIGHT): alternative LGPL 2.1 or CDDL 1.0, plus component notices including BSD-style DCB/FBDD/X3F and MIT DNG portions. Not a permissive MIT/Apache-only dependency. No version downloaded/linked; exact release/options/license obligations would need review before selecting it. Keep as fallback if Apple decoder qualification fails, not an adopted RAW engine.

No DNG/EXR return dependency is required for the first TIFF product. Existing GRDB remains unchanged. None of this changes the AI licensing gate/backend order or introduces ComfyUI migration.

## Proposed controls and next bounded work

Propose **six** controls for agreement, with one common luminance/color pipeline for single image and merged master; names/ranges/algorithms are not frozen:

| Control | Purpose / qualification still needed |
| --- | --- |
| Exposure | Global scene-linear gain in EV; RAW midtone scaling demonstrated, clipping/negative gamut cases pending |
| Dynamic Range | Luminance shoulder compression, same RGB gain; simple monotonic compression proved numerically, appearance/range pending |
| Shadows | Lift dark luminance while protecting black; noise/color and endpoint behavior untested |
| Contrast | Midtone contrast about a defined pivot; monotonicity/white-black behavior untested |
| Detail | Bounded local contrast, one fixed initial spatial scale; halo/noise and preview/full-size consistency untested |
| Saturation | Controlled chroma after tone compression; gamut/hue clipping tests pending |

Start with neutral/raw and natural tone-mapped before/after, not a preset library or six unrelated Core Image filters. Do not claim the simple probe implements Shadows/Contrast/Detail/Saturation. Share `SliderRow`, reset/typed entry/history semantics and `ZoomViewport` only when the UI slice is approved; no extract-everything refactor now.

Recommended next bounded task after Rosh’s single-image priority clarification: **AT-021a single-image look and document-transport gate**. First compare direct scene-linear tone mapping with a three-virtual-exposure fusion approach derived from the same decoded original (proposed −2/0/+2 EV, not a settled product setting). Measure tone/detail, noise/halos, highlight clipping, hue and preview/full-size consistency on these known single-image fixtures and brighter/high-contrast examples; the current dark proxy look fails the visual starting-point gate. Virtual exposures add no captured scene information and need no inter-frame alignment, since they share the same image geometry. Select the method by visual/numeric evidence rather than assuming proprietary Machinery math. Do not label synthesized exposures as a captured bracket. Continue the minimal project/transport gate alongside this work. **Separate bracket gate**, before committing to bracket support: (1) Obtain a confirmed Nikon exposure bracket plus motion/handheld/highlight examples; qualify common-WB RAW ratios across actual captures, exposure metadata, normalization/MTB alignment residual/crop, basic merge and full-resolution profiled TIFF against originals and a reference. (2) Build only a minimal second-app document receiver plus headless Core project/receipt service through the same Processor boundary; test grouped delivery, re-edit/Save/New identities, staged-copy removal, duplicate return, close/cancel and actual crash/relaunch. No broad plugin platform. Desktop work requires fresh explicit permission. Agree source-copy default, reference-stack policy, Save As New project fork semantics and six controls before the editor implementation.

After the single-image look and transport gates pass, a separately approved first editor slice can prioritize one-image creative HDR: native window, reusable engine, coalesced preview, six agreed controls/undo/project save and focused single-input Atelier return through the grouped-capable Processor contract. Keep grouped bracket UI/merge qualification explicitly pending until its own gate passes; changing the original combined first-slice delivery scope requires Rosh’s agreement. No runtime implementation is added by this clarification. Include full-resolution memory/latency measurements, all-source transaction tests, app/Help/PRD/snapshot work and Rosh's visual acceptance. General platform, advanced deghosting, presets, float/±10 EV Develop, shortcuts/headless/batch remain deferred. Parent AT-021 and AT-021a acceptance remain open where fixture/transport/visual evidence is missing.

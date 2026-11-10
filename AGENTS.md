# Working on Atelier

Rules for any coding agent (Claude, Antigravity, Codex, …) working in this repo.

## Project

Atelier is Rosh's personal Lightroom-style photo catalog and editor.

- Native macOS only: Swift, SwiftUI + AppKit, macOS 15+. Apple Silicon is the main target; Intel (x86_64) and universal Release builds are supported (`Scripts/build_macos_app.py --arch`), so guard any Apple Silicon-only code (MLX, `Float16`, Neural Engine assumptions) with `#if arch(arm64)` or a runtime check and hide that feature on Intel. Swift package with `AtelierCore` (library) and `AtelierApp` (executable).
- [Requirements/Atelier-PRD.md](Requirements/Atelier-PRD.md) is the spec and the single source of truth. There is no other copy.
  - Update it in the same PR whenever a feature or UX decision changes.
  - If a request conflicts with the PRD, say so before building it.
- [README.md](README.md) covers building, running and CI.

## Product rules

- **UX:** polished, Mac-native and Lightroom-like in every feature. The PRD's "User experience principles" are the checklist: a feature is not done until it meets every one. How to design for them is under [Design principles](#design-principles).
- **One Processor contract** for Edit In apps, plugins and AI backends. Don't add a second integration path.
- **AI backend order:** ComfyUI headless API first, then Core ML, then MLX. Nothing generative is bundled with the app. Exception (Rosh, Nov 10, 2026): small Apache 2.0/MIT mask models that must answer while you click (MediaPipe Multiclass Selfie Segmentation for Select People) are built into the app and run in-process with Core ML; larger optional ones (SAM 2.1, BiRefNet) are downloads in Settings. BiRefNet (Fine Edges) runs with ONNX Runtime (MIT, linked into the app; Rosh, Nov 10, 2026) from the authors' published ONNX file, so no converted model has to be hosted.
- **Licensing:** images for Rosh's website or shop may only come from permissively licensed models (Apache 2.0 or MIT, e.g. Qwen-Image-Edit-2511, FLUX.2 [klein] 4B). Non-commercial models (e.g. Qwen-Image-2.1, Fibo 2.0, FLUX.2 [klein] 9B) are for experiments only.
- **One look and feel:** every tool must look and work like the rest, whatever its idea came from (PRD UX principle 13). Reuse the shared pieces (listed under [Solve a pattern once, centrally](#solve-a-pattern-once-centrally)) instead of building a tool's own copy. When you add or change a pattern, apply it to every panel and tool that has the same kind of control, not just the one you were asked about, and list the others for Rosh to test.
- **Cursors:** never set an `NSCursor` in a view. Name the shape with `.cursor(_:)` (SwiftUI) or `Cursors.shared` (AppKit), from `Sources/AtelierApp/Cursors.swift`; for a tool with handles, work the shape out from the same hit test its drag uses. Add a `CursorShape` case if one is missing. PRD UX principle 11.
- **Deletes:** every delete calls `DeleteFeedback.play(.trash)` (files to the Trash) or `.remove` (anything else) once it succeeds. PRD UX principle 12.
- **Preview cache:** when the way previews are rendered changes, bump `PreviewCache.version` in `Sources/AtelierCore/Previews/PreviewCache.swift` (and note why in its comment) so old previews are rebuilt.
- **Help:** Atelier Help (`Sources/AtelierApp/Help`, opened with Help > Atelier Help, ⌘?) documents every tool with drawn controls and before/after pictures. A PR that adds or changes a feature or control updates its help page in the same PR:
  - Edit the page's HTML (or add a page and list it in `GROUPS` in `Scripts/help/build_help_index.py`). Give each h2/h3 an `id`.
  - New or changed before/after pictures come from `Scripts/help/make_help_images.py`; add a pair there and run it.
  - Run `python3 Scripts/help/build_help_index.py`. It rebuilds the search index and must report no problems (missing pictures, broken links).
  - Open the page in a browser (or with Playwright) and look at it before saying it's done.

## Design principles

How to think before writing code. The PRD says *what* the app does; this says how to build it so Rosh doesn't have to report the same problem twice.

### Lightroom is the floor, not the ceiling

- Start from how Lightroom Classic does it: names, layout, gestures, keys. Rosh knows Lightroom; matching it is the default.
- Keep anything Atelier already does better than Lightroom. Never remove or downgrade an improvement "to match Lightroom" without asking Rosh first.
- If you add something Lightroom doesn't have, it still follows Atelier's shared patterns (next section).

### Solve a pattern once, centrally

Rosh's most common complaint is the same bug showing up tool by tool. Before you build or fix anything, ask: "is this one instance of a pattern?" If yes, fix the pattern in the shared piece, not in the tool.

- **Use the shared piece; don't make a tool's own copy.** If none fits, extend it (add a case, a parameter) so every tool gets it. Today's shared pieces:
  | Concern | Use | Where |
  |---|---|---|
  | Zoom, pan and the zoomed spot across modes | `ZoomViewport` (every photo view reads and writes it) | `Views/ZoomableImageView.swift` |
  | Drawing a tool on the photo | an overlay on the Develop photo view (as Masking does), not a second photo view | `Views/MaskViews.swift`, `Views/DevelopView.swift` |
  | Cursors | `CursorShape`, `.cursor(_:)`, `Cursors.shared` | `Cursors.swift` |
  | Delete sound and poof | `DeleteFeedback.play(_:)` | `DeleteFeedback.swift` |
  | Panel header, on/off switch | `PanelSection` (with `SectionBand`, the header band both sidebars use); `DevelopSettings.disabledPanels` + `applyingPanelSwitches()` before rendering | `Views/DevelopView.swift`, `AtelierCore/Develop/PanelSwitches.swift` |
  | Sliders (every slider in the app, not only Develop) | `SliderRow` (its track is `DevelopSlider`; `ParameterSlider` binds it to a Develop setting) (double-click name resets, click value to type, ⌥-drag view). A bare track outside a row is `DevelopSlider`; never SwiftUI's `Slider`. Sizes and press rules come from `SliderGeometry` (13 pt knob, 20 pt grab zone: a press there keeps the knob under the pointer, elsewhere jumps it), the knob is `SliderKnob`, the cursor `.slide` over the knob and during every drag | `Views/SharedDevelopControls.swift`, `Views/DevelopView.swift`, `AtelierCore/Keyboard/SliderGeometry.swift` |
  | Group headings with reset | `GroupHeading(reset:)` (⌥ shows "Reset X") | `Views/DevelopView.swift` |
  | Eyedroppers / color pickers | `DevelopController.picker` (`PhotoPicker`), `PickerButton`, `PickerHint` | `DevelopController.swift`, `Views/DevelopView.swift` |
  | Right-click photo menu | one menu for grid, Loupe, Develop and Filmstrip | `PhotoMenu.swift` |
  | Keys | `KeyBindings` (customizable in Settings) | `KeyBindings.swift` |
- **State that outlives a mode lives in one place every mode reads and writes** (PRD UX principle 10). A new tool must not save and restore its own zoom, selection or scroll position.
- **When you change a pattern, change it everywhere it applies.** A panel switch, slider gesture or picker behaviour added to one panel goes on every panel with that kind of control. A tool missing a pattern the others have is a bug (PRD UX principle 13, "One look and feel" above).
- If you find a tool with its own copy of a shared piece, move it onto the shared one (or note it in your PR if that's too big for this change).

### Fixing a bug: find its siblings

- Find the cause, not the symptom. Then search for every other place with the same cause (same gesture, same control, same view, same math) and fix them together, or list the ones you didn't fix.
- In your hand-off, list every place Rosh should re-test, with click paths. For an input or gesture change, walk every gesture of that mode (click, drag, handles, hover cursor, Space-drag, scroll, pinch, ⌘-scroll, zoom buttons, Navigator, keys), not just the reported one.

### Structure

- **Core vs app.** Image math, catalog and file work go in `AtelierCore`, with tests in `AtelierCoreTests`. `AtelierApp` holds views and controllers only. If logic can be tested without a window, it belongs in Core.
- **Small, focused files.** Add a new file (or an extension like `Catalog+Feature.swift`) for a new feature instead of growing `DevelopView.swift` or `DevelopController.swift`. Split a view when it gets hard to read.
- **Non-destructive and backward compatible.** Edits are settings, never pixels written to originals. New `DevelopSettings` fields decode with a default (`decodeIfPresent`) and a neutral value that changes nothing, so old catalogs, presets and history still load and look the same. Catalog schema changes are new GRDB migrations, never edits to old ones.
- **One edit, one history step.** A slider drag, reset, group reset or picker click records one undoable step with a plain name.
- **Rendering changes bump `PreviewCache.version`** (see Product rules).

### Performance

- Measure before optimizing: time it (Instruments, `os_signpost`, or a timed test) and put the numbers in the PR. Don't add caches, threads or lower-quality paths on a guess.
- Keep the main thread free: rendering, analysis, file and network work run in the background with progress and Cancel (PRD UX principle 4). Slider and handle drags must stay smooth: renders are coalesced (one in flight plus one follow-up, see `DevelopController`), so never queue a render per event.

## Action list and ways of working

- [BACKLOG.md](BACKLOG.md) is the canonical action/status list in Git. The PRD remains the product specification; the backlog does not replace it or approve a product change.
- Keep the backlog current in the same PR as the work. Use stable IDs; record evidence and its revision, scope, dependencies, acceptance criteria, and PR links. Distinguish approved actions, proposals awaiting discussion, and implementation that still needs acceptance.
- When work starts, record the owner, chat, branch and PR (once one exists). When it ends, record validation, limitations and deferred work. Do not mark acceptance complete from source inspection or a build alone.
- Pick one bounded approved item at a time. Discuss a proposal's scope with Rosh before implementing it; a review recommendation is not blanket approval for an architecture rewrite.
- Use one separate Codex chat in the App project for each new PR, carrying the relevant context and backlog IDs. Title it `PR planning: <topic>` until GitHub assigns the actual number, then prefix its title with `PR #N`. Never invent or reserve PR numbers. Further PRs get their own chats for discussion; do not create chats merely for internal subtasks.
- Do not merge a PR without Rosh's instruction.

## Git workflow

Several agents open PRs on this repo at the same time.

1. Fetch `origin/main` and start a separate task worktree from it. Leave Rosh's active Xcode checkout untouched.
2. Create a branch for the task. Never commit to `main`.
3. Keep each PR small and on one topic.
4. Push the branch and open a PR against `main`.
5. Run the checks available in your execution environment (see below) and report results. The repository has a GitHub Actions workflow, but do not assume a run exists or passed; verify its status when available. Fix failures or report the specific blocker; don't ask Rosh to paste build errors.

### Where you work

Agents run in one of two places. Know which one you are.

- **On Rosh's Mac** (Co/Codex, Antigravity): use a separate worktree and task branch from the existing repository; do not clone again. Never switch branches, stash, or edit files in `~/RoshProjects/Atelier/App`, Rosh's active Xcode checkout. Branch switches and cleanup apply only to your own task worktree; preserve other agents' changes.
- **In the cloud** (Cl/Claude project threads): use your own clone and branch, then push. Do not write into Rosh's Mac checkout. A non-Mac cloud environment cannot run the macOS/Xcode checks: report this limitation explicitly and arrange a Mac check of the same revision before treating validation as complete.

Either way, GitHub is the only hand-off: Rosh sees a change after it's pushed and they pull or check out the branch in Xcode.

## Local checks before a PR

- Mac agents run `python3 Scripts/check_pr.py` in the task worktree before opening or updating a PR. Cl/Claude in the cloud follows the environment rule above. The [Automated testing guide](Docs/Automated-Testing.md) explains the group selectors, when to use them, and how to read the reports.
- Include the checked commit, working changes, summary/log location, failures and skipped tests in the PR. A failed build/test is not a pass. Resolve failures or explicitly report the blocker.
- Fetch the PR base first. Whitespace validation compares the working tree to the merge base with `origin/main`, including committed changes and new files; use `--base <ref>` for another base. Inspect test logs for skipped RAW fixtures.
- Pass `--ui` to include the native smoke test and screenshot comparison in the local check. Review intentional visual changes as described below. No GitHub setup is needed for the local check.

### Cloud review when macOS is unavailable

- A cloud agent without macOS/full Xcode must still review the diff and run applicable portable checks. State exactly which checks were run, skipped or unavailable; a missing toolchain is a limitation, not a build failure or a pass. Do not try to replace the native macOS checks with Linux Swift or ask Rosh to paste build errors.
- For a read-only review, the reviewer may cite a Mac agent's existing `Scripts/check_pr.py` result for the **same exact commit**. Verify the checked SHA against the reviewed PR head and read the recorded result, working changes, summary/log location and skipped tests. Attribute it explicitly: “Source reviewed at `<SHA>`; macOS validation performed by Codex at `<SHA>`: `<result>`, logs `<location>`, skips `<details>`. I did not independently run the Mac checks.” A generic reported pass without revision/evidence is insufficient. If logs are not accessible in the cloud, say so; do not imply independent verification of their contents.
- If the cloud agent changes code, the prior Mac pass does not validate the new head. Push the changes, then request a Mac agent check the new commit in a separate task worktree from that exact head, without touching Rosh's active Xcode checkout. The Mac agent runs the required checks, reports failures directly and records fresh evidence in the PR. Fix failures and repeat at the resulting head. Keep native validation pending if no Mac agent is available; source approval alone must not be presented as complete validation.
- A later documentation-only commit may cite an earlier build/test result only with both SHAs and a verified empty diff for the relevant source/tests/build inputs; label this inherited evidence, not a fresh final-head run. Prefer a fresh final-head check before handoff. GUI snapshots, real RAW skips, live integration tests and Rosh's manual acceptance remain separate; neither source review nor a passing build substitutes for them. Check GitHub Actions for the actual head and report unavailable/blocked CI separately from local results. Never merge without Rosh's instruction.


## Pull requests

Rosh reads PRs to decide what to test and merge, often days later and from several agents at once. Each PR must make sense on its own. [.github/pull_request_template.md](.github/pull_request_template.md) has the layout; GitHub fills it in when a PR is opened in the browser, and agents that open PRs another way copy it.

### Title

- `<Area>: <what changes for Rosh>`, in plain words, under about 80 characters. Examples from main: `Effects > Grain: Grain Type (Standard, Fine, Cubic, Tabular) set by film presets`, `Masking: Temp/Tint the Lightroom way, one Invert, draggable gradient lines`.
- **Area** is where Rosh finds it in the app, with the app's own names (`Develop > Tone Curve`, `Import`, `Library > Filmstrip`). For work outside the app, use the file or system: `AGENTS.md`, `CI`, `Help`, `Presets`.
- Say what the user gets or what is fixed, not how: `Crop: straighten no longer leaves streaks`, not `Fix CIAffineTransform extent in CropRenderer`.
- PRs are squash-merged, so the title becomes the commit on main. Rename the PR if its scope changes.

### Description

1. **Agent:** first, which agent did the work: `Claude`, `Codex` or `Antigravity` (list each one if several worked on it), with a link to the session or thread when there is one. Claude project threads keep their two attribution lines above everything else.
2. **Summary:** one or two sentences on what changes for Rosh and why (the request or bug it answers).
3. **Changes:** bullet points, one per change, detailed enough that Rosh can test and review from them without reading the diff.
   - Lead each bullet with what Rosh sees and where (panel, menu, key), then the technical note if it helps (type, file, algorithm).
   - Group bullets under **Features**, **Fixes** and **Under the hood** when there are more than a few.
   - Call out anything that changes existing photos or data: a different look for old edits, a `PreviewCache.version` bump, a catalog migration, a renamed setting or key.
   - Say what was left out or is still known to be wrong, and which other places with the same pattern were or weren't changed (see [Fixing a bug: find its siblings](#fixing-a-bug-find-its-siblings)).
4. **How to test:** the steps from [Handing off to Rosh](#handing-off-to-rosh): the git commands, then numbered click paths with what to expect at each one.
5. **Checklist:** tick or strike each item in the template so Rosh can see what was done (PRD, Help, PreviewCache, snapshots, tests).

Keep the description current: when you push more commits, update the bullets and test steps to match.

## UI changes

- For routine native UI checks, read the PR's **Atelier UI checks** summary and `layout-snapshots` artifact. Confirm the tested revision. If Actions is unavailable, run `python3 Scripts/check_ui.py` from the task worktree on a Mac with a logged-in desktop session. Read the summary and open the relevant diffs or failure artifacts.
- Passing covered checks need no agent-driven desktop replay. Review intentional visual changes in the generated screenshots before handoff. List uncovered gestures and workflows that still need manual acceptance.
- For a new screen or state, add coverage to `LayoutSnapshots.swift`. For repeatable interactions, extend the native smoke suite under `Tests/AtelierUITests`.

## Handing off to Rosh

Rosh tests manually: they get the branch with git in Terminal, then run the app in Xcode (scheme **AtelierApp**, destination **My Mac**).

- Give the branch name and the git commands to get it, ready to paste. Always start with `git status` so Rosh sees uncommitted changes (possibly another agent's) before switching:
  ```
  cd ~/RoshProjects/Atelier/App
  git status
  git fetch origin
  git checkout <branch>      # test a PR branch
  git pull                   # update it after new pushes
  ```
  Back to latest main: `git checkout main && git pull`. If `git status` shows changes, say what to do with them (usually `git stash`); never tell Rosh to discard them.
- For everything in the app and Xcode, give exact click paths, e.g. Product > Run (⌘R), Atelier > Settings… > Appearance.
- Say what to check and where, step by step. Never "open the panel and try it".
- Use Xcode 26's real names. If you're not sure what a dialog or menu is called, ask Rosh for a screenshot instead of guessing.

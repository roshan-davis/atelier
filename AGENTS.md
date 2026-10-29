# Working on Atelier

Rules for any coding agent (Claude, Antigravity, Codex, …) working in this repo.

## Project

Atelier is Rosh's personal Lightroom-style photo catalog and editor.

- Native macOS only: Swift, SwiftUI + AppKit, Apple Silicon, macOS 15+. Swift package with `AtelierCore` (library) and `AtelierApp` (executable).
- [Requirements/Atelier-PRD.md](Requirements/Atelier-PRD.md) is the spec and the single source of truth. There is no other copy.
  - Update it in the same PR whenever a feature or UX decision changes.
  - If a request conflicts with the PRD, say so before building it.
- [README.md](README.md) covers building, running and CI.

## Product rules

- **UX:** polished, Mac-native and Lightroom-like in every feature. The PRD's "User experience principles" are the checklist: a feature is not done until it meets every one. How to design for them is under [Design principles](#design-principles).
- **One Processor contract** for Edit In apps, plugins and AI backends. Don't add a second integration path.
- **AI backend order:** ComfyUI headless API first, then Core ML, then MLX. Nothing is bundled with the app.
- **Licensing:** images for Rosh's website or shop may only come from permissively licensed models (Apache 2.0 or MIT, e.g. Qwen-Image-Edit-2511, FLUX.2 [klein] 4B). Non-commercial models (e.g. Qwen-Image-2.1, Fibo 2.0, FLUX.2 [klein] 9B) are for experiments only.
- **One look and feel:** every tool must look and work like the rest, whatever its idea came from (PRD UX principle 13). Reuse the shared pieces (listed under [Solve a pattern once, centrally](#solve-a-pattern-once-centrally)) instead of building a tool's own copy. When you add or change a pattern, apply it to every panel and tool that has the same kind of control, not just the one you were asked about, and list the others for Rosh to test.
- **Cursors:** never set an `NSCursor` in a view. Name the shape with `.cursor(_:)` (SwiftUI) or `Cursors.shared` (AppKit), from `Sources/AtelierApp/Cursors.swift`; for a tool with handles, work the shape out from the same hit test its drag uses. Add a `CursorShape` case if one is missing. PRD UX principle 11.
- **Deletes:** every delete calls `DeleteFeedback.play(.trash)` (files to the Trash) or `.remove` (anything else) once it succeeds. PRD UX principle 12.
- **Preview cache:** when the way previews are rendered changes, bump `PreviewCache.version` in `Sources/AtelierCore/Previews/PreviewCache.swift` (and note why in its comment) so old previews are rebuilt.

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
  | Sliders | `SliderRow` (its track is `DevelopSlider`; `ParameterSlider` binds it to a Develop setting) (double-click name resets, click value to type, ⌥-drag view) | `Views/DevelopView.swift` |
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

## Git workflow

Several agents open PRs on this repo at the same time.

1. Start every task from a fresh main: `git checkout main && git pull`.
2. Create a branch for the task. Never commit to `main`.
3. Keep each PR small and on one topic.
4. Push the branch and open a PR against `main`.
5. GitHub Actions CI (`.github/workflows/build.yml`) builds, runs `AtelierCoreTests` and renders layout snapshots on every PR. Check it passes and fix failures yourself; don't ask Rosh to paste build errors.

### Where you work

Agents run in one of two places. Know which one you are.

- **On Rosh's Mac** (e.g. Antigravity): work in the existing clone at `~/RoshProjects/Atelier/App`; don't clone again. This is also the folder Rosh runs in Xcode, so:
  - Before switching branches, check `git status`. Never discard uncommitted changes you didn't make; stash them and tell Rosh.
  - When your PR is open, run `git checkout main` so Rosh's Xcode isn't left on your branch.
- **In the cloud** (e.g. Claude project threads): work in your own clone and push from there. Never write files into Rosh's App folder, even if you have folder access: Rosh gets cloud changes only by pulling.

Either way, GitHub is the only hand-off: Rosh sees a change after it's pushed and they pull or check out the branch in Xcode.

## UI changes

Nobody but Rosh can see the running app, so don't guess at layout.

- CI runs the app with `ATELIER_SNAPSHOTS` (see `Sources/AtelierApp/LayoutSnapshots.swift`) and force-pushes the PNGs to the `layout-snapshots` branch; its commit message names the PR head SHA.
- Before saying a UI change works, fetch that branch for your PR's latest commit and look at the images.
- If a new screen or state matters, add it to `LayoutSnapshots.swift`.

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

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

- **UX:** polished and Lightroom-like in every feature. Follow the PRD's "User experience principles": the app's own dialog first (pickers inside it), preview the outcome, background progress with cancel, confirm destructive actions, plain language.
- **One Processor contract** for Edit In apps, plugins and AI backends. Don't add a second integration path.
- **AI backend order:** ComfyUI headless API first, then Core ML, then MLX. Nothing is bundled with the app.
- **Licensing:** images for Rosh's website or shop may only come from permissively licensed models (Apache 2.0 or MIT, e.g. Qwen-Image-Edit-2511, FLUX.2 [klein] 4B). Non-commercial models (e.g. Qwen-Image-2.1, Fibo 2.0, FLUX.2 [klein] 9B) are for experiments only.
- **Cursors:** never set an `NSCursor` in a view. Name the shape with `.cursor(_:)` (SwiftUI) or `Cursors.shared` (AppKit), from `Sources/AtelierApp/Cursors.swift`; for a tool with handles, work the shape out from the same hit test its drag uses. Add a `CursorShape` case if one is missing. PRD UX principle 11.
- **Deletes:** every delete calls `DeleteFeedback.play(.trash)` (files to the Trash) or `.remove` (anything else) once it succeeds. PRD UX principle 12.
- **Preview cache:** when the way previews are rendered changes, bump `PreviewCache.version` in `Sources/AtelierCore/Previews/PreviewCache.swift` (and note why in its comment) so old previews are rebuilt.
- **Help:** Atelier Help (`Sources/AtelierApp/Help`, opened with Help > Atelier Help, ⌘?) documents every tool with drawn controls and before/after pictures. A PR that adds or changes a feature or control updates its help page in the same PR:
  - Edit the page's HTML (or add a page and list it in `GROUPS` in `Scripts/help/build_help_index.py`). Give each h2/h3 an `id`.
  - New or changed before/after pictures come from `Scripts/help/make_help_images.py`; add a pair there and run it.
  - Run `python3 Scripts/help/build_help_index.py`. It rebuilds the search index and must report no problems (missing pictures, broken links).
  - Open the page in a browser (or with Playwright) and look at it before saying it's done.

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

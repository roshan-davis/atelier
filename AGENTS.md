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
- **Preview cache:** when the way previews are rendered changes, bump `PreviewCache.version` in `Sources/AtelierCore/Previews/PreviewCache.swift` (and note why in its comment) so old previews are rebuilt.

## Git workflow

Several agents open PRs on this repo at the same time.

1. Start every task from a fresh main: `git checkout main && git pull`.
2. Create a branch for the task. Never commit to `main`.
3. Keep each PR small and on one topic.
4. Push the branch and open a PR against `main`.
5. GitHub Actions CI (`.github/workflows/build.yml`) builds, runs `AtelierCoreTests` and renders layout snapshots on every PR. Check it passes and fix failures yourself; don't ask Rosh to paste build errors.

Work in the existing clone; don't clone the repo again. Don't copy files onto Rosh's Mac by other means: Rosh gets changes by pulling.

## UI changes

Nobody but Rosh can see the running app, so don't guess at layout.

- CI runs the app with `ATELIER_SNAPSHOTS` (see `Sources/AtelierApp/LayoutSnapshots.swift`) and force-pushes the PNGs to the `layout-snapshots` branch; its commit message names the PR head SHA.
- Before saying a UI change works, fetch that branch for your PR's latest commit and look at the images.
- If a new screen or state matters, add it to `LayoutSnapshots.swift`.

## Handing off to Rosh

Rosh tests manually by pulling the branch in Xcode (scheme **AtelierApp**, destination **My Mac**) and does not want to run terminal commands.

- Give the branch name and exact click paths, e.g. Xcode > Integrate > Pull…, Product > Run (⌘R), Atelier > Settings… > Appearance.
- Say what to check and where, step by step. Never "open the panel and try it".

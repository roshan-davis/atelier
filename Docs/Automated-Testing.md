# Automated testing

Atelier's checks write a short summary and keep detailed logs on disk. Agents can run the
checks once, read the summary, and open the relevant artifacts when a test fails or a
screenshot changes.

## Run from App

Run these commands from the `App` folder after checking out the branch you want to test.
That branch must include the automation runner.

| What to run | Command |
| --- | --- |
| Both UI groups, one after the other | `python3 Scripts/check_ui.py` |
| Native smoke test only | `python3 Scripts/check_ui.py --group smoke` |
| Screenshot comparison only | `python3 Scripts/check_ui.py --group visual` |
| All checks, including both UI groups | `python3 Scripts/check_pr.py --group all --quiet` |

Use Python 3 and full Xcode. The UI groups need a logged-in Mac desktop session and open
temporary Atelier windows with a disposable catalog. The visual group exercises Edit In
stacking inside Atelier and keeps its generated TIFF in the disposable test folder.
For older baselines, the runner applies those same isolation changes to the test setup.
The visual group uses a locally
available `origin/main` as its default baseline. Run `git fetch origin main` to refresh it,
or pass `--base <ref>` to compare against a different fetched revision.

`check_ui.py` prints the path to `.build/ui-checks/<run>/summary.txt`. The combined
`check_pr.py` command writes its summary under `.build/local-checks/<run>/`.

Repeat `--group` to combine any groups in one run. With no group specified, the command runs
`checks`, `build`, and `swift`. The existing `--ui` option is an alias for `--group all`.
For camera and RAW work, add `--samples /absolute/path/to/sample-raws`. The local runner
uses existing fixtures from that folder and never downloads them.

| Group | What it runs |
| --- | --- |
| `checks` | PR whitespace, Python script tests, and Help links and index validation |
| `build` | Swift package build |
| `swift` | All Swift tests across Atelier Core, App, and HDR. Swift also builds the test targets |
| `smoke` | XCUITest opens a fixture photo in Develop, enters an Exposure value, and verifies that ⌘Z restores it |
| `visual` | Captures layouts at the base revision and current checkout on the same Mac and compares the PNGs |
| `all` | Every group above |

## Choose groups for the change

| Change | Start with | Add when relevant |
| --- | --- | --- |
| Documentation or Help | `checks` | For changed Help content, inspect the changed page as described in [AGENTS.md](../AGENTS.md) |
| Build, packaging, or CI scripts | `checks` and `build` | `smoke` if app packaging, launch, or UI test setup changes. Run the affected packaging command for packaging-specific changes |
| Catalog, import, export, rendering, or HDR logic | `checks`, `build`, and `swift` | `visual` if a rendered preview or layout can change. Supply RAW fixtures for camera or RAW work |
| Layout, panels, themes, or Help illustrations that reflect changed controls | `checks`, `build`, and `visual` | `swift` for logic changes. `smoke` for shared controls or Develop changes |
| Develop controls, undo, keyboard focus, or gestures | `all` | Check the specific interaction manually or add a native test when it is outside the current Exposure and Undo coverage |
| Cross-cutting changes or an uncertain impact | `all` | Review affected screens and any uncovered workflows |

For example, to check a layout change while iterating:

```sh
python3 Scripts/check_pr.py --group checks --group build --group visual --quiet
```

To rerun a single Swift suite while debugging, use `swift test --filter LookMatchTests`.
Then use the `swift` group to get the full Swift suite and a saved report. Before opening or
updating a PR, follow the validation requirements in [AGENTS.md](../AGENTS.md#local-checks-before-a-pr).

## Read the report

Open the `summary.txt` in the printed `.build/local-checks/<run>/` folder. Check the revision,
working changes, selected groups, and any groups listed as omitted. For UI checks, the
summary also shows the smoke result and visual comparison count. The full UI report lives
in `ui/summary.txt`.

- **PASS** means the selected check completed successfully. **FAIL** exits nonzero. Open
  the corresponding log in the run folder. For the native test, use `ui/smoke.log` or open
  `ui/smoke.xcresult` in Xcode.
- **Groups not selected** means those checks were omitted. Check `tests.log` for skipped
  cases, particularly when real RAW fixtures were unavailable.
- **Visual comparison** shows how many screenshots changed. `0/N changed` means the
  captured images matched. A nonzero count calls for review even when the command passes.
  Read `ui/visual.log` for the per-screen list and open `ui/visual/<screen>/` for the before,
  after, and highlighted pixel diff. Added, removed, and resized images have the available
  before or after images. Look at the screenshots for intentional changes, timing
  differences, and regressions.
- **Capture failure** is a failed check. Inspect `ui/snapshots-base.log` or
  `ui/snapshots-head.log` and any images under `ui/partial-base/` or `ui/partial-head/`.
- **Source changed during checks** means the run crossed multiple working states. Rerun
  on the revision you want to validate.

On GitHub, open the PR's Actions run and read **Atelier UI checks**. Download the
**layout-snapshots** artifact for the UI report, logs, and changed images. Confirm the
reported revision matches the PR head. If GitHub never starts a runner, use the local Mac
command above and record the CI blocker separately.

#!/usr/bin/env python3
"""Run the native UI smoke test and compare Atelier screenshots against a Git revision."""
import argparse
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import uuid

ROOT = Path(__file__).resolve().parents[1]
PROJECT = ROOT / "Tests/AtelierUITests/AtelierUITests.xcodeproj"


def run(command, *, cwd=ROOT, env=None, log, timeout=900):
    print("Running " + log.stem + "…", flush=True)
    try:
        with log.open("w") as output:
            subprocess.run(command, cwd=cwd, env=env, stdout=output, stderr=subprocess.STDOUT,
                           check=True, timeout=timeout)
    except subprocess.TimeoutExpired as error:
        raise RuntimeError(f"{log.stem} timed out after {timeout}s. See {log.name}.") from error
    except subprocess.CalledProcessError as error:
        raise RuntimeError(f"{log.stem} exited with status {error.returncode}. See {log.name}.") from error


def isolated_data(path):
    (path / "tmp").mkdir(parents=True)
    return {"HOME": str(path), "CFFIXED_USER_HOME": str(path),
            "TMPDIR": str(path / "tmp"), "LC_ALL": "en_US.UTF-8"}


def package(source, app, name, output, env):
    # Separate preference domains even when the current desktop has Atelier open.
    run([sys.executable, "Scripts/build_macos_app.py", "--configuration", "debug",
         "--output", str(app), "--bundle-id", "local.atelier.pr-" + uuid.uuid4().hex],
        cwd=source, env=env, log=output / f"build-{name}.log")


def smoke(app, scratch, output, env):
    data = scratch / "smoke"
    isolated_data(data)
    run(["xcodebuild", "test", "-project", str(PROJECT), "-scheme", "AtelierUITests",
         "-destination", "platform=macOS", "-parallel-testing-enabled", "NO",
         "-derivedDataPath", str(scratch / "derived-data"),
         "-resultBundlePath", str(output / "smoke.xcresult")],
        env={**env, "TEST_RUNNER_ATELIER_UI_APP": str(app), "TEST_RUNNER_ATELIER_UI_DATA": str(data)},
        log=output / "smoke.log", timeout=180)


def capture(app, name, scratch, output, env):
    # The recovery and import screens show paths. Give both revisions the same
    # path, with a fresh catalog and fixture directory for each capture.
    data = scratch / "snapshot-data"
    images = data / "images"
    saved = scratch / f"images-{name}"
    try:
        run([str(app / "Contents/MacOS/AtelierApp")],
            env={**env, **isolated_data(data), "ATELIER_CATALOG_PATH": str(data / "Snapshots.ateliercatalog"),
                 "ATELIER_SNAPSHOTS": str(images)}, log=output / f"snapshots-{name}.log", timeout=420)
        if not any(images.glob("*.png")):
            raise RuntimeError(f"{name} did not produce any snapshots")
    finally:
        if images.is_dir():
            images.rename(saved)
        if data.is_dir():
            shutil.rmtree(data)
    return saved


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", default="origin/main", help="Revision to compare against")
    parser.add_argument("--output", type=Path, help="New directory for results (default: .build/ui-checks/...)")
    parser.add_argument("--smoke-only", action="store_true", help="Skip the visual comparison")
    args = parser.parse_args()
    if sys.platform != "darwin":
        parser.error("Run on a Mac with full Xcode and a logged-in desktop session.")
    output = (args.output or ROOT / ".build/ui-checks" / uuid.uuid4().hex[:12]).resolve()
    output.mkdir(parents=True, exist_ok=False)
    env = {key: value for key, value in os.environ.items() if not key.startswith("ATELIER_")}
    if not env.get("DEVELOPER_DIR"):
        selected = subprocess.run(["xcode-select", "-p"], capture_output=True, text=True)
        developer = selected.stdout.strip()
        if selected.returncode or developer.endswith("/CommandLineTools"):
            developer = "/Applications/Xcode.app/Contents/Developer"
        env["DEVELOPER_DIR"] = developer
    if not (Path(env["DEVELOPER_DIR"]) / "usr/bin/xcodebuild").is_file():
        parser.error("Full Xcode required. Set DEVELOPER_DIR to Xcode.app/Contents/Developer.")

    revision = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
    status = subprocess.check_output(["git", "status", "--short"], cwd=ROOT, text=True).strip()
    results = [f"Revision: {revision}", "Working changes: " + (status or "(clean)")]
    failed = False
    visual_done = False
    with tempfile.TemporaryDirectory(prefix="atelier-ui-") as directory:
        scratch = Path(directory)
        app = scratch / "Atelier.app"
        try:
            package(ROOT, app, "head", output, env)
            try:
                smoke(app, scratch, output, env)
                results.append("Native smoke: PASS")
            except (OSError, RuntimeError) as error:
                failed = True
                results.append(f"Native smoke: FAIL ({error})")

            if not args.smoke_only:
                base = subprocess.check_output(
                    ["git", "rev-parse", "--verify", args.base + "^{commit}"], cwd=ROOT, text=True
                ).strip()
                results.append(f"Baseline: {base}")
                baseline = scratch / "baseline"
                run(["git", "worktree", "add", "--detach", str(baseline), base],
                    log=output / "baseline-worktree.log")
                try:
                    base_app = scratch / "Baseline.app"
                    package(baseline, base_app, "base", output, env)
                    before = capture(base_app, "base", scratch, output, env)
                    after = capture(app, "head", scratch, output, env)
                    comparator = scratch / "compare-snapshots"
                    run(["xcrun", "swiftc", "-O", str(ROOT / "Scripts/compare_snapshots.swift"),
                         "-o", str(comparator)], env=env, log=output / "build-comparator.log")
                    comparison = output / "visual.log"
                    run([str(comparator), str(before), str(after), str(output / "visual")], log=comparison)
                    results.append("Visual comparison: " + comparison.read_text().splitlines()[-1])
                    visual_done = True
                finally:
                    run(["git", "worktree", "remove", "--force", str(baseline)],
                        log=output / "baseline-cleanup.log")
        except (OSError, RuntimeError, subprocess.SubprocessError) as error:
            failed = True
            results.append(f"UI checks: FAIL ({error})")
        finally:
            # Preserve available screenshots on capture failure for diagnosis.
            if failed and not visual_done:
                for name in ("base", "head"):
                    images = list((scratch / f"images-{name}").glob("*.png"))
                    if images:
                        partial = output / f"partial-{name}"
                        partial.mkdir()
                        for image in images:
                            shutil.copy2(image, partial)

    report = "\n".join(results) + "\n"
    (output / "summary.txt").write_text(report)
    print(report + f"Reports: {output}")
    return int(failed)


if __name__ == "__main__":
    sys.exit(main())

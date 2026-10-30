#!/usr/bin/env python3
"""Local pre-PR checks for Atelier. No GitHub setup or third-party Python packages required."""
import argparse
import datetime
import hashlib
import os
from pathlib import Path
import subprocess
import sys


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--samples", type=Path, help="Existing sample RAW directory (no downloads)")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    if sys.platform != "darwin":
        parser.error("Run on a Mac with full Xcode installed.")
    env = os.environ.copy()
    # Never change the Mac's global xcode-select setting.
    if not env.get("DEVELOPER_DIR"):
        selected = subprocess.run(["xcode-select", "-p"], capture_output=True, text=True)
        developer = selected.stdout.strip()
        if selected.returncode or "/CommandLineTools" in developer:
            developer = "/Applications/Xcode.app/Contents/Developer"
        env["DEVELOPER_DIR"] = developer
    if not (Path(env["DEVELOPER_DIR"]) / "usr/bin/xcodebuild").is_file():
        parser.error("Full Xcode required. Set DEVELOPER_DIR to Xcode.app/Contents/Developer.")
    samples = args.samples or (Path(env["ATELIER_SAMPLE_RAWS"]) if env.get("ATELIER_SAMPLE_RAWS") else None)
    if samples:
        samples = samples.expanduser().resolve()
        if not samples.is_dir() or not any(p.is_file() for p in samples.iterdir()):
            parser.error("Sample directory must exist and contain sample files.")
        env["ATELIER_SAMPLE_RAWS"] = str(samples)
    out = root / ".build/local-checks" / datetime.datetime.now().strftime("%Y%m%d-%H%M%S-%f")
    out.mkdir(parents=True)
    env["ATELIER_SAMPLE_OUT"] = str(out / "raw-results")
    Path(env["ATELIER_SAMPLE_OUT"]).mkdir()
    # Explicitly exclude GUI snapshot mode from these command-line checks.
    env.pop("ATELIER_SNAPSHOTS", None)

    def git(*arguments):
        return subprocess.check_output(["git", *arguments], cwd=root, text=True)

    def fingerprint():
        return (git("rev-parse", "HEAD"), git("diff", "HEAD", "--", ".", ":(exclude)Package.resolved"))

    before = fingerprint()
    working_status = git("status", "--short")
    # Untracked task files also form part of the tested state. SwiftPM may create
    # Package.resolved during the run; report it afterward rather than treating it as source.
    def untracked_hashes():
        names = git("ls-files", "--others", "--exclude-standard", "-z").split("\0")
        return {name: hashlib.sha256((root / name).read_bytes()).hexdigest()
                for name in names if name and name != "Package.resolved" and (root / name).is_file()}
    untracked_before = untracked_hashes()
    results = []
    def check(name, command):
        print("\n== " + name + " ==", flush=True)
        try:
            with (out / (name + ".log")).open("w") as log:
                process = subprocess.Popen(command, cwd=root, env=env, stdout=subprocess.PIPE,
                                           stderr=subprocess.STDOUT, text=True)
                try:
                    for line in process.stdout:
                        print(line, end="", flush=True)
                        log.write(line)
                    code = process.wait()
                except KeyboardInterrupt:
                    process.terminate()
                    process.wait()
                    raise
        except OSError as error:
            print(error)
            code = 1
        results.append((name, code))

    print("Revision: " + before[0].strip())
    print("Worktree: " + str(root))
    print("Xcode: " + env["DEVELOPER_DIR"])
    print("Logs: " + str(out))
    print("Working changes:\n" + working_status)
    check("toolchain", ["xcrun", "swift", "--version"])
    check("whitespace", ["git", "diff", "--check", "HEAD"])
    check("help", [sys.executable, str(root / "Scripts/help/build_help_index.py"), "--check"])
    check("build", ["xcrun", "swift", "build"])
    check("tests", ["xcrun", "swift", "test"])
    if fingerprint() != before or untracked_hashes() != untracked_before:
        results.append(("source-changed-during-checks", 1))
    notes = ["Layout snapshots: NOT RUN; render and inspect separately for UI changes.",
             "Real RAW coverage: inspect tests.log for skipped tests; sample files are never downloaded."]
    if not samples:
        notes.append("No sample RAW directory supplied; real-RAW tests may skip.")
    summary = "Revision: " + before[0].strip() + "\n"
    summary += "Working changes at start:\n" + (working_status or "(clean)\n")
    summary += "Working changes at end:\n" + (git("status", "--short") or "(clean)\n")
    summary += "Xcode: " + env["DEVELOPER_DIR"] + "\n"
    summary += "\n".join(name + ": " + ("PASS" if code == 0 else "FAIL (exit " + str(code) + ")")
                         for name, code in results)
    summary += "\n" + "\n".join(notes) + "\n"
    (out / "summary.txt").write_text(summary)
    print("\n" + summary + "Logs: " + str(out))
    return 1 if any(code for _, code in results) else 0


if __name__ == "__main__":
    sys.exit(main())

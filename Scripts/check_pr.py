#!/usr/bin/env python3
"""Local pre-PR checks for Atelier. No GitHub setup or third-party Python packages required."""
import argparse
import datetime
import hashlib
import os
from pathlib import Path
import subprocess
import sys


def whitespace_commands(root, base):
    """Check the PR's net changes, including tracked worktree and new files."""
    merge_base = subprocess.check_output(
        ["git", "merge-base", "HEAD", base], cwd=root, text=True).strip()
    commands = [["git", "diff", "--check", merge_base]]
    names = subprocess.check_output(
        ["git", "ls-files", "--others", "--exclude-standard", "-z"], cwd=root).decode().split("\0")
    commands += [["git", "diff", "--no-index", "--check", "--", "/dev/null", name]
                 for name in names if name and (root / name).is_file()]
    return merge_base, commands


def check_exit_code(command, code, has_output):
    """Only no-index's silent difference status is a successful whitespace check."""
    if (command[:5] == ["git", "diff", "--no-index", "--check", "--"]
            and code == 1 and not has_output):
        return 0
    return code


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--samples", type=Path, help="Existing sample RAW directory (no downloads)")
    parser.add_argument("--base", default="origin/main", help="Fetched PR base ref (default: origin/main)")
    parser.add_argument("--ui", action="store_true", help="Also run native UI and visual checks in a logged-in session")
    parser.add_argument("--quiet", action="store_true", help="Show progress and the summary, with detailed output in logs")
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

    try:
        merge_base, whitespace = whitespace_commands(root, args.base)
    except subprocess.CalledProcessError:
        parser.error("Cannot resolve PR base. Fetch origin main or supply --base <ref>.")
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
        has_output = False
        try:
            with (out / (name + ".log")).open("w") as log:
                process = subprocess.Popen(command, cwd=root, env=env, stdout=subprocess.PIPE,
                                           stderr=subprocess.STDOUT, text=True)
                try:
                    for line in process.stdout:
                        has_output = True
                        if not args.quiet:
                            print(line, end="", flush=True)
                        log.write(line)
                    code = check_exit_code(command, process.wait(), has_output)
                except KeyboardInterrupt:
                    process.terminate()
                    process.wait()
                    raise
        except OSError as error:
            print(error)
            code = 1
        results.append((name, code))

    print("Revision: " + before[0].strip())
    print("PR base: " + args.base + " (merge base " + merge_base + ")")
    print("Worktree: " + str(root))
    print("Xcode: " + env["DEVELOPER_DIR"])
    print("Logs: " + str(out))
    print("Working changes:\n" + working_status)
    check("toolchain", ["xcrun", "swift", "--version"])
    for index, command in enumerate(whitespace):
        check("whitespace" if index == 0 else "whitespace-new-" + str(index), command)
    check("script-tests", [sys.executable, "-m", "unittest", "discover", "-s", "Scripts/tests"])
    check("help", [sys.executable, str(root / "Scripts/help/build_help_index.py"), "--check"])
    check("build", ["xcrun", "swift", "build"])
    check("tests", ["xcrun", "swift", "test"])
    if args.ui:
        check("ui", [sys.executable, str(root / "Scripts/check_ui.py"), "--base", args.base,
                     "--output", str(out / "ui")])
    if fingerprint() != before or untracked_hashes() != untracked_before:
        results.append(("source-changed-during-checks", 1))
    notes = ["Real RAW coverage: inspect tests.log for skipped tests; sample files are never downloaded."]
    if args.ui:
        notes.append("UI results: " + str(out / "ui"))
    else:
        notes.append("UI checks: NOT RUN. Use --ui for native smoke and visual checks.")
    if not samples:
        notes.append("No sample RAW directory supplied; real-RAW tests may skip.")
    summary = "Revision: " + before[0].strip() + "\n"
    summary += "PR base: " + args.base + " (merge base " + merge_base + ")\n"
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

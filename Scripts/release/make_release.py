#!/usr/bin/env python3
"""Makes an Atelier release to share as a file (AT-087, Docs/Releasing.md). Run on a Mac.

    python3 Scripts/release/make_release.py                       # ad hoc signed
    python3 Scripts/release/make_release.py --sign "Atelier Release"   # self-signed certificate
    python3 Scripts/release/make_release.py --sign "Developer ID Application: Name (TEAMID)" \\
        --notary-profile atelier                                  # signed and notarized
    ... --publish                                                 # also create the GitHub Release

Releases live in a public repository of their own, roshan-davis/atelier-releases, so the
source repository can stay private: its GitHub Releases hold the files and its appcast.xml is
the feed installed copies read.

Steps: reads the published appcast; checks VERSION is newer and that ReleaseNotes.md has its
section; builds the universal app with the version, build number, feed and key; signs it (and
notarizes it with a Developer ID); makes Atelier-<version>.dmg and .zip under
.build/Releases/<version>/; signs the zip with Sparkle's EdDSA key; writes the new appcast.xml
next to them. With --publish it creates the GitHub Release v<version> in the releases repository
with both files, then commits appcast.xml there (gh); installed copies see it from then on.
"""
import base64
import json
import urllib.error
import urllib.request
import argparse
from datetime import datetime, timezone
from pathlib import Path
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(Path(__file__).resolve().parent))
import appcast  # noqa: E402

# Public, holds only appcast.xml and the release files (no source). Keep in step with FEED_URL
# in build_macos_app.py.
REPO = "roshan-davis/atelier-releases"
FEED_URL = "https://raw.githubusercontent.com/%s/main/appcast.xml" % REPO
NOTES = ROOT / "Sources/AtelierApp/Resources/ReleaseNotes.md"
BUILD = ROOT / "Scripts/build_macos_app.py"

READ_ME_UNSIGNED = """Opening Atelier the first time

This copy of Atelier isn't notarized by Apple, so macOS asks before opening it once:

1. Drag Atelier to Applications, then open it. macOS says it can't check it.
2. Open System Settings > Privacy & Security, scroll down, and click Open Anyway next to Atelier.
3. Click Open Anyway again and enter your password.

After that Atelier opens normally, checks for new versions by itself, and installs them when you
choose Install in the update window.
"""


def run(command, **kw):
    print("$ " + " ".join(str(c) for c in command), flush=True)
    return subprocess.run([str(c) for c in command], check=True, **kw)


def tool(name):
    """One of Sparkle's tools (sign_update, generate_keys) from the SwiftPM artifacts."""
    for found in sorted((ROOT / ".build/artifacts").glob("**/bin/" + name)):
        return found
    raise SystemExit(name + " not found under .build/artifacts. Run `swift package resolve` first.")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--sign", default="-", metavar="IDENTITY",
                        help="Developer ID Application identity, a self-signed certificate's name, or - (ad hoc)")
    parser.add_argument("--notary-profile", help="notarytool keychain profile (xcrun notarytool store-credentials)")
    parser.add_argument("--critical", action="store_true", help="Mark as a critical update (no Skip This Version)")
    parser.add_argument("--publish", action="store_true",
                        help="Create the GitHub Release v<version> in %s and update its appcast.xml (gh)" % REPO)
    parser.add_argument("--allow-dirty", action="store_true", help="Release with uncommitted changes (testing only)")
    args = parser.parse_args()
    if sys.platform != "darwin":
        raise SystemExit("Releases are built on a Mac.")
    if args.publish and not shutil.which("gh"):
        parser.error("--publish uploads with gh: brew install gh, then gh auth login")
    developer_id = args.sign.startswith("Developer ID Application")
    if developer_id and not args.notary_profile:
        parser.error("A Developer ID release is notarized: pass --notary-profile (Docs/Releasing.md, step 3)")

    # 1. What we're releasing, checked before anything is built.
    if not args.allow_dirty and subprocess.run(["git", "status", "--porcelain"], cwd=ROOT,
                                               capture_output=True, text=True).stdout.strip():
        raise SystemExit("Commit or stash your changes first, so the release matches a commit.")
    version = appcast.Version.parse((ROOT / "VERSION").read_text())
    build = int(subprocess.check_output(["git", "rev-list", "--count", "HEAD"], cwd=ROOT, text=True).strip())
    release = next((r for r in appcast.parse_notes(NOTES.read_text()) if r.version == version), None)
    if release is None or not release.sections:
        raise SystemExit("Add a '## %s (date)' section with New/Improved/Fixed bullets to %s." % (version, NOTES.relative_to(ROOT)))
    published, sha = read_published_appcast()
    items = appcast.read_appcast(published)
    appcast.check_new_release(items, version, build)
    kind = appcast.update_kind(items[0].version, version) if items else "first"
    print("Releasing Atelier %s (build %d), a %s release, signed %s." % (
        version, build, kind, "with " + args.sign if args.sign != "-" else "ad hoc"))

    # 2. The app.
    out = ROOT / ".build/Releases" / str(version)
    shutil.rmtree(out, ignore_errors=True)
    out.mkdir(parents=True)
    app = out / "Atelier.app"
    run([sys.executable, BUILD, "--configuration", "release", "--arch", "universal", "--release",
         "--version", version, "--build-number", build, "--sign", args.sign, "--output", app])
    run(["codesign", "--verify", "--deep", "--strict", app])
    if developer_id:
        notarize(app, out, args.notary_profile)

    # 3. The zip Sparkle downloads, and the disk image people download.
    archive = out / ("Atelier-%s.zip" % version)
    run(["ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", app, archive])
    dmg = make_dmg(app, out, version, developer_id, args)

    # 4. Sign the zip for Sparkle, and add it to the appcast.
    signature, length = appcast.parse_sign_update(
        subprocess.check_output([str(tool("sign_update")), str(archive)], text=True))
    url = "https://github.com/%s/releases/download/v%s/%s" % (REPO, version, archive.name)
    item = appcast.new_item(items, release, build, url, length, signature, datetime.now(timezone.utc),
                            critical=args.critical)
    feed = out / "appcast.xml"
    feed.write_text(appcast.write_appcast(items + [item]))
    notes_file = out / "notes.md"
    notes_file.write_text(item.notes + "\n")
    print("Wrote %s with %s added." % (feed, version))

    # 5. The GitHub Release.
    if args.publish:
        command = ["gh", "release", "create", "v%s" % version, archive, dmg, "--repo", REPO,
                   "--title", "Atelier %s" % version, "--notes-file", notes_file]
        if version.prerelease:
            command.append("--prerelease")
        run(command)
        # The feed last, once the files it points at are there.
        publish_appcast(feed, sha, version)
        print("\nPublished Atelier %s. Installed copies see it within a day, or at once with Check for Updates…" % version)
    else:
        print("\nDone: %s\n%s\n%s" % (archive, dmg, feed))
        print("Nothing is published. Run again with --publish, or by hand: make a GitHub Release v%s in %s "
              "with the .dmg and .zip, then replace appcast.xml there with the one above." % (version, REPO))


def read_published_appcast():
    """The live appcast.xml and its blob sha (for the update), or ("", None) before the first release.
    Read through the API with gh when it's there, so a just-published release is seen at once."""
    if shutil.which("gh"):
        result = subprocess.run(["gh", "api", "repos/%s/contents/appcast.xml" % REPO], capture_output=True, text=True)
        if result.returncode == 0:
            data = json.loads(result.stdout)
            return base64.b64decode(data["content"]).decode("utf-8"), data["sha"]
        if "Not Found" not in result.stderr and "404" not in result.stderr:
            raise SystemExit("Couldn't read appcast.xml from %s: %s" % (REPO, result.stderr.strip()))
        return "", None
    try:
        with urllib.request.urlopen(FEED_URL, timeout=30) as response:
            return response.read().decode("utf-8"), None
    except urllib.error.HTTPError as error:
        if error.code == 404:
            return "", None
        raise


def publish_appcast(feed, sha, version):
    """Commits the new appcast.xml to the releases repository."""
    fields = ["-f", "message=Atelier %s" % version,
              "-f", "content=" + base64.b64encode(feed.read_bytes()).decode("ascii")]
    if sha:
        fields += ["-f", "sha=" + sha]
    print("$ gh api -X PUT repos/%s/contents/appcast.xml (Atelier %s)" % (REPO, version), flush=True)
    subprocess.run(["gh", "api", "-X", "PUT", "repos/%s/contents/appcast.xml" % REPO] + fields,
                   check=True, stdout=subprocess.DEVNULL)


def notarize(path, out, profile):
    """Notarizes an app (zipped for upload) or a disk image, then staples the ticket to it."""
    upload = path
    if path.suffix == ".app":
        upload = out / "notarize.zip"
        run(["ditto", "-c", "-k", "--keepParent", path, upload])
    run(["xcrun", "notarytool", "submit", upload, "--keychain-profile", profile, "--wait"])
    run(["xcrun", "stapler", "staple", path])
    if upload != path:
        upload.unlink()


def make_dmg(app, out, version, developer_id, args):
    """Atelier and an Applications shortcut to drag it to, plus a Read Me when not notarized."""
    staging = out / "dmg"
    staging.mkdir()
    run(["ditto", app, staging / "Atelier.app"])
    (staging / "Applications").symlink_to("/Applications")
    if not developer_id:
        (staging / "Read Me First.txt").write_text(READ_ME_UNSIGNED)
    dmg = out / ("Atelier-%s.dmg" % version)
    run(["hdiutil", "create", "-volname", "Atelier %s" % version, "-srcfolder", staging, "-ov", "-format", "UDZO", dmg])
    shutil.rmtree(staging)
    if args.sign != "-":
        run(["codesign", "--force", "--sign", args.sign] + (["--timestamp"] if developer_id else []) + [dmg])
    if developer_id:
        notarize(dmg, out, args.notary_profile)
    return dmg


if __name__ == "__main__":
    main()

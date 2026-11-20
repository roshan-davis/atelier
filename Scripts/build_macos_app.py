#!/usr/bin/env python3
"""Build Atelier into a local, ad-hoc-signed macOS app.

--arch picks the processor: native (this Mac, the default), arm64 (Apple Silicon),
x86_64 (Intel) or universal (one app that runs natively on both). --arch all builds
the three release apps side by side under .build/Applications/<arch>/.

--release makes a copy to share (Scripts/release/make_release.py passes it, AT-087): the version
from VERSION, the build number from the commit count, Sparkle's feed and public key so it updates
itself, and --sign's identity (a Developer ID, a self-signed certificate, or "-" for ad hoc).
Without --release the app never checks for updates.
"""
import argparse
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import uuid

ROOT = Path(__file__).resolve().parents[1]
ARCHS = ["arm64", "x86_64"]
APP_ICON = ROOT / "Sources/AtelierApp/Resources/AppIcon.icns"
MIN_MACOS = "15.0"
VERSION_FILE = ROOT / "VERSION"
PUBLIC_KEY_FILE = ROOT / "Scripts/release/sparkle-public-key.txt"
# The appcast in the public releases repository (the source repository is private), which
# Scripts/release/make_release.py updates after uploading a release's files.
FEED_URL = "https://raw.githubusercontent.com/roshan-davis/atelier-releases/main/appcast.xml"


def read_version():
    return VERSION_FILE.read_text().strip()


def build_number():
    """The commit count, so every later commit has a larger number (Sparkle compares it)."""
    return subprocess.check_output(["git", "rev-list", "--count", "HEAD"], cwd=ROOT, text=True).strip()


def signing_kind(identity):
    if identity == "-":
        return "adhoc"
    return "developerID" if identity.startswith("Developer ID Application") else "selfSigned"


def swift_build(configuration, arch, env, scratch_path):
    """Builds every product for one processor (or this Mac's when arch is None) and
    returns the folder holding the executables and resource bundles."""
    flags = ["-c", configuration]
    if scratch_path is not None:
        flags += ["--scratch-path", str(scratch_path.resolve())]
    if arch:
        # One triple per build keeps SwiftPM's own build system (and its resource bundle
        # layout); the two results are joined with lipo for universal.
        flags += ["--triple", arch + "-apple-macosx" + MIN_MACOS]
    # xcrun picks the toolchain from DEVELOPER_DIR, even when a `swift` from the Command
    # Line Tools comes first on PATH.
    subprocess.run(["xcrun", "swift", "build"] + flags, cwd=ROOT, env=env, check=True)
    return Path(subprocess.check_output(["xcrun", "swift", "build"] + flags + ["--show-bin-path"],
                                        cwd=ROOT, env=env, text=True).strip())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--configuration", choices=["debug", "release"], default="release")
    parser.add_argument("--arch", choices=["native", "arm64", "x86_64", "universal", "all"], default="native",
                        help="native: this Mac; arm64: Apple Silicon; x86_64: Intel; "
                             "universal: both in one app; all: arm64, x86_64 and universal apps")
    parser.add_argument("--output", type=Path,
                        help="Default .build/Applications/Atelier.app (native) or "
                             ".build/Applications/<arch>/Atelier.app")
    parser.add_argument("--scratch-path", type=Path, help="Use a separate SwiftPM build directory")
    parser.add_argument("--bundle-id", default="local.atelier.app")
    parser.add_argument("--test-catalog", type=Path, help="Debug only: disposable catalog override")
    parser.add_argument("--release", action="store_true",
                        help="A copy to share: version, build number, update feed and key (AT-087)")
    parser.add_argument("--version", help="Default: the VERSION file")
    parser.add_argument("--build-number", help="Default: the commit count")
    parser.add_argument("--feed-url", default=FEED_URL, help="Appcast URL (a local file:// one to test updates)")
    parser.add_argument("--sign", default="-", metavar="IDENTITY",
                        help='Code signing identity: "Developer ID Application: …" (hardened runtime, '
                             'for notarizing), a self-signed certificate\'s name, or - for ad hoc (default)')
    args = parser.parse_args()
    args.version = args.version or read_version()
    args.build_number = args.build_number or build_number()
    if args.release:
        if args.configuration != "release":
            parser.error("--release needs --configuration release")
        if not PUBLIC_KEY_FILE.exists() or not PUBLIC_KEY_FILE.read_text().strip():
            parser.error("--release needs Sparkle's public key in " + str(PUBLIC_KEY_FILE.relative_to(ROOT))
                         + " (see Docs/Releasing.md, step 1)")
    if args.test_catalog and args.configuration != "debug":
        parser.error("A test catalog requires --configuration debug")
    if args.arch == "all" and args.output:
        parser.error("--arch all writes one app per architecture; leave out --output")
    env = os.environ.copy()
    # Prefer full Xcode (as check_pr.py does) without changing the Mac's xcode-select
    # setting. The app also builds with the Command Line Tools if Xcode isn't there.
    if not env.get("DEVELOPER_DIR"):
        selected = subprocess.run(["xcode-select", "-p"], capture_output=True, text=True)
        developer = selected.stdout.strip()
        xcode = "/Applications/Xcode.app/Contents/Developer"
        if (selected.returncode or "/CommandLineTools" in developer) and Path(xcode).is_dir():
            developer = xcode
        if developer:
            env["DEVELOPER_DIR"] = developer
    print("Toolchain: " + env.get("DEVELOPER_DIR", "(xcode-select default)"))
    revision = subprocess.check_output(["git", "rev-parse", "--short", "HEAD"], cwd=ROOT, text=True).strip()

    products = {}
    wanted = ["native"] if args.arch == "native" else (ARCHS if args.arch in ("universal", "all") else [args.arch])
    for arch in wanted:
        products[arch] = swift_build(args.configuration, None if arch == "native" else arch, env, args.scratch_path)
    targets = ["arm64", "x86_64", "universal"] if args.arch == "all" else [args.arch]
    built = []
    for arch in targets:
        if arch == "native":
            output = args.output or ROOT / ".build/Applications/Atelier.app"
        else:
            output = args.output or ROOT / ".build/Applications" / arch / "Atelier.app"
        built.append(package(args, arch, products, revision, output))
    for output, kinds in built:
        print("Built", output, "from", revision, "for", kinds)


def embed_sparkle(app, products):
    """Copies Sparkle.framework (already universal) into the app and points the executable at it.
    Its XPC services are only for sandboxed apps, so they are left out (Sparkle's sandboxing guide)."""
    framework = products / "Sparkle.framework"
    if not framework.is_dir():
        raise SystemExit("Sparkle.framework is missing from " + str(products) + "; run swift package resolve")
    frameworks = app / "Contents/Frameworks"
    frameworks.mkdir(parents=True, exist_ok=True)
    target = frameworks / "Sparkle.framework"
    shutil.copytree(framework, target, symlinks=True)
    shutil.rmtree(target / "Versions/B/XPCServices", ignore_errors=True)
    xpc_link = target / "XPCServices"
    if xpc_link.is_symlink():
        xpc_link.unlink()
    executable = app / "Contents/MacOS/AtelierApp"
    rpaths = subprocess.run(["otool", "-l", str(executable)], capture_output=True, text=True).stdout
    if "@executable_path/../Frameworks" not in rpaths:
        subprocess.run(["install_name_tool", "-add_rpath", "@executable_path/../Frameworks", str(executable)], check=True)


def sign_bundle(app, helper, identity):
    """Signs inside out: Sparkle's pieces, the framework, the helper, then the app. A Developer ID
    gets the hardened runtime and a secure timestamp, which notarization requires."""
    flags = ["codesign", "--force", "--sign", identity]
    if signing_kind(identity) == "developerID":
        flags += ["--options", "runtime", "--timestamp"]
    sparkle = app / "Contents/Frameworks/Sparkle.framework"
    for part in [sparkle / "Versions/B/Autoupdate", sparkle / "Versions/B/Updater.app", sparkle]:
        if part.exists():
            subprocess.run(flags + [str(part)], check=True)
    subprocess.run(flags + [str(helper)], check=True)
    # No entitlements: Atelier isn't sandboxed and needs no hardened-runtime exceptions (no JIT,
    # no Apple Events, no unsigned libraries).
    subprocess.run(flags + [str(app)], check=True)


def executable_for(arch, products, name, scratch):
    """The executable for one arch, or a lipo-joined copy for universal."""
    if arch != "universal":
        return products[arch] / name
    joined = scratch / name
    subprocess.run(["lipo", "-create", "-output", str(joined)] + [str(products[a] / name) for a in ARCHS],
                   check=True)
    return joined


def package(args, arch, products, revision, output):
    # Resource bundles hold no machine code, so the arm64 build's copies serve universal too.
    resources_from = products["arm64" if arch == "universal" else arch]
    output = output.expanduser().absolute()
    output.parent.mkdir(parents=True, exist_ok=True)
    staging = output.parent / ("Atelier-building-" + str(uuid.uuid4()) + ".app")

    def bundle(path, executable, name, identifier, resource_names):
        mac = path / "Contents/MacOS"
        mac.mkdir(parents=True)
        shutil.copy2(executable_file(executable), mac / executable)
        for resource in resource_names:
            source = resources_from / resource
            if source.is_dir():
                shutil.copytree(source, path / "Contents/Resources" / resource)
        # Finder and the Dock read the icon from the bundle itself (CFBundleIconFile); the app
        # setting it at run time only changes the Dock while it runs.
        resources = path / "Contents/Resources"
        resources.mkdir(parents=True, exist_ok=True)
        shutil.copy2(APP_ICON, resources / APP_ICON.name)
        info = {"CFBundleIdentifier": identifier, "CFBundleExecutable": executable,
                "CFBundleIconFile": APP_ICON.stem,
                "CFBundleName": name, "CFBundleDisplayName": name, "CFBundlePackageType": "APPL",
                "CFBundleVersion": args.build_number, "CFBundleShortVersionString": args.version,
                "LSMinimumSystemVersion": MIN_MACOS, "AtelierSourceRevision": revision,
                "NSHumanReadableCopyright": "Atelier " + args.version}
        if args.release and executable == "AtelierApp":
            # Sparkle (AT-087): the feed, the key every update must be signed with, daily checks
            # without first asking. Automatic install only for notarized (Developer ID) copies.
            developer_id = signing_kind(args.sign) == "developerID"
            info.update({"SUFeedURL": args.feed_url, "SUPublicEDKey": PUBLIC_KEY_FILE.read_text().strip(),
                         "SUEnableAutomaticChecks": True, "SUAllowsAutomaticUpdates": developer_id,
                         "SUAutomaticallyUpdate": developer_id, "AtelierSigning": signing_kind(args.sign)})
        if args.test_catalog and executable == "AtelierApp":
            info["AtelierTestCatalogPath"] = str(args.test_catalog.absolute())
        if executable == "AtelierApp":
            # HDR projects (.atelierhdr, made in Atelier's HDR mode) are packages: Finder shows
            # one item, and folder imports never pull in their private source copy.
            info["UTExportedTypeDeclarations"] = [{"UTTypeIdentifier": "local.atelier.hdr-project",
                "UTTypeDescription": "Atelier HDR Project", "UTTypeConformsTo": ["com.apple.package"],
                "UTTypeTagSpecification": {"public.filename-extension": ["atelierhdr"]}}]
        (path / "Contents/Info.plist").write_bytes(plistlib.dumps(info))

    scratch = output.parent / ("Atelier-lipo-" + str(uuid.uuid4()))
    scratch.mkdir(parents=True)

    def executable_file(name):
        return executable_for(arch, products, name, scratch)

    bundle(staging, "AtelierApp", "Atelier", args.bundle_id,
           ["Atelier_AtelierApp.bundle", "GRDB_GRDB.bundle", "Atelier_AtelierCore.bundle"])
    # Release: keep the symbols in Atelier.app.dSYM next to the app (crash logs and Instruments
    # find it by UUID), then strip them from the app's executable. They were about 29 MB of the
    # app (Nov 19, 2026: 101.4 MB to 72.1 MB). dsymutil reads the debug map before strip removes it.
    staging_dsym = None
    if args.configuration == "release":
        executable = staging / "Contents/MacOS/AtelierApp"
        staging_dsym = staging.with_name(staging.name + ".dSYM")
        subprocess.run(["xcrun", "dsymutil", str(executable), "-o", str(staging_dsym)], check=True)
        subprocess.run(["xcrun", "strip", "-x", str(executable)], check=True)
    # Sparkle.framework (AT-087) goes in Contents/Frameworks, where the app finds it.
    embed_sparkle(staging, resources_from)
    # The MCP helper chat apps launch (Settings > Agents shows its path). Nested code is
    # signed before the bundle that holds it.
    helper = staging / "Contents/MacOS/atelier-mcp"
    shutil.copy2(executable_file("atelier-mcp"), helper)
    sign_bundle(staging, helper, args.sign)
    if output.exists():
        backup = output.parent / (output.stem + "-previous-" + str(uuid.uuid4()) + ".app")
        output.rename(backup)
        print("Previous generated app preserved at", backup)
    staging.rename(output)
    dsym = output.with_name(output.name + ".dSYM")
    if dsym.exists():
        # The previous app (kept above) still matches the previous dSYM, so keep it beside it.
        dsym.rename(output.parent / (output.stem + "-previous-" + str(uuid.uuid4()) + ".app.dSYM"))
    if staging_dsym is not None:
        staging_dsym.rename(dsym)
    shutil.rmtree(scratch, ignore_errors=True)
    kinds = subprocess.check_output(["lipo", "-archs", str(output / "Contents/MacOS/AtelierApp")], text=True).strip()
    return output, kinds


if __name__ == "__main__":
    main()

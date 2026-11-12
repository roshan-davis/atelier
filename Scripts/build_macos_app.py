#!/usr/bin/env python3
"""Build Atelier into a local, ad-hoc-signed macOS app.

--arch picks the processor: native (this Mac, the default), arm64 (Apple Silicon),
x86_64 (Intel) or universal (one app that runs natively on both). --arch all builds
the three release apps side by side under .build/Applications/<arch>/.
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
    args = parser.parse_args()
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
                "CFBundleVersion": "1", "CFBundleShortVersionString": "0.1",
                "LSMinimumSystemVersion": "15.0", "AtelierSourceRevision": revision}
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
    subprocess.run(["codesign", "--force", "--sign", "-", str(staging)], check=True)
    if output.exists():
        backup = output.parent / (output.stem + "-previous-" + str(uuid.uuid4()) + ".app")
        output.rename(backup)
        print("Previous generated app preserved at", backup)
    staging.rename(output)
    shutil.rmtree(scratch, ignore_errors=True)
    kinds = subprocess.check_output(["lipo", "-archs", str(output / "Contents/MacOS/AtelierApp")], text=True).strip()
    return output, kinds


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Build Atelier and its HDR companion into a local, ad-hoc-signed macOS app.

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
MIN_MACOS = "15.0"


def swift_build(configuration, arch, env):
    """Builds every product for one processor (or this Mac's when arch is None) and
    returns the folder holding the executables and resource bundles."""
    flags = ["-c", configuration]
    if arch:
        # One triple per build keeps SwiftPM's own build system (and its resource bundle
        # layout); the two results are joined with lipo for universal.
        flags += ["--triple", arch + "-apple-macosx" + MIN_MACOS]
    subprocess.run(["swift", "build"] + flags, cwd=ROOT, env=env, check=True)
    return Path(subprocess.check_output(["swift", "build"] + flags + ["--show-bin-path"],
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
    parser.add_argument("--bundle-id", default="local.atelier.app")
    parser.add_argument("--test-catalog", type=Path, help="Debug only: disposable catalog override")
    parser.add_argument("--snapshots", type=Path, help="Debug only: HDR layout snapshot folder")
    args = parser.parse_args()
    if (args.test_catalog or args.snapshots) and args.configuration != "debug":
        parser.error("Test catalog and snapshots require --configuration debug")
    if args.arch == "all" and args.output:
        parser.error("--arch all writes one app per architecture; leave out --output")
    env = os.environ.copy()
    env.setdefault("DEVELOPER_DIR", "/Applications/Xcode.app/Contents/Developer")
    revision = subprocess.check_output(["git", "rev-parse", "--short", "HEAD"], cwd=ROOT, text=True).strip()

    products = {}
    wanted = ["native"] if args.arch == "native" else (ARCHS if args.arch in ("universal", "all") else [args.arch])
    for arch in wanted:
        products[arch] = swift_build(args.configuration, None if arch == "native" else arch, env)
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
        info = {"CFBundleIdentifier": identifier, "CFBundleExecutable": executable,
                "CFBundleName": name, "CFBundleDisplayName": name, "CFBundlePackageType": "APPL",
                "CFBundleVersion": "1", "CFBundleShortVersionString": "0.1",
                "LSMinimumSystemVersion": "15.0", "AtelierSourceRevision": revision}
        if args.test_catalog and executable == "AtelierApp":
            info["AtelierTestCatalogPath"] = str(args.test_catalog.absolute())
        if executable == "AtelierHDRApp":
            info["CFBundleDocumentTypes"] = [{"CFBundleTypeName": "Atelier HDR Project",
                "CFBundleTypeRole": "Editor", "LSItemContentTypes": ["local.atelier.hdr-project"],
                "LSTypeIsPackage": True}]
            info["UTExportedTypeDeclarations"] = [{"UTTypeIdentifier": "local.atelier.hdr-project",
                "UTTypeDescription": "Atelier HDR Project", "UTTypeConformsTo": ["com.apple.package"],
                "UTTypeTagSpecification": {"public.filename-extension": ["atelierhdr"]}}]
            if args.snapshots:
                info["AtelierHDRSnapshotPath"] = str(args.snapshots.absolute())
        (path / "Contents/Info.plist").write_bytes(plistlib.dumps(info))

    scratch = output.parent / ("Atelier-lipo-" + str(uuid.uuid4()))
    scratch.mkdir(parents=True)

    def executable_file(name):
        return executable_for(arch, products, name, scratch)

    bundle(staging, "AtelierApp", "Atelier", args.bundle_id,
           ["Atelier_AtelierApp.bundle", "GRDB_GRDB.bundle"])
    helper = staging / "Contents/Helpers/Atelier HDR.app"
    bundle(helper, "AtelierHDRApp", "Atelier HDR", args.bundle_id + ".hdr",
           ["Atelier_AtelierHDRApp.bundle", "GRDB_GRDB.bundle"])
    subprocess.run(["codesign", "--force", "--sign", "-", str(helper)], check=True)
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

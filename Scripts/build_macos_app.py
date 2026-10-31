#!/usr/bin/env python3
"""Build Atelier and its HDR companion into a local, ad-hoc-signed macOS app."""
import argparse
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import uuid

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--configuration", choices=["debug", "release"], default="release")
    parser.add_argument("--output", type=Path, default=ROOT / ".build/Applications/Atelier.app")
    parser.add_argument("--bundle-id", default="local.atelier.app")
    parser.add_argument("--test-catalog", type=Path, help="Debug only: disposable catalog override")
    parser.add_argument("--snapshots", type=Path, help="Debug only: HDR layout snapshot folder")
    args = parser.parse_args()
    if (args.test_catalog or args.snapshots) and args.configuration != "debug":
        parser.error("Test catalog and snapshots require --configuration debug")
    env = os.environ.copy()
    env.setdefault("DEVELOPER_DIR", "/Applications/Xcode.app/Contents/Developer")
    subprocess.run(["swift", "build", "-c", args.configuration], cwd=ROOT, env=env, check=True)
    products = Path(subprocess.check_output(["swift", "build", "-c", args.configuration, "--show-bin-path"],
                                           cwd=ROOT, env=env, text=True).strip())
    revision = subprocess.check_output(["git", "rev-parse", "--short", "HEAD"], cwd=ROOT, text=True).strip()
    output = args.output.expanduser().absolute()
    output.parent.mkdir(parents=True, exist_ok=True)
    staging = output.parent / ("Atelier-building-" + str(uuid.uuid4()) + ".app")

    def bundle(path, executable, name, identifier, resource_names):
        mac = path / "Contents/MacOS"
        mac.mkdir(parents=True)
        shutil.copy2(products / executable, mac / executable)
        for resource in resource_names:
            source = products / resource
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
    print("Built", output, "from", revision)


if __name__ == "__main__":
    main()

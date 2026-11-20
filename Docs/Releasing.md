# Releasing Atelier (AT-087)

How to make a version people can download, and how installed copies update themselves.
Design: PRD "Updates and distribution". Everything runs on a Mac, from a clean checkout of `main`.

## Where things live

| What | Where |
|---|---|
| Version people see | `VERSION` (semantic: `1.3.0`, `1.3.0-beta.1`) |
| Build number Sparkle compares | the commit count of `main` (`git rev-list --count HEAD`), set by the build |
| Release notes | `Sources/AtelierApp/Resources/ReleaseNotes.md` (What's New and the update window) |
| The feed installed copies read | `Releases/appcast.xml` on `main` (raw.githubusercontent.com) |
| The downloads | GitHub Release `v<version>`: `Atelier-<version>.dmg` (people) and `.zip` (Sparkle) |
| Update signing key | private: your login Keychain; public: `Scripts/release/sparkle-public-key.txt` |

## 1. Once: make the update signing key

```
cd ~/RoshProjects/Atelier/App
swift package resolve
.build/artifacts/sparkle/Sparkle/bin/generate_keys
```

It stores the private key in your login Keychain and prints the public key. Put that one line in
`Scripts/release/sparkle-public-key.txt` and commit it. Then back up the private key somewhere
safe (a password manager or an encrypted drive):

```
.build/artifacts/sparkle/Sparkle/bin/generate_keys -x ~/Desktop/atelier-sparkle-private-key
```

If the private key is lost, copies already out there can't update any more (a Developer ID build
can move to a new key). Never commit it.

## 2. Choose how to sign

- **Ad hoc** (free, the default): people click Open Anyway once per Mac; Keychain passwords and
  folder permissions are asked for again after each update.
- **Self-signed certificate** (free): in Keychain Access > Certificate Assistant > Create a
  Certificate…, name it `Atelier Release`, Identity Type Self-Signed Root, Certificate Type Code
  Signing. Then pass `--sign "Atelier Release"`. People still click Open Anyway once, but the app
  keeps the same identity across versions, so passwords and permissions survive updates.
- **Developer ID** ($99/year, Apple Developer Program): no warnings and fully automatic installs.
  See step 3.

## 3. Developer ID only: notarization credentials, once

After enrolling, create a "Developer ID Application" certificate in Xcode > Settings… > Accounts >
Manage Certificates…, then store notarization credentials (an app-specific password from
appleid.apple.com):

```
xcrun notarytool store-credentials atelier --apple-id <your Apple ID> --team-id <TEAMID>
```

## 4. Each release

1. Raise `VERSION`: patch for fixes (1.3.1), minor for features (1.4.0), major (2.0.0) when the
   catalog changes in a way an older Atelier can't read (then also raise `Catalog.format` in
   `Catalog+Upgrade.swift`, in the same PR as that migration).
2. Add `## <version> (<date>)` to `ReleaseNotes.md`: a sentence, then `### New`, `### Improved`,
   `### Fixed`. Merge both to `main`.
3. On `main`, run one of:
   ```
   python3 Scripts/release/make_release.py --publish
   python3 Scripts/release/make_release.py --sign "Atelier Release" --publish
   python3 Scripts/release/make_release.py --sign "Developer ID Application: <Name> (<TEAMID>)" --notary-profile atelier --publish
   ```
   `--publish` uploads both files to the GitHub Release with `gh` (`brew install gh`, then
   `gh auth login`). Without it, upload `.build/Releases/<version>/Atelier-<version>.dmg` and
   `.zip` by hand to a release named `v<version>`. Add `--critical` for an urgent fix.
4. Open a PR with the changed `Releases/appcast.xml` and merge it. Installed copies see the
   version within a day, or at once with Atelier > Check for Updates….

A pre-release version (`1.4.0-beta.1`) goes on the beta channel: only copies with Settings >
Updates > Include beta versions see it, and its GitHub Release is marked pre-release.

A major version gets `sparkle:minimumAutoupdateVersion` automatically, so every older copy asks
before installing it, and its notes start with a line about the catalog upgrade.

## Testing an update before releasing

1. Build an older copy that reads a test feed from your branch:
   ```
   python3 Scripts/build_macos_app.py --configuration release --release --version 0.9.0 \
     --feed-url https://raw.githubusercontent.com/roshan-davis/atelier/<branch>/Releases/appcast.xml
   ```
2. Run `make_release.py` on that branch (`--allow-dirty` if needed), upload the zip to a draft or
   pre-release, and push the branch with its `Releases/appcast.xml`.
3. Open the 0.9.0 copy: Atelier > Check for Updates… finds the release, shows its notes, installs
   it, and What's New opens once after the restart.

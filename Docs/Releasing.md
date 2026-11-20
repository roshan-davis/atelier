# Releasing Atelier (AT-087)

How to make a version people can download, and how installed copies update themselves.
Design: PRD "Updates and distribution". Everything runs on a Mac, from a clean checkout of `main`.

## Where things live

| What | Where |
|---|---|
| Version people see | `VERSION` (semantic: `1.3.0`, `1.3.0-beta.1`) |
| Build number Sparkle compares | the commit count of `main` (`git rev-list --count HEAD`), set by the build |
| Release notes | `Sources/AtelierApp/Resources/ReleaseNotes.md` (What's New and the update window) |
| The feed installed copies read | `atelier/appcast.xml` on `main` of the public `roshan-davis/product-releases` repository (raw.githubusercontent.com) |
| The downloads | GitHub Release `atelier-v<version>` in `product-releases`: `Atelier-<version>.dmg` (people) and `.zip` (Sparkle) |

The source repositories are private, so releases of all Rosh's apps go to `product-releases`,
which holds only feeds and release files: one folder per app for its feed (`atelier/`, `easel/`)
and tags prefixed with the app (`atelier-v1.3.0`, `easel-v0.4.0`). Create it once on github.com: New repository, name `product-releases`,
Public, tick "Add a README file" (a release needs a first commit), Create repository.
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
   `--publish` creates the release `atelier-v<version>` in `product-releases` with both files,
   then replaces `atelier/appcast.xml` there, using `gh` (`brew install gh`, then `gh auth login`). Installed
   copies see the version within a day, or at once with Atelier > Check for Updates….
   Without `--publish` nothing goes out: the files and the new `appcast.xml` are in
   `.build/Releases/<version>/` to check or upload by hand. Add `--critical` for an urgent fix.

A pre-release version (`1.4.0-beta.1`) goes on the beta channel: only copies with Settings >
Updates > Include beta versions see it, and its GitHub Release is marked pre-release.

A major version gets `sparkle:minimumAutoupdateVersion` automatically, so every older copy asks
before installing it, and its notes start with a line about the catalog upgrade.

## Testing an update before releasing

1. In `product-releases`, make a branch `test` (GitHub: branch menu > type `test` > Create branch).
2. Build an older copy that reads the test branch's feed:
   ```
   python3 Scripts/build_macos_app.py --configuration release --release --version 0.9.0 \
     --feed-url https://raw.githubusercontent.com/roshan-davis/product-releases/test/atelier/appcast.xml
   ```
3. Run `make_release.py` without `--publish`, upload the zip to a pre-release in
   `product-releases`, and put the generated `appcast.xml` at `atelier/appcast.xml` on the `test` branch.
4. Open the 0.9.0 copy: Atelier > Check for Updates… finds the release, shows its notes, installs
   it, and What's New opens once after the restart.

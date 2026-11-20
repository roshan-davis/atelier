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
| Update signing key | private: your login Keychain; public: `Scripts/release/sparkle-public-key.txt` |

The source repositories are private, so releases of all Rosh's apps go to `product-releases`,
which holds only feeds and release files: one folder per app for its feed (`atelier/`, `easel/`)
and tags prefixed with the app (`atelier-v1.3.0`, `easel-v0.4.0`). Create it once on github.com: New repository, name `product-releases`,
Public, tick "Add a README file" (a release needs a first commit), Create repository.

## Setup status on Rosh's Mac

| Step | State |
|---|---|
| 1. Update signing key | Done Nov 20, 2026. The private key is in Rosh's login Keychain. The public key `t/NpmlAw8z1I4OduK0RpLNDbPH9BLelayk3XzISG/ps=` is in `Scripts/release/sparkle-public-key.txt`. |
| 1. Back up the private key | Done Nov 20, 2026: exported into Rosh's Apple Note "Atelier update signing key" (Rosh locks the note), Desktop export file deleted. Agents never export or read it. |
| `product-releases` repository | Exists: public, branch `main`, holds a README. |
| `gh` | Installed (`/opt/homebrew/bin/gh`) and logged in as `roshan-davis` with `repo` scope. |
| 2. Signing | Self-signed `Atelier Release` certificate in Rosh's login Keychain (Nov 20, 2026); release with `--sign "Atelier Release"`. codesign asks for the login password once: click Always Allow. No Developer ID yet. |
| 3. Notarization | Not set up (needs a Developer ID). |
| First release | Atelier 1.0.0 (build 296) published Nov 20, 2026 from main 633a22b: [atelier-v1.0.0](https://github.com/roshan-davis/product-releases/releases/tag/atelier-v1.0.0), dmg 68.0 MB, zip 62.9 MB, feed live. |

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

## Troubleshooting

- **"codesign wants to sign using key "Atelier Release""**: enter your Mac login password and
  click **Always Allow** (Allow covers only one of the several signatures a build makes). Pressing
  Escape or Deny makes codesign fail with `errSecInternalComponent`; run the release again.
- **`CSSMERR_TP_NOT_TRUSTED` for Atelier Release**: Keychain Access > login > My Certificates,
  double-click Atelier Release > Trust > Code Signing: Always Trust.
- **No Atelier > Check for Updates…**: that copy has no feed or update key, so it hides the item on
  purpose (`AppUpdater.isEnabled`). Copies run from Xcode and `build_macos_app.py` builds without
  `--release` are like this; What's New still shows in them. Install a published dmg (quit other
  copies first, Replace in Applications) to get updates, and use Xcode for development.
- **First open of a downloaded copy**: System Settings > Privacy & Security > Open Anyway, once per
  Mac (self-signed and ad hoc builds).
- **Lost the private update key**: make a new one, commit the new public key and release; every
  installed copy then needs one manual dmg download (only Developer ID builds can rotate keys
  without that). Rosh's backup is the locked Apple Note "Atelier update signing key".

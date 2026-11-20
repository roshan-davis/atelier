# Atelier release notes

<!--
The one changelog (AT-087). What's New in Atelier shows it, and Scripts/release/make_release.py
copies each version's section into the update window. Write for people, with the app's own names.
One "## <version> (<yyyy-mm-dd>)" per release, newest first, then a short summary and any of
"### New", "### Improved", "### Fixed" with one bullet each. A major version says what it does
to the catalog.
-->

## 1.1.0 (2026-11-20)
Smoother cropping, and composition guides beyond the rule of thirds.

### New
- **Crop guide overlays:** Grid, Thirds, Diagonal, Triangle, Golden Ratio, Golden Spiral and Aspect Ratios, as in Lightroom. Press O while cropping to step through them and Shift-O to turn the Triangle or Golden Spiral, or pick one in the Crop panel's Overlay menu or Develop > Crop Guide Overlay. Show them always, only while dragging, or never.

### Improved
- **Crop & Straighten:** dragging a corner, an edge or the whole crop, and straightening, follow the pointer smoothly instead of stuttering.

## 1.0.0 (2026-11-20)
The first copy of Atelier to share as a file. It now keeps itself up to date.

### New
- **Atelier > Check for Updates…** looks for a new version on Atelier’s GitHub releases. Atelier also checks once a day by itself.
- **Settings > Updates:** your version, when Atelier last checked, and whether updates download and install by themselves when you quit. Include beta versions if you want previews of the next release.
- **What’s New in Atelier** opens once after each update with what changed, and any time from Help > What’s New in Atelier.
- **Catalog backups before upgrades:** when a new version needs to upgrade your catalog, Atelier first saves a copy in the catalog’s Backups > Before Upgrade folder.

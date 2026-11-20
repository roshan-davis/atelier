"""Tests for Scripts/release/appcast.py (AT-087): versions, release notes and the appcast."""
from datetime import datetime, timezone
from pathlib import Path
import sys
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "Scripts/release"))
import appcast  # noqa: E402
from appcast import Version  # noqa: E402

NOTES = """# Atelier release notes
<!--
## 9.9.9 (in a comment, ignored)
-->
## 2.0.0 (2026-12-01)
A new catalog format.
### New
- Big thing.
## 1.3.0-beta.1 (2026-11-25)
### New
- Preview.
## 1.2.0 (2026-11-20)
Updates arrive by themselves.
### New
- **Settings > Updates** shows the version.
- A long bullet that
  wraps onto a second line.
### Fixed
- Crop streaks.
"""


class VersionTests(unittest.TestCase):
    def test_parse(self):
        self.assertEqual(Version.parse("v1.3"), Version(1, 3, 0))
        self.assertEqual(str(Version.parse("1.3.0-beta.2")), "1.3.0-beta.2")
        for bad in ["", "1.x", "1.2.3.4", "1.2-", "beta"]:
            with self.assertRaises(ValueError):
                Version.parse(bad)

    def test_order_follows_semver(self):
        ordered = ["1.0.0-alpha", "1.0.0-alpha.1", "1.0.0-beta.2", "1.0.0-beta.11", "1.0.0-rc.1", "1.0.0", "1.0.1", "1.1.0", "2.0.0"]
        versions = [Version.parse(v) for v in ordered]
        self.assertEqual(sorted(reversed(versions), key=Version.key), versions)

    def test_update_kind(self):
        self.assertEqual(appcast.update_kind(Version(1, 2, 0), Version(1, 2, 1)), "patch")
        self.assertEqual(appcast.update_kind(Version(1, 2, 0), Version(1, 3, 0)), "minor")
        self.assertEqual(appcast.update_kind(Version(1, 9, 0), Version(2, 0, 0)), "major")
        self.assertEqual(appcast.update_kind(Version(1, 2, 0), Version(1, 2, 0)), "none")


class NotesTests(unittest.TestCase):
    def test_parse_notes(self):
        releases = appcast.parse_notes(NOTES)
        self.assertEqual([str(r.version) for r in releases], ["2.0.0", "1.3.0-beta.1", "1.2.0"])
        r = releases[2]
        self.assertEqual(r.date, "2026-11-20")
        self.assertEqual(r.summary, "Updates arrive by themselves.")
        self.assertEqual(r.sections[0], ("New", ["**Settings > Updates** shows the version.",
                                                 "A long bullet that wraps onto a second line."]))
        self.assertEqual(r.sections[1], ("Fixed", ["Crop streaks."]))

    def test_markdown_for_major_says_catalog(self):
        text = appcast.notes_markdown(appcast.parse_notes(NOTES)[0], major=True)
        self.assertTrue(text.startswith(appcast.MAJOR_NOTE))
        self.assertIn("### New\n- Big thing.", text)

    def test_shipped_changelog_parses_and_has_version_file(self):
        notes = appcast.parse_notes((ROOT / "Sources/AtelierApp/Resources/ReleaseNotes.md").read_text())
        version = Version.parse((ROOT / "VERSION").read_text())
        self.assertIn(version, [r.version for r in notes], "ReleaseNotes.md needs a section for VERSION")


class AppcastTests(unittest.TestCase):
    date = datetime(2026, 11, 20, 12, 0, tzinfo=timezone.utc)

    def release(self, version):
        return appcast.Release(Version.parse(version), "2026-11-20", "Notes for " + version, [("Fixed", ["A]]>B"])])

    def add(self, items, version, build, **kw):
        appcast.check_new_release(items, Version.parse(version), build)
        item = appcast.new_item(items, self.release(version), build, "https://x/Atelier-%s.zip" % version,
                                1000 + build, "sig%d==" % build, self.date, **kw)
        return appcast.read_appcast(appcast.write_appcast(items + [item]))

    def test_round_trip_and_order(self):
        items = self.add([], "1.0.0", 100)
        items = self.add(items, "1.0.1", 105, critical=True)
        self.assertEqual([i.build for i in items], [105, 100])
        first = items[1]
        self.assertEqual((first.url, first.length, first.signature), ("https://x/Atelier-1.0.0.zip", 1100, "sig100=="))
        self.assertIn("A]]>B", first.notes)
        self.assertIsNone(first.minimum_autoupdate)
        self.assertTrue(items[0].critical)
        self.assertFalse(first.critical)
        self.assertEqual(first.pub_date, "Fri, 20 Nov 2026 12:00:00 +0000")

    def test_major_gates_older_copies(self):
        items = self.add([], "1.0.0", 100)
        items = self.add(items, "1.1.0", 110)
        items = self.add(items, "2.0.0", 200)
        major = items[0]
        self.assertEqual(major.minimum_autoupdate, 200)
        self.assertTrue(major.notes.startswith(appcast.MAJOR_NOTE))
        items = self.add(items, "2.1.0", 210)
        # 1.x copies still have to ask before 2.1; the catalog note is only on the first 2.x.
        self.assertEqual(items[0].minimum_autoupdate, 200)
        self.assertFalse(items[0].notes.startswith(appcast.MAJOR_NOTE))
        self.assertIsNone(items[2].minimum_autoupdate)

    def test_prerelease_on_beta_channel(self):
        items = self.add([], "1.0.0", 100)
        items = self.add(items, "1.1.0-beta.1", 105)
        self.assertEqual(items[0].channel, "beta")
        self.assertIsNone(items[1].channel)

    def test_refuses_old_version_or_build(self):
        items = self.add([], "1.2.0", 100)
        with self.assertRaises(ValueError):
            appcast.check_new_release(items, Version(1, 2, 0), 101)
        with self.assertRaises(ValueError):
            appcast.check_new_release(items, Version(1, 3, 0), 100)

    def test_empty_feed(self):
        self.assertEqual(appcast.read_appcast(""), [])
        self.assertEqual(appcast.read_appcast(appcast.write_appcast([])), [])

    def test_sign_update_output(self):
        self.assertEqual(appcast.parse_sign_update('sparkle:edSignature="abc+/=" length="1234"\n'), ("abc+/=", 1234))
        with self.assertRaises(ValueError):
            appcast.parse_sign_update("error")


if __name__ == "__main__":
    unittest.main()

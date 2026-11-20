"""Atelier's release notes and appcast (AT-087), without anything Mac-only, so it is tested
anywhere (Scripts/tests/test_release.py).

- Versions are semantic (1.3.0, 1.3.0-beta.2) and compared like AppVersion in AtelierCore.
- Release notes come from Sources/AtelierApp/Resources/ReleaseNotes.md, read the same way as
  ReleaseNotes.swift: "## <version> (<date>)", a summary, then "### New/Improved/Fixed" bullets.
- appcast.xml (in the public roshan-davis/atelier-releases repository) is Sparkle's feed. A major version's items carry
  sparkle:minimumAutoupdateVersion (the major's first build), so older copies ask before
  installing it; a pre-release goes on the beta channel.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from email.utils import format_datetime
import re
import xml.etree.ElementTree as ET

SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
S = "{" + SPARKLE_NS + "}"
MIN_SYSTEM = "15.0.0"
MAJOR_NOTE = ("**This is a major update.** Atelier backs up your catalog, then upgrades it. "
              "Older versions of Atelier may not open it afterwards.")


# MARK: Versions

@dataclass(frozen=True)
class Version:
    major: int
    minor: int
    patch: int
    prerelease: str | None = None

    @staticmethod
    def parse(text):
        text = text.strip()
        if text[:1] in ("v", "V"):
            text = text[1:]
        core, _, tag = text.partition("-")
        parts = core.split(".")
        if not 1 <= len(parts) <= 3 or not all(p.isdigit() for p in parts):
            raise ValueError("Not a version: " + repr(text))
        if "-" in text and not tag:
            raise ValueError("Empty pre-release tag: " + repr(text))
        numbers = [int(p) for p in parts] + [0] * (3 - len(parts))
        return Version(numbers[0], numbers[1], numbers[2], tag or None)

    def __str__(self):
        return "%d.%d.%d" % (self.major, self.minor, self.patch) + ("-" + self.prerelease if self.prerelease else "")

    def key(self):
        """Sort key following semver: a pre-release sorts before its release; numeric
        identifiers compare as numbers and before words."""
        if self.prerelease is None:
            tag = (1,)
        else:
            tag = (0,) + tuple((0, int(p), "") if p.isdigit() else (1, 0, p) for p in self.prerelease.split("."))
        return (self.major, self.minor, self.patch, tag)

    def __lt__(self, other):
        return self.key() < other.key()

    def __le__(self, other):
        return self.key() <= other.key()

    def __gt__(self, other):
        return self.key() > other.key()

    def __ge__(self, other):
        return self.key() >= other.key()


def update_kind(old, new):
    """none, patch, minor or major, as UpdateKind in AtelierCore."""
    if new <= old:
        return "none"
    if new.major != old.major:
        return "major"
    if new.minor != old.minor:
        return "minor"
    return "patch"


# MARK: Release notes

@dataclass
class Release:
    version: Version
    date: str | None = None
    summary: str = ""
    sections: list = field(default_factory=list)  # [(title, [items])]


def parse_notes(markdown):
    """Every release in the changelog, newest first."""
    releases = []
    current = None
    in_comment = False
    for raw in markdown.splitlines():
        line = raw.strip()
        if in_comment:
            in_comment = "-->" not in line
            continue
        if line.startswith("<!--"):
            in_comment = "-->" not in line
            continue
        if line.startswith("## "):
            current = _release_from_heading(line[3:])
            if current:
                releases.append(current)
            continue
        if current is None:
            continue
        if line.startswith("### "):
            current.sections.append((line[4:].strip(), []))
        elif line.startswith(("- ", "* ")):
            if not current.sections:
                current.sections.append(("", []))
            current.sections[-1][1].append(line[2:].strip())
        elif line and raw.startswith("  ") and current.sections and current.sections[-1][1]:
            current.sections[-1][1][-1] += " " + line
        elif line and not current.sections:
            current.summary = (current.summary + " " + line).strip()
    return sorted(releases, key=lambda r: r.version.key(), reverse=True)


def _release_from_heading(heading):
    words = [w for w in re.split(r"[ ()\[\]]+", heading) if w and w not in ("-", "–", "—")]
    if not words:
        return None
    try:
        version = Version.parse(words[0])
    except ValueError:
        return None
    return Release(version, words[1] if len(words) > 1 else None)


def notes_markdown(release, major=False):
    """One release's notes as Markdown for the update window."""
    lines = []
    if major:
        lines += [MAJOR_NOTE, ""]
    if release.summary:
        lines += [release.summary, ""]
    for title, items in release.sections:
        if title:
            lines.append("### " + title)
        lines += ["- " + item for item in items]
        lines.append("")
    return "\n".join(lines).strip()


# MARK: Appcast

@dataclass
class Item:
    version: Version
    build: int
    url: str
    length: int
    signature: str
    pub_date: str
    notes: str = ""
    minimum_autoupdate: int | None = None
    channel: str | None = None
    critical: bool = False
    minimum_system: str = MIN_SYSTEM


def read_appcast(text):
    """The items of an appcast, newest first; [] for an empty or missing feed."""
    if not text or not text.strip():
        return []
    root = ET.fromstring(text)
    items = []
    for node in root.iter("item"):
        enclosure = node.find("enclosure")
        description = node.find("description")
        minimum = node.findtext(S + "minimumAutoupdateVersion")
        items.append(Item(
            version=Version.parse(node.findtext(S + "shortVersionString")),
            build=int(node.findtext(S + "version")),
            url=enclosure.get("url"), length=int(enclosure.get("length")),
            signature=enclosure.get(S + "edSignature"),
            pub_date=node.findtext("pubDate") or "",
            notes=(description.text or "").strip() if description is not None else "",
            minimum_autoupdate=int(minimum) if minimum else None,
            channel=node.findtext(S + "channel"),
            critical=node.find(S + "criticalUpdate") is not None,
            minimum_system=node.findtext(S + "minimumSystemVersion") or MIN_SYSTEM))
    return sorted(items, key=lambda i: i.build, reverse=True)


def check_new_release(items, version, build):
    """Raises ValueError unless `version` and `build` are newer than every item in the feed."""
    for item in items:
        if version <= item.version:
            raise ValueError("Version %s is not newer than %s, already in the appcast. Raise VERSION." % (version, item.version))
        if build <= item.build:
            raise ValueError("Build %d is not newer than %d (%s) in the appcast." % (build, item.build, item.version))


def is_major_step(items, version):
    """Whether `version` starts a new major version (there are older-major releases to protect)."""
    return any(item.version.major < version.major for item in items)


def minimum_autoupdate(items, version, build):
    """The build older majors must reach before installing `version` silently: the first build of
    its major. None when nothing older needs protecting."""
    if not is_major_step(items, version):
        return None
    same_major = [item.build for item in items if item.version.major == version.major]
    return min(same_major + [build])


def new_item(items, release, build, url, length, signature, date, critical=False):
    """The appcast item for a new release (call check_new_release first)."""
    version = release.version
    minimum = minimum_autoupdate(items, version, build)
    first_of_major = minimum == build
    return Item(version=version, build=build, url=url, length=length, signature=signature,
                pub_date=format_datetime(date), notes=notes_markdown(release, major=first_of_major),
                minimum_autoupdate=minimum, channel="beta" if version.prerelease else None, critical=critical)


def _cdata(text):
    return "<![CDATA[" + text.replace("]]>", "]]]]><![CDATA[>") + "]]>"


def _escape(text):
    return text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace('"', "&quot;")


def write_appcast(items, title="Atelier", link="https://github.com/roshan-davis/atelier"):
    """The whole feed, newest first."""
    out = ['<?xml version="1.0" encoding="utf-8"?>',
           '<rss version="2.0" xmlns:sparkle="%s">' % SPARKLE_NS,
           "  <channel>",
           "    <title>%s</title>" % _escape(title),
           "    <link>%s</link>" % _escape(link),
           "    <description>New versions of %s.</description>" % _escape(title),
           "    <language>en</language>"]
    for item in sorted(items, key=lambda i: i.build, reverse=True):
        out += ["    <item>",
                "      <title>%s %s</title>" % (_escape(title), item.version),
                "      <pubDate>%s</pubDate>" % _escape(item.pub_date),
                "      <sparkle:version>%d</sparkle:version>" % item.build,
                "      <sparkle:shortVersionString>%s</sparkle:shortVersionString>" % item.version,
                "      <sparkle:minimumSystemVersion>%s</sparkle:minimumSystemVersion>" % item.minimum_system]
        if item.minimum_autoupdate is not None:
            out.append("      <sparkle:minimumAutoupdateVersion>%d</sparkle:minimumAutoupdateVersion>" % item.minimum_autoupdate)
        if item.channel:
            out.append("      <sparkle:channel>%s</sparkle:channel>" % _escape(item.channel))
        if item.critical:
            out.append("      <sparkle:criticalUpdate></sparkle:criticalUpdate>")
        if item.notes:
            out.append('      <description sparkle:format="markdown">%s</description>' % _cdata(item.notes))
        out += ['      <enclosure url="%s" length="%d" type="application/octet-stream" sparkle:edSignature="%s"/>'
                % (_escape(item.url), item.length, _escape(item.signature)),
                "    </item>"]
    out += ["  </channel>", "</rss>", ""]
    return "\n".join(out)


def parse_sign_update(output):
    """sign_update prints `sparkle:edSignature="…" length="…"`; returns (signature, length)."""
    signature = re.search(r'sparkle:edSignature="([^"]+)"', output)
    length = re.search(r'length="(\d+)"', output)
    if not signature or not length:
        raise ValueError("Unexpected sign_update output: " + output.strip())
    return signature.group(1), int(length.group(1))

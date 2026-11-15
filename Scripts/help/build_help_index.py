#!/usr/bin/env python3
"""Writes Atelier Help's page list and search index (Sources/AtelierApp/Help/assets/toc.js),
and checks every page: each listed page exists, every picture it uses exists, and every link
to another help page or section lands somewhere.

Run it after adding or editing a help page:

    python3 Scripts/help/build_help_index.py

To add a page: write Sources/AtelierApp/Help/<name>.html from an existing page, then add it to
GROUPS below. Give each h2/h3 an id so search results and the app can link straight to it.
"""

import argparse
import json
import os
import re
import sys
from html.parser import HTMLParser

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
HELP = os.path.join(ROOT, "Sources/AtelierApp/Help")

# The sidebar, in order.
GROUPS = [
    ("Get started", [
        ("index.html", "Welcome"),
        ("workspace.html", "The Atelier window"),
        ("shortcuts.html", "Keyboard shortcuts"),
    ]),
    ("Library", [
        ("import.html", "Import photos"),
        ("library.html", "Organize and find"),
        ("cull.html", "Cull: pick the keepers"),
        ("photos.html", "Virtual copies, stacks and removing"),
        ("notes.html", "Notes on photos"),
    ]),
    ("Develop", [
        ("develop.html", "Develop basics"),
        ("basic.html", "Basic"),
        ("tone-curve.html", "Tone Curve"),
        ("hsl.html", "HSL / Color and B&W"),
        ("color-grading.html", "Color Grading"),
        ("detail.html", "Detail"),
        ("lens-corrections.html", "Lens Corrections"),
        ("transform.html", "Transform"),
        ("effects.html", "Effects"),
        ("calibration.html", "Calibration"),
    ]),
    ("Tools", [
        ("crop.html", "Crop & Straighten"),
        ("remove.html", "Remove: Content-Aware, Heal and Clone"),
        ("masking.html", "Masking"),
        ("presets.html", "Presets"),
        ("preset-lookbook.html", "Built-in preset lookbook"),
        ("match-look.html", "Match Look"),
        ("ai.html", "AI tools"),
        ("hdr.html", "Single-image HDR"),
    ]),
    ("Share", [
        ("export.html", "Export"),
        ("edit-in.html", "Edit In other apps"),
    ]),
    ("Set up", [
        ("settings.html", "Settings"),
        ("chat-apps.html", "Connect a chat app"),
    ]),
]


class Page(HTMLParser):
    """Collects the h1, each h2/h3 with its id and text, and every src/href."""

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.title = ""
        self.sections = []  # [id, title, text]
        self.refs = []
        self.ids = set()
        self._in = None
        self._skip = 0

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if "id" in attrs:
            self.ids.add(attrs["id"])
        for key in ("src", "href", "data-before", "data-after"):
            if attrs.get(key):
                self.refs.append((key, attrs[key]))
        if attrs.get("data-frames"):
            self.refs += [("data-frames", f) for f in attrs["data-frames"].split(",")]
        if tag in ("script", "style"):
            self._skip += 1
        if tag == "h1":
            self._in = "h1"
            self.sections.append(["", "", ""])
        elif tag in ("h2", "h3"):
            self._in = tag
            self.sections.append([attrs.get("id", ""), "", ""])

    def handle_endtag(self, tag):
        if tag in ("script", "style"):
            self._skip -= 1
        if tag == self._in:
            self._in = None

    def handle_data(self, data):
        if self._skip:
            return
        if self._in == "h1":
            self.title += data
            self.sections[-1][1] += data
        elif self._in in ("h2", "h3"):
            self.sections[-1][1] += data
        elif self.sections:
            self.sections[-1][2] += data


def clean(text):
    return re.sub(r"\s+", " ", text).strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="Validate without writing; fail if toc.js is stale")
    args = parser.parse_args()

    problems = []
    parsed = {}
    for _, pages in GROUPS:
        for file, _ in pages:
            path = os.path.join(HELP, file)
            if not os.path.exists(path):
                problems.append(f"{file}: listed in GROUPS but missing")
                continue
            page = Page()
            with open(path, encoding="utf-8") as f:
                page.feed(f.read())
            parsed[file] = page

    listed = {file for _, pages in GROUPS for file, _ in pages}
    for name in sorted(os.listdir(HELP)):
        if name.endswith(".html") and name not in listed:
            problems.append(f"{name}: not listed in GROUPS, so it isn't in the sidebar or search")

    for file, page in parsed.items():
        for key, ref in page.refs:
            if re.match(r"^(https?:|mailto:|#$)", ref):
                continue
            target, _, anchor = ref.partition("#")
            if key in ("data-before", "data-after", "data-frames"):
                target = "images/" + target
            target_file = target or file
            if not os.path.exists(os.path.join(HELP, target_file)):
                problems.append(f"{file}: {key} {ref} doesn't exist")
            elif anchor and target_file.endswith(".html"):
                other = parsed.get(target_file)
                if other and anchor not in other.ids:
                    problems.append(f"{file}: link {ref} has no matching id")

    groups = [{"title": title, "pages": [{"file": f, "title": t} for f, t in pages]} for title, pages in GROUPS]
    sections = []
    for title, pages in GROUPS:
        for file, nav_title in pages:
            page = parsed.get(file)
            if not page:
                continue
            for anchor, heading, text in page.sections:
                heading = clean(heading.replace("#", ""))
                sections.append({
                    "file": file,
                    "id": anchor,
                    "title": heading or nav_title,
                    "page": nav_title if anchor else title,
                    "text": clean(text)[:1500],
                })

    out = os.path.join(HELP, "assets/toc.js")
    content = "// Written by Scripts/help/build_help_index.py; don't edit by hand.\n"
    content += "window.HELP_TOC = " + json.dumps({"groups": groups, "sections": sections}, ensure_ascii=False,
                                               separators=(",", ":")) + ";\n"
    if args.check:
        try:
            with open(out, encoding="utf-8") as f:
                current = f.read()
        except FileNotFoundError:
            current = None
        if current != content:
            problems.append("Help index is stale; run python3 Scripts/help/build_help_index.py")
    else:
        with open(out, "w", encoding="utf-8") as f:
            f.write(content)
    print(f"{len(parsed)} pages, {len(sections)} sections -> {os.path.relpath(out, ROOT)}")
    for problem in problems:
        print("PROBLEM:", problem)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())

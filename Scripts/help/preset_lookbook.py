"""Build the Help lookbook from PresetQualification's native sRGB renders."""

import csv
from html import escape
from io import BytesIO
import json
from pathlib import Path
import re

from PIL import Image, ImageChops, ImageStat

ROOT = Path(__file__).resolve().parents[2]
HELP = ROOT / "Sources/AtelierApp/Help"
BEGIN = "<!-- BEGIN GENERATED LOOKS -->"
END = "<!-- END GENERATED LOOKS -->"

SCENES = {
    # Rosh's own photos (Scripts/presets/scenes, made by Scripts/help/prepare_photos.py).
    # No children: the repo is public.
    "portrait": "A couple by the sea on an overcast day",
    "portrait-light": "A woman by the sea in soft overcast light",
    "landscape": "Dry golden hills with a winding path",
    "sky": "A golf course under a blue sky with clouds",
    "haze": "A headland and a footbridge in fog",
    "street": "A San Francisco street with taxis",
    "urban": "Paris at night from the Eiffel Tower",
    "twilight": "The Eiffel Tower at dusk",
    "product": "White garlic bulbs",
    "forest": "A lush green park after rain",
    "wildlife": "A finch on a branch",
    "fine-art": "A painted chapel ceiling in a gilded frame",
}


def slug(name):
    return re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-")


def make_image(source, filename, alt, check, differences):
    with Image.open(source) as image:
        image.thumbnail((520, 390), Image.Resampling.LANCZOS)
        target = HELP / "images" / filename
        data = BytesIO()
        image.save(data, format="JPEG", quality=85, optimize=True, progressive=True,
                   icc_profile=image.info.get("icc_profile"))
        if check:
            with Image.open(target) as reference, Image.open(data) as current:
                if reference.size != current.size:
                    differences.append(f"{filename}: dimensions changed")
                else:
                    delta = ImageChops.difference(reference.convert("RGB"), current.convert("RGB"))
                    mean = max(ImageStat.Stat(delta).mean)
                    if mean > 3:
                        differences.append(f"{filename}: worst-channel mean absolute error {mean:.2f}/255")
        else:
            target.write_bytes(data.getvalue())
        return (f'<img src="images/{filename}" alt="{escape(alt)}" loading="lazy" '
                f'width="{image.width}" height="{image.height}">')


def build(render_dir, check=False):
    render_dir = Path(render_dir)
    presets = json.loads((render_dir / "presets.json").read_text())
    with (ROOT / "Scripts/presets/looks.tsv").open() as file:
        rows = list(csv.DictReader(file, delimiter="\t"))
    names = [row["Name"] for row in rows]
    if names != [preset["name"] for preset in presets] or len(set(map(slug, names))) != len(names):
        raise ValueError("The lookbook must list every visible built-in preset once, in app order")

    page = HELP / "preset-lookbook.html"
    existing = page.read_text()
    before_page, generated = existing.split(BEGIN)
    _, after_page = generated.split(END)
    differences = []
    sections = []
    befores = {}
    group = None
    for preset, row in zip(presets, rows):
        if group != preset["group"]:
            group = preset["group"]
            sections.append(f'<h2 id="{slug(group)}">{escape(group)}</h2>')
        name = preset["name"]
        ident = slug(name)
        scene = row["Scene"]
        description = SCENES[scene]
        source = render_dir / scene
        if scene not in befores:
            befores[scene] = make_image(source / "before.jpg", f"look-before-{scene}.jpg",
                                        f"{description} before applying a preset", check, differences)
        before = befores[scene]
        after = make_image(source / f'{preset["id"]}.jpg', f"look-{ident}.jpg",
                           f"{description} with {name} applied", check, differences)
        sections.append(f'''<h3 id="look-{ident}">{escape(name)}</h3>
<p><b>Best for</b> {escape(row["Best for"])}. {escape(row["Qualities to look for"])}</p>
<div class="look-pair">
  <figure>{before}<figcaption>Before</figcaption></figure>
  <figure>{after}<figcaption>{escape(name)} · 100%</figcaption></figure>
</div>''')
    updated = before_page + BEGIN + "\n" + "\n\n".join(sections) + "\n" + END + after_page
    if check:
        if updated != existing:
            differences.append("The lookbook text or image dimensions are out of date")
        if differences:
            raise ValueError("\n".join(differences))
        print(f"Verified {len(presets)} preset examples and {len(befores)} before images")
    else:
        page.write_text(updated)

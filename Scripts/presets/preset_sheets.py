#!/usr/bin/env python3
"""Contact sheets of the built-in presets on test photos, for tuning them without a Mac.

Reads the presets straight from Sources/AtelierCore/Develop/BuiltInPresets.swift (so the
sheet always reads the current recipes) and renders each with develop_sim, a numpy port of
parts of DevelopRenderer. Glow is omitted. Use PresetQualification on macOS for native review. One sheet per pack: a column per photo, a row per preset, the unedited
photo on top.

    pip install numpy opencv-python-headless pillow rawpy
    python3 Scripts/presets/preset_sheets.py OUT_DIR PHOTO [PHOTO ...]

Use only photos you own or have a license for. A RAW file is decoded with rawpy (camera
white balance), so its base look differs a little from Atelier's camera match.
"""

import os
import re
import sys

import numpy as np
from PIL import Image, ImageDraw, ImageFont

sys.path.insert(0, os.path.dirname(__file__))
import develop_sim as sim  # noqa: E402

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
SOURCE = os.path.join(ROOT, "Sources/AtelierCore/Develop/BuiltInPresets.swift")
CELL = 360

HSL = {"hue": "hue", "saturation": "sat", "luminance": "lum"}
GRAIN_TYPES = ["standard", "fine", "cubic", "tabular"]  # DevelopSettings.GrainType order


def parse_presets(path=SOURCE):
    with open(path) as source:
        text = source.read().split("private static let retired:", 1)[0]
    groups = re.search(r"builtInGroups = \[(.*?)\]", text, re.S).group(1)
    group_names = re.findall(r'"([^"]+)"', groups)
    presets = []
    for m in re.finditer(r'look\("([^"]+)", (\d+), "([^"]+)"\) \{ s in\n(.*?)\n        \}', text, re.S):
        group, name, body = m.group(1), m.group(3), m.group(4)
        s = {}
        for line in body.splitlines():
            line = line.split("//")[0].strip()
            if not line:
                continue
            if mm := re.fullmatch(r"s\.(\w+) = (true|false|-?[\d.]+)", line):
                s[mm.group(1)] = mm.group(2) == "true" if mm.group(2) in ("true", "false") else float(mm.group(2))
            elif re.fullmatch(r"s\.glowStyle = \.\w+", line):
                continue  # The portable renderer does not implement Glow.
            elif mm := re.fullmatch(r"s\.grainType = \.(\w+)", line):
                s["grainType"] = GRAIN_TYPES.index(mm.group(1))
            elif mm := re.fullmatch(r"s\[\.hsl\(\.(\w+), \.(\w+)\)\] = (-?[\d.]+)", line):
                s[HSL[mm.group(1)] + mm.group(2).capitalize()] = float(mm.group(3))
            elif mm := re.fullmatch(r"s\[\.gray\(\.(\w+)\)\] = (-?[\d.]+)", line):
                s["gray" + mm.group(1).capitalize()] = float(mm.group(2))
            elif mm := re.fullmatch(r"s\[\.(\w+)\] = (-?[\d.]+)", line):
                s[mm.group(1)] = float(mm.group(2))
            elif mm := re.fullmatch(r"grade\(&s, \.(\w+), hue: ([\d.]+), saturation: ([\d.]+)(?:, luminance: (-?[\d.]+))?\)",
                                    line):
                region = mm.group(1).capitalize()
                s[f"grade{region}Hue"] = float(mm.group(2))
                s[f"grade{region}Sat"] = float(mm.group(3))
                if mm.group(4):
                    s[f"grade{region}Lum"] = float(mm.group(4))
            elif mm := re.fullmatch(r"s\.setPoints\(curve\((.*)\), for: \.(\w+)\)", line):
                pts = [(float(a), float(b)) for a, b in re.findall(r"\((-?[\d.]+), (-?[\d.]+)\)", mm.group(1))]
                s["curve_" + mm.group(2)] = pts
            else:
                raise ValueError(f"{name}: can't read `{line}`")
        presets.append((group, name, s))
    return group_names, presets


# ColorChecker Classic (sRGB, BabelColor averages), a row of skin tones from light to deep,
# and a gray ramp: a reference for what each preset does to known colors.
CHECKER = [(115, 82, 68), (194, 150, 130), (98, 122, 157), (87, 108, 67), (133, 128, 177), (103, 189, 170),
           (214, 126, 44), (80, 91, 166), (193, 90, 99), (94, 60, 108), (157, 188, 64), (224, 163, 46),
           (56, 61, 150), (70, 148, 73), (175, 54, 60), (231, 199, 31), (187, 86, 149), (8, 133, 161),
           (243, 243, 242), (200, 200, 200), (160, 160, 160), (122, 122, 121), (85, 85, 85), (52, 52, 52)]
SKIN = [(246, 222, 200), (232, 190, 160), (208, 156, 120), (176, 122, 88), (134, 88, 62), (92, 60, 44)]


def chart(width=CELL * 2):
    h = width * 2 // 3
    image = np.zeros((h, width, 3), np.float32)
    pw, ph = width // 6, h * 2 // 3 // 4
    for i, c in enumerate(CHECKER):
        r, k = divmod(i, 6)
        image[r * ph:(r + 1) * ph, k * pw:(k + 1) * pw] = np.array(c) / 255
    y0 = ph * 4
    sh = (h - y0) // 2
    for k, c in enumerate(SKIN):
        image[y0:y0 + sh, k * pw:(k + 1) * pw] = np.array(c) / 255
    image[y0 + sh:, :] = np.linspace(0, 1, width)[None, :, None]
    return sim.from_srgb_encoded(image), 0.25


def crop_3x2(image, focus=0.5):
    """Center-crops to 3:2 landscape, keeping `focus` (0 top ... 1 bottom) in view."""
    w, h = image.size
    if w / h > 1.5:
        nw = round(h * 1.5)
        return image.crop(((w - nw) // 2, 0, (w - nw) // 2 + nw, h))
    nh = round(w / 1.5)
    top = min(max(0, round(focus * h - nh / 2)), h - nh)
    return image.crop((0, top, w, top + nh))


def load_photo(path, width=CELL * 2):
    """Linear Rec. 2020 at `width`, and its scale relative to the full-size photo. A path may
    end in `@0.3` to say where to center a 3:2 crop of a tall photo; `chart` is the test chart."""
    if path == "chart":
        return chart(width)
    focus = 0.5
    if "@" in path:
        path, focus = path.rsplit("@", 1)
        focus = float(focus)
    if path.lower().endswith((".nef", ".dng", ".cr3", ".arw", ".raf")):
        import rawpy
        with rawpy.imread(path) as raw:
            rgb = raw.postprocess(use_camera_wb=True, output_bps=16, half_size=True)
        image = Image.fromarray((rgb / 257).astype(np.uint8))
        full = image.width * 2
    else:
        image = Image.open(path).convert("RGB")
        full = image.width
    image = crop_3x2(image, focus)
    image.thumbnail((width, width), Image.LANCZOS)
    encoded = np.asarray(image).astype(np.float32) / 255
    return sim.from_srgb_encoded(encoded), image.width / full


def to_image(linear):
    encoded = np.clip(sim.to_srgb_encoded(linear), 0, 1)
    return Image.fromarray((encoded * 255 + 0.5).astype(np.uint8))


def font(size):
    for f in ("/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf", "/System/Library/Fonts/Helvetica.ttc"):
        if os.path.exists(f):
            return ImageFont.truetype(f, size)
    return ImageFont.load_default()


def sheet(rows, photos, title):
    label_w, pad = 170, 6
    heights = [max(1, round(p[0].shape[0] * CELL / p[0].shape[1])) for p in photos]
    row_h = max(heights)
    W = label_w + len(photos) * (CELL + pad)
    H = 40 + len(rows) * (row_h + pad)
    out = Image.new("RGB", (W, H), (28, 28, 28))
    draw = ImageDraw.Draw(out)
    draw.text((10, 10), title, fill=(230, 230, 230), font=font(20))
    for r, (name, images) in enumerate(rows):
        y = 40 + r * (row_h + pad)
        draw.text((10, y + row_h // 2 - 8), name, fill=(220, 220, 220), font=font(15))
        for c, im in enumerate(images):
            im = im.resize((CELL, heights[c]), Image.LANCZOS)
            out.paste(im, (label_w + c * (CELL + pad), y))
    return out


def main():
    out_dir, paths = sys.argv[1], sys.argv[2:]
    os.makedirs(out_dir, exist_ok=True)
    photos = [load_photo(p) for p in paths]
    groups, presets = parse_presets()
    only = os.environ.get("PACKS")
    for group in groups:
        if only and group not in only.split(","):
            continue
        rows = [("None", [to_image(p) for p, _ in photos])]
        for g, name, s in presets:
            if g != group:
                continue
            rows.append((name, [to_image(sim.develop(p, s, scale)) for p, scale in photos]))
        file = os.path.join(out_dir, "presets-" + re.sub(r"[^a-z0-9]+", "-", group.lower()).strip("-") + ".jpg")
        sheet(rows, photos, group).save(file, quality=85)
        print(file)


if __name__ == "__main__":
    main()

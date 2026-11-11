#!/usr/bin/env python3
"""Build Atelier's app icon from Scripts/icon/AppIcon-source.png.

Writes the Xcode asset catalog set (Sources/AtelierApp/Resources/Assets.xcassets/AppIcon.appiconset,
16-512 pt at @1x and @2x) and Sources/AtelierApp/Resources/AppIcon.icns, which the app sets as its
Dock icon at launch and Scripts/build_macos_app.py copies into Atelier.app (CFBundleIconFile).

The source art already has its rounded-square shape, so nothing is masked. It is only placed on
Apple's macOS icon grid (an 824 px wide body on a 1024 px canvas) so it sits the same size as
other Dock and Finder icons. Near-invisible stray pixels (alpha 3 or less) around the shape are
cleared, and the body's 253 alpha is made fully opaque.

Run from the repository root: python3 Scripts/icon/make_app_icon.py  (needs Pillow and numpy).
For flat art without transparency (a JPEG), run Scripts/icon/cut_out_flat_icon.py first.
"""
import json
from pathlib import Path

import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "Scripts/icon/AppIcon-source.png"
RESOURCES = ROOT / "Sources/AtelierApp/Resources"
ICONSET = RESOURCES / "Assets.xcassets/AppIcon.appiconset"
ICNS = RESOURCES / "AppIcon.icns"

CANVAS = 1024
BODY_WIDTH = 824   # Apple's macOS app icon grid
BODY_TOP = 100


def master():
    pixels = np.array(Image.open(SOURCE).convert("RGBA"))
    alpha = pixels[..., 3]
    alpha[alpha <= 3] = 0
    alpha[alpha >= 250] = 255
    pixels[alpha == 0] = 0
    art = Image.fromarray(pixels, "RGBA")
    # The body's bounds (ignoring the soft drop shadow) set the scale and position.
    body = np.where(alpha >= 128)
    left, right = body[1].min(), body[1].max() + 1
    top = body[0].min()
    scale = BODY_WIDTH / (right - left)
    art = art.resize((round(art.width * scale), round(art.height * scale)), Image.LANCZOS)
    canvas = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    x = round((CANVAS - BODY_WIDTH) / 2 - left * scale)
    y = round(BODY_TOP - top * scale)
    canvas.alpha_composite(art, (max(x, 0), max(y, 0)),
                           (max(-x, 0), max(-y, 0)))
    return canvas


def main():
    icon = master()
    images = []
    for points in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            pixels = points * scale
            name = f"icon_{points}x{points}{'@2x' if scale == 2 else ''}.png"
            icon.resize((pixels, pixels), Image.LANCZOS).save(ICONSET / name, optimize=True)
            images.append({"filename": name, "idiom": "mac", "scale": f"{scale}x",
                           "size": f"{points}x{points}"})
    contents = {"images": images, "info": {"author": "xcode", "version": 1}}
    (ICONSET / "Contents.json").write_text(json.dumps(contents, indent=2, separators=(",", " : ")) + "\n")
    # Pillow writes every icns size (16-1024 px) from the 1024 master.
    icon.save(ICNS, format="ICNS")
    print(f"Wrote {ICONSET.relative_to(ROOT)} and {ICNS.relative_to(ROOT)}")


if __name__ == "__main__":
    main()

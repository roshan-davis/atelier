#!/usr/bin/env python3
"""Cut an app icon out of a flat image (a JPEG with a drawn checkerboard or plain background).

Usage: python3 Scripts/icon/cut_out_flat_icon.py <input.jpg> [Scripts/icon/AppIcon-source.png]

The icon's body must be darker than its surround (luminance under DARK) at its edge. Everything
connected to the image border that isn't dark is background; the rest that joins the image's
center is the icon, holes and bright glow inside it included. The edge is smoothed and anti-aliased at 4x and pulled in by
about a pixel so no background color fringes it. A glow drawn outside the shape onto the
background can't be separated from the checkerboard and is dropped. Then run make_app_icon.py.
"""
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

DARK = 140
SUPERSAMPLE = 4


def cut_out(path):
    rgb = Image.open(path).convert("RGB")
    lum = np.asarray(rgb, dtype=float).mean(axis=2)
    # Light pixels reachable from the border are background; flood them from every border pixel.
    regions = Image.fromarray(np.where(lum >= DARK, 255, 0).astype(np.uint8)).copy()
    w, h = regions.size
    for x, y in [(x, 0) for x in range(w)] + [(x, h - 1) for x in range(w)] + \
                [(0, y) for y in range(h)] + [(w - 1, y) for y in range(h)]:
        if regions.getpixel((x, y)) == 255:
            ImageDraw.floodfill(regions, (x, y), 128)
    # Keep only the icon itself: the region joined to the image's center, not stray dark specks.
    body = Image.fromarray(np.where(np.asarray(regions) != 128, 255, 0).astype(np.uint8)).copy()
    ImageDraw.floodfill(body, (w // 2, h // 2), 128)
    inside = np.asarray(body) == 128
    # Open (erode then dilate) to drop thin specks stuck to the edge, then pull in one pixel.
    mask = Image.fromarray((inside * 255).astype(np.uint8))
    mask = mask.filter(ImageFilter.MinFilter(9)).filter(ImageFilter.MaxFilter(9)).filter(ImageFilter.MinFilter(3))
    big = mask.resize((mask.width * SUPERSAMPLE, mask.height * SUPERSAMPLE), Image.BILINEAR)
    big = big.filter(ImageFilter.GaussianBlur(SUPERSAMPLE * 1.5)).point(lambda v: 255 if v >= 128 else 0)
    alpha = big.resize(mask.size, Image.BOX)
    out = rgb.convert("RGBA")
    out.putalpha(alpha)
    return out


def main():
    source = Path(sys.argv[1])
    target = Path(sys.argv[2]) if len(sys.argv) > 2 else Path(__file__).with_name("AppIcon-source.png")
    cut_out(source).save(target)
    print(f"Wrote {target}")


if __name__ == "__main__":
    main()

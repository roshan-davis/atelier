#!/usr/bin/env python3
"""Cut an app icon out of a flat image (a JPEG with a drawn checkerboard or plain background).

Usage: python3 Scripts/icon/cut_out_flat_icon.py [--rounded-square] <input.jpg> [Scripts/icon/AppIcon-source.png]

The icon's body must be darker than its surround (luminance under DARK) at its edge. Everything
connected to the image border that isn't dark is background; the rest that joins the image's
center is the icon, holes and bright glow inside it included. The edge is smoothed and anti-aliased at 4x and pulled in by
about a pixel so no background color fringes it. A glow drawn outside the shape onto the
background can't be separated from the checkerboard and is dropped. Then run make_app_icon.py.

--rounded-square: for art whose body is a plain rounded square with a drop shadow drawn onto the
checkerboard (the shadow is as dark as the checkerboard, so tracing the edge picks it up). The
mask is then a clean rounded square fitted to the art: its sides from the middle row, its top
from the middle column, its height equal to its width, and its corner radius fitted to the
top-left corner's edge. The drawn shadow is dropped.
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


def rounded_square(path):
    rgb = Image.open(path).convert("RGB")
    lum = np.asarray(rgb, dtype=float).mean(axis=2)
    h, w = lum.shape
    row = np.where(lum[h // 2] < DARK)[0]
    left, right = row[0], row[-1] + 1
    # The top edge may be a light bevel, so it ends where the image stops looking like the surround.
    surround = np.median(np.concatenate([lum[0], lum[-1], lum[:, 0], lum[:, -1]]))
    top = int(np.where(lum[:, w // 2] < surround * 0.85)[0][0])
    side = right - left
    # Fit the corner radius to where each row of the top-left corner turns dark.
    rows = range(top + 25, top + side // 4)
    edges = [(int(np.where(lum[y, : w // 2] < DARK)[0][0]), y) for y in rows]

    def error(r):
        cx, cy = left + r, top + r
        d = [np.hypot(cx - x, cy - y) - r if y < cy else left - x for x, y in edges]
        return float(np.mean(np.square(d)))

    radius = min(range(side // 10, side // 3), key=error)
    big = Image.new("L", (w * SUPERSAMPLE, h * SUPERSAMPLE), 0)
    inset = 2  # pull in two pixels so no surround color fringes the edge
    ImageDraw.Draw(big).rounded_rectangle(
        [(left + inset) * SUPERSAMPLE, (top + inset) * SUPERSAMPLE,
         (left + side - inset) * SUPERSAMPLE - 1, (top + side - inset) * SUPERSAMPLE - 1],
        radius=(radius - inset) * SUPERSAMPLE, fill=255)
    out = rgb.convert("RGBA")
    out.putalpha(big.resize((w, h), Image.BOX))
    print(f"Rounded square: x {left}-{left + side}, y {top}-{top + side}, corner radius {radius}")
    return out


def main():
    args = sys.argv[1:]
    fitted = "--rounded-square" in args
    args = [a for a in args if a != "--rounded-square"]
    source = Path(args[0])
    target = Path(args[1]) if len(args) > 1 else Path(__file__).with_name("AppIcon-source.png")
    (rounded_square(source) if fitted else cut_out(source)).save(target)
    print(f"Wrote {target}")


if __name__ == "__main__":
    main()

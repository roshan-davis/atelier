#!/usr/bin/env python3
"""Render the README's landing visuals into Docs/readme/*.webp.

Each picture is an HTML page in this folder (hero, features, agents, storage) drawn with
the app's Graphite colors, Help's before/after pictures and Rosh's example photos
(Scripts/help/photos). The hero's histogram is computed from the photo it shows. Pages are screenshotted at 2x with
Playwright (Node) and saved as WebP with transparent rounded corners.

    python3 Scripts/readme/make_readme_images.py            # all four
    python3 Scripts/readme/make_readme_images.py hero       # one

Needs Python 3 with Pillow and NumPy, Node with the `playwright` package, and Chromium.
The Inter font is used when installed (it falls back to the system sans-serif).
"""

import subprocess
import sys
import tempfile
from pathlib import Path

import numpy as np
from PIL import Image

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
OUT = ROOT / "Docs" / "readme"
PAGES = ["hero", "features", "agents", "storage"]
HERO_PHOTO = ROOT / "Scripts/help/photos/palace.jpg"

RENDER_JS = r"""
const { chromium } = require('playwright');
(async () => {
  const [dir, out, ...pages] = process.argv.slice(2);
  const browser = await chromium.launch({ args: ['--allow-file-access-from-files'] });
  const page = await browser.newPage({ viewport: { width: 1000, height: 1000 }, deviceScaleFactor: 2 });
  for (const name of pages) {
    await page.goto('file://' + dir + '/' + name + '.html');
    await page.evaluate(() => document.fonts.ready);
    await page.waitForTimeout(300);
    await page.locator('.card').screenshot({ path: out + '/' + name + '.png', omitBackground: true });
  }
  await browser.close();
})();
"""


def histogram_svg(path: Path, width: int = 186, height: int = 64) -> str:
    """An RGB histogram of the photo, drawn like the app's Histogram panel."""
    pixels = np.asarray(Image.open(path).convert("RGB").resize((400, 266)))
    colors = {0: "#e0484a", 1: "#3fbf5a", 2: "#3a7bf0"}
    shapes = []
    for channel, color in colors.items():
        counts, _ = np.histogram(pixels[..., channel], bins=64, range=(0, 256))
        counts = np.convolve(counts, np.ones(3) / 3, mode="same")
        counts = counts / counts.max()
        points = [f"0,{height}"]
        points += [f"{x * width / 63:.1f},{height - v * height * 0.92:.1f}" for x, v in enumerate(counts)]
        points.append(f"{width},{height}")
        shapes.append(
            f'<polygon points="{" ".join(points)}" fill="{color}" fill-opacity=".22" '
            f'stroke="{color}" stroke-width="1.2"/>'
        )
    return f'<svg width="{width}" height="{height}" viewBox="0 0 {width} {height}">{"".join(shapes)}</svg>'


def main() -> int:
    pages = sys.argv[1:] or PAGES
    unknown = [p for p in pages if p not in PAGES]
    if unknown:
        print(f"Unknown page(s): {', '.join(unknown)}. Choose from {', '.join(PAGES)}.")
        return 2
    OUT.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory() as tmp:
        tmp_dir = Path(tmp)
        # Pages are rendered from this folder so their relative paths to the app's images hold;
        # only the hero needs its histogram filled in first.
        hero = (HERE / "hero.html").read_text().replace("{{HIST}}", histogram_svg(HERO_PHOTO))
        (HERE / ".hero.rendered.html").write_text(hero)
        try:
            names = [".hero.rendered" if p == "hero" else p for p in pages]
            script = tmp_dir / "render.js"
            script.write_text(RENDER_JS)
            subprocess.run(["node", str(script), str(HERE), str(tmp_dir), *names], check=True)
        finally:
            (HERE / ".hero.rendered.html").unlink(missing_ok=True)
        for page, name in zip(pages, names):
            image = Image.open(tmp_dir / f"{name}.png").convert("RGBA")
            target = OUT / f"{page}.webp"
            image.save(target, quality=86, method=6, alpha_quality=100)
            print(f"{target.relative_to(ROOT)}: {image.width}×{image.height}, {target.stat().st_size // 1024} KB")
    return 0


if __name__ == "__main__":
    sys.exit(main())

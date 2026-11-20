#!/usr/bin/env python3
"""Makes the example photos for Atelier Help and the README (Scripts/help/photos) from Rosh's
RAW samples. Each photo is the camera's own rendering (the JPEG preview inside the NEF), turned
upright, resized and saved with no metadata at all (no EXIF, GPS, serial numbers or ICC
profile), so the public repository holds only pixels. The noisy close-up comes from the RAW
data itself, so its noise is real, not the camera's noise-reduced preview.

    pip install rawpy exifread pillow numpy
    python3 Scripts/help/prepare_photos.py "/path/to/for Atelier"

The source folder is Rosh's (~/Documents/for Atelier); the NEFs are not in the repository.
"""

import io
import os
import sys

import exifread
import numpy as np
import rawpy
from PIL import Image

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "photos")

# name: (NEF, long edge in pixels). Larger ones are cropped at 100% in Help.
PHOTOS = {
    # Develop examples
    "lake": ("DSC_0004", 2400),        # Basic, Tone Curve, Color Grading, Masking, Lens Blur
    "fog": ("DSC_0053", 1600),         # Dehaze
    "sunset": ("DSC_0102", 1600),      # Highlights, Match Look reference
    "palace": ("DSC_0230", 2400),      # Shadows, Tone Curve, HDR, README hero
    "market": ("DSC_0034", 1600),      # Vibrance, Saturation, HSL Saturation
    "hills": ("RHN_2983", 1600),       # HSL Hue and Luminance, B&W Mix
    "berets": ("_RZF1355", 2400),      # Black & White treatment, Grain
    "bird": ("DSC_0046", 2400),        # Texture, Sharpening, Noise Reduction
    "kathakali": ("DSC_0096", 2400),   # Select Subject / Background, AI Upscale
    "golf": ("DSC_0027", 1600),        # Remove (dust, Content-Aware), Lens vignetting
    "street": ("DSC_0013", 1600),      # Distortion, Upright
    "snow": ("DSC_0211", 2400),        # Chromatic aberration, Defringe
    "bay": ("RHN_3172", 1600),         # Straighten, Match Look
    "cars": ("DSC_0264", 1600),        # AI Remove Object
    "bench": ("RDV_1309", 1600),       # Select Subject / Background
    "flower": ("DSC_0425", 1600),      # Post-crop vignette
    # Library, Grid, Filmstrip and Cull thumbnails
    "kayaks": ("DSC_0052", 800),
    "clown": ("DSC_0243", 800),
    "blossoms": ("RDV_7677", 800),
    "golden-gate": ("DSC_0099", 800),
    "dancers": ("DSC_0037", 800),
    "tomatoes": ("DSC_4803", 800),
    "lanterns": ("RDV_1489", 800),
    "bikes": ("_RZF0876", 800),
    "rose": ("DSC_0145", 800),
    "flower-1": ("DSC_0432", 800),     # Cull: a burst in the rain
    "flower-2": ("DSC_0426", 800),
    "flower-3": ("DSC_0433", 800),
    "flower-4": ("DSC_0425", 800),
    "fog-1": ("DSC_0568", 800),        # Cull: same frame, a second apart
    "fog-2": ("DSC_0569", 800),
}

# Preset Lookbook and Match Look scenes (Scripts/presets/scenes): name: (NEF, crop x, y, w, h
# as fractions or None). No children: the repo is public (Rosh, 2026-11-19).
SCENES_OUT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "presets", "scenes")
SCENES = {
    "portrait": ("DSC_0314", (0.22, 0.17, 0.54, 0.75)),        # a couple by the sea, faces large
    "portrait-light": ("DSC_0315", (0.485, 0.22, 0.255, 0.62)), # one face in soft overcast light
    "landscape": ("RHN_2983", None),       # dry golden hills
    "sky": ("DSC_0027", None),             # blue sky with white clouds
    "haze": ("DSC_0053", None),            # a headland in fog
    "street": ("DSC_0013", None),
    "urban": ("_RZF1429", None),           # Paris at night
    "twilight": ("_RZF0572", None),
    "product": ("DSC_4804", None),         # white garlic
    "forest": ("RDV_1307", None),          # lush green park
    "wildlife": ("DSC_0046", None),
    "fine-art": ("_RZF1123", (0.375, 0.05, 0.22, 0.19)),       # the chapel's ceiling painting
}

# The noisy close-up for Detail: ISO 2800 at dusk, straight from the RAW.
NOISY = ("DSC_0348", (0.135, 0.28, 0.17, 0.30))  # x, y, w, h fractions: the doe, at 100%


def upright(image, orientation):
    if "90 CW" in orientation:
        return image.rotate(-90, expand=True)
    if "90 CCW" in orientation or "270" in orientation:
        return image.rotate(90, expand=True)
    if "180" in orientation:
        return image.rotate(180)
    return image


def embedded(path):
    """The camera's own full-size JPEG inside the NEF, turned upright."""
    with open(path, "rb") as f:
        orientation = str(exifread.process_file(f, details=False).get("Image Orientation", ""))
    with rawpy.imread(path) as raw:
        image = Image.open(io.BytesIO(raw.extract_thumb().data))
        image.load()
    return upright(image, orientation)


def remove_sky_dust(image, top=0.30):
    """Heal the faint sensor-dust specks in a smooth blue sky (the palace photo has a dozen).
    Only small, faint dark spots above `top` of the frame are replaced, by the sky around them."""
    import cv2
    a = np.asarray(image.convert("RGB")).astype(np.float32)
    H = a.shape[0]
    L = a.mean(2)
    median = np.stack([cv2.medianBlur(a[..., c].astype(np.uint8), 31) for c in range(3)], 2).astype(np.float32)
    dark = median.mean(2) - L
    sky = (a[..., 2] > a[..., 0] + 4) & (median.mean(2) > 50)
    sky[int(top * H):] = False
    spots = ((dark > 1.5) & sky).astype(np.uint8)
    count, labels, stats, _ = cv2.connectedComponentsWithStats(spots)
    keep = np.zeros_like(spots)
    for i in range(1, count):
        if stats[i, cv2.CC_STAT_AREA] < 600 and dark[labels == i].max() < 20:
            keep[labels == i] = 1
    keep = cv2.GaussianBlur(cv2.dilate(keep, np.ones((7, 7), np.uint8)).astype(np.float32), (0, 0), 2)[..., None]
    return Image.fromarray(np.clip(a * (1 - keep) + median * keep, 0, 255).astype(np.uint8))


def save(image, name, quality=86):
    # A fresh image: nothing from the source's metadata comes along.
    clean = Image.new("RGB", image.size)
    clean.paste(image.convert("RGB"))
    clean.save(os.path.join(OUT, name + ".jpg"), quality=quality, optimize=True, progressive=True)


def main(source):
    os.makedirs(OUT, exist_ok=True)
    for name, (nef, edge) in PHOTOS.items():
        image = embedded(os.path.join(source, nef + ".NEF"))
        image.thumbnail((edge, edge), Image.LANCZOS)
        if name == "palace":
            image = remove_sky_dust(image)
        save(image, name)
        print(name, image.size)
    os.makedirs(SCENES_OUT, exist_ok=True)
    for name, (nef, box) in SCENES.items():
        image = embedded(os.path.join(source, nef + ".NEF"))
        if box:
            W, H = image.size
            x, y, w, h = box
            image = image.crop((int(x * W), int(y * H), int((x + w) * W), int((y + h) * H)))
        image.thumbnail((1600, 1600), Image.LANCZOS)
        clean = Image.new("RGB", image.size)
        clean.paste(image.convert("RGB"))
        clean.save(os.path.join(SCENES_OUT, name + ".jpg"), quality=88, optimize=True, progressive=True)
        print("scene", name, image.size)
    nef, (x, y, w, h) = NOISY
    with rawpy.imread(os.path.join(source, nef + ".NEF")) as raw:
        rgb = raw.postprocess(use_camera_wb=True, no_auto_bright=False, output_bps=8, half_size=False)
    H, W = rgb.shape[:2]
    patch = rgb[int(y * H):int((y + h) * H), int(x * W):int((x + w) * W)]
    image = Image.fromarray(patch)
    save(image, "noisy-deer", quality=94)
    print("noisy-deer", image.size)
    total = sum(os.path.getsize(os.path.join(OUT, n)) for n in os.listdir(OUT))
    print(f"Wrote {OUT} ({total / 1e6:.1f} MB)")


if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else os.path.expanduser("~/Documents/for Atelier")))

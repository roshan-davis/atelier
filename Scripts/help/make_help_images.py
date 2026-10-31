#!/usr/bin/env python3
"""Makes the pictures in Lightfast Help (Sources/AtelierApp/Help/images).

The example photos are the splash images in Sources/AtelierApp/Resources/Splash. Each tool's
before/after pair is made here with a close approximation of what the tool does, so Help can
be rebuilt anywhere without the app. When CI can run the app again, pairs can be swapped for
real renders from DevelopRenderer; keep the file names so the pages don't change.

    pip install numpy scipy opencv-python-headless pillow
    python3 Scripts/help/make_help_images.py
"""

import json
import os
import sys

import cv2
import numpy as np
from PIL import Image
from scipy.interpolate import PchipInterpolator

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
SPLASH = os.path.join(ROOT, "Sources/AtelierApp/Resources/Splash")
OUT = os.path.join(ROOT, "Sources/AtelierApp/Help/images")
WIDTH = 960
QUALITY = 74
# Pictures used by many pairs are written once; pair() skips them (see SHARED).
SHARED = {}
rng = np.random.default_rng(7)


# MARK: Basics

def load(name, width=WIDTH):
    image = Image.open(os.path.join(SPLASH, name)).convert("RGB")
    if width and image.width != width:
        image = image.resize((width, round(image.height * width / image.width)), Image.LANCZOS)
    return np.asarray(image).astype(np.float32) / 255


def save(image, name, quality=QUALITY):
    data = (np.clip(image, 0, 1) * 255 + 0.5).astype(np.uint8)
    Image.fromarray(data).save(os.path.join(OUT, name), quality=quality, optimize=True, progressive=True)


def crop(image, x, y, w, h):
    """Crop by fractions of the image."""
    H, W = image.shape[:2]
    return image[round(y * H):round((y + h) * H), round(x * W):round((x + w) * W)]


def enlarge(image, factor, interpolation=cv2.INTER_CUBIC):
    H, W = image.shape[:2]
    return cv2.resize(image, (W * factor, H * factor), interpolation=interpolation)


def luma(image):
    return image @ np.array([0.2126, 0.7152, 0.0722], np.float32)


def blur(image, sigma):
    return cv2.GaussianBlur(image, (0, 0), sigma)


def smoothstep(a, b, x):
    t = np.clip((x - a) / (b - a), 0, 1)
    return t * t * (3 - 2 * t)


def with_luma(image, new):
    """Sets brightness while keeping each pixel's hue (scales RGB together)."""
    old = luma(image)
    ratio = (new + 1e-4) / (old + 1e-4)
    out = image * ratio[..., None]
    # Where a channel would clip, move toward white instead, so the hue doesn't skew.
    peak = out.max(axis=2, keepdims=True)
    over = np.clip(peak - 1, 0, 1)
    return np.clip(out / np.maximum(peak, 1) * (1 - over) + over, 0, 1)


def add_luma(image, delta):
    return np.clip(image + delta[..., None], 0, 1)


def mix(a, b, weight):
    if np.ndim(weight) == 2:
        weight = weight[..., None]
    return a * (1 - weight) + b * weight


def gray(image):
    return np.repeat(luma(image)[..., None], 3, axis=2)


# MARK: Develop approximations (sliders scaled -1...1 unless noted)

def flat(image):
    """An unedited look: lower contrast, lifted blacks, a little less color."""
    out = 0.5 + (image - 0.5) * 0.8 + 0.03
    return saturation(out, -0.12)


def exposure(image, ev):
    linear = np.power(np.clip(image, 0, 1), 2.2) * (2 ** ev)
    knee = 0.8
    over = linear > knee
    linear = np.where(over, knee + (1 - knee) * (1 - np.exp(-(linear - knee) / (1 - knee))), linear)
    return np.power(np.clip(linear, 0, 1), 1 / 2.2)


def contrast(image, amount):
    L = luma(image)
    k = 1 + 4 * abs(amount)
    s = 1 / (1 + np.exp(-k * (L - 0.5) * 2))
    lo, hi = 1 / (1 + np.exp(k)), 1 / (1 + np.exp(-k))
    s = (s - lo) / (hi - lo)
    new = L + (s - L) * (1 if amount > 0 else -0.6)
    return with_luma(image, np.clip(new, 0, 1))


def tone_base(image):
    """How bright each area is, ignoring detail (Highlights and Shadows act on this)."""
    L = luma(image)
    return cv2.bilateralFilter(L, 0, 0.25, image.shape[1] / 40)


def highlights(image, amount):
    base = tone_base(image)
    weight = smoothstep(0.4, 0.85, base)
    return add_luma(image, amount * 0.38 * weight)


def shadows(image, amount):
    base = tone_base(image)
    weight = 1 - smoothstep(0.05, 0.38, base)
    return add_luma(image, amount * 0.3 * weight * smoothstep(0.0, 0.06, luma(image)))


def whites(image, amount):
    L = luma(image)
    return with_luma(image, np.clip(L + amount * 0.3 * L ** 3, 0, 1))


def blacks(image, amount):
    L = luma(image)
    return with_luma(image, np.clip(L + amount * 0.22 * (1 - L) ** 4, 0, 1))


def temperature(image, amount):
    linear = np.power(image, 2.2)
    linear = linear * np.array([1 + 0.22 * amount, 1 + 0.02 * amount, 1 - 0.22 * amount], np.float32)
    return np.power(np.clip(linear, 0, 1), 1 / 2.2)


def tint(image, amount):
    linear = np.power(image, 2.2)
    linear = linear * np.array([1 + 0.08 * amount, 1 - 0.14 * amount, 1 + 0.08 * amount], np.float32)
    return np.power(np.clip(linear, 0, 1), 1 / 2.2)


def saturation(image, amount):
    L = luma(image)[..., None]
    return np.clip(L + (image - L) * (1 + amount), 0, 1)


def vibrance(image, amount):
    L = luma(image)[..., None]
    sat = image.max(axis=2) - image.min(axis=2)
    factor = 1 + amount * 1.4 * (1 - np.clip(sat * 1.6, 0, 1)) ** 2
    return np.clip(L + (image - L) * factor[..., None], 0, 1)


def clarity(image, amount):
    L = luma(image)
    base = cv2.bilateralFilter(L, 0, 0.15, image.shape[1] / 60)
    detail = L - base
    weight = np.clip(4 * L * (1 - L), 0, 1)
    return add_luma(image, amount * 1.6 * detail * weight)


def texture(image, amount, scale=1.0):
    L = luma(image)
    detail = blur(L, 0.8 * scale) - blur(L, 5 * scale)
    return add_luma(image, amount * 1.3 * detail)


def haze(image, strength=0.6):
    H, W = image.shape[:2]
    depth = np.linspace(1, 0.35, H, dtype=np.float32)[:, None] * np.ones((1, W), np.float32)
    t = 1 - strength * depth
    air = np.array([0.82, 0.85, 0.88], np.float32)
    return image * t[..., None] + air * (1 - t[..., None])


def curve(points):
    xs, ys = zip(*points)
    return PchipInterpolator(xs, ys)


def tone_curve(image, points):
    f = curve(points)
    return with_luma(image, np.clip(f(luma(image)), 0, 1).astype(np.float32))


def hsv(image):
    return cv2.cvtColor(image, cv2.COLOR_RGB2HSV)  # H 0...360, S, V 0...1


def rgb(hsv_image):
    return cv2.cvtColor(hsv_image, cv2.COLOR_HSV2RGB)


BANDS = {"red": 0, "orange": 30, "yellow": 60, "green": 120, "aqua": 180, "blue": 240, "purple": 270, "magenta": 300}


def band_weight(hue, center, width=40):
    d = np.abs((hue - center + 180) % 360 - 180)
    return np.clip(1 - d / width, 0, 1) ** 1.5


def hsl(image, hue=None, sat=None, lum=None):
    """Lightroom-style HSL: per-band shifts, grays untouched. Values -1...1."""
    h = hsv(image)
    H, S, V = h[..., 0], h[..., 1], h[..., 2]
    colorful = smoothstep(0.04, 0.2, S)
    dh = np.zeros_like(H)
    ds = np.zeros_like(H)
    dl = np.zeros_like(H)
    for name, center in BANDS.items():
        w = band_weight(H, center) * colorful
        dh += w * (hue or {}).get(name, 0) * 30
        ds += w * (sat or {}).get(name, 0)
        dl += w * (lum or {}).get(name, 0)
    out = np.stack([(H + dh) % 360, np.clip(S * (1 + ds), 0, 1), V], axis=2)
    out = rgb(out.astype(np.float32))
    L = luma(out)
    return with_luma(out, np.clip(L * (1 + 0.6 * dl), 0, 1))


def bw(image, mix_values=None):
    h = hsv(image)
    H, S = h[..., 0], h[..., 1]
    L = luma(image)
    for name, center in BANDS.items():
        L = L + band_weight(H, center) * S * (mix_values or {}).get(name, 0) * 0.45
    return gray(np.clip(L, 0, 1)[..., None] * np.ones_like(image))


def hue_rgb(hue):
    h = np.array([[[hue, 1.0, 1.0]]], np.float32)
    return rgb(h)[0, 0]


def color_grade(image, shadows=None, midtones=None, highlights=None, blending=0.5):
    """Each wheel is (hue degrees, saturation 0...1); tints shift color, not brightness."""
    L = luma(image)
    width = 0.15 + 0.35 * blending
    ws = 1 - smoothstep(0.5 - width, 0.5 + width * 0.2, L)
    wh = smoothstep(0.5 - width * 0.2, 0.5 + width, L)
    wm = np.clip(1 - ws - wh, 0, 1)
    out = image.copy()
    for wheel, w in ((shadows, ws), (midtones, wm), (highlights, wh)):
        if not wheel:
            continue
        tint_rgb = hue_rgb(wheel[0])
        offset = (tint_rgb - luma(tint_rgb[None, None])[0, 0]) * wheel[1] * 0.45
        out = out + w[..., None] * offset
    return with_luma(np.clip(out, 0, 1), L)


def sharpen(image, amount, radius=1.0):
    L = luma(image)
    return add_luma(image, amount * (L - blur(L, radius)))


def luminance_noise(image, sigma):
    noise = blur(rng.standard_normal(image.shape[:2]).astype(np.float32), 0.6) * sigma
    return add_luma(image, noise)


def color_noise(image, sigma):
    noise = blur(rng.standard_normal(image.shape).astype(np.float32), 2.2) * sigma
    noise -= noise.mean(axis=2, keepdims=True)
    return np.clip(image + noise, 0, 1)


def radius_map(image, cx=0.5, cy=0.5):
    H, W = image.shape[:2]
    y, x = np.mgrid[0:H, 0:W].astype(np.float32)
    nx, ny = (x / W - cx) * 2, (y / H - cy) * 2
    return np.sqrt(nx * nx + ny * ny) / np.sqrt(2)


def vignette(image, amount, midpoint=0.5):
    r = radius_map(image)
    w = smoothstep(midpoint * 0.7, 1.05, r)
    return exposure(image, amount * 2.2 * w) if amount > 0 else np.clip(image * (1 + amount * 0.9 * w[..., None]), 0, 1)


def grain(image, amount, size=1.0):
    noise = blur(rng.standard_normal(image.shape[:2]).astype(np.float32), 0.7 * size)
    noise /= noise.std()
    L = luma(image)
    return add_luma(image, noise * amount * 0.09 * np.clip(4 * L * (1 - L), 0.05, 1))


def remap(image, map_x, map_y):
    return cv2.remap(image, map_x.astype(np.float32), map_y.astype(np.float32), cv2.INTER_CUBIC,
                     borderMode=cv2.BORDER_CONSTANT, borderValue=(0.62, 0.62, 0.62))


def barrel(image, k):
    H, W = image.shape[:2]
    y, x = np.mgrid[0:H, 0:W].astype(np.float32)
    cx, cy = W / 2, H / 2
    norm = np.hypot(cx, cy)
    dx, dy = (x - cx) / norm, (y - cy) / norm
    r2 = dx * dx + dy * dy
    factor = (1 + k * r2) / (1 + k)
    return remap(image, cx + dx * norm * factor, cy + dy * norm * factor)


def scale_channels(image, red, blue):
    H, W = image.shape[:2]
    out = image.copy()
    for channel, s in ((0, red), (2, blue)):
        m = cv2.getRotationMatrix2D((W / 2, H / 2), 0, s)
        out[..., channel] = cv2.warpAffine(image[..., channel], m, (W, H), flags=cv2.INTER_CUBIC,
                                           borderMode=cv2.BORDER_REFLECT)
    return out


def keystone(image, squeeze):
    """Verticals lean in toward the top, as when a camera tilts up."""
    H, W = image.shape[:2]
    src = np.float32([[0, 0], [W, 0], [W, H], [0, H]])
    dst = np.float32([[W * squeeze, 0], [W * (1 - squeeze), 0], [W, H], [0, H]])
    m = cv2.getPerspectiveTransform(src, dst)
    return cv2.warpPerspective(image, m, (W, H), flags=cv2.INTER_CUBIC, borderMode=cv2.BORDER_CONSTANT,
                               borderValue=(0.62, 0.62, 0.62))


def rotate(image, degrees, fill=True):
    H, W = image.shape[:2]
    a = np.radians(abs(degrees))
    scale = (np.cos(a) + np.sin(a) * max(W / H, H / W)) if fill else 1
    m = cv2.getRotationMatrix2D((W / 2, H / 2), degrees, scale)
    return cv2.warpAffine(image, m, (W, H), flags=cv2.INTER_CUBIC, borderMode=cv2.BORDER_CONSTANT,
                          borderValue=(0.62, 0.62, 0.62))


def red_overlay(image, mask, strength=0.55):
    red = np.array([0.95, 0.12, 0.12], np.float32)
    return mix(image, red, mask * strength)


# MARK: Pictures

def pair(name, before, after):
    """Writes name-before.jpg and name-after.jpg, except for a shared picture (redwoods.jpg,
    redwoods-flat.jpg), which the page uses directly."""
    for side, image in (("before", before), ("after", after)):
        if not any(image is shared for shared in SHARED.values()):
            save(image, f"{name}-{side}.jpg")


def frames(name, image, values, fn):
    for i, v in enumerate(values):
        save(fn(image, v), f"{name}-{i}.jpg", quality=76)


def eagle_mask(eagle):
    """A rough subject mask for the eagle: everything that isn't the blue-gray water."""
    lab = cv2.cvtColor(eagle, cv2.COLOR_RGB2LAB)
    border = np.concatenate([lab[:20].reshape(-1, 3), lab[-20:].reshape(-1, 3), lab[:, :20].reshape(-1, 3)])
    ref = np.median(border, axis=0)
    local = cv2.GaussianBlur(lab, (0, 0), 25)
    distance = np.linalg.norm(lab - (0.5 * ref + 0.5 * local), axis=2)
    mask = (distance > 9).astype(np.uint8)
    mask = cv2.morphologyEx(mask, cv2.MORPH_OPEN, np.ones((5, 5), np.uint8))
    mask = cv2.morphologyEx(mask, cv2.MORPH_CLOSE, np.ones((21, 21), np.uint8))
    count, labels, stats, _ = cv2.connectedComponentsWithStats(mask)
    keep = 1 + np.argsort(stats[1:, cv2.CC_STAT_AREA])[::-1][:2]
    mask = np.isin(labels, keep).astype(np.uint8)
    mask = cv2.erode(mask, np.ones((5, 5), np.uint8)).astype(np.float32)
    # Leave out the photographer's watermark in the bottom left corner.
    H, W = mask.shape
    mask[int(H * 0.88):, :int(W * 0.12)] = 0
    return blur(mask, 2)


def wheel_svg(path, image, region, hue, sat, others=()):
    """A Color Grading wheel as the panel draws it, with the photo's colors as dots."""
    size, r = 220, 100
    c = size / 2
    parts = [f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {size} {size}" width="{size}" height="{size}">',
             '<defs><radialGradient id="g"><stop offset="0" stop-color="#808080"/>'
             '<stop offset="1" stop-color="#808080" stop-opacity="0"/></radialGradient></defs>']
    for i in range(72):
        a0, a1 = np.radians(i * 5), np.radians(i * 5 + 5.6)
        color = hue_rgb(i * 5 + 2.5) * 0.9 * 0.8 + 0.9 * 0.2
        hexcolor = "#%02x%02x%02x" % tuple(int(v * 255) for v in np.clip(color, 0, 1))
        p = lambda a: (c + r * np.cos(a), c - r * np.sin(a))
        (x0, y0), (x1, y1) = p(a0), p(a1)
        parts.append(f'<path d="M{c},{c} L{x0:.1f},{y0:.1f} A{r},{r} 0 0 0 {x1:.1f},{y1:.1f} Z" fill="{hexcolor}"/>')
    parts.append(f'<circle cx="{c}" cy="{c}" r="{r}" fill="url(#g)"/>')
    parts.append(f'<circle cx="{c}" cy="{c}" r="{r}" fill="none" stroke="#000" stroke-opacity=".4"/>')
    # The photo's colors that fall in this wheel's tonal range.
    small = cv2.resize(image, (60, 40), interpolation=cv2.INTER_AREA).reshape(-1, 3)
    L = luma(small[None])[0]
    h = hsv(small[None])[0]
    weight = {"shadows": 1 - smoothstep(0.2, 0.45, L), "highlights": smoothstep(0.55, 0.8, L)}.get(
        region, 1 - np.abs(L - 0.5) * 2)
    dots, seen = [], set()
    for (hh, ss, _), w in zip(h, weight):
        if w < 0.3:
            continue
        a = np.radians(hh)
        rr = min(1, ss * 1.1) * r
        x, y = round(c + rr * np.cos(a)), round(c - rr * np.sin(a))
        if (x, y) in seen:
            continue
        seen.add((x, y))
        dots.append(f'<circle cx="{x}" cy="{y}" r="1.1" fill-opacity="{0.18 + 0.3 * w:.2f}"/>')
    parts.append('<g class="scope" fill="#000">' + "".join(dots) + "</g>")
    for ohue, osat in others:
        a = np.radians(ohue)
        rr = osat * r
        color = hue_rgb(ohue) * osat + 0.5 * (1 - osat)
        parts.append(f'<circle class="other" cx="{c + rr * np.cos(a):.1f}" cy="{c - rr * np.sin(a):.1f}" r="3.5" '
                     f'fill="#%02x%02x%02x" stroke="#fff" stroke-opacity=".8"/>' % tuple(int(v * 255) for v in color))
    a = np.radians(hue)
    rim = (c + r * np.cos(a), c - r * np.sin(a))
    dot = (c + sat * r * np.cos(a), c - sat * r * np.sin(a))
    swatch = hue_rgb(hue) * sat + 0.5 * (1 - sat)
    rimc = hue_rgb(hue) * 0.85 + 0.1
    if sat > 0:
        parts.append(f'<line class="spoke" x1="{c}" y1="{c}" x2="{rim[0]:.1f}" y2="{rim[1]:.1f}" stroke="#fff" stroke-opacity=".6"/>')
    parts.append(f'<circle class="rim" cx="{rim[0]:.1f}" cy="{rim[1]:.1f}" r="5" fill="#%02x%02x%02x" stroke="#fff" stroke-width="1.5"/>'
                 % tuple(int(v * 255) for v in np.clip(rimc, 0, 1)))
    parts.append(f'<circle class="dot" cx="{dot[0]:.1f}" cy="{dot[1]:.1f}" r="6" fill="#%02x%02x%02x" stroke="#fff" stroke-width="2"/>'
                 % tuple(int(v * 255) for v in np.clip(swatch, 0, 1)))
    parts.append("</svg>")
    with open(os.path.join(OUT, path), "w") as f:
        f.write("\n".join(parts))


def histogram_json(image):
    """RGB histogram bins (64 each, 0...1) for the panel diagrams."""
    result = {}
    for i, name in enumerate(("r", "g", "b")):
        counts, _ = np.histogram(image[..., i], bins=64, range=(0, 1))
        counts = np.sqrt(counts.astype(np.float64))
        result[name] = [round(v, 3) for v in (counts / counts.max()).tolist()]
    counts, _ = np.histogram(luma(image), bins=64, range=(0, 1))
    counts = np.sqrt(counts.astype(np.float64))
    result["l"] = [round(v, 3) for v in (counts / counts.max()).tolist()]
    return result


def thumbnails(red, eagle, paint):
    """Small photos for the Library and Cull diagrams."""
    os.makedirs(os.path.join(OUT, "thumbs"), exist_ok=True)
    shots = {
        "forest": red, "forest-warm": temperature(red, 0.4), "forest-bw": bw(red),
        "logs": crop(red, 0.3, 0.55, 0.6, 0.45), "person": crop(red, 0.25, 0.4, 0.4, 0.45),
        "eagle": eagle, "eagle-wide": cv2.resize(eagle, None, fx=0.8, fy=0.8),
        "eagle-head": crop(eagle, 0.55, 0.45, 0.3, 0.3), "eagle-tail": crop(eagle, 0.15, 0.4, 0.45, 0.45),
        "eagle-soft": blur(eagle, 3), "eagle-dark": exposure(eagle, -0.8),
        "paint": paint, "paint-face": crop(paint, 0.15, 0.25, 0.65, 0.4),
        "light": crop(red, 0.35, 0.0, 0.4, 0.4), "fern": crop(red, 0.6, 0.25, 0.4, 0.4),
    }
    for name, image in shots.items():
        h, w = image.shape[:2]
        scale = 360 / max(h, w)
        small = cv2.resize(image, (round(w * scale), round(h * scale)), interpolation=cv2.INTER_AREA)
        save(small, f"thumbs/{name}.jpg", quality=74)


def make_hdr_images(base):
    # HDR: illustrative linear luminance shoulder plus bounded texture, matching the
    # single-image engine's controls; not a claim of extra captured scene detail.
    linear_hdr = np.where(base <= 0.04045, base / 12.92, ((base + 0.055) / 1.055) ** 2.4)
    hdr_luma = np.sum(linear_hdr * np.array([0.2126, 0.7152, 0.0722]), axis=2)
    log_y = np.log2(np.maximum(hdr_luma, 1e-6))
    radius = max(1, round(max(base.shape[:2]) * 0.02))
    mean = lambda x: cv2.boxFilter(x, -1, (2 * radius + 1, 2 * radius + 1), borderType=cv2.BORDER_REPLICATE)
    m = mean(log_y)
    variance = np.maximum(0, mean(log_y * log_y) - m * m)
    a = variance / (variance + 0.12)
    guided = mean(a) * log_y + mean((1 - a) * m)
    anchor = np.log2(0.18)
    amount = 0.65 * np.where(guided < anchor, np.clip(hdr_luma / 0.06, 0, 1), 1)
    compressed = anchor + (guided - anchor) * (1 - amount * 0.85)
    local = 2 ** (compressed + log_y - guided)
    shaped = 0.18 * (local / 0.18) ** 1.25
    mapped = shaped * (1 + 0.65 * 0.18) / (1 + 0.65 * shaped)
    small = cv2.boxFilter(log_y, -1, (5, 5), borderType=cv2.BORDER_REPLICATE)
    fine = np.clip(log_y - small, -0.5, 0.5)
    coarse = np.clip(small - guided, -0.5, 0.5)
    protection = (0.5 + 0.5 * np.clip(hdr_luma / 0.08, 0, 1)) * (0.5 + 0.5 / (1 + np.maximum(0, hdr_luma - 0.7) * 4))
    boundary = 1 / (1 + np.abs(log_y - small) * 4)
    texture_gain = 2 ** (protection * (0.35 * fine * 2 + 0.6 * coarse * 3 * boundary))
    hdr_gain = np.where(hdr_luma > 1e-6, mapped / np.maximum(hdr_luma, 1e-6), 1) * texture_gain
    hdr_linear = linear_hdr * hdr_gain[..., None]
    hdr_encoded = np.where(hdr_linear <= 0.0031308, hdr_linear * 12.92, 1.055 * np.maximum(hdr_linear, 0) ** (1 / 2.4) - 0.055)
    pair("hdr", base.copy(), hdr_encoded)



def main():
    os.makedirs(OUT, exist_ok=True)
    if "--hdr-only" in sys.argv:
        make_hdr_images(flat(load("splash-redwoods.jpg")))
        return 0
    red = load("splash-redwoods.jpg")
    eagle = load("splash-eagle.jpg")
    paint = load("splash-watercolor.jpg", width=760)
    red_full = load("splash-redwoods.jpg", width=None)
    eagle_full = load("splash-eagle.jpg", width=None)
    base = flat(red)
    eagle_base = flat(eagle)

    # Overview pictures, shared by many pairs
    save(red, "redwoods.jpg")
    save(base, "redwoods-flat.jpg")
    SHARED.update({"redwoods.jpg": red, "redwoods-flat.jpg": base})
    thumbnails(red, eagle, paint)

    # Basic
    frames("exposure", base, [-1.5, -0.75, 0, 0.75, 1.5], exposure)
    frames("temp", base, [-0.8, -0.4, 0, 0.4, 0.8], temperature)
    pair("contrast", base, contrast(base, 0.45))
    pair("highlights", base, highlights(base, -0.9))
    pair("shadows", base, shadows(base, 0.9))
    pair("whites-blacks", base, blacks(whites(base, 0.5), -0.6))
    pair("tint", tint(base, 0.5), base)
    pair("texture", crop(flat(eagle_full), 0.48, 0.25, 0.3, 0.3), texture(crop(flat(eagle_full), 0.48, 0.25, 0.3, 0.3), 0.9, 1.4))
    pair("clarity", base, clarity(base, 0.7))
    pair("dehaze", haze(red, 0.55), red)
    save(base, "presence-base.jpg")
    save(vibrance(base, 0.6), "vibrance.jpg")
    save(saturation(base, 0.6), "saturation.jpg")
    pair("treatment", paint, bw(paint))
    pair("profile", red, flat(red))
    neutral_wb = temperature(base, 0.5)
    pair("white-balance", neutral_wb, base)
    pair("auto-tone", exposure(flat(red), -1.0), red)

    # Tone Curve
    s_curve = [(0, 0), (0.25, 0.18), (0.5, 0.5), (0.75, 0.83), (1, 1)]
    pair("tone-curve", base, tone_curve(base, s_curve))
    matte = [(0, 0.12), (0.25, 0.27), (0.5, 0.52), (0.8, 0.82), (1, 0.95)]
    save(tone_curve(red, matte), "tone-curve-matte.jpg")

    # HSL / Color and B&W Mix
    pair("hsl-hue", red, hsl(red, hue={"green": -1.0, "yellow": -0.6}))
    pair("hsl-sat", paint, hsl(paint, sat={"orange": -0.7, "red": -0.5}))
    pair("hsl-lum", red, hsl(red, lum={"green": -0.6, "yellow": -0.5}))
    save(bw(red), "bw-default.jpg")
    save(bw(red, {"green": 0.9, "yellow": 0.8, "orange": -0.6}), "bw-mix.jpg")

    # Color Grading
    graded = color_grade(base, shadows=(195, 0.55), highlights=(35, 0.55))
    pair("color-grading", base, graded)
    wheel_svg("wheel-shadows.svg", graded, "shadows", 195, 0.55, others=[(35, 0.55)])
    wheel_svg("wheel-highlights.svg", graded, "highlights", 35, 0.55, others=[(195, 0.55)])
    wheel_svg("wheel-midtones.svg", graded, "midtones", 0, 0.0, others=[(195, 0.55), (35, 0.55)])
    pair("grade-split", base, color_grade(base, shadows=(220, 0.6), highlights=(50, 0.5), blending=0.8))

    # Detail: 100% views of the eagle's head
    head = crop(eagle_full, 0.6, 0.48, 0.2, 0.2)
    head = cv2.resize(head, (540, round(540 * head.shape[0] / head.shape[1])), interpolation=cv2.INTER_CUBIC)
    soft = blur(head, 1.2)
    pair("sharpening", soft, sharpen(soft, 2.4, 1.4))
    noisy = luminance_noise(head, 0.05)
    pair("noise", noisy, blur(head, 0.6))
    pair("color-noise", color_noise(head, 0.07), head)

    # Lens Corrections
    pair("distortion", barrel(red, 0.32), red)
    pair("lens-vignette", np.clip(red * (1 - 0.6 * smoothstep(0.25, 1.0, radius_map(red))[..., None]), 0, 1), red)
    corner = crop(red_full, 0.0, 0.08, 0.12, 0.12)
    ca = scale_channels(red_full, 1.0015, 0.9985)
    pair("chromatic-aberration", enlarge(crop(ca, 0.0, 0.08, 0.12, 0.12), 3), enlarge(corner, 3))
    edge = crop(red_full, 0.08, 0.0, 0.14, 0.14)
    L = luma(edge)
    edges = np.abs(cv2.Sobel(blur(L, 1), cv2.CV_32F, 1, 0, ksize=3)) + np.abs(cv2.Sobel(blur(L, 1), cv2.CV_32F, 0, 1, ksize=3))
    near = blur((edges > 0.6).astype(np.float32), 1.5) * (1 - smoothstep(0.45, 0.75, L))
    fringed = mix(edge, np.array([0.55, 0.22, 0.8], np.float32) * (0.5 + 0.5 * L[..., None]), np.clip(near * 1.2, 0, 0.6))
    pair("defringe", enlarge(fringed, 3), enlarge(edge, 3))

    # Transform
    pair("upright", keystone(red, 0.12), red)
    pair("straighten", rotate(red, 4), red)

    # Effects
    pair("post-crop-vignette", base, vignette(base, -0.5))
    grain_view = crop(red_full, 0.42, 0.42, 0.2, 0.15)
    pair("grain", enlarge(grain_view, 2), enlarge(grain(grain_view, 0.45, 1.0), 2))

    # Masking
    H, W = red.shape[:2]
    ramp = 1 - smoothstep(0.02, 0.45, np.linspace(0, 1, H, dtype=np.float32))[:, None] * np.ones((1, W), np.float32)
    pair("mask-linear", base, mix(base, exposure(base, -1.0), ramp))
    save(red_overlay(base, ramp), "mask-linear-overlay.jpg")
    y, x = np.mgrid[0:H, 0:W].astype(np.float32)
    ellipse = np.sqrt(((x / W - 0.425) / 0.13) ** 2 + ((y / H - 0.66) / 0.24) ** 2)
    radial = 1 - smoothstep(0.55, 1.0, ellipse)
    lifted = exposure(base, 0.9)
    pair("mask-radial", base, mix(exposure(base, -0.35), lifted, radial))
    save(red_overlay(base, radial), "mask-radial-overlay.jpg")
    subject = eagle_mask(eagle)
    pair("mask-subject", eagle_base, mix(saturation(exposure(eagle_base, -0.3), -0.35), exposure(eagle_base, 0.2), subject))
    save(red_overlay(eagle_base, subject), "mask-subject-overlay.jpg")
    bright = smoothstep(0.55, 0.75, luma(base))
    save(red_overlay(base, bright), "mask-luminance-overlay.jpg")
    pair("mask-luminance", base, mix(base, highlights(base, -0.6), bright))

    # Presets: the real built-in looks, read from BuiltInPresets.swift and rendered with the
    # renderer's numpy port (Scripts/presets/develop_sim.py).
    sys.path.insert(0, os.path.join(ROOT, "Scripts/presets"))
    import develop_sim
    from preset_sheets import parse_presets
    presets = {name: s for _, name, s in parse_presets()[1]}
    shown = ["Portrait 400", "Pastel 400", "Chrome 64", "Vivid Slide", "Golden Hour", "Muted Chrome",
             "Teal & Orange", "Dark & Moody", "Faded Matte", "Classic 400", "Dark Sky", "Noir"]
    small_base = cv2.resize(base, (480, round(480 * H / W)), interpolation=cv2.INTER_AREA)
    linear = develop_sim.from_srgb_encoded(small_base)
    scale = 480 / Image.open(os.path.join(SPLASH, "splash-redwoods.jpg")).width
    for name in shown:
        image = develop_sim.to_srgb_encoded(develop_sim.develop(linear, presets[name], scale))
        slug = name.lower().replace(" & ", "-").replace(" ", "-")
        save(image, f"preset-{slug}.jpg", quality=76)
    small = cv2.resize(base, (480, round(480 * H / W)), interpolation=cv2.INTER_AREA)
    save(small, "preset-none.jpg", quality=76)

    # Match Look: Reinhard transfer in Lab, as a stand-in for the slider fit
    reference = load("splash-eagle.jpg")
    lab_ref, lab_photo = cv2.cvtColor(reference, cv2.COLOR_RGB2LAB), cv2.cvtColor(base, cv2.COLOR_RGB2LAB)
    matched = (lab_photo - lab_photo.mean((0, 1))) / lab_photo.std((0, 1)) * lab_ref.std((0, 1)) * [0.9, 0.7, 0.7] + lab_ref.mean((0, 1))
    matched = cv2.cvtColor(matched.astype(np.float32), cv2.COLOR_LAB2RGB)
    save(mix(base, np.clip(matched, 0, 1), 0.8), "match-result.jpg")
    save(cv2.resize(reference, (540, round(540 * reference.shape[0] / reference.shape[1]))), "match-reference.jpg")

    # AI: Remove Object (the hiker), Upscale (the eagle's eye)
    person = np.zeros((H, W), np.uint8)
    cv2.ellipse(person, (int(W * 0.425), int(H * 0.655)), (int(W * 0.03), int(H * 0.12)), 0, 0, 360, 255, -1)
    cv2.circle(person, (int(W * 0.427), int(H * 0.585)), int(W * 0.015), 255, -1)
    person = cv2.dilate(person, np.ones((9, 9), np.uint8))
    # Stand-in for the model: fill from the forest floor beside the hiker.
    removed = np.roll(red, -int(W * 0.07), axis=1)
    soft_mask = blur(person.astype(np.float32) / 255, 4)
    pair("ai-remove", red, mix(red, removed, soft_mask))
    save(red_overlay(red, soft_mask, 0.6), "ai-remove-strokes.jpg")
    eye = crop(eagle_full, 0.68, 0.53, 0.09, 0.09)
    small_eye = cv2.resize(eye, (eye.shape[1] // 4, eye.shape[0] // 4), interpolation=cv2.INTER_AREA)
    pair("ai-upscale", cv2.resize(small_eye, (540, 540 * eye.shape[0] // eye.shape[1]), interpolation=cv2.INTER_LINEAR),
         sharpen(cv2.resize(eye, (540, 540 * eye.shape[0] // eye.shape[1]), interpolation=cv2.INTER_CUBIC), 0.6, 1.2))

    make_hdr_images(base)

    # Histogram data for the panel diagrams
    with open(os.path.join(OUT, "histogram.js"), "w") as f:
        f.write("window.HELP_HISTOGRAM = " + json.dumps({"redwoods": histogram_json(base)}) + ";\n")

    total = sum(os.path.getsize(os.path.join(dirpath, n)) for dirpath, _, names in os.walk(OUT) for n in names)
    print(f"Wrote {OUT} ({total / 1e6:.1f} MB)")


if __name__ == "__main__":
    sys.exit(main())

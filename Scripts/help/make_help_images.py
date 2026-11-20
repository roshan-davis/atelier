#!/usr/bin/env python3
"""Makes the pictures in Atelier Help (Sources/AtelierApp/Help/images).

The example photos are Rosh's own, in Scripts/help/photos (made from the RAW samples with
prepare_photos.py, metadata stripped). Each tool gets a photo that suits it: a lake at dawn for
Basic and Masking, a foggy coast for Dehaze, a Kathakali dancer for Select Subject, a market
stall for Vibrance, a golf course sky for dust spots. Each tool's before/after pair is made here
with a close approximation of what the tool does, so Help can be rebuilt anywhere without the
app. AI Denoise is the exception: it is the app's own PMRID model on a real ISO 2800 RAW
(pmrid_example.py). When CI can run the app again, pairs can be swapped for
real renders from DevelopRenderer; keep the file names so the pages don't change.

    pip install numpy scipy opencv-python-headless pillow
    python3 Scripts/help/make_help_images.py

For preset examples, use --presets-from RENDER_DIR (see Scripts/presets/README.md).
For the built-in Match Look example, run the native qualification test with
ATELIER_BUILT_IN_LOOK_OUT=RENDER_DIR, then use --built-in-look-from RENDER_DIR.
For Match Skin Tone, run the portrait study test with ATELIER_SKIN_LOOK_OUT=RENDER_DIR,
then use --skin-look-from RENDER_DIR.
"""

import json
import os
import sys

import cv2
import numpy as np
from PIL import Image
from scipy.interpolate import PchipInterpolator

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
PHOTOS = os.path.join(ROOT, "Scripts/help/photos")
DATA = os.path.join(ROOT, "Scripts/help/data")
OUT = os.path.join(ROOT, "Sources/AtelierApp/Help/images")
WIDTH = 960
QUALITY = 74
# Pictures used by many pairs are written once; pair() skips them (see SHARED).
SHARED = {}
rng = np.random.default_rng(7)


# MARK: Basics

def load(name, width=WIDTH):
    image = Image.open(os.path.join(PHOTOS, name)).convert("RGB")
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


def tone_base(image, full_width=6000):
    """How bright each area is, ignoring detail, as Atelier's Highlights and Shadows read it
    (LocalContrast.toneRegions): a guided filter on gamma luma with a 100 px window at full size."""
    g = np.power(np.clip(np.power(image, 2.2) @ np.array([0.2627, 0.6780, 0.0593], np.float32), 0, 1), 1 / 2.2)
    radius = max(1, round(100 * image.shape[1] / full_width))
    box = lambda x: cv2.boxFilter(x, -1, (2 * radius + 1, 2 * radius + 1), borderType=cv2.BORDER_REFLECT)
    mean, mean_sq = box(g), box(g * g)
    a = np.maximum(mean_sq - mean * mean, 0) / (np.maximum(mean_sq - mean * mean, 0) + 0.01)
    b = mean - a * mean
    return np.clip(box(a) * g + box(b), 0, 1)


def _tone_regions(image, highlight_amount, shadow_amount):
    """Atelier's kernel: bumps peaking at 25% (Shadows) and 75% (Highlights) of the base,
    added to the gamma-encoded color."""
    base = tone_base(image)
    ws = base * (1 - base) ** 3 / 0.10546875
    wh = base ** 3 * (1 - base) / 0.10546875
    shadow_gain = 0.22 * (0.7 if shadow_amount < 0 else 1) * shadow_amount
    shift = shadow_gain * ws + 0.22 * highlight_amount * wh
    return np.clip(image + shift[..., None], 0, 1)


def highlights(image, amount):
    return _tone_regions(image, amount, 0)


def shadows(image, amount):
    return _tone_regions(image, 0, amount)


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


# Oklab, as Color Range masks see color (sRGB primaries; the app reads the same space from
# its linear Rec. 2020 working space).
OKLAB_M1 = np.array([[0.4122214708, 0.5363325363, 0.0514459929], [0.2119034982, 0.6806995451, 0.1073969566],
                     [0.0883024619, 0.2817188376, 0.6299787005]], np.float32)
OKLAB_M2 = np.array([[0.2104542553, 0.7936177850, -0.0040720468], [1.9779984951, -2.4285922050, 0.4505937099],
                     [0.0259040371, 0.7827717662, -0.8086757660]], np.float32)


def oklab(image):
    linear = np.where(image <= 0.04045, image / 12.92, ((image + 0.055) / 1.055) ** 2.4)
    return np.cbrt(linear @ OKLAB_M1.T) @ OKLAB_M2.T


def color_range_mask(image, box, refine=50):
    """Color Range as the app works it out (ColorRange.weight): the mean color in `box` (x, y,
    w, h fractions) and its spread, then a smooth falloff in Oklab with lightness counting half."""
    lab = oklab(image)
    area = crop(lab, *box).reshape(-1, 3)
    pick = area.mean(0)
    d = area - pick
    spread = min(float(np.sqrt(np.mean(d[:, 1] ** 2 + d[:, 2] ** 2 + 0.25 * d[:, 0] ** 2))), 0.15)
    zero = 0.012 + refine / 100 * 0.14 + spread
    full = zero * 0.45
    d = lab - pick
    distance = np.sqrt(d[..., 1] ** 2 + d[..., 2] ** 2 + 0.25 * d[..., 0] ** 2)
    t = np.clip((zero - distance) / (zero - full), 0, 1)
    return t * t * (3 - 2 * t)


def turn_hue(image, degrees):
    """The mask Hue slider (MaskSliders.turnHue): Oklab a and b turned by `degrees`."""
    lab = oklab(image)
    t = np.radians(degrees)
    a = lab[..., 1] * np.cos(t) - lab[..., 2] * np.sin(t)
    b = lab[..., 1] * np.sin(t) + lab[..., 2] * np.cos(t)
    lms = np.stack([lab[..., 0], a, b], -1) @ np.linalg.inv(OKLAB_M2).T
    linear = np.clip((lms ** 3) @ np.linalg.inv(OKLAB_M1).T, 0, 1)
    return np.where(linear <= 0.0031308, linear * 12.92, 1.055 * linear ** (1 / 2.4) - 0.055).astype(np.float32)


# Color Range's pick on the lake photo: the yellow kayak (x, y, w, h fractions).
KAYAK = (0.62, 0.56, 0.03, 0.03)


def make_mask_slider_images(base):
    kayak = color_range_mask(base, KAYAK)
    pair("mask-hue", base, mix(base, turn_hue(base, -50), kayak))
    # A mask's own Color Grading: the sky under a Linear Gradient, lavender shadows and peach highlights.
    H, W = base.shape[:2]
    ramp = 1 - smoothstep(0.0, 0.3, np.linspace(0, 1, H, dtype=np.float32))[:, None] * np.ones((1, W), np.float32)
    graded = color_grade(base, shadows=(265, 0.25), midtones=(20, 0.35), highlights=(30, 0.75))
    pair("mask-grade", base, mix(base, graded, ramp))


def red_overlay(image, mask, strength=0.55):
    red = np.array([0.95, 0.12, 0.12], np.float32)
    return mix(image, red, mask * strength)


# MARK: Pictures

def calibration(image, red_hue=0, red_sat=0, green_hue=0, green_sat=0, blue_hue=0, blue_sat=0, tint=0):
    """Calibration (AT-069), the same math as Calibration.swift, in linear Rec. 2020. Sliders -1...1."""
    to2020 = np.array([[0.6274, 0.3293, 0.0433], [0.0691, 0.9195, 0.0114], [0.0164, 0.0880, 0.8956]], np.float32)
    linear = np.power(np.clip(image, 0, 1), 2.2) @ to2020.T
    k = np.ones(3) / np.sqrt(3)
    gray = np.ones(3) / 3
    columns = []
    for i, (hue, sat) in enumerate(((red_hue, red_sat), (green_hue, green_sat), (blue_hue, blue_sat))):
        p = np.zeros(3)
        p[i] = 1
        a = hue * np.pi / 6
        turned = p * np.cos(a) + np.cross(k, p) * np.sin(a) + k * np.dot(k, p) * (1 - np.cos(a))
        columns.append(gray + (turned - gray) * (1 + sat * 0.6))
    m = np.array(columns).T
    m = m * np.linalg.solve(m, np.ones(3))
    c = linear @ m.T.astype(np.float32)
    if tint:
        weights = np.array([0.2627, 0.6780, 0.0593], np.float32)
        y = c @ weights
        t = np.clip(np.cbrt(np.maximum(y, 0)) / 0.68, 0, 1)
        w = 1 - t * t * (3 - 2 * t)
        tinted = c * (1 + np.array([0.5, -1, 0.5], np.float32) * (tint * 0.16 * w)[..., None])
        new_y = tinted @ weights
        c = np.where((new_y > 1e-6)[..., None], tinted * (y / np.maximum(new_y, 1e-6))[..., None], tinted)
    out = c @ np.linalg.inv(to2020).T.astype(np.float32)
    return np.power(np.clip(out, 0, 1), 1 / 2.2)


def _lens_gather(color, c, R, shape, cat_eye, count, skip, holes=None):
    """One level of Lens Blur's gather (atelierLensBlurGather): `c` is the signed blur, capped to
    this level's radius `R` (in its pixels) and divided by it; `skip` marks the pixels whose own
    blur belongs to coarser levels (left at 0); `holes` the pixels sharp at this level (no
    weight in atelierLensBlurWeigh), which take no light of their own and are never gathered.
    Returns the blur and the spill."""
    from scipy.ndimage import map_coordinates
    h, w = c.shape
    if holes is None:
        holes = np.zeros((h, w), bool)
    yy, xx = np.mgrid[0:h, 0:w].astype(np.float32)
    half = 0.5 * np.hypot(w, h)
    vx, vy = (xx - w / 2) / half, (yy - h / 2) / half
    hf = holes.astype(np.float32)
    c_reach = np.where(holes, 1.0, c)
    weight = np.where(holes, 0.0, 1 / np.maximum((np.abs(c) * R) ** 2, 1))
    total, acc, spill = weight.copy(), color * weight[..., None], np.zeros_like(weight)
    for i in range(count):
        r = R * np.sqrt((i + 0.5) / count)
        a = i * 2.39996323
        ox, oy = r * np.cos(a), r * np.sin(a)
        cq = map_coordinates(c, [yy + oy, xx + ox], order=1, mode="nearest")
        cols = np.dstack([map_coordinates(color[..., k], [yy + oy, xx + ox], order=1, mode="nearest") for k in range(3)])
        hq = map_coordinates(hf, [yy + oy, xx + ox], order=1, mode="nearest")
        reach = np.where(cq > c_reach, np.minimum(np.abs(cq), np.abs(c_reach)), np.abs(cq)) * R
        dx, dy = -ox, -oy
        limit = 1.0
        if shape == 2:
            t = np.mod(np.arctan2(dx, -dy) + 2 * np.pi, 1.2566371) - 0.6283185
            limit = 0.80901699 / np.cos(t)
        elif shape == 4:
            limit = 1 / np.sqrt((dx / max(r, 1e-4) / 0.55) ** 2 + (dy / max(r, 1e-4)) ** 2)
        cover = np.clip(reach * limit - r + 0.5, 0, 1) * (hq < 0.5)
        if cat_eye > 0:
            cover *= np.clip(reach - np.hypot(dx + cat_eye * 0.7 * vx * reach, dy + cat_eye * 0.7 * vy * reach) + 0.5, 0, 1)
        u = np.clip(r / np.maximum(reach * limit, 1e-3), 0, 1)
        light = 0.55 + 0.9 * u ** 4 if shape == 1 else (0.12 + smoothstep(0.55, 0.85, u) if shape == 3 else 1.0)
        wq = cover * light / np.maximum(reach ** 2, 1)
        acc += cols * wq[..., None]
        total += wq
        spill += np.where((cq < c - 0.02) & (np.abs(cq) > np.abs(c)), wq, 0)
    alpha = np.where(holes, spill / (1 + spill), spill / np.maximum(total, 1e-6))
    out = np.dstack([acc / np.maximum(total, 1e-6)[..., None], alpha])
    return np.where((skip & ~holes)[..., None], 0.0, out)


LENS_DETAIL = (0.01, 0.05, 0.003, 2.0, 3.0)
LENS_HAIR_SHARE = 0.01


def _push_pull(values, weight, levels=6):
    """`values` where `weight` is 1, filled in from around where it is 0 (a weighted pyramid,
    then back up: atelierLensBlurFill)."""
    pyramid = [(values * weight, weight)]
    for _ in range(levels):
        v, w = pyramid[-1]
        h, wd = max(1, v.shape[0] // 3), max(1, v.shape[1] // 3)
        pyramid.append((cv2.resize(v, (wd, h), interpolation=cv2.INTER_AREA), cv2.resize(w, (wd, h), interpolation=cv2.INTER_AREA)))
    v, w = pyramid[-1]
    filled = np.where(w > 1e-4, v / np.maximum(w, 1e-4), 0)
    for v, w in reversed(pyramid[:-1]):
        up = cv2.resize(filled, (v.shape[1], v.shape[0]), interpolation=cv2.INTER_LINEAR)
        own = np.where(w > 1e-4, v / np.maximum(w, 1e-4), 0)
        filled = up + (own - up) * smoothstep(0.0, 0.3, w)
    return filled.astype(np.float32)


def lens_blur(image, depth, amount=0.5, near=0.7, far=0.8, shape=0, cat_eye=0.0, boost=0.5, areas=None):
    """Lens Blur (AT-072), the same steps as LensBlur.swift: a signed blur from depth (0 near to
    1 far), changed by the Focus areas (`areas[..., 0]`, toward sharp) and Blur areas
    (`areas[..., 1]`, toward the most blur), Boost on near-clipped highlights, then a gather at
    full size and on copies a third, a ninth... the size, each pixel taking its blur from the
    level that fits it, so edges near the focus stay fine when zoomed in. Sliders 0...1."""
    H, W = image.shape[:2]
    lin = np.power(np.clip(image, 0, 1), 2.2).astype(np.float32)
    d = cv2.resize(depth.astype(np.float32), (W, H), interpolation=cv2.INTER_LINEAR)
    coc = np.clip((d - far) / 0.5, 0, 1) - np.clip((near - d) / 0.5, 0, 1)
    # Focus areas work as a layer mask (atelierLensBlurAreas): the photo is blurred as if the
    # area weren't there (its blur filled in from around it, its pixels left out of the gather),
    # then the sharp photo goes back on top through the area. Blur areas take the blur of what
    # is around them (the farthest blur when that is sharp).
    focus = np.zeros((H, W), np.float32)
    if areas is not None:
        # Detailed Focus edges (hair: the mask changes within a pixel or two) work as a layer
        # mask; smooth ones (a feathered gradient) lower the blur, as Lightroom's Focus brush.
        a0 = areas[..., 0].astype(np.float32)
        lo, hi, share, spread, gain = LENS_DETAIL
        sigma = max(1.0, share * max(W, H))
        raw = smoothstep(lo, hi, np.abs(a0 - cv2.GaussianBlur(a0, (0, 0), sigma)))
        detail = np.clip(cv2.GaussianBlur(raw, (0, 0), spread * sigma) * gain, 0, 1)
        # Hair-like edges (many edges around, not one outline) get the near band; along a single
        # outline the mask may sit a pixel inside the subject, and the band smeared that sliver
        # outward as a halo (atelierLensBlurDetail's green).
        hair_sigma = max(1.0, LENS_HAIR_SHARE * max(W, H))
        gy, gx = np.gradient(a0)
        edges = cv2.GaussianBlur(np.hypot(gx, gy).astype(np.float32), (0, 0), hair_sigma) * hair_sigma * 2.5066283
        hairy = np.clip(cv2.GaussianBlur(raw * smoothstep(1.5, 3.0, edges), (0, 0), spread * sigma) * gain, 0, 1)
        # The depth model sees a hair cloud as one near blob, gaps included, so close to a
        # detailed, hair-like edge (2% of the long edge) the depth isn't trusted: the blur there
        # comes from beyond, and what isn't in the area blurs at least as much as the background
        # past it.
        margin = max(1, int(round(0.02 * max(W, H))))
        band = cv2.dilate((hairy > 0.5).astype(np.float32), cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (2 * margin + 1, 2 * margin + 1)))
        band = np.clip(cv2.GaussianBlur(band, (0, 0), margin / 3), 0, 1)
        filled = _push_pull(coc, (1 - band) * (1 - areas[..., 1]))
        larger = np.where(np.abs(filled) > np.abs(coc), filled, coc)
        coc = coc + (larger - coc) * band
        coc = coc + (filled - coc) * smoothstep(0.0, 0.25, a0) * band
        focus = a0 * detail
        coc = coc * (1 - a0 * (1 - detail))
        sign = np.where(filled < 0, -1.0, 1.0)
        blur_c = sign + (filled - sign) * smoothstep(0.05, 0.2, np.abs(filled))
        coc = coc + (blur_c - coc) * areas[..., 1]
    luma = np.power(np.maximum(lin @ np.array([0.2627, 0.6780, 0.0593], np.float32), 0), 1 / 2.2)
    boosted = lin * (1 + 2 * boost * smoothstep(0.85, 1.0, luma))[..., None]
    max_r = amount * 0.025 * max(W, H)
    if max_r < 0.5:
        return image
    levels = []
    k = 0
    while True:
        factor = 3.0 ** -k
        w, h = max(1, int(W * factor)), max(1, int(H * factor))
        holes = None
        if k == 0 and areas is None:
            color, c = boosted, coc
        else:
            # Only pixels that blur by about a level pixel or more feed a coarse level, so a sharp
            # edge doesn't spread a halo into the background's blur (atelierLensBlurWeigh); a
            # Focus area's pixels feed none.
            wt = (1.0 if k == 0 else smoothstep(0.5, 1.5, np.abs(coc) * max_r * factor)) * (1 - focus)
            wt = np.asarray(wt, np.float32)
            small_color = cv2.resize(boosted * wt[..., None], (w, h), interpolation=cv2.INTER_AREA)
            small = cv2.resize(np.dstack([coc * wt, wt]), (w, h), interpolation=cv2.INTER_AREA)
            sw = small[..., 1]
            holes = sw < 0.02
            color = np.where(holes[..., None], 0, small_color / np.maximum(sw, 1e-6)[..., None])
            c = np.where(holes, 0, small[..., 0] / np.maximum(sw, 1e-6))
        R = min(12.0, max_r * factor)
        last = 12 * 3 ** k >= max_r or k >= 5
        cutoff = 1e9 if last else 4 * 3 ** (k + 1) * factor
        skip = (np.abs(c) * max_r * factor >= cutoff) & (True if holes is None else ~holes)
        c = np.sign(c) * np.minimum(np.abs(c) * max_r * factor, R) / R
        count = min(112, max(12, round(np.pi * R * R / 3.5)))
        # Softened by under a pixel first, so fine texture doesn't come out mottled (LensBlur.prefilter).
        out = _lens_gather(cv2.GaussianBlur(color, (0, 0), 0.8), c, R, shape, cat_eye, count, skip, holes)
        levels.append(out if k == 0 else cv2.resize(out, (W, H), interpolation=cv2.INTER_LINEAR))
        if last:
            break
        k += 1
    own_c = np.abs(coc) * max_r
    f = np.clip(np.log(np.maximum(own_c, 1e-3) / 4) / np.log(3), 0, len(levels) - 1)
    own = levels[0][..., :3]
    for index, level in enumerate(levels[1:], 1):
        t = np.clip(f - (index - 1), 0, 1)[..., None]
        own = own * (1 - t) + level[..., :3] * t
    mix_ = smoothstep(0.25, 1.0, own_c)[..., None]
    out = lin * (1 - mix_) + np.maximum(own, 0) * mix_
    out = out + (lin - out) * focus[..., None]
    mix_ = smoothstep(0.25, 1.0, own_c * (1 - focus))[..., None]
    for level in levels:
        a = np.clip(level[..., 3:], 0, 1) * (1 - mix_)
        out = out * (1 - a) + np.maximum(level[..., :3], 0) * a
    return np.power(np.clip(out, 0, 1), 1 / 2.2)


def depth_view(depth, near, far, size):
    """Visualize Depth: warm near to cool far, the focal range lighter (LensBlur.swift)."""
    d = np.clip(cv2.resize(depth.astype(np.float32), size, interpolation=cv2.INTER_LINEAR), 0, 1)[..., None]
    near_c, mid, far_c = (np.array(v, np.float32) for v in ((1.0, 0.55, 0.12), (0.62, 0.36, 0.72), (0.12, 0.32, 0.95)))
    c = np.where(d < 0.5, near_c + (mid - near_c) * d * 2, mid + (far_c - mid) * (d * 2 - 1))
    inside = ((d >= near) & (d <= far)).astype(np.float32)
    return c * 0.8 * (1 - 0.55 * inside) + 0.55 * inside


def guided_depth(depth, image, radius_share=0.005, eps=0.0004):
    """The depth map at the photo's size, its edges snapped to the photo's with a guided filter,
    as the app places the depth model's map (DepthMap's guided snap)."""
    H, W = image.shape[:2]
    d = cv2.resize(depth.astype(np.float32), (W, H), interpolation=cv2.INTER_LINEAR)
    lin = np.power(np.clip(image, 0, 1), 2.2).astype(np.float32)
    guide = np.power(np.clip(lin @ np.array([0.2627, 0.6780, 0.0593], np.float32), 0, 1), 1 / 2.2)
    r = max(1, int(radius_share * max(W, H)))
    box = lambda x: cv2.blur(x, (2 * r + 1, 2 * r + 1))
    m_i, m_p, m_ii, m_ip = box(guide), box(d), box(guide * guide), box(guide * d)
    a = (m_ip - m_i * m_p) / (np.maximum(m_ii - m_i * m_i, 0) + eps)
    b = m_p - a * m_i
    return np.clip(box(a) * guide + box(b), 0, 1)


def radial_area(shape, center, radius_x, radius_y, feather=0.5):
    """A Radial Gradient mask (fractions of the photo; radii of its long edge), 1 inside."""
    H, W = shape[:2]
    L = max(W, H)
    yy, xx = np.mgrid[0:H, 0:W].astype(np.float32)
    r = np.hypot((xx - center[0] * W) / (radius_x * L), (yy - center[1] * H) / (radius_y * L))
    return 1 - smoothstep(1 - feather, 1.0, r)


def pair(name, before, after):
    """Writes name-before.jpg and name-after.jpg, except for a shared picture (lake.jpg,
    lake-flat.jpg), which the page uses directly."""
    for side, image in (("before", before), ("after", after)):
        if not any(image is shared for shared in SHARED.values()):
            save(image, f"{name}-{side}.jpg")


def frames(name, image, values, fn):
    for i, v in enumerate(values):
        save(fn(image, v), f"{name}-{i}.jpg", quality=76)


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


def hdr_render(linear, method="direct", range_=0.65, spacing=2.0, micro=0.6, detail=0.35, shadows=0.0,
               highlights=0.0, temperature=0.0, vibrance=0.0, saturation=0.0):
    """HDRToneMapper.render (Natural or Fusion, Highlights/Shadows, texture, Color) at Exposure 0."""
    weights = np.array([0.2126, 0.7152, 0.0722])
    l = np.maximum(0, linear @ weights)
    lg = np.log2(np.maximum(l, 1e-6))
    size = max(linear.shape[:2])
    box = lambda x, r: cv2.boxFilter(x, -1, (2 * r + 1, 2 * r + 1), borderType=cv2.BORDER_REPLICATE)
    small = box(lg, max(1, int(size * 0.002)))
    r = max(1, int(size * 0.02))
    m = box(lg, r)
    a = np.maximum(0, box(lg * lg, r) - m * m)
    a = a / (a + 0.12)
    large = box(a, r) * lg + box((1 - a) * m, r)
    plate = lambda x: 1 - np.exp(-np.maximum(x, 0) * 1.2)

    def curve(l, lg, large):
        if method == "fusion":
            region = 2 ** large
            total, wsum = 0, 0
            for ev in (-spacing, 0, spacing):
                t = (plate(region * 2 ** ev) ** (1 / 2.2) - 0.5) / 0.2
                w = np.exp(-t * t / 2) + 0.0001
                total, wsum = total + plate(l * 2 ** ev) * w, wsum + w
            blend = range_ * np.clip(region / 0.06, 0, 1)
            return plate(l) * (1 - blend) + total / wsum * blend
        anchor = np.log2(0.18)
        amount = range_ * np.where(large < anchor, np.clip(l / 0.06, 0, 1), 1)
        base = anchor + (large - anchor) * (1 - amount * 0.85)
        local = 2 ** (base + lg - large)
        shaped = 0.18 * np.maximum(0, local / 0.18) ** 1.25
        return shaped * (1 + range_ * 0.18) / (1 + range_ * shaped)

    mapped = curve(l, lg, large)
    if shadows or highlights:
        region = np.clip(np.maximum(0, curve(2 ** large, large, large)) ** (1 / 2.2), 0, 1)
        shift = (0.22 * highlights * region ** 3 * (1 - region)
                 + 0.22 * (0.7 if shadows < 0 else 1) * shadows * region * (1 - region) ** 3) / 0.10546875
        mapped = np.maximum(0, np.maximum(0, mapped) ** (1 / 2.2) + shift) ** 2.2
    protect = (0.5 + 0.5 * np.minimum(1, l / 0.08)) * (0.5 + 0.5 / (1 + np.maximum(0, l - 0.7) * 4))
    fine = np.clip(lg - small, -0.5, 0.5)
    coarse = np.clip(small - large, -0.5, 0.5)
    texture = 2 ** (protect * (detail * fine * 2 + micro * coarse * 3 / (1 + np.abs(lg - small) * 4)))
    out = np.maximum(0, linear * np.where(l > 1e-6, mapped / np.maximum(l, 1e-12) * texture, 1)[..., None])
    if temperature or vibrance or saturation:
        before = out @ weights
        if temperature:
            out = out * np.array([1 + 0.3 * temperature, 1, 1 - 0.3 * temperature])
            after = out @ weights
            out = out * np.where(after > 1e-6, before / np.maximum(after, 1e-12), 1)[..., None]
        high, low = out.max(-1), out.min(-1)
        chroma = np.where(high > 1e-6, (high - low) / np.maximum(high, 1e-12), 0)
        amount = (1 + vibrance * (1 - chroma)) * (1 + saturation)
        out = np.maximum(0, before[..., None] + (out - before[..., None]) * amount[..., None])
    return out


# A few of HDRPreset.builtIn, one per group, for the Presets panel drawing.
HDR_PRESET_PICTURES = [
    ("natural", {}),
    ("balanced", dict(range_=0.8, micro=0.45, detail=0.3, highlights=-0.3, shadows=0.2, vibrance=0.1)),
    ("dramatic", dict(range_=1, micro=1, detail=0.7, highlights=-0.4, shadows=0.3, saturation=-0.25)),
    ("crisp-lines", dict(range_=0.85, micro=0.7, detail=0.6, highlights=-0.4, shadows=0.2)),
    ("landscape", dict(range_=0.8, micro=0.7, detail=0.45, highlights=-0.5, shadows=0.25, vibrance=0.35)),
    ("painterly", dict(method="fusion", spacing=3, range_=1, micro=1, detail=1, vibrance=0.3, saturation=0.3)),
]


def make_hdr_preset_images(linear):
    h, w = linear.shape[:2]
    thumb = cv2.resize(linear.astype(np.float32), (200, round(200 * h / w)), interpolation=cv2.INTER_AREA)
    encode = lambda x: np.where(x <= 0.0031308, x * 12.92, 1.055 * np.maximum(x, 0) ** (1 / 2.4) - 0.055)
    for name, settings in HDR_PRESET_PICTURES:
        save(encode(hdr_render(thumb, **settings)), f"hdr-preset-{name}.jpg", quality=80)


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
    encode = lambda x: np.where(x <= 0.0031308, x * 12.92, 1.055 * np.maximum(x, 0) ** (1 / 2.4) - 0.055)
    hdr_encoded = encode(hdr_linear)
    pair("hdr", base.copy(), hdr_encoded)

    # Fusion (HDRToneMapper.fusion): three soft-shouldered exposures at -2, 0 and +2 EV, blended
    # by how well exposed the region (the guided base) is in each, Range 0.65, less in deep blacks.
    plate = lambda x: 1 - np.exp(-np.maximum(x, 0) * 1.2)
    region = 2 ** guided
    total, weights = 0, 0
    for ev in (-2, 0, 2):
        t = (plate(region * 2 ** ev) ** (1 / 2.2) - 0.5) / 0.2
        weight = np.exp(-t * t / 2) + 0.0001
        total = total + plate(hdr_luma * 2 ** ev) * weight
        weights = weights + weight
    blend = 0.65 * np.clip(region / 0.06, 0, 1)
    fused = plate(hdr_luma) * (1 - blend) + total / weights * blend
    fusion_gain = np.where(hdr_luma > 1e-6, fused / np.maximum(hdr_luma, 1e-6), 1) * texture_gain
    pair("hdr-fusion", hdr_encoded, encode(linear_hdr * fusion_gain[..., None]))
    # The Exposures strip: the photo at -2, 0 and +2 EV as Fusion sees them.
    h, w = base.shape[:2]
    thumb = cv2.resize(linear_hdr.astype(np.float32), (240, round(240 * h / w)), interpolation=cv2.INTER_AREA)
    for i, ev in enumerate((-2, 0, 2)):
        save(encode(plate(thumb * 2 ** ev)), f"hdr-plate-{i}.jpg", quality=80)
    make_hdr_preset_images(linear_hdr)



def make_built_in_look_images(folder):
    """Use the actual Whole Photo match from BuiltInLookReferenceTests."""
    for kind in ("reference", "before", "after"):
        with Image.open(os.path.join(folder, f"thronesLandscape-{kind}.png")) as source:
            image = np.asarray(source.convert("RGB")).astype(np.float32) / 255
            save(image, f"match-built-in-{kind}.jpg")


def make_skin_look_images(folder):
    """Use the actual local face fit from BuiltInLookReferenceTests."""
    for kind in ("reference", "before", "after"):
        with Image.open(os.path.join(folder, f"skin-{kind}.png")) as source:
            image = np.asarray(source.convert("RGB")).astype(np.float32) / 255
            save(image, f"match-skin-{kind}.jpg")


def make_calibration_images(base):
    pair("calibration", base, calibration(base, red_hue=0.25, blue_sat=0.6))




def dehaze(image, amount=0.6):
    """Dehaze's idea: estimate the haze from each area's darkest channel and take it back out."""
    dark = cv2.erode(image.min(axis=2), np.ones((15, 15), np.uint8))
    dark = blur(dark, 12)
    air = np.percentile(image.reshape(-1, 3), 99.5, axis=0)
    t = np.clip(1 - amount * dark / air.max(), 0.3, 1)[..., None]
    out = (image - air) / t + air
    return np.clip(saturation(contrast(np.clip(out, 0, 1), 0.1), 0.15), 0, 1)


def lake_depth(shape):
    """A depth map of the lake photo (0 near, 1 far), worked out from where things stand: the
    beach and the water are one flat plane, so distance follows the height above the far shore;
    the man stands where his feet touch the beach; each kayak is as far as where it rests."""
    H, W = shape[:2]
    y = (np.arange(H, dtype=np.float32) + 0.5)[:, None] / H * np.ones((1, W), np.float32)
    x = np.ones((H, 1), np.float32) * (np.arange(W, dtype=np.float32) + 0.5)[None, :] / W
    shore, feet = 0.345, 0.565
    plane = 0.75 * np.sqrt((feet - shore) / np.maximum(y - shore, 1e-3))
    depth = np.where(y > shore, np.minimum(plane, 1.0), 1.0)
    # The man, at the distance of his feet.
    # The man, at the distance of his feet: inside his outline, what is darker or more orange
    # than the pale sky and water behind him.
    image = load("lake.jpg", width=W)
    hsv_image = hsv(image)
    box = np.zeros((H, W), np.uint8)
    cv2.rectangle(box, (int(0.262 * W), int(0.195 * H)), (int(0.358 * W), int(feet * H)), 1, -1)
    figure = (luma(image) < 0.33) | ((hsv_image[..., 1] > 0.4) & (hsv_image[..., 0] < 40))
    man = (box > 0) & figure & (y < feet + 0.005)
    man = cv2.morphologyEx(man.astype(np.uint8), cv2.MORPH_CLOSE, np.ones((5, 5), np.uint8))
    man = cv2.morphologyEx(man, cv2.MORPH_OPEN, np.ones((3, 3), np.uint8))
    depth = np.where(man > 0, 0.75, depth)
    # Kayaks (saturated red, orange and yellow): as far as the lowest point of each one's column.
    boats = ((hsv_image[..., 1] > 0.45) & (hsv_image[..., 2] > 0.35) & (y > 0.45)).astype(np.uint8)
    boats = cv2.morphologyEx(boats, cv2.MORPH_OPEN, np.ones((5, 5), np.uint8))
    rows = np.where(boats > 0, y, 0).max(axis=0)
    contact = 0.75 * np.sqrt((feet - shore) / np.maximum(rows - shore, 1e-3))
    depth = np.where(boats > 0, np.minimum(contact, 1.0)[None, :] * np.ones((H, 1), np.float32), depth)
    return blur(depth.astype(np.float32), 5)


def make_lens_blur_images(lake):
    """The lake photo focused on the man: the whole photo, Visualize Depth, a Focus Area that
    keeps the yellow kayak in front sharp too, and a 100% crop from the full-size photo."""
    focus = dict(amount=0.5, near=0.70, far=0.80, boost=0.5)
    depth = lake_depth(lake.shape)
    placed = guided_depth(depth, lake)
    after = lens_blur(lake, placed, **focus)
    pair("lens-blur", lake, after)
    save(depth_view(depth, 0.70, 0.80, (lake.shape[1], lake.shape[0])), "lens-blur-depth.jpg")
    area = radial_area(lake.shape, (0.71, 0.66), 0.2, 0.14)
    areas = np.dstack([area, np.zeros_like(area)])
    save(lens_blur(lake, placed, areas=areas, **focus), "lens-blur-refine-after.jpg")
    full = load("lake.jpg", width=None)
    sharp = lens_blur(full, guided_depth(lake_depth(full.shape), full), **dict(focus, amount=1.0))
    H, W = full.shape[:2]
    x, y = int(0.20 * W), int(0.30 * H)
    box = (slice(y, y + 400), slice(x, x + 600))
    save(full[box], "lens-blur-zoom-before.jpg")
    save(sharp[box], "lens-blur-zoom-after.jpg")


def subject_mask(image):
    """Select Subject on the finch: GrabCut from a box around it (Vision's subject mask
    stand-in), softened at the edge like Feather 20."""
    H, W = image.shape[:2]
    img8 = (np.clip(image, 0, 1) * 255).astype(np.uint8)[..., ::-1].copy()
    mask = np.zeros((H, W), np.uint8)
    rect = (int(W * 0.225), int(H * 0.265), int(W * 0.15), int(H * 0.545))
    bgd, fgd = np.zeros((1, 65), np.float64), np.zeros((1, 65), np.float64)
    cv2.grabCut(img8, mask, rect, bgd, fgd, 6, cv2.GC_INIT_WITH_RECT)
    fg = np.isin(mask, (cv2.GC_FGD, cv2.GC_PR_FGD)).astype(np.uint8)
    count, labels, stats, _ = cv2.connectedComponentsWithStats(fg)
    keep = 1 + np.argmax(stats[1:, cv2.CC_STAT_AREA])
    fg = (labels == keep).astype(np.uint8)
    fg = cv2.morphologyEx(fg, cv2.MORPH_CLOSE, np.ones((9, 9), np.uint8))
    return blur(fg.astype(np.float32), 2.0)


def thumbnails():
    """Small photos for the Library, Grid, Filmstrip, Import and Cull diagrams."""
    os.makedirs(os.path.join(OUT, "thumbs"), exist_ok=True)
    for old in os.listdir(os.path.join(OUT, "thumbs")):
        os.remove(os.path.join(OUT, "thumbs", old))
    lake = load("lake.jpg", width=800)
    kathakali = load("kathakali.jpg", width=1200)
    shots = {"lake": lake, "lake-warm": temperature(lake, 0.9), "lake-bw": bw(lake),
             "kathakali-face": crop(kathakali, 0.44, 0.16, 0.36, 0.5)}
    for name in ("kayaks", "clown", "blossoms", "golden-gate", "locks", "market", "tomatoes", "lanterns",
                 "bikes", "rose", "kathakali", "palace", "flower-1", "flower-2", "flower-3", "flower-4",
                 "temple-1", "temple-2"):
        shots[name] = kathakali if name == "kathakali" else load(f"{name}.jpg", width=None)
    for name, image in shots.items():
        h, w = image.shape[:2]
        scale = 360 / max(h, w)
        small = cv2.resize(image, (round(w * scale), round(h * scale)), interpolation=cv2.INTER_AREA)
        save(small, f"thumbs/{name}.jpg", quality=78)


def make_spot_images(golf):
    """Remove tool: sensor dust in the golf course's sky (before) and the clean photo (after),
    Visualize Spots, which shows the specks as dark rings on white, and Content-Aware removing
    the golf ball on the right."""
    H, W = golf.shape[:2]
    dusty = golf.copy()
    y, x = np.mgrid[0:H, 0:W].astype(np.float32)
    for cx, cy, r, depth in [(0.12, 0.16, 10, 0.30), (0.83, 0.22, 7, 0.36), (0.36, 0.06, 12, 0.26),
                             (0.62, 0.36, 8, 0.34), (0.47, 0.13, 6, 0.4), (0.93, 0.07, 11, 0.28)]:
        d = np.sqrt((x - cx * W) ** 2 + (y - cy * H) ** 2)
        speck = (1 - smoothstep(r * 0.35, r, d)) * depth
        dusty = dusty * (1 - speck[..., None])
    pair("spots", dusty, golf)
    from patchmatch_fill import complete
    cx, cy, radius = 0.716 * W, 0.784 * H, 0.016 * W
    x0, y0, x1, y1 = int(cx - 0.12 * W), int(cy - 0.12 * H), int(cx + 0.12 * W), min(H, int(cy + 0.12 * H))
    region = golf[y0:y1, x0:x1].astype(np.float64)
    yy, xx = np.mgrid[y0:y1, x0:x1].astype(np.float64)
    hole = np.hypot(xx - cx, (yy - cy) * 1.15) <= radius
    filled = golf.copy()
    filled[y0:y1, x0:x1] = complete(region, hole).astype(np.float32)
    pair("content-aware", golf, filled)
    L = blur(np.clip(luma(dusty), 0, 1) ** (1 / 2.2), 1.0)
    edge = np.abs(cv2.Laplacian(L, cv2.CV_32F, ksize=3))
    save(np.repeat((1 - smoothstep(0.03, 0.07, edge))[..., None], 3, axis=2), "spots-visualize.jpg")


def load_data(name):
    return np.asarray(Image.open(os.path.join(DATA, name)).convert("RGB")).astype(np.float32) / 255


def lab_denoise(image, luminance=0, color=0):
    """Noise Reduction: smooth brightness (Luminance) and color (Color) separately."""
    lab = cv2.cvtColor(image.astype(np.float32), cv2.COLOR_RGB2LAB)
    if luminance:
        L8 = np.clip(lab[..., 0] * 2.55, 0, 255).astype(np.uint8)
        lab[..., 0] = cv2.fastNlMeansDenoising(L8, None, luminance, 7, 21).astype(np.float32) / 2.55
    if color:
        lab[..., 1] = blur(lab[..., 1], color)
        lab[..., 2] = blur(lab[..., 2], color)
    return np.clip(cv2.cvtColor(lab, cv2.COLOR_LAB2RGB), 0, 1)


def main():
    os.makedirs(OUT, exist_ok=True)
    if len(sys.argv) == 3 and sys.argv[1] in ("--presets-from", "--check-presets-from"):
        from preset_lookbook import build
        build(sys.argv[2], check=sys.argv[1] == "--check-presets-from")
        return 0
    if len(sys.argv) == 3 and sys.argv[1] == "--built-in-look-from":
        make_built_in_look_images(sys.argv[2])
        return 0
    if len(sys.argv) == 3 and sys.argv[1] == "--skin-look-from":
        make_skin_look_images(sys.argv[2])
        return 0
    lake = load("lake.jpg")
    lake_full = load("lake.jpg", width=None)
    base = flat(lake)
    if "--lens-blur-only" in sys.argv:
        make_lens_blur_images(lake)
        return 0

    # Overview pictures, shared by many pairs
    save(lake, "lake.jpg")
    save(base, "lake-flat.jpg")
    SHARED.update({"lake.jpg": lake, "lake-flat.jpg": base})
    thumbnails()

    # Basic: the lake at dawn, with tools that need other light on photos that show them best
    frames("exposure", base, [-1.5, -0.75, 0, 0.75, 1.5], exposure)
    frames("temp", base, [-0.8, -0.4, 0, 0.4, 0.8], temperature)
    pair("contrast", base, contrast(base, 0.45))
    sunset = flat(load("sunset.jpg"))
    pair("highlights", sunset, highlights(sunset, -0.9))
    palace = load("palace.jpg")
    palace_flat = flat(palace)
    pair("shadows", palace_flat, shadows(palace_flat, 0.9))
    pair("whites-blacks", base, blacks(whites(base, 0.5), -0.6))
    pair("tint", tint(base, 0.5), base)
    bird_full = load("bird.jpg", width=None)
    feathers = crop(flat(bird_full), 0.235, 0.32, 0.12, 0.12)
    feathers = cv2.resize(feathers, (720, round(720 * feathers.shape[0] / feathers.shape[1])), interpolation=cv2.INTER_CUBIC)
    pair("texture", feathers, texture(feathers, 0.9, 1.4))
    pair("clarity", base, clarity(base, 0.7))
    fog = load("fog.jpg")
    pair("dehaze", fog, dehaze(fog, 0.6))
    market = flat(load("market.jpg"))
    save(market, "presence-base.jpg")
    save(vibrance(market, 1.0), "vibrance.jpg")
    save(saturation(market, 0.6), "saturation.jpg")
    berets = load("berets.jpg", width=760)
    pair("treatment", berets, bw(berets))
    pair("profile", lake, saturation(contrast(lake, -0.35), -0.22))
    snow_view = load("snow.jpg")
    pair("white-balance", temperature(snow_view, 0.6), snow_view)
    pair("auto-tone", exposure(flat(lake), -1.0), lake)

    # Tone Curve: the Palace of Fine Arts at sunrise
    s_curve = [(0, 0), (0.25, 0.18), (0.5, 0.5), (0.75, 0.83), (1, 1)]
    pair("tone-curve", palace_flat, tone_curve(palace_flat, s_curve))
    matte = [(0, 0.12), (0.25, 0.27), (0.5, 0.52), (0.8, 0.82), (1, 0.95)]
    save(palace, "palace.jpg")
    save(tone_curve(palace, matte), "tone-curve-matte.jpg")

    # HSL / Color and B&W Mix: golden hills, a market stall
    hills = load("hills.jpg")
    save(hills, "hills.jpg")
    SHARED["hills.jpg"] = hills
    pair("hsl-hue", hills, hsl(hills, hue={"green": -1.0, "yellow": -0.6}))
    market_full = load("market.jpg")
    pair("hsl-sat", market_full, hsl(market_full, sat={"orange": -0.7, "red": -0.5}))
    pair("hsl-lum", hills, hsl(hills, lum={"green": -0.6, "yellow": -0.5}))
    save(bw(hills), "bw-default.jpg")
    save(bw(hills, {"green": 0.9, "yellow": 0.8, "orange": -0.6}), "bw-mix.jpg")

    # Color Grading
    graded = color_grade(base, shadows=(195, 0.55), highlights=(35, 0.55))
    pair("color-grading", base, graded)
    wheel_svg("wheel-shadows.svg", graded, "shadows", 195, 0.55, others=[(35, 0.55)])
    wheel_svg("wheel-highlights.svg", graded, "highlights", 35, 0.55, others=[(195, 0.55)])
    wheel_svg("wheel-midtones.svg", graded, "midtones", 0, 0.0, others=[(195, 0.55), (35, 0.55)])
    pair("grade-split", base, color_grade(base, shadows=(220, 0.6), highlights=(50, 0.5), blending=0.8))

    # Detail: the finch's head at 100%; real high-ISO noise from the doe at ISO 2800
    head = crop(bird_full, 0.255, 0.265, 0.1, 0.1)
    head = cv2.resize(head, (540, round(540 * head.shape[0] / head.shape[1])), interpolation=cv2.INTER_CUBIC)
    soft = blur(head, 1.2)
    pair("sharpening", soft, sharpen(soft, 2.4, 1.4))
    doe = load_data("deer-pmrid-before.jpg")[:600]
    doe_clean = load_data("deer-pmrid-after.jpg")[:600]
    pair("noise", doe, lab_denoise(doe, luminance=14, color=2))
    pair("color-noise", doe, lab_denoise(doe, color=4))
    pair("ai-denoise", doe, doe_clean)

    # Lens Corrections
    street = load("street.jpg")
    pair("distortion", barrel(street, 0.32), street)
    golf = load("golf.jpg")
    pair("lens-vignette", np.clip(golf * (1 - 0.6 * smoothstep(0.25, 1.0, radius_map(golf))[..., None]), 0, 1), golf)
    snow_full = load("snow.jpg", width=None)
    corner = crop(snow_full, 0.30, 0.0, 0.12, 0.12)
    ca = scale_channels(snow_full, 1.0008, 0.9992)
    pair("chromatic-aberration", enlarge(crop(ca, 0.30, 0.0, 0.12, 0.12), 3), enlarge(corner, 3))
    edge = crop(snow_full, 0.62, 0.0, 0.14, 0.14)
    L = luma(edge)
    edges = np.abs(cv2.Sobel(blur(L, 1), cv2.CV_32F, 1, 0, ksize=3)) + np.abs(cv2.Sobel(blur(L, 1), cv2.CV_32F, 0, 1, ksize=3))
    sky = cv2.dilate((L > 0.85).astype(np.uint8), np.ones((5, 5), np.uint8)).astype(np.float32)
    near = blur(((edges > 0.5) & (sky > 0)).astype(np.float32), 1.2) * (1 - smoothstep(0.55, 0.85, L))
    fringed = mix(edge, np.array([0.55, 0.25, 0.75], np.float32) * (0.6 + 0.4 * L[..., None]), np.clip(near * 0.9, 0, 0.5))
    pair("defringe", enlarge(fringed, 3), enlarge(edge, 3))

    # Transform: a San Francisco street for Upright, the bay's horizon for Straighten
    leaning = keystone(street, 0.12)
    H, W = street.shape[:2]
    inside = leaning[:, int(W * 0.12):W - int(W * 0.12)]
    pair("upright", cv2.resize(inside[int(H * 0.12):H - int(H * 0.12)], (W, H), interpolation=cv2.INTER_CUBIC), street)
    bay = load("bay.jpg")
    save(bay, "bay.jpg")
    SHARED["bay.jpg"] = bay
    pair("straighten", rotate(bay, 4), bay)

    # Effects: a daisy in the rain, the berets for grain
    flower = flat(load("flower.jpg"))
    pair("post-crop-vignette", flower, vignette(flower, -0.5))
    make_calibration_images(base)
    make_lens_blur_images(lake)
    berets_full = load("berets.jpg", width=None)
    grain_view = crop(berets_full, 0.62, 0.62, 0.2, 0.15)
    pair("grain", enlarge(grain_view, 2), enlarge(grain(grain_view, 0.45, 1.0), 2))

    # Masking: the lake (gradients, ranges), the Kathakali dancer (Select Subject)
    H, W = lake.shape[:2]
    ramp = 1 - smoothstep(0.02, 0.45, np.linspace(0, 1, H, dtype=np.float32))[:, None] * np.ones((1, W), np.float32)
    pair("mask-linear", base, mix(base, exposure(base, -1.0), ramp))
    save(red_overlay(base, ramp), "mask-linear-overlay.jpg")
    y, x = np.mgrid[0:H, 0:W].astype(np.float32)
    ellipse = np.sqrt(((x / W - 0.31) / 0.13) ** 2 + ((y / H - 0.40) / 0.30) ** 2)
    radial = 1 - smoothstep(0.25, 1.0, ellipse)
    pair("mask-radial", base, mix(exposure(base, -0.35), exposure(base, 0.45), radial))
    save(red_overlay(base, radial), "mask-radial-overlay.jpg")
    bench = load("bird.jpg")
    bench_base = flat(bench)
    subject = subject_mask(bench)
    background = 1 - subject
    pair("mask-subject", bench_base, mix(bench_base, saturation(exposure(bench_base, -0.4), -0.6), background))
    save(red_overlay(bench_base, subject), "mask-subject-overlay.jpg")
    save(red_overlay(bench_base, background), "mask-background-overlay.jpg")
    # The page reuses mask-subject-before.jpg as the before picture.
    save(mix(bench_base, temperature(exposure(bench_base, -0.7), -0.5), background), "mask-background-after.jpg")
    bright = smoothstep(0.55, 0.75, luma(base))
    save(red_overlay(base, bright), "mask-luminance-overlay.jpg")
    pair("mask-luminance", base, mix(base, highlights(base, -0.6), bright))
    kayak = color_range_mask(base, KAYAK)
    save(red_overlay(base, kayak), "mask-color-overlay.jpg")
    pair("mask-color", base, mix(base, saturation(exposure(base, 0.25), 0.5), kayak))
    make_mask_slider_images(base)

    # Remove tool: dust in the golf course's sky, a golf ball
    make_spot_images(golf)

    # Match Look: Reinhard transfer in Lab, as a stand-in for the slider fit. The bay takes on
    # the golden light of a sunset over the water.
    reference = load("sunset.jpg")
    bay_flat = flat(bay)
    lab_ref, lab_photo = cv2.cvtColor(reference, cv2.COLOR_RGB2LAB), cv2.cvtColor(bay_flat, cv2.COLOR_RGB2LAB)
    matched = (lab_photo - lab_photo.mean((0, 1))) / lab_photo.std((0, 1)) * lab_ref.std((0, 1)) * [0.9, 0.7, 0.7] + lab_ref.mean((0, 1))
    matched = cv2.cvtColor(matched.astype(np.float32), cv2.COLOR_LAB2RGB)
    save(bay_flat, "match-photo.jpg")
    save(mix(bay_flat, np.clip(matched, 0, 1), 0.8), "match-result.jpg")
    save(cv2.resize(reference, (540, round(540 * reference.shape[0] / reference.shape[1]))), "match-reference.jpg")

    # AI: Remove Object (the man by the cars), Upscale (the dancer's eye)
    cars = load("cars.jpg")
    H, W = cars.shape[:2]
    person = np.zeros((H, W), np.uint8)
    cv2.ellipse(person, (int(W * 0.138), int(H * 0.47)), (int(W * 0.03), int(H * 0.115)), 0, 0, 360, 255, -1)
    cv2.circle(person, (int(W * 0.136), int(H * 0.37)), int(W * 0.014), 255, -1)
    person = cv2.dilate(person, np.ones((9, 9), np.uint8))
    from patchmatch_fill import complete
    x0, y0, x1, y1 = int(0.02 * W), int(0.28 * H), int(0.30 * W), int(0.64 * H)
    hole = person[y0:y1, x0:x1] > 0
    removed = cars.copy()
    removed[y0:y1, x0:x1] = complete(cars[y0:y1, x0:x1].astype(np.float64), hole).astype(np.float32)
    soft_mask = blur(person.astype(np.float32) / 255, 3)
    pair("ai-remove", cars, mix(cars, removed, soft_mask))
    save(red_overlay(cars, soft_mask, 0.6), "ai-remove-strokes.jpg")
    dancer_full = load("kathakali.jpg", width=None)
    eye = crop(dancer_full, 0.56, 0.355, 0.09, 0.07)
    small_eye = cv2.resize(eye, (eye.shape[1] // 4, eye.shape[0] // 4), interpolation=cv2.INTER_AREA)
    pair("ai-upscale", cv2.resize(small_eye, (540, 540 * eye.shape[0] // eye.shape[1]), interpolation=cv2.INTER_LINEAR),
         sharpen(cv2.resize(eye, (540, 540 * eye.shape[0] // eye.shape[1]), interpolation=cv2.INTER_CUBIC), 0.6, 1.2))

    # HDR: the palace at sunrise, bright sky over a dark lagoon
    make_hdr_images(palace_flat)

    # Histogram data for the panel diagrams
    with open(os.path.join(OUT, "histogram.js"), "w") as f:
        f.write("window.HELP_HISTOGRAM = " + json.dumps({"lake": histogram_json(base)}) + ";\n")

    total = sum(os.path.getsize(os.path.join(dirpath, n)) for dirpath, _, names in os.walk(OUT) for n in names)
    print(f"Wrote {OUT} ({total / 1e6:.1f} MB)")


if __name__ == "__main__":
    sys.exit(main())

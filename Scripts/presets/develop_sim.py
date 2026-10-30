"""A numpy port of the parts of DevelopRenderer that the built-in presets use.

It follows `DevelopRenderer.applyAdjustments` step for step (Highlights/Shadows, the tone
curve, Dehaze, Clarity, Texture, Vibrance, Saturation, the HSL / B&W Mix / Color Grading
cube, Post-Crop Vignetting and Grain) so preset values can be judged on real photos without
a Mac. The kernels in LocalContrast, ToneCurve, Dehaze, ColorLUT, Oklab and FilmGrain are
ported line for line. Two steps are Core Image filters whose code Apple doesn't publish, so
they are close approximations: CIVibrance and CIVignetteEffect. Sharpening and noise
reduction are left out (no preset changes them).

Images are float32 arrays in linear Rec. 2020 (the app's working space), shape (H, W, 3).
"""

import math

import cv2
import numpy as np

# MARK: Color spaces

SRGB_TO_2020 = np.array([[0.6274, 0.3293, 0.0433],
                         [0.0691, 0.9195, 0.0114],
                         [0.0164, 0.0880, 0.8956]], np.float32)
REC2020_TO_SRGB = np.linalg.inv(SRGB_TO_2020).astype(np.float32)
LUMA_2020 = np.array([0.2627, 0.6780, 0.0593], np.float32)


def srgb_encode(c):
    c = np.asarray(c)
    a = np.abs(c)
    out = np.where(a <= 0.0031308, a * 12.92, 1.055 * np.power(a, 1 / 2.4) - 0.055)
    return np.sign(c) * out


def srgb_decode(c):
    c = np.asarray(c)
    a = np.abs(c)
    out = np.where(a <= 0.04045, a / 12.92, np.power((a + 0.055) / 1.055, 2.4))
    return np.sign(c) * out


def from_srgb_encoded(image):
    """sRGB-encoded 0...1 to linear Rec. 2020."""
    return (srgb_decode(image) @ SRGB_TO_2020.T).astype(np.float32)


def to_srgb_encoded(image):
    """Linear Rec. 2020 to sRGB-encoded (unclipped)."""
    return srgb_encode(image @ REC2020_TO_SRGB.T).astype(np.float32)


def box(image, radius):
    k = 2 * int(round(radius)) + 1
    return cv2.blur(image, (k, k), borderType=cv2.BORDER_REPLICATE)


def gamma_luma(image):
    return np.power(np.maximum(image @ LUMA_2020, 0), 1 / 2.2)


# MARK: LocalContrast

CLARITY = dict(radius=70, edge=0.01, strength=0.9, midtones=True)
TEXTURE = dict(radius=15, edge=0.003, strength=1.0, midtones=False)


def guided_coefficients(g, radius, edge):
    moments = np.stack([g, g * g], axis=-1).astype(np.float32)
    m = box(moments, radius)
    variance = np.maximum(m[..., 1] - m[..., 0] ** 2, 0)
    a = variance / (variance + edge)
    coeffs = np.stack([a, m[..., 0] - a * m[..., 0]], axis=-1).astype(np.float32)
    return box(coeffs, radius)


def local_contrast(image, amount, kind, scale):
    if amount == 0:
        return image
    radius = max(1, kind["radius"] * scale)
    g0 = gamma_luma(image)
    ab = guided_coefficients(g0, radius, kind["edge"])
    luma = np.maximum(image @ LUMA_2020, 0)
    g = np.power(luma, 1 / 2.2)
    detail = g - (ab[..., 0] * g + ab[..., 1])
    if kind["midtones"]:
        w = np.sqrt(np.clip(4 * g * (1 - g), 0, 1))
    else:
        w = np.clip(4 * g, 0, 1)
    g2 = np.maximum(g + kind["strength"] * amount * detail * w, 0)
    new = np.power(g2, 2.2)
    ratio = np.where(luma > 1e-4, new / np.maximum(luma, 1e-4), 1)
    out = np.where((luma > 1e-4)[..., None], image * ratio[..., None], image + (new - luma)[..., None])
    return out.astype(np.float32)


def tone_regions(image, highlights, shadows, scale):
    if highlights == 0 and shadows == 0:
        return image
    radius = max(1, 100 * scale)
    shadow_gain = 0.22 * (0.7 if shadows < 0 else 1) * shadows
    g = gamma_luma(image)
    ab = guided_coefficients(g, radius, 0.01)
    base = np.clip(ab[..., 0] * g + ab[..., 1], 0, 1)
    ws = base * (1 - base) ** 3 / 0.10546875
    wh = base ** 3 * (1 - base) / 0.10546875
    shift = shadow_gain * ws + 0.22 * highlights * wh
    encoded = np.power(np.maximum(image, 0), 1 / 2.2)
    return np.power(np.maximum(encoded + shift[..., None], 0), 2.2).astype(np.float32)


# MARK: Tone curve

def evaluate_curve(points, x):
    """Monotone cubic (Fritsch-Carlson), flat outside the points; `x` is an array."""
    px = np.array([p[0] for p in points], float)
    py = np.array([p[1] for p in points], float)
    n = len(px)
    deltas = np.diff(py) / np.diff(px)
    slopes = np.zeros(n)
    slopes[0], slopes[-1] = deltas[0], deltas[-1]
    for i in range(1, n - 1):
        slopes[i] = 0 if deltas[i - 1] * deltas[i] <= 0 else (deltas[i - 1] + deltas[i]) / 2
    for i in range(n - 1):
        if deltas[i] == 0:
            slopes[i] = slopes[i + 1] = 0
            continue
        a, b = slopes[i] / deltas[i], slopes[i + 1] / deltas[i]
        s = a * a + b * b
        if s > 9:
            t = 3 / math.sqrt(s)
            slopes[i], slopes[i + 1] = t * a * deltas[i], t * b * deltas[i]
    x = np.asarray(x, float)
    k = np.clip(np.searchsorted(px, x, side="left") - 1, 0, n - 2)
    x0, x1 = px[k], px[k + 1]
    span = x1 - x0
    t = (x - x0) / span
    t2, t3 = t * t, t * t * t
    y = ((2 * t3 - 3 * t2 + 1) * py[k] + (t3 - 2 * t2 + t) * span * slopes[k]
         + (-2 * t3 + 3 * t2) * py[k + 1] + (t3 - t2) * span * slopes[k + 1])
    y = np.where(x <= px[0], py[0], np.where(x >= px[-1], py[-1], y))
    return np.clip(y, 0, 1)


def tone_curve_points(s):
    c, w, b = s.get("contrast", 0) / 100, s.get("whites", 0) / 100, s.get("blacks", 0) / 100
    if c == 0 and w == 0 and b == 0:
        return None
    return [(max(0, -b) * 0.1, max(0, b) * 0.1), (0.25, 0.25 - c * 0.08), (0.5, 0.5),
            (0.75, min(1, 0.75 + c * 0.08)), (1 - max(0, w) * 0.1, 1 - max(0, -w) * 0.1)]


REGIONS = [("curveShadows", 0.125), ("curveDarks", 0.375), ("curveLights", 0.625), ("curveHighlights", 0.875)]


def master_lut(s, samples=1024):
    pts = tone_curve_points(s)
    master = s.get("curve_rgb")
    if pts is None and not any(s.get(r, 0) for r, _ in REGIONS) and not master:
        return None
    x = np.linspace(0, 1, samples)
    y = evaluate_curve(pts, x) if pts else x.copy()
    for name, center in REGIONS:
        amount = s.get(name, 0) / 100
        if amount:
            w = np.maximum(0, 1 - np.abs(x - center) / 0.25)
            y = y + amount * 0.12 * w * w * (3 - 2 * w)
    y = np.maximum.accumulate(np.clip(y, 0, 1))
    if master:
        y = evaluate_curve(master, y)
    return y


def lut_lookup(lut, x):
    n = len(lut)
    inside = np.interp(np.clip(x, 0, 1), np.linspace(0, 1, n), lut)
    return np.where(x <= 0, lut[0] + x, np.where(x >= 1, lut[-1] + (x - 1), inside))


def apply_master_curve(image, lut):
    c = to_srgb_encoded(image)
    high, low = c.max(axis=-1), c.min(axis=-1)
    nh, nl = lut_lookup(lut, high), lut_lookup(lut, low)
    span = high - low
    scale = np.where(span < 1e-6, 0, (nh - nl) / np.maximum(span, 1e-6))
    out = nl[..., None] + (c - low[..., None]) * scale[..., None]
    out = np.where((span < 1e-6)[..., None], nh[..., None], out)
    return from_srgb_encoded(out)


def apply_channel_curves(image, s):
    curves = [s.get("curve_red"), s.get("curve_green"), s.get("curve_blue")]
    if not any(curves):
        return image
    c = np.clip(to_srgb_encoded(image), 0, 1)
    for i, pts in enumerate(curves):
        if pts:
            c[..., i] = evaluate_curve(pts, c[..., i])
    return from_srgb_encoded(c)


# MARK: Dehaze

def dehaze(image, amount):
    if amount == 0:
        return image
    H, W = image.shape[:2]
    s = min(1, 512 / max(H, W))
    small = cv2.resize(image, (max(2, round(W * s)), max(2, round(H * s))), interpolation=cv2.INTER_AREA)
    kernel = np.ones((15, 15), np.uint8)

    def minimum(x):
        return cv2.erode(x, kernel, borderType=cv2.BORDER_REPLICATE)

    darkest = np.maximum(small.min(axis=-1), 0).astype(np.float32)
    dark = minimum(darkest)
    peak = dark.max()
    w = np.clip(dark / max(peak, 1e-4), 0, 1) ** 8
    color = (small * w[..., None]).reshape(-1, 3).mean(0) / max(w.mean(), 1e-6)
    lum = color @ LUMA_2020
    air = np.maximum(color + (lum - color) * 0.6, 0.05).astype(np.float32)
    relative = np.clip((small / air).min(axis=-1), 0, 1).astype(np.float32)
    haze = minimum(relative)
    guide = small @ LUMA_2020
    t = 1 - 0.95 * haze
    packed = box(np.stack([guide, t, guide * guide], -1).astype(np.float32), 16)
    product = box((guide * t).astype(np.float32), 16)
    a = (product - packed[..., 0] * packed[..., 1]) / (packed[..., 2] - packed[..., 0] ** 2 + 1e-3)
    b = packed[..., 1] - a * packed[..., 0]
    coeffs = box(np.stack([a, b], -1).astype(np.float32), 16)
    coeffs = cv2.resize(coeffs, (W, H), interpolation=cv2.INTER_LINEAR)
    tt = np.clip(coeffs[..., 0] * (image @ LUMA_2020) + coeffs[..., 1], 0, 1)
    hz = 1 - tt
    if amount > 0:
        te = np.maximum(1 - amount * hz, 0.15)[..., None]
        clear = np.maximum(air + (image - air) / te, 0)
        return np.where(image >= air, image, clear).astype(np.float32)
    k = (-amount * (0.25 + 0.4 * hz))[..., None]
    return (image + (air - image) * k).astype(np.float32)


# MARK: Vibrance and Saturation (Core Image filters, approximated)

def vibrance(image, amount):
    """CIVibrance: boosts muted colors more than saturated ones and holds back skin. Apple
    doesn't publish the kernel; this is the usual form (saturation scaled by 1 - sat)."""
    if amount == 0:
        return image
    luma = image @ np.array([0.2126, 0.7152, 0.0722], np.float32)
    mx, mn = image.max(-1), image.min(-1)
    sat = np.clip((mx - mn) / np.maximum(mx, 1e-4), 0, 1)
    k = amount * (1 - sat) * (1.0 if amount > 0 else 1.0)
    return (luma[..., None] + (image - luma[..., None]) * (1 + k)[..., None]).astype(np.float32)


def saturation(image, amount):
    if amount == 0:
        return image
    luma = image @ np.array([0.2125, 0.7154, 0.0721], np.float32)
    return (luma[..., None] + (image - luma[..., None]) * (1 + amount)).astype(np.float32)


# MARK: Color cube (HSL, B&W Mix, Color Grading), on arrays of sRGB-encoded colors

BAND_HUES = np.array([0, 30, 60, 120, 180, 240, 270, 300], float)
BANDS = ["Red", "Orange", "Yellow", "Green", "Aqua", "Blue", "Purple", "Magenta"]


def rgb_to_hsl(c):
    r, g, b = c[:, 0], c[:, 1], c[:, 2]
    mx, mn = c.max(1), c.min(1)
    l = (mx + mn) / 2
    d = mx - mn
    s = np.where(d > 1e-6, d / np.maximum(1 - np.abs(2 * l - 1), 1e-9), 0)
    dd = np.maximum(d, 1e-9)
    h = np.where(mx == r, np.fmod((g - b) / dd, 6), np.where(mx == g, (b - r) / dd + 2, (r - g) / dd + 4)) * 60
    h = np.where(h < 0, h + 360, h)
    h = np.where(d > 1e-6, h, 0)
    return h, np.minimum(1, s), l


def hsl_to_rgb(h, s, l):
    c = (1 - np.abs(2 * l - 1)) * s
    hp = np.fmod(np.fmod(h, 360) + 360, 360) / 60
    x = c * (1 - np.abs(np.fmod(hp, 2) - 1))
    m = l - c / 2
    z = np.zeros_like(c)
    seg = np.floor(hp).astype(int)
    r = np.select([seg == 0, seg == 1, seg == 2, seg == 3, seg == 4], [c, x, z, z, x], c)
    g = np.select([seg == 0, seg == 1, seg == 2, seg == 3, seg == 4], [x, c, c, x, z], z)
    b = np.select([seg == 0, seg == 1, seg == 2, seg == 3, seg == 4], [z, z, x, c, c], x)
    return np.stack([r + m, g + m, b + m], 1)


def band_weights(h):
    w = np.zeros((len(h), 8))
    ends = np.append(BAND_HUES[1:], 360)
    for i in range(8):
        inside = (h >= BAND_HUES[i]) & (h < ends[i])
        t = (h - BAND_HUES[i]) / (ends[i] - BAND_HUES[i])
        w[:, i] += np.where(inside, 1 - t, 0)
        w[:, (i + 1) % 8] += np.where(inside, t, 0)
    return w


def hsl_adjust(c, s):
    hue = np.array([s.get(f"hue{b}", 0) for b in BANDS]) / 100
    sat = np.array([s.get(f"sat{b}", 0) for b in BANDS]) / 100
    lum = np.array([s.get(f"lum{b}", 0) for b in BANDS]) / 100
    if not (hue.any() or sat.any() or lum.any()):
        return c
    h, sa, l = rgb_to_hsl(c)
    w = band_weights(h)
    hs, ss, ls = w @ hue, w @ sat, w @ lum
    nh = h + hs * 30
    ns = np.clip(sa * (1 + ss), 0, 1)
    nl = np.clip(l + ls * 0.25 * sa * np.where(ls > 0, 1 - l, l) * 2, 0, 1)
    out = hsl_to_rgb(nh, ns, nl)
    return np.where((sa > 0.001)[:, None], out, c)


def rec709_luma(c):
    return c @ np.array([0.2126, 0.7152, 0.0722])


def bw_mix(c, s):
    mix = np.array([s.get(f"gray{b}", 0) for b in BANDS]) / 100
    y = rec709_luma(c)
    h, sa, _ = rgb_to_hsl(c)
    shift = np.where(sa > 0.001, band_weights(h) @ mix, 0)
    gray = np.clip(y + shift * sa * 0.8 * np.where(shift > 0, 1 - y, y), 0, 1)
    return np.stack([gray] * 3, 1)


def oklab_from_encoded(c):
    lin = srgb_decode(np.clip(c, 0, None))
    M1 = np.array([[0.4122214708, 0.5363325363, 0.0514459929], [0.2119034982, 0.6806995451, 0.1073969566],
                   [0.0883024619, 0.2817188376, 0.6299787005]])
    M2 = np.array([[0.2104542553, 0.7936177850, -0.0040720468], [1.9779984951, -2.4285922050, 0.4505937099],
                   [0.0259040371, 0.7827717662, -0.8086757660]])
    return np.cbrt(lin @ M1.T) @ M2.T


def oklab_to_linear(lab):
    L, a, b = lab[:, 0], lab[:, 1], lab[:, 2]
    l = (L + 0.3963377774 * a + 0.2158037573 * b) ** 3
    m = (L - 0.1055613458 * a - 0.0638541728 * b) ** 3
    s = (L - 0.0894841775 * a - 1.2914855480 * b) ** 3
    return np.stack([4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
                     -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
                     -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s], 1)


def in_gamut(lab):
    c = oklab_to_linear(lab)
    return np.all((c >= -1e-6) & (c <= 1 + 1e-6), axis=1)


def largest_fraction(fits):
    """Vectorized `ColorGrade.largestFraction`: fits(t array) -> bool array."""
    n = fits.n
    one = fits(np.ones(n))
    low, high = np.zeros(n), np.ones(n)
    for _ in range(14):
        mid = (low + high) / 2
        ok = fits(mid)
        low = np.where(ok, mid, low)
        high = np.where(ok, high, mid)
    return np.where(one, 1, low)


def _anchor_directions():
    anchors = []
    for k in range(6):
        lab = oklab_from_encoded(hsl_to_rgb(np.array([k * 60.0]), np.array([1.0]), np.array([0.5])))[0]
        anchors.append(math.atan2(lab[2], lab[1]))
    for k in range(1, 6):
        while anchors[k] < anchors[k - 1]:
            anchors[k] += 2 * math.pi
    anchors.append(anchors[0] + 2 * math.pi)
    dirs = []
    for hue in range(360):
        k, t = hue // 60, (hue % 60) / 60
        angle = anchors[k] + (anchors[k + 1] - anchors[k]) * t
        dirs.append((math.cos(angle), math.sin(angle)))
    return np.array(dirs)


DIRECTIONS = _anchor_directions()


def grade_direction(hue):
    h = ((hue % 360) + 360) % 360
    i = min(359, int(h))
    t = h - i
    mixed = DIRECTIONS[i] * (1 - t) + DIRECTIONS[(i + 1) % 360] * t
    return mixed / max(1e-9, np.linalg.norm(mixed))


GRADE_REGIONS = ["Shadows", "Midtones", "Highlights", "Global"]


def grade_weights(y, blending, balance):
    pivot = 0.5 - balance * 0.3
    e = 2.5 - 2 * blending
    sh = np.maximum(0, 1 - y / pivot) ** e
    hi = np.maximum(0, (y - pivot) / (1 - pivot)) ** e
    return np.stack([sh, np.maximum(0, 1 - sh - hi), hi, np.ones_like(y)], 1)


def color_grade(c, s):
    tints = []
    active = False
    for r in GRADE_REGIONS:
        sat = s.get(f"grade{r}Sat", 0)
        lum = s.get(f"grade{r}Lum", 0)
        active = active or sat != 0 or lum != 0
        tints.append((grade_direction(s.get(f"grade{r}Hue", 0)) * (sat / 100 * 0.10), lum / 100))
    if not active:
        return c
    w = grade_weights(rec709_luma(c), s.get("gradeBlending", 50) / 100, s.get("gradeBalance", 0) / 100)
    shift = sum(w[:, [i]] * tints[i][0][None, :] for i in range(4))
    lift = sum(w[:, i] * tints[i][1] for i in range(4))
    lab = oklab_from_encoded(c)
    L = lab[:, 0]
    lab[:, 0] = np.clip(L + lift * 0.3 * np.where(lift > 0, 1 - L, L), 0, 1)
    base = lab.copy()

    class Fit:
        def __init__(self, f):
            self.f, self.n = f, len(c)

        def __call__(self, t):
            return self.f(t)

    out_of = ~in_gamut(lab)
    if out_of.any():
        scale = largest_fraction(Fit(lambda t: in_gamut(np.stack([base[:, 0], base[:, 1] * t, base[:, 2] * t], 1))))
        lab[:, 1] = np.where(out_of, lab[:, 1] * scale, lab[:, 1])
        lab[:, 2] = np.where(out_of, lab[:, 2] * scale, lab[:, 2])
    start = lab.copy()
    reach = largest_fraction(Fit(lambda t: in_gamut(np.stack([start[:, 0], start[:, 1] + shift[:, 0] * t,
                                                              start[:, 2] + shift[:, 1] * t], 1))))
    lab[:, 1] += shift[:, 0] * reach
    lab[:, 2] += shift[:, 1] * reach
    return np.minimum(1, srgb_encode(np.maximum(oklab_to_linear(lab), 0)))


def build_cube(s, n=32):
    g = np.linspace(0, 1, n)
    b, gg, r = np.meshgrid(g, g, g, indexing="ij")
    c = np.stack([r.ravel(), gg.ravel(), b.ravel()], 1)
    if s.get("monochrome"):
        c = bw_mix(c, s)
    else:
        c = hsl_adjust(c, s)
    c = color_grade(c, s)
    return np.clip(c, 0, 1).reshape(n, n, n, 3)  # [b][g][r]


def apply_cube(image, cube):
    n = cube.shape[0]
    c = np.clip(to_srgb_encoded(image), 0, 1) * (n - 1)
    i0 = np.floor(c).astype(int).clip(0, n - 2)
    f = c - i0
    out = 0
    for dr in (0, 1):
        for dg in (0, 1):
            for db in (0, 1):
                w = ((f[..., 0] if dr else 1 - f[..., 0]) * (f[..., 1] if dg else 1 - f[..., 1])
                     * (f[..., 2] if db else 1 - f[..., 2]))
                out = out + w[..., None] * cube[i0[..., 2] + db, i0[..., 1] + dg, i0[..., 0] + dr]
    return from_srgb_encoded(out)


def cube_needed(s):
    keys = [f"{p}{b}" for p in ("hue", "sat", "lum") for b in BANDS]
    keys += [f"grade{r}{k}" for r in GRADE_REGIONS for k in ("Sat", "Lum")]
    return s.get("monochrome") or any(s.get(k, 0) for k in keys)


# MARK: Effects

def vignette(image, amount, midpoint):
    """CIVignetteEffect approximated: a smooth falloff from `radius` outward, darkening by
    `intensity` (-amount) at the corners."""
    if amount == 0:
        return image
    H, W = image.shape[:2]
    diag = math.hypot(W, H) / 2
    radius = diag * (0.35 + midpoint / 100 * 0.6)
    falloff = 0.6
    y, x = np.mgrid[0:H, 0:W]
    d = np.hypot(x - W / 2, y - H / 2)
    inner, outer = radius * (1 - falloff), radius * (1 + falloff)
    t = np.clip((d - inner) / (outer - inner), 0, 1)
    t = t * t * (3 - 2 * t)
    intensity = -amount / 100
    factor = 1 - intensity * t
    return (image * factor[..., None]).astype(np.float32)


def _hash(px, py, seed):
    h = (px.astype(np.uint32) * np.uint32(0x8da6b343)) ^ (py.astype(np.uint32) * np.uint32(0xd8163841)) \
        ^ np.uint32((seed * 0xcb1ab31f) & 0xffffffff)
    h ^= h >> np.uint32(15)
    h *= np.uint32(0x2c1b3c6d)
    h ^= h >> np.uint32(12)
    h *= np.uint32(0x297a2d39)
    h ^= h >> np.uint32(15)
    return h.astype(np.float64) * (2.0 / 4294967295.0) - 1.0


def _value_noise(px, py, seed):
    ix, iy = np.floor(px), np.floor(py)
    fx, fy = px - ix, py - iy
    ux = fx ** 3 * (fx * (fx * 6 - 15) + 10)
    uy = fy ** 3 * (fy * (fy * 6 - 15) + 10)
    ix, iy = ix.astype(np.int64), iy.astype(np.int64)
    a, b = _hash(ix, iy, seed), _hash(ix + 1, iy, seed)
    d, e = _hash(ix, iy + 1, seed), _hash(ix + 1, iy + 1, seed)
    return (a + (b - a) * ux) * (1 - uy) + (d + (e - d) * ux) * uy


def _rot(px, py, angle):
    c, s = math.cos(angle), math.sin(angle)
    return c * px - s * py, s * px + c * py


def grain(image, amount, size, roughness, scale):
    if amount <= 0:
        return image
    if size > 0.25:
        sigma = (size - 0.25) / 0.75 * 1.2 * scale
        if sigma >= 0.3:
            image = cv2.GaussianBlur(image, (0, 0), sigma, borderType=cv2.BORDER_REPLICATE)
    particle = 2 ** (3 * size)
    on_screen = particle * max(scale, 1e-4)
    cell = max(on_screen, 1)

    def visible(e):
        return e / math.sqrt(e * e + 0.9)

    strength = 0.10 * amount * (visible(on_screen) / visible(particle)) / (0.79 if on_screen <= 1 else 1)
    H, W = image.shape[:2]
    y, x = np.mgrid[0:H, 0:W].astype(np.float64)
    qx, qy = (x + 0.5) / cell, (H - y - 0.5) / cell
    r = roughness
    ax, ay = _rot(qx, qy, 1.1)
    fine = _value_noise(qx, qy, 1) + 0.6 * _value_noise(ax * 1.7 + 17.3, ay * 1.7 + 5.1, 2)
    bx, by = _rot(qx, qy, 2.3)
    clump = _value_noise(bx / 1.8 + 3.7, by / 1.8 + 9.2, 3)
    g = fine * (1 - 0.3 * r) + clump * 0.8 * r
    cx, cy = _rot(qx, qy, 0.7)
    g *= 1 + 0.6 * r * _value_noise(cx / 3.5 + 1.3, cy / 3.5 + 7.7, 4)
    g /= 0.528 - 0.167 * r + 0.174 * r * r
    luma = np.maximum(image @ LUMA_2020, 0)
    lp = np.power(luma, 1 / 2.2)
    w = np.power(np.clip(4 * lp * (1 - lp), 0, 1), 0.6)
    grained = np.power(np.maximum(lp + strength * w * g, 0), 2.2)
    ratio = np.where(luma > 1e-4, grained / np.maximum(luma, 1e-4), 1)
    out = np.where((luma > 1e-4)[..., None], image * ratio[..., None], image + (grained - luma)[..., None])
    return out.astype(np.float32)


# MARK: Pipeline

def develop(image, s, scale):
    """`applyAdjustments` for a settings dict (keys as DevelopSettings parameter names, plus
    monochrome and curve_rgb / curve_red / curve_green / curve_blue point lists)."""
    mono = s.get("monochrome", False)
    image = tone_regions(image, s.get("highlights", 0) / 100, s.get("shadows", 0) / 100, scale)
    lut = master_lut(s)
    if lut is not None:
        image = apply_master_curve(image, lut)
    image = apply_channel_curves(image, s)
    image = dehaze(image, s.get("dehaze", 0) / 100)
    image = local_contrast(image, s.get("clarity", 0) / 100, CLARITY, scale)
    image = local_contrast(image, s.get("texture", 0) / 100, TEXTURE, scale)
    if not mono:
        image = vibrance(image, s.get("vibrance", 0) / 100)
        image = saturation(image, s.get("saturation", 0) / 100)
    if cube_needed(s):
        image = apply_cube(image, build_cube(s))
    image = vignette(image, s.get("vignette", 0), s.get("vignetteMidpoint", 50))
    image = grain(image, s.get("grain", 0) / 100, s.get("grainSize", 25) / 100, s.get("grainRoughness", 50) / 100, scale)
    return image

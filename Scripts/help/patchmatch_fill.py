"""Content-Aware Remove for the Help pictures: the same PatchMatch completion as
Sources/AtelierCore/Develop/Spots/ContentAwareFill.swift (Barnes et al. 2009, Wexler et al. 2007), in NumPy."""
import numpy as np, time

P = 7; H2 = P // 2
SHARP = True

def downsample(img, hole):
    h, w = img.shape[:2]
    h2, w2 = h // 2, w // 2
    im = img[:h2*2, :w2*2].reshape(h2, 2, w2, 2, 3).mean((1, 3))
    ho = hole[:h2*2, :w2*2].reshape(h2, 2, w2, 2).any((1, 3))
    return im, ho

def dilate(mask, r):
    h, w = mask.shape
    out = np.zeros_like(mask)
    ys, xs = np.nonzero(mask)
    for y, x in zip(ys, xs):
        out[max(0, y-r):y+r+1, max(0, x-r):x+r+1] = True
    return out

def complete_level(img, hole, nnf, rng, iters, sharp=False):
    h, w = hole.shape
    # Valid source centers: patch inside image, no hole pixel.
    holeP = dilate(hole, H2)
    valid = np.zeros((h, w), bool)
    valid[H2:h-H2, H2:w-H2] = ~holeP[H2:h-H2, H2:w-H2]
    targets = [(y, x) for y in range(H2, h-H2) for x in range(H2, w-H2) if holeP[y, x]]
    if not valid.any() or not targets:
        return img, nnf
    vy, vx = np.nonzero(valid)
    def dist(img, ty, tx, sy, sx):
        a = img[ty-H2:ty+H2+1, tx-H2:tx+H2+1]; b = img[sy-H2:sy+H2+1, sx-H2:sx+H2+1]
        return float(((a-b)**2).sum())
    def random_valid():
        i = rng.integers(len(vy)); return int(vy[i]), int(vx[i])
    for it in range(iters):
        # (Re)initialise unknown or invalid matches.
        for (ty, tx) in targets:
            m = nnf.get((ty, tx))
            if m is None or not valid[m[0], m[1]]:
                nnf[(ty, tx)] = random_valid()
        D = {t: dist(img, t[0], t[1], *nnf[t]) for t in targets}
        for p in range(2):
            order = targets if p % 2 == 0 else targets[::-1]
            step = 1 if p % 2 == 0 else -1
            for (ty, tx) in order:
                best = nnf[(ty, tx)]; bd = D[(ty, tx)]
                # Propagation from the left/up (or right/down) neighbour.
                for (ny, nx) in ((ty, tx-step), (ty-step, tx)):
                    m = nnf.get((ny, nx))
                    if m is None: continue
                    cy, cx = m[0] + (ty-ny), m[1] + (tx-nx)
                    if 0 <= cy < h and 0 <= cx < w and valid[cy, cx]:
                        d = dist(img, ty, tx, cy, cx)
                        if d < bd: best, bd = (cy, cx), d
                # Random search around the best, halving the radius.
                r = max(h, w)
                while r >= 1:
                    cy = best[0] + int(rng.integers(-r, r+1)); cx = best[1] + int(rng.integers(-r, r+1))
                    if 0 <= cy < h and 0 <= cx < w and valid[cy, cx]:
                        d = dist(img, ty, tx, cy, cx)
                        if d < bd: best, bd = (cy, cx), d
                    r //= 2
                nnf[(ty, tx)] = best; D[(ty, tx)] = bd
        # Vote: every hole pixel is the weighted mean of what overlapping patches say.
        acc = np.zeros((h, w, 3)); wsum = np.zeros((h, w))
        ds = np.array(list(D.values())); sigma2 = max(np.percentile(ds, 50), 1e-6)
        for (ty, tx) in targets:
            sy, sx = nnf[(ty, tx)]
            wgt = np.exp(-D[(ty, tx)] / (2 * sigma2))
            acc[ty-H2:ty+H2+1, tx-H2:tx+H2+1] += wgt * img[sy-H2:sy+H2+1, sx-H2:sx+H2+1]
            wsum[ty-H2:ty+H2+1, tx-H2:tx+H2+1] += wgt
        upd = hole & (wsum > 0)
        img = img.copy(); img[upd] = acc[upd] / wsum[upd][:, None]
    if sharp:
        # Final pass: each hole pixel takes the centre of its own best match, keeping grain.
        out = img.copy()
        for (ty, tx) in targets:
            if hole[ty, tx]:
                sy, sx = nnf[(ty, tx)]
                out[ty, tx] = img[sy, sx]
        img = out
    return img, nnf

def diffuse(img, hole, n=200):
    img = img.copy(); img[hole] = img[~hole].mean(0)
    for _ in range(n):
        s = (np.roll(img, 1, 0) + np.roll(img, -1, 0) + np.roll(img, 1, 1) + np.roll(img, -1, 1)) / 4
        img[hole] = s[hole]
    return img

def complete(img, hole, seed=1):
    rng = np.random.default_rng(seed)
    pyr = [(img, hole)]
    while min(pyr[-1][1].shape) >= 4 * P and dilate(pyr[-1][1], 0).sum() > 0:
        im, ho = downsample(*pyr[-1])
        # Stop when the hole is a few patches wide.
        pyr.append((im, ho))
        ys, xs = np.nonzero(ho)
        if len(ys) == 0 or max(np.ptp(ys), np.ptp(xs)) <= P: break
    cur = diffuse(*pyr[-1])
    nnf = {}
    for level in range(len(pyr) - 1, -1, -1):
        im, ho = pyr[level]
        if level < len(pyr) - 1:
            # Upsample the estimate and the matches.
            up = np.repeat(np.repeat(cur, 2, 0), 2, 1)
            pad = np.zeros_like(im); pad[:up.shape[0], :up.shape[1]] = up[:im.shape[0], :im.shape[1]]
            est = im.copy(); est[ho] = pad[ho]
            nnf = {(y, x): (2*m[0] + (y % 2), 2*m[1] + (x % 2)) for y in range(im.shape[0]) for x in range(im.shape[1])
                   for m in [old.get((y//2, x//2))] if m is not None}
        else:
            est = cur
        old = None
        cur, nnf = complete_level(est, ho, nnf, rng, iters=(12 if level == len(pyr) - 1 else 6) if level else 4, sharp=SHARP and level == 0)
        old = nnf
    return cur

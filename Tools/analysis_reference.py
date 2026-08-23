"""Python port of the Phase 3A analysis numerics.

Mirrors `LumaStatisticsCalculator`, `SyntheticFrameFactory` and
`DeterministicRandom` formula for formula. It exists because the analysis
thresholds are numeric claims, and a numeric claim that has never been
evaluated is a guess.

Running this checks that the values the Swift tests assert are the values the
algorithms actually produce:

    python3 Tools/analysis_reference.py

It is a cross-check, not a substitute for running the Swift tests in Xcode. If
a formula changes on one side, change it on the other and re-run.
"""
import math

MASK = (1 << 64) - 1

class Rand:
    def __init__(self, seed): self.s = seed & MASK
    def next(self):
        self.s = (self.s + 0x9E3779B97F4A7C15) & MASK
        z = self.s
        z = ((z ^ (z >> 30)) * 0xBF58476D1CE4E5B9) & MASK
        z = ((z ^ (z >> 27)) * 0x94D049BB133111EB) & MASK
        return (z ^ (z >> 31)) & MASK
    def unit(self): return (self.next() >> 40) / (1 << 24)
    def gauss(self):
        u1 = max(self.unit(), 2.2250738585072014e-308)
        u2 = self.unit()
        return math.sqrt(-2 * math.log(u1)) * math.cos(2 * math.pi * u2)

class Img:
    def __init__(self, w, h, fill=0.0):
        self.w, self.h = w, h
        self.v = [fill] * (w * h)
    def get(self, x, y): return self.v[y * self.w + x]
    def set(self, x, y, val): self.v[y * self.w + x] = val

def draw_disc(img, cx_n, cy_n, radius_px, brightness):
    if radius_px <= 0 or img.w == 0: return
    cx = cx_n * img.w; cy = cy_n * img.h
    extent = int(math.ceil(radius_px)) + 1
    x0 = max(0, int(cx) - extent); x1 = min(img.w - 1, int(cx) + extent)
    y0 = max(0, int(cy) - extent); y1 = min(img.h - 1, int(cy) + extent)
    if x0 > x1 or y0 > y1: return
    for y in range(y0, y1 + 1):
        dy = y + 0.5 - cy
        for x in range(x0, x1 + 1):
            dx = x + 0.5 - cx
            d = math.hypot(dx, dy)
            if d > radius_px + 1: continue
            f = max(0.0, 1 - d / (radius_px + 1))
            img.v[y * img.w + x] += brightness * f * f

def render(scene, t, frame_index):
    img = Img(scene['w'], scene['h'], scene['base'])
    ox = scene.get('tx', 0.0) * t; oy = scene.get('ty', 0.0) * t

    vig = scene.get('vignette', 0.0)
    if vig > 0:
        cx = img.w / 2; cy = img.h / 2
        rmax = math.hypot(cx, cy)
        for y in range(img.h):
            for x in range(img.w):
                r = math.hypot(x - cx, y - cy) / rmax
                img.v[y * img.w + x] *= (1 - vig * r * r)

    for s in scene.get('scratches', []):
        sx, sy, ex, ey, b, wpx = s
        sxp = (sx + ox) * img.w; syp = (sy + oy) * img.h
        exp_ = (ex + ox) * img.w; eyp = (ey + oy) * img.h
        length = math.hypot(exp_ - sxp, eyp - syp)
        steps = max(1, int(math.ceil(length)))
        for i in range(steps + 1):
            u = i / steps
            draw_disc(img, (sxp + (exp_ - sxp) * u) / img.w,
                      (syp + (eyp - syp) * u) / img.h, max(0.5, wpx / 2), b)

    for (bx, by, r, b) in scene.get('blobs', []):
        draw_disc(img, bx + ox, by + oy, r, b)
    if scene.get('hotspot'):
        hx, hy, r, b = scene['hotspot']
        draw_disc(img, hx + ox, hy + oy, r, b)
    for sp in scene.get('specks', []):
        cx, cy, orb, w, ph, dx, dy, r, b = sp
        px = cx + orb * math.cos(ph + w * t) + dx * t + ox
        py = cy + orb * math.sin(ph + w * t) + dy * t + oy
        draw_disc(img, px, py, r, b)
    for bu in scene.get('bubbles', []):
        bx, by, speed, r, b = bu
        draw_disc(img, bx + ox, by + speed * t + oy, r, b)

    fl = scene.get('flicker')
    gain = 1.0 if not fl else 1 + fl[0] * math.sin(2 * math.pi * fl[1] * t + fl[2])
    rnd = Rand(scene.get('seed', 0x5EED) + frame_index)
    sigma = scene.get('sigma', 0.0)
    for i in range(len(img.v)):
        val = img.v[i] * gain + (rnd.gauss() * sigma if sigma > 0 else 0.0)
        img.v[i] = min(max(val, 0.0), 1.0)
    return img

SAT = 0.98
NEAR_BLACK = 0.02
TILES = 4

def stats(img, mask=None):
    if img.w == 0 or img.h == 0: return None
    hist = [0] * 256
    tiles = [0.0] * (TILES * TILES)
    n = 0; tot = 0.0; tot2 = 0.0
    mn = float('inf'); mx = -float('inf'); sat = 0; nb = 0
    for y in range(img.h):
        row = y * img.w
        tr = min(TILES - 1, y * TILES // img.h)
        for x in range(img.w):
            i = row + x
            if mask is not None and not mask[i]: continue
            v = img.v[i]
            n += 1; tot += v; tot2 += v * v
            mn = min(mn, v); mx = max(mx, v)
            if v >= SAT: sat += 1
            if v < NEAR_BLACK: nb += 1
            hist[min(255, max(0, int(v * 255)))] += 1
            tc = min(TILES - 1, x * TILES // img.w)
            tiles[tr * TILES + tc] += v
    if n == 0: return None
    mean = tot / n
    var = max(0.0, tot2 / n - mean * mean)
    def pct(f):
        target = max(1, round(f * n))
        run = 0
        for b, c in enumerate(hist):
            run += c
            if run >= target: return b / 255
        return 1.0
    return dict(n=n, mean=mean, sd=math.sqrt(var), min=mn, max=mx,
                p01=pct(0.01), p50=pct(0.50), p99=pct(0.99),
                sat=sat / n, nb=nb / n,
                tile=(max(tiles) / tot if tot > 0 else 0),
                sharp=sharpness(img, mask, mean))

def sharpness(img, mask, mean, subtract_noise=True):
    if img.w < 3 or img.h < 3 or mean <= 0: return 0.0
    n = 0; tot = 0.0; tot2 = 0.0
    for y in range(1, img.h - 1):
        row = y * img.w
        for x in range(1, img.w - 1):
            i = row + x
            if mask is not None and not (mask[i] and mask[i-1] and mask[i+1]
                                         and mask[i-img.w] and mask[i+img.w]):
                continue
            lap = (4 * img.v[i] - img.v[i-1] - img.v[i+1]
                   - img.v[i-img.w] - img.v[i+img.w])
            n += 1; tot += lap; tot2 += lap * lap
    if n < 2: return 0.0
    lm = tot / n
    var = max(0.0, tot2 / n - lm * lm)
    if subtract_noise:
        sigma = estimate_noise(img, mask)
        var = max(0.0, var - 20.0 * sigma * sigma)
    return var / (mean * mean)

NOISE_SAMPLE_TARGET = 8192

def estimate_noise(img, mask):
    """Robust sigma from horizontally adjacent differences (median absolute).

    Rows are subsampled exactly as the Swift does, so the two agree.
    """
    if img.w < 2 or img.h < 1: return 0.0
    pairs = img.w - 1
    if pairs <= 0: return 0.0
    stride = max(1, (img.h * pairs) // NOISE_SAMPLE_TARGET)
    diffs = []
    for y in range(0, img.h, stride):
        row = y * img.w
        for x in range(pairs):
            i = row + x
            if mask is not None and not (mask[i] and mask[i+1]): continue
            diffs.append(abs(img.v[i+1] - img.v[i]))
    if len(diffs) < 8: return 0.0
    diffs.sort()
    median = diffs[len(diffs)//2]
    # For Gaussian noise, median|d| = 0.6745 * sqrt(2) * sigma
    return median / (0.6745 * math.sqrt(2))

def box_average(src, ow, oh):
    dst = Img(ow, oh)
    for oy in range(oh):
        y0 = oy * src.h // oh; y1 = max(y0 + 1, (oy + 1) * src.h // oh)
        for ox in range(ow):
            x0 = ox * src.w // ow; x1 = max(x0 + 1, (ox + 1) * src.w // ow)
            tot = 0.0; c = 0
            for y in range(y0, min(y1, src.h)):
                r = y * src.w
                for x in range(x0, min(x1, src.w)):
                    tot += src.v[r + x]; c += 1
            dst.v[oy * ow + ox] = tot / c if c else 0.0
    return dst

def norm_diff(a, b):
    if a.w != b.w or a.h != b.h or a.w * a.h == 0: return 0.0
    tot = 0.0; lvl = 0.0
    for i in range(len(a.v)):
        tot += abs(a.v[i] - b.v[i]); lvl += (a.v[i] + b.v[i]) / 2
    ml = lvl / len(a.v)
    return (tot / len(a.v)) / ml if ml > 0 else 0.0


# ---------------------------------------------------------------------------
# Self-check: the claims the Swift tests make about these numerics.
# ---------------------------------------------------------------------------

SATURATION_LIMIT = 0.005
TILE_LIMIT = 0.35
MEAN_LOW, MEAN_HIGH = 0.02, 0.65
SHARPNESS_LIMIT = 0.0008
MOTION_LIMIT = 0.0012
EXPOSURE_LIMIT = 0.03


def good_scene(**kw):
    """The scene `FrameAnalyzerTests` treats as a clean sample."""
    specks = [(0.2 + (i % 4) * 0.2, 0.2 + (i // 4) * 0.25,
               0.03, 0.6, float(i), 0.0, 0.0, 1.5, 0.35) for i in range(12)]
    scene = dict(w=160, h=120, base=0.30, sigma=0.01, specks=specks, seed=2024)
    scene.update(kw)
    return scene


def coarse(img, long_edge=64):
    scale = max(1, max(img.w, img.h) // long_edge)
    return box_average(img, max(1, img.w // scale), max(1, img.h // scale))


def motion(a, b):
    """Mirrors LumaStatisticsCalculator.normalizedDifference."""
    total = sum(abs(a.v[i] - b.v[i]) for i in range(len(a.v)))
    level = sum((a.v[i] + b.v[i]) / 2 for i in range(len(a.v)))
    n = len(a.v)
    mean_level = level / n
    if mean_level <= 0:
        return 0.0
    sigma = (estimate_noise(a, None) + estimate_noise(b, None)) / 2
    return max(0.0, total / n - 1.1284 * sigma) / mean_level


def median_motion(scene, frames=30, fps=30.0):
    prev, values = None, []
    for i in range(frames):
        c = coarse(render(scene, i / fps, i))
        if prev is not None:
            values.append(motion(prev, c))
        prev = c
    values.sort()
    return values[len(values) // 2] if values else 0.0


def main():
    failures = []

    def check(name, condition, detail):
        status = "ok  " if condition else "FAIL"
        print(f"  [{status}] {name}: {detail}")
        if not condition:
            failures.append(name)

    print("Phase 3A numeric cross-check")
    print()

    print("A clean scene clears every per-frame gate")
    sharps = [stats(render(good_scene(), i / 30.0, i))["sharp"] for i in range(60)]
    st = stats(render(good_scene(), 0, 0))
    check("mean in band", MEAN_LOW < st["mean"] < MEAN_HIGH, f"{st['mean']:.4f}")
    check("no clipping", st["sat"] <= SATURATION_LIMIT, f"{st['sat']:.5f}")
    check("no hotspot", st["tile"] <= TILE_LIMIT, f"{st['tile']:.4f}")
    check("sharp enough (worst frame)", min(sharps) >= SHARPNESS_LIMIT,
          f"min {min(sharps):.6f} vs {SHARPNESS_LIMIT}")
    check("still", median_motion(good_scene()) <= MOTION_LIMIT,
          f"{median_motion(good_scene()):.6f}")

    print()
    print("Noise subtraction is what makes the focus gate able to fire")
    noisy_flat = dict(w=160, h=120, base=0.30, sigma=0.004, seed=1)
    img = render(noisy_flat, 0, 0)
    raw = sharpness(img, None, stats(img)["mean"], subtract_noise=False)
    corrected = sharpness(img, None, stats(img)["mean"], subtract_noise=True)
    check("defocused frame rejected once corrected", corrected < SHARPNESS_LIMIT,
          f"raw {raw:.6f} -> corrected {corrected:.6f}")

    print()
    print("Noise subtraction is what makes the motion gate mean anything")
    still = median_motion(good_scene())
    slow = median_motion(good_scene(tx=0.10))
    fast = median_motion(good_scene(tx=0.25))
    check("still reads as still", still < 0.0001, f"{still:.6f}")
    check("slow drift tolerated", slow <= MOTION_LIMIT, f"{slow:.6f}")
    check("fast pan rejected", fast > MOTION_LIMIT, f"{fast:.6f}")

    print()
    print("Failure scenes are rejected")
    dark = stats(render(dict(w=160, h=120, base=0.004, sigma=0.0005, seed=4), 0, 0))
    check("dark scene", dark["mean"] < MEAN_LOW, f"mean {dark['mean']:.5f}")
    blown = stats(render(dict(w=160, h=120, base=0.95, sigma=0.05,
                              hotspot=(0.5, 0.5, 60, 1.0), seed=3), 0, 0))
    check("saturated scene", blown["sat"] > SATURATION_LIMIT, f"sat {blown['sat']:.4f}")
    spot = stats(render(dict(w=160, h=120, base=0.05, sigma=0.0,
                             hotspot=(0.125, 0.125, 40, 1.5), seed=0), 0, 0))
    check("hotspot scene", spot["tile"] > TILE_LIMIT, f"tile {spot['tile']:.4f}")

    flicker = good_scene(flicker=(0.25, 2.0, 0.0))
    means = [stats(render(flicker, i / 30.0, i))["mean"] for i in range(60)]
    m = sum(means) / len(means)
    cv = (sum((x - m) ** 2 for x in means) / len(means)) ** 0.5 / m
    check("flicker scene", cv > EXPOSURE_LIMIT, f"coefficient of variation {cv:.4f}")

    print()
    if failures:
        print(f"{len(failures)} check(s) failed: {', '.join(failures)}")
        return 1
    print("all checks passed")
    return 0


if __name__ == "__main__":
    import sys
    sys.exit(main())

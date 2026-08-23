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

    # The translation `SimulatedSample.unsteady` and the pipeline's shaken-run
    # test use. Both claim it is rejected; this is where that claim is checked.
    unsteady = median_motion(good_scene(tx=0.35, ty=0.25))
    check("the unsteady scene is rejected", unsteady > MOTION_LIMIT * 1.5,
          f"{unsteady:.6f} vs limit {MOTION_LIMIT}")

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

    failures.extend(check_phase_3b())
    failures.extend(check_phase_3c())
    failures.extend(check_phase_3d())
    failures.extend(check_phase_4())

    print()
    if failures:
        print(f"{len(failures)} check(s) failed: {', '.join(failures)}")
        return 1
    print("all checks passed")
    return 0





# ---------------------------------------------------------------------------
# Phase 3B: background subtraction and band-pass detection.
# ---------------------------------------------------------------------------

def gaussian_kernel(sigma):
    if sigma <= 0:
        return [1.0]
    radius = max(1, int(math.ceil(sigma * 3)))
    k = [math.exp(-(o * o) / (2 * sigma * sigma)) for o in range(-radius, radius + 1)]
    total = sum(k)
    return [v / total for v in k]


def convolve_h(src, w, h, kernel):
    r = len(kernel) // 2
    out = [0.0] * (w * h)
    for y in range(h):
        row = y * w
        for x in range(w):
            t = 0.0
            for i, kv in enumerate(kernel):
                sx = min(max(x + i - r, 0), w - 1)
                t += src[row + sx] * kv
            out[row + x] = t
    return out


def convolve_v(src, w, h, kernel):
    r = len(kernel) // 2
    out = [0.0] * (w * h)
    for y in range(h):
        for x in range(w):
            t = 0.0
            for i, kv in enumerate(kernel):
                sy = min(max(y + i - r, 0), h - 1)
                t += src[sy * w + x] * kv
            out[y * w + x] = t
    return out


def band_pass(src, w, h, narrow=1.0, wide=2.5):
    kn, kw = gaussian_kernel(narrow), gaussian_kernel(wide)
    a = convolve_v(convolve_h(src, w, h, kn), w, h, kn)
    b = convolve_v(convolve_h(src, w, h, kw), w, h, kw)
    return [a[i] - b[i] for i in range(len(src))]


NOISE_TARGET = 8192


def mad_sigma(values, mask=None):
    """1.4826 * MAD, subsampled exactly as the Swift does."""
    n = len(values)
    stride = max(1, n // NOISE_TARGET)
    sample = [values[i] for i in range(0, n, stride)
              if mask is None or mask[i]]
    if len(sample) < 8:
        return 0.0
    sample.sort()
    med = sample[len(sample) // 2]
    dev = sorted(abs(v - med) for v in sample)
    return dev[len(dev) // 2] * 1.4826


def temporal_median(frames):
    """Per-pixel median across a list of frames."""
    n = len(frames[0].v)
    out = [0.0] * n
    for i in range(n):
        window = sorted(f.v[i] for f in frames)
        out[i] = window[len(window) // 2]
    return out


def components(response, w, h, threshold, mask=None):
    """Eight-connected flood fill; returns (area, peak) per component."""
    labels = [0] * (w * h)
    found = []
    for seed in range(w * h):
        if labels[seed] or response[seed] <= threshold:
            continue
        if mask is not None and not mask[seed]:
            continue
        stack = [seed]
        labels[seed] = 1
        area = 0
        peak = 0.0
        while stack:
            idx = stack.pop()
            x, y = idx % w, idx // w
            area += 1
            peak = max(peak, response[idx])
            for ny in range(max(0, y - 1), min(h, y + 2)):
                for nx in range(max(0, x - 1), min(w, x + 2)):
                    ni = ny * w + nx
                    if labels[ni] or response[ni] <= threshold:
                        continue
                    if mask is not None and not mask[ni]:
                        continue
                    labels[ni] = 1
                    stack.append(ni)
        found.append((area, peak))
    return found


# ---------------------------------------------------------------------------
# Phase 3B self-check.
# ---------------------------------------------------------------------------

DETECT_W, DETECT_H = 192, 144
DETECT_FPS = 30.0
ACQUISITION_FRAMES = 60
MEDIAN_SAMPLES = 9
ACQUISITION_STRIDE = ACQUISITION_FRAMES // MEDIAN_SAMPLES
THRESHOLD_SIGMAS = 5.0
MIN_AREA_PIXELS = 2
MAX_NORMALIZED_DIAMETER = 0.04
MIN_LOCAL_CONTRAST = 1.2
STABILITY_LIMIT_SIGMAS = 6.0
# Reported, never gated on. Kept here because the 3B checks below are what
# establish that it separates a still container from a moving one and does NOT
# separate a still container from one full of drifting particles - which is
# exactly why it cannot be a quality gate.
BACKGROUND_STABILITY_REFERENCE = 0.93


def detect_scene(**kw):
    scene = dict(w=DETECT_W, h=DETECT_H, base=0.30, sigma=0.01, seed=4242)
    scene.update(kw)
    return scene


def acquisition_samples(scene):
    """The frames the background model actually retains, at the real stride."""
    frames = [render(scene, i / DETECT_FPS, i)
              for i in range(0, ACQUISITION_FRAMES, ACQUISITION_STRIDE)]
    return frames[-MEDIAN_SAMPLES:]


def background_of(scene):
    return temporal_median(acquisition_samples(scene))


def background_stability(scene, noise=0.01):
    kept = acquisition_samples(scene)
    used = len(kept)
    limit = max(noise, 1e-6) * STABILITY_LIMIT_SIGMAS
    unstable = 0
    for i in range(len(kept[0].v)):
        window = sorted(f.v[i] for f in kept)
        if window[used - 1] - window[0] > limit:
            unstable += 1
    return 1 - unstable / len(kept[0].v)


def accepted_candidates(scene, background, frame_index, mask=None):
    """Components surviving the same filters the Swift applies."""
    img = render(scene, frame_index / DETECT_FPS, frame_index)
    diff = [(0.0 if (mask is not None and not mask[i]) else img.v[i] - background[i])
            for i in range(len(background))]
    g = band_pass(diff, DETECT_W, DETECT_H)
    sigma = mad_sigma(g, mask)
    threshold = max(sigma * THRESHOLD_SIGMAS, 1e-7)
    diagonal = math.hypot(DETECT_W, DETECT_H)

    out = []
    for area, peak in components(g, DETECT_W, DETECT_H, threshold, mask):
        if area < MIN_AREA_PIXELS:
            continue
        if (2 * math.sqrt(area / math.pi)) / diagonal > MAX_NORMALIZED_DIAMETER:
            continue
        if peak / threshold < MIN_LOCAL_CONTRAST:
            continue
        out.append((area, peak))
    return out, threshold


def speck(cx, cy, orbit, omega, phase, radius, brightness):
    return (cx, cy, orbit, omega, phase, 0.0, 0.0, radius, brightness)


# ---------------------------------------------------------------------------
# Phase 4: the scenes the Simulator and the UI tests measure
#
# The interface is driven on the Simulator by a synthetic frame source, and the
# UI tests assert what each scene produces. Those assertions are only worth
# anything if the scenes really do clear (or really do fail) the gates, and the
# gates are applied to the cropped, masked analysis region rather than to the
# whole frame. That is what this section checks.
# ---------------------------------------------------------------------------

# `AnalysisRegion.screeningDefault`.
REGION_RECT = (0.25, 0.28, 0.50, 0.44)
REGION_EXCLUDED_RECTS = [(0.0, 0.0, 1.0, 0.12)]
REGION_EXCLUDED_ELLIPSES = [(0.30, 0.02, 0.40, 0.34)]


def region_pixel_rect(w, h):
    """Mirrors `AnalysisRegion.pixelRect(inWidth:height:)`."""
    x = math.floor(REGION_RECT[0] * w)
    y = math.floor(REGION_RECT[1] * h)
    max_x = math.ceil((REGION_RECT[0] + REGION_RECT[2]) * w)
    max_y = math.ceil((REGION_RECT[1] + REGION_RECT[3]) * h)
    return x, y, min(max_x, w) - x, min(max_y, h) - y


def crop_to_region(img):
    x, y, w, h = region_pixel_rect(img.w, img.h)
    out = Img(w, h)
    for row in range(h):
        src = (y + row) * img.w + x
        dst = row * w
        out.v[dst:dst + w] = img.v[src:src + w]
    return out


def region_mask(w, h):
    """Mirrors `RasterizedMask`, sampling at pixel centres."""
    flags = [True] * (w * h)
    for yy in range(h):
        ny = (yy + 0.5) / h
        for xx in range(w):
            nx = (xx + 0.5) / w
            excluded = False
            for rx, ry, rw, rh in REGION_EXCLUDED_RECTS:
                if rx <= nx <= rx + rw and ry <= ny <= ry + rh:
                    excluded = True
            for ex, ey, ew, eh in REGION_EXCLUDED_ELLIPSES:
                if ew <= 0 or eh <= 0:
                    continue
                dx = (nx - (ex + ew / 2)) / (ew / 2)
                dy = (ny - (ey + eh / 2)) / (eh / 2)
                if dx * dx + dy * dy <= 1:
                    excluded = True
            flags[yy * w + xx] = not excluded
    return flags


def simulated_scene(kind):
    """Mirrors `SimulatedSample.scene`."""
    counts = {"clear": (2, 0.16), "lightlyLoaded": (12, 0.30),
              "heavilyLoaded": (30, 0.46), "unsteady": (12, 0.30)}
    count, brightness = counts[kind]
    specks = []
    for i in range(count):
        column = i % 8
        row = i // 8
        specks.append((0.30 + column * 0.055, 0.47 + row * 0.035,
                       0.012 + (i % 3) * 0.004, 0.9 + (i % 5) * 0.2, float(i) * 0.7,
                       0.002, 0.004, 1.0 + (i % 3) * 0.2, brightness))
    scene = dict(w=320, h=240, base=0.14, sigma=0.004, vignette=0.12,
                 scratches=[(0.28, 0.44, 0.72, 0.50, 0.30, 2.0)],
                 blobs=[(0.62, 0.62, 3.0, 0.25)],
                 specks=specks, seed=0x51CE)
    if kind == "unsteady":
        scene["tx"] = 0.35
        scene["ty"] = 0.25
    return scene


def region_stats(scene, t=0.0, frame_index=0):
    img = crop_to_region(render(scene, t, frame_index))
    return stats(img, region_mask(img.w, img.h))


def region_frame_motions(scene, frames=16, fps=30.0):
    """Per-frame motion on the region, which is what the gate actually sees."""
    values = []
    prev = None
    for i in range(frames):
        c = coarse(crop_to_region(render(scene, i / fps, i)))
        if prev is not None:
            values.append(motion(prev, c))
        prev = c
    return values


def check_phase_4():
    failures = []

    def check(name, condition, detail):
        status = "ok  " if condition else "FAIL"
        print(f"  [{status}] {name}: {detail}")
        if not condition:
            failures.append(name)

    print()
    print("Phase 4: the simulated scenes, judged on the analysis region")
    print()

    for kind in ("clear", "lightlyLoaded", "heavilyLoaded"):
        scene = simulated_scene(kind)
        st = region_stats(scene)
        motions = region_frame_motions(scene)
        worst = max(motions) if motions else 0.0
        check(f"{kind}: level in band",
              MEAN_LOW < st["mean"] < MEAN_HIGH, f"mean {st['mean']:.4f}")
        check(f"{kind}: no clipping",
              st["sat"] <= SATURATION_LIMIT, f"{st['sat']:.5f}")
        check(f"{kind}: no hotspot",
              st["tile"] <= TILE_LIMIT, f"{st['tile']:.4f}")
        check(f"{kind}: in focus",
              st["sharp"] >= SHARPNESS_LIMIT,
              f"{st['sharp']:.6f} vs {SHARPNESS_LIMIT}")
        # Every frame, not the median: a frame the gate rejects is a frame that
        # does not count towards the usable ratio, and enough of them fail the
        # window even when the median passes.
        check(f"{kind}: every frame reads as still", worst <= MOTION_LIMIT,
              f"worst {worst:.6f} of {len(motions)} vs {MOTION_LIMIT}")

    print()
    shaken = region_frame_motions(simulated_scene("unsteady"))
    rejected = sum(1 for value in shaken if value > MOTION_LIMIT)
    check("unsteady is rejected on the region too, on every frame",
          rejected == len(shaken), f"{rejected}/{len(shaken)} frames over the limit")

    print()
    # Why background stability is not a gate: a busy sample scores worse than a
    # container creeping at 2% of the frame width per second, which the motion
    # gate lets through. No threshold separates them, so gating on it would
    # reject the turbid samples the app exists to identify.
    # A denser sample than any of the shipped scenes: those are tuned so the
    # *motion* gate has margin at this frame size, which also lifts their
    # stability. The point being made here is about the metric, so it is made
    # with a sample that is genuinely full of material.
    dense = simulated_scene("heavilyLoaded")
    dense["specks"] = [(0.30 + (i % 8) * 0.055, 0.47 + (i // 8) * 0.035,
                        0.012 + (i % 3) * 0.004, 0.9 + (i % 5) * 0.2, float(i) * 0.7,
                        0.002, 0.004, 1.4 + (i % 3) * 0.3, 0.46) for i in range(48)]
    busy = background_stability_on_region(dense)
    still = background_stability_on_region(simulated_scene("clear"))
    marks = dict(
        scratches=[(0.10, 0.20, 0.90, 0.26, 0.40, 2.0),
                   (0.15, 0.70, 0.85, 0.62, 0.35, 2.0),
                   (0.30, 0.10, 0.36, 0.90, 0.30, 2.0)],
        blobs=[(0.25, 0.45, 4, 0.5), (0.70, 0.55, 5, 0.45), (0.50, 0.80, 3, 0.4)],
    )
    creep_scene = detect_scene(tx=0.02, ty=0.01, **marks)
    creep = background_stability(creep_scene)
    creep_motion = median_motion(creep_scene, frames=12)
    check("a still sample reads as stable", still > BACKGROUND_STABILITY_REFERENCE,
          f"{still:.4f}")
    check("a sample full of material scores worse than an undetected creep",
          busy < creep, f"busy {busy:.4f} vs creep {creep:.4f}")
    check("that creep is invisible to the motion gate",
          creep_motion <= MOTION_LIMIT, f"{creep_motion:.6f}")

    return failures


def background_stability_on_region(scene, noise=0.004):
    """`background_stability`, but on the cropped and masked region."""
    frames = [crop_to_region(render(scene, i / DETECT_FPS, i))
              for i in range(0, ACQUISITION_FRAMES, ACQUISITION_STRIDE)][-MEDIAN_SAMPLES:]
    if not frames:
        return 0.0
    mask = region_mask(frames[0].w, frames[0].h)
    limit = max(noise, 1e-6) * STABILITY_LIMIT_SIGMAS
    considered = 0
    unstable = 0
    for i in range(len(frames[0].v)):
        if not mask[i]:
            continue
        considered += 1
        window = sorted(f.v[i] for f in frames)
        if window[-1] - window[0] > limit:
            unstable += 1
    return 1 - unstable / considered if considered else 0.0

def check_phase_3b():
    failures = []

    def check(name, condition, detail):
        print(f"  [{'ok  ' if condition else 'FAIL'}] {name}: {detail}")
        if not condition:
            failures.append(name)

    print()
    print("Phase 3B: background subtraction and detection")
    print()

    clean = detect_scene()
    clean_bg = background_of(clean)

    total = sum(len(accepted_candidates(clean, clean_bg, i)[0]) for i in range(200, 240))
    check("noise alone yields nothing", total == 0, f"{total} candidates over 40 frames")

    scratched = detect_scene(scratches=[(0.2, 0.3, 0.7, 0.35, 0.40, 2.0)])
    bg = background_of(scratched)
    total = sum(len(accepted_candidates(scratched, bg, i)[0]) for i in range(200, 220))
    check("static scratch absorbed", total == 0, f"{total} candidates over 20 frames")

    blobbed = detect_scene(blobs=[(0.5, 0.5, 3.0, 0.45)])
    bg = background_of(blobbed)
    total = sum(len(accepted_candidates(blobbed, bg, i)[0]) for i in range(200, 210))
    check("stationary bubble absorbed", total == 0, f"{total} candidates over 10 frames")

    moving = detect_scene(specks=[speck(0.5, 0.5, 0.25, 1.2, 0.0, 1.5, 0.35)])
    bg = background_of(moving)
    hits = sum(1 for i in range(200, 230) if accepted_candidates(moving, bg, i)[0])
    check("moving speck detected", hits > 25, f"found in {hits} of 30 frames")

    dim = detect_scene(specks=[speck(0.5, 0.5, 0.25, 1.2, 0.0, 1.5, 0.10)])
    bg = background_of(dim)
    found, threshold = accepted_candidates(dim, bg, 200)
    ratio = found[0][1] / threshold if found else 0
    check("dim speck detected", bool(found), f"peak/threshold {ratio:.2f}")

    many = detect_scene(specks=[speck(0.2 + i * 0.15, 0.5, 0.04, 1.0, float(i), 1.5, 0.35)
                                for i in range(5)])
    bg = background_of(many)
    found, _ = accepted_candidates(many, bg, 200)
    check("five specks found separately", len(found) == 5, f"{len(found)} candidates")

    flicker = detect_scene(flicker=(0.25, 2.0, 0.0))
    total = sum(len(accepted_candidates(flicker, clean_bg, i)[0]) for i in range(200, 240))
    check("flicker yields nothing", total == 0, f"{total} candidates over 40 frames")

    vignetted = detect_scene(vignette=0.5)
    found, _ = accepted_candidates(vignetted, clean_bg, 200)
    check("illumination gradient yields nothing", not found, f"{len(found)} candidates")

    glare = detect_scene(hotspot=(0.30, 0.30, 22, 1.6))
    mask = []
    for y in range(DETECT_H):
        ny = (y + 0.5) / DETECT_H
        for x in range(DETECT_W):
            nx = (x + 0.5) / DETECT_W
            dx = (nx - 0.30) / 0.24
            dy = (ny - 0.30) / 0.24
            mask.append(dx * dx + dy * dy > 1)
    img = render(glare, 200 / DETECT_FPS, 200)
    raw = band_pass([img.v[i] - clean_bg[i] for i in range(len(clean_bg))], DETECT_W, DETECT_H)
    unmasked = components(raw, DETECT_W, DETECT_H,
                          max(mad_sigma(raw) * THRESHOLD_SIGMAS, 1e-7))
    masked_diff = [(0.0 if not mask[i] else img.v[i] - clean_bg[i]) for i in range(len(clean_bg))]
    masked_g = band_pass(masked_diff, DETECT_W, DETECT_H)
    masked = components(masked_g, DETECT_W, DETECT_H,
                        max(mad_sigma(masked_g, mask) * THRESHOLD_SIGMAS, 1e-7), mask)
    check("glare found without the mask", len(unmasked) > 0, f"{len(unmasked)} components")
    check("glare removed by the mask", len(masked) == 0, f"{len(masked)} components")

    specks20 = [speck(0.1 + (i % 5) * 0.2, 0.15 + (i // 5) * 0.22, 0.03, 1.0, float(i), 1.5, 0.35)
                for i in range(20)]
    marks = dict(
        scratches=[(0.10, 0.20, 0.90, 0.26, 0.40, 2.0),
                   (0.15, 0.70, 0.85, 0.62, 0.35, 2.0),
                   (0.30, 0.10, 0.36, 0.90, 0.30, 2.0)],
        blobs=[(0.25, 0.45, 4, 0.5), (0.70, 0.55, 5, 0.45), (0.50, 0.80, 3, 0.4)],
    )
    still = background_stability(detect_scene())
    sample = background_stability(detect_scene(specks=specks20))
    shifted = background_stability(detect_scene(tx=0.4, ty=0.2, **marks))
    check("still background is stable", still > 0.95, f"{still:.4f}")
    check("drifting particles stay stable", sample > BACKGROUND_STABILITY_REFERENCE,
          f"{sample:.4f}")
    check("shifted structure is unstable", shifted < BACKGROUND_STABILITY_REFERENCE,
          f"{shifted:.4f}")

    return failures



# ---------------------------------------------------------------------------
# Phase 3C: flow, tracking and classification.
# ---------------------------------------------------------------------------

FLOW_GRID, FLOW_PATCH, FLOW_RADIUS = 7, 21, 6
FLOW_EIGENVALUE_SIGMAS, FLOW_INLIER_TOLERANCE, FLOW_MIN_PATCHES = 4.0, 0.6, 3


def _sad(cur, ref, cx, cy, half, ox, oy, cutoff=float("inf")):
    total = 0.0
    for y in range(cy - half, cy + half + 1):
        cr = y * cur.w
        rr = (y + oy) * ref.w
        for x in range(cx - half, cx + half + 1):
            total += abs(cur.v[cr + x] - ref.v[rr + x + ox])
        if total > cutoff:
            return total
    return total


def parabolic_offset(left, centre, right):
    d = left - 2 * centre + right
    if d <= 0:
        return 0.0
    o = 0.5 * (left - right) / d
    return o if abs(o) <= 1 else 0.0


def structure_min_eigenvalue(img, cx, cy, half):
    """Shi-Tomasi. Near zero when the patch has gradient in only one direction."""
    gxx = gyy = gxy = 0.0
    n = 0
    for y in range(cy - half + 1, cy + half):
        for x in range(cx - half + 1, cx + half):
            i = y * img.w + x
            gx = (img.v[i + 1] - img.v[i - 1]) * 0.5
            gy = (img.v[i + img.w] - img.v[i - img.w]) * 0.5
            gxx += gx * gx
            gyy += gy * gy
            gxy += gx * gy
            n += 1
    gxx /= n; gyy /= n; gxy /= n
    trace = gxx + gyy
    root = math.sqrt(max(0.0, (gxx - gyy) ** 2 + 4 * gxy * gxy))
    return (trace - root) / 2


def measure_displacement(current, reference, noise):
    half = FLOW_PATCH // 2
    margin = half + FLOW_RADIUS
    uw, uh = current.w - 2 * margin, current.h - 2 * margin
    limit = FLOW_EIGENVALUE_SIGMAS * noise * noise
    dxs, dys = [], []
    for gy in range(FLOW_GRID):
        cy = margin + (uh * (2 * gy + 1)) // (2 * FLOW_GRID)
        for gx in range(FLOW_GRID):
            cx = margin + (uw * (2 * gx + 1)) // (2 * FLOW_GRID)
            if structure_min_eigenvalue(current, cx, cy, half) <= limit:
                continue
            best, bx, by = float("inf"), 0, 0
            for oy in range(-FLOW_RADIUS, FLOW_RADIUS + 1):
                for ox in range(-FLOW_RADIUS, FLOW_RADIUS + 1):
                    c = _sad(current, reference, cx, cy, half, ox, oy, best)
                    if c < best:
                        best, bx, by = c, ox, oy
            if abs(bx) >= FLOW_RADIUS or abs(by) >= FLOW_RADIUS:
                continue
            sx = parabolic_offset(_sad(current, reference, cx, cy, half, bx - 1, by), best,
                                  _sad(current, reference, cx, cy, half, bx + 1, by))
            sy = parabolic_offset(_sad(current, reference, cx, cy, half, bx, by - 1), best,
                                  _sad(current, reference, cx, cy, half, bx, by + 1))
            dxs.append(-(bx + sx))
            dys.append(-(by + sy))
    if len(dxs) < FLOW_MIN_PATCHES:
        return None, 0.0, len(dxs)
    mx = sorted(dxs)[len(dxs) // 2]
    my = sorted(dys)[len(dys) // 2]
    inliers = sum(1 for i in range(len(dxs))
                  if math.hypot(dxs[i] - mx, dys[i] - my) <= FLOW_INLIER_TOLERANCE)
    return (mx, my), inliers / len(dxs), len(dxs)


# --- Classifier -------------------------------------------------------------

CLASSIFIER = dict(staticSpeedLow=0.004, staticSpeedHigh=0.012,
                  bubbleSpeedLow=0.05, bubbleSpeedHigh=0.15,
                  bubbleDiameterLow=0.010, bubbleDiameterHigh=0.025,
                  upwardLow=0.35, upwardHigh=0.80,
                  straightnessLow=0.55, straightnessHigh=0.90,
                  minimumObservations=5, minimumConfidenceMargin=0.12)


def ramp(value, low, high):
    if high <= low:
        return 1.0 if value >= high else 0.0
    return min(1.0, max(0.0, (value - low) / (high - low)))


def fuzzy_and(values):
    return min(max(0.0, min(1.0, v)) for v in values) if values else 0.0


def classify(speed, diameter, straightness, upward, observations, in_plane=1.0):
    c = CLASSIFIER
    obs = ramp(observations, c["minimumObservations"], c["minimumObservations"] * 2)
    reliability = min(1.0, max(0.0, in_plane))
    up = 0.5 + (ramp(upward, c["upwardLow"], c["upwardHigh"]) - 0.5) * reliability
    static = 1 - ramp(speed, c["staticSpeedLow"], c["staticSpeedHigh"])
    size = ramp(diameter, c["bubbleDiameterLow"], c["bubbleDiameterHigh"])
    fast = ramp(speed, c["bubbleSpeedLow"], c["bubbleSpeedHigh"])
    straight = ramp(straightness, c["straightnessLow"], c["straightnessHigh"])

    scores = {
        "staticDefect": static,
        "risingBubble": fuzzy_and([up, straight, max(size, fast), 1 - static]),
        "suspendedSpeck": fuzzy_and([1 - up, 1 - size, 1 - straight, 1 - static, obs]),
    }
    ranked = sorted(scores.items(), key=lambda kv: (-kv[1], kv[0]))
    best, second = ranked[0], ranked[1][1]
    margin = best[1] - second
    if best[0] in ("risingBubble", "suspendedSpeck"):
        margin *= 0.5 + 0.5 * reliability
    if margin < c["minimumConfidenceMargin"] or best[1] <= 0:
        return "ambiguous", margin
    return best[0], margin


def check_phase_3c():
    failures = []

    def check(name, condition, detail):
        print(f"  [{'ok  ' if condition else 'FAIL'}] {name}: {detail}")
        if not condition:
            failures.append(name)

    print()
    print("Phase 3C: flow, tracking and classification")
    print()

    width, height, fps = 192, 144, 30.0
    marks = dict(
        scratches=[(0.10, 0.20, 0.90, 0.26, 0.40, 2.0),
                   (0.15, 0.70, 0.85, 0.62, 0.35, 2.0),
                   (0.30, 0.10, 0.36, 0.90, 0.30, 2.0)],
        blobs=[(0.25, 0.45, 4, 0.5), (0.70, 0.55, 5, 0.45), (0.50, 0.80, 3, 0.4)],
    )

    def scene(**kw):
        s = dict(w=width, h=height, base=0.30, sigma=0.01, seed=77)
        s.update(marks)
        s.update(kw)
        return s

    baseline = 9
    reference = render(scene(), 2.0, 60)

    # Sign: content moving right must read as positive.
    right = render(scene(tx=0.05), 2.0 + baseline / fps, 60 + baseline)
    ref_right = render(scene(tx=0.05), 2.0, 60)
    got, confidence, used = measure_displacement(right, ref_right, 0.01)
    check("pan right reads positive", got is not None and got[0] > 0,
          f"dx {got[0]:+.2f} px over {baseline} frames" if got else "refused")

    left = render(scene(tx=-0.05), 2.0 + baseline / fps, 60 + baseline)
    ref_left = render(scene(tx=-0.05), 2.0, 60)
    got_left, _, _ = measure_displacement(left, ref_left, 0.01)
    check("pan left reads negative", got_left is not None and got_left[0] < 0,
          f"dx {got_left[0]:+.2f} px" if got_left else "refused")

    # Accuracy over a multi-frame baseline.
    truth = 0.05 * width * baseline / fps
    error = abs(got[0] - truth) / truth if got else 1
    check("pan magnitude within 15%", error < 0.15,
          f"measured {got[0]:.2f} px vs {truth:.2f} px ({error * 100:.1f}%)")

    still = render(scene(), 2.0 + baseline / fps, 60 + baseline)
    got_still, conf_still, _ = measure_displacement(still, reference, 0.01)
    check("still scene reads still",
          got_still is not None and math.hypot(*got_still) < 0.5,
          f"{got_still} confidence {conf_still:.2f}")

    # A featureless sample has nothing to match, and must say so.
    flat = dict(w=width, h=height, base=0.30, sigma=0.01, seed=77, tx=0.05)
    got_flat, _, used_flat = measure_displacement(
        render(flat, 2.0 + baseline / fps, 60 + baseline), render(flat, 2.0, 60), 0.01
    )
    check("featureless scene refuses", got_flat is None,
          f"{used_flat} patches passed the gate")

    # Classification, at the shipping region size.
    print()
    cases = [
        ("static scratch",           "staticDefect",   dict(speed=0.001, diameter=0.004, straightness=0.3,  upward=0.0,  observations=20)),
        ("stationary bubble",        "staticDefect",   dict(speed=0.002, diameter=0.020, straightness=0.2,  upward=0.1,  observations=20)),
        ("large fast rising bubble", "risingBubble",   dict(speed=0.150, diameter=0.028, straightness=0.98, upward=0.97, observations=15)),
        ("small slow rising bubble", "risingBubble",   dict(speed=0.060, diameter=0.014, straightness=0.95, upward=0.92, observations=12)),
        ("small slow curved speck",  "suspendedSpeck", dict(speed=0.020, diameter=0.003, straightness=0.45, upward=0.05, observations=20)),
        ("sinking speck",            "suspendedSpeck", dict(speed=0.025, diameter=0.004, straightness=0.80, upward=-0.9, observations=15)),
        ("small slow upward drift",  "ambiguous",      dict(speed=0.030, diameter=0.009, straightness=0.85, upward=0.75, observations=12)),
        ("too few sightings",        "ambiguous",      dict(speed=0.020, diameter=0.003, straightness=0.4,  upward=0.0,  observations=3)),
    ]
    for name, expected, kw in cases:
        verdict, margin = classify(**kw)
        check(name, verdict == expected, f"{verdict} (confidence {margin:.3f})")

    upright = classify(speed=0.060, diameter=0.014, straightness=0.95, upward=0.92,
                       observations=12, in_plane=1.0)[1]
    flat_phone = classify(speed=0.060, diameter=0.014, straightness=0.95, upward=0.92,
                          observations=12, in_plane=0.05)[1]
    check("confidence falls when gravity leaves the image plane",
          flat_phone < upright, f"{upright:.3f} upright vs {flat_phone:.3f} flat")

    return failures



# ---------------------------------------------------------------------------
# Phase 3D: index, curve fitting and the NTU gate.
# ---------------------------------------------------------------------------

INDEX_WEIGHTS = dict(bulk=0.55, excess=0.25, active=0.15, specks=0.05, speckScale=0.0002)
INDEX_SCALE = 1000.0


def scattering_index(residual, speck_rate_per_megapixel, weights=None):
    """Mirrors RelativeScatteringIndex.make, with the summary's derived terms."""
    w = weights or INDEX_WEIGHTS
    excess = residual * 1.6
    active = residual * 0.4
    return INDEX_SCALE * (w["bulk"] * max(0.0, residual)
                          + w["excess"] * max(0.0, excess)
                          + w["active"] * max(0.0, active)
                          + w["specks"] * w["speckScale"] * max(0.0, speck_rate_per_megapixel))


def monotone_hermite_slopes(knots):
    n = len(knots)
    if n < 2:
        return [0.0] * n
    h = [knots[i + 1][0] - knots[i][0] for i in range(n - 1)]
    d = [(knots[i + 1][1] - knots[i][1]) / h[i] if h[i] > 0 else 0.0 for i in range(n - 1)]
    m = [0.0] * n
    m[0] = d[0]
    m[n - 1] = d[n - 2]
    for i in range(1, n - 1):
        if d[i - 1] * d[i] <= 0:
            m[i] = 0.0
        else:
            w1 = 2 * h[i] + h[i - 1]
            w2 = h[i] + 2 * h[i - 1]
            m[i] = (w1 + w2) / (w1 / d[i - 1] + w2 / d[i])
    for i in (0, n - 1):
        s = d[0] if i == 0 else d[n - 2]
        if s == 0:
            m[i] = 0.0
        elif m[i] / s > 3:
            m[i] = 3 * s
        elif m[i] < 0:
            m[i] = 0.0
    return m


def evaluate_cubic(x, knots, slopes):
    if x <= knots[0][0]:
        return knots[0][1]
    if x >= knots[-1][0]:
        return knots[-1][1]
    for i in range(1, len(knots)):
        if x <= knots[i][0]:
            lo, hi = knots[i - 1], knots[i]
            h = hi[0] - lo[0]
            if h <= 0:
                return lo[1]
            t = (x - lo[0]) / h
            t2, t3 = t * t, t * t * t
            return ((2 * t3 - 3 * t2 + 1) * lo[1] + (t3 - 2 * t2 + t) * h * slopes[i - 1]
                    + (-2 * t3 + 3 * t2) * hi[1] + (t3 - t2) * h * slopes[i])
    return knots[-1][1]


def evaluate_linear(x, knots):
    if x <= knots[0][0]:
        return knots[0][1]
    if x >= knots[-1][0]:
        return knots[-1][1]
    for i in range(1, len(knots)):
        if x <= knots[i][0]:
            lo, hi = knots[i - 1], knots[i]
            span = hi[0] - lo[0]
            return lo[1] + (hi[1] - lo[1]) * (x - lo[0]) / span if span > 0 else lo[1]
    return knots[-1][1]


def fit_power_law(knots):
    usable = [(x, y) for x, y in knots if x > 0 and y > 0]
    if len(usable) < 2:
        return None
    lx = [math.log(p[0]) for p in usable]
    ly = [math.log(p[1]) for p in usable]
    n = len(usable)
    mx, my = sum(lx) / n, sum(ly) / n
    cov = sum((lx[i] - mx) * (ly[i] - my) for i in range(n))
    var = sum((lx[i] - mx) ** 2 for i in range(n))
    if var <= 0:
        return None
    slope = cov / var
    return (my - slope * mx, slope) if slope > 0 else None


CURVE_BUILDERS = [
    ("piecewise linear", lambda k: k, lambda x, f: evaluate_linear(x, f)),
    ("monotone cubic", lambda k: (k, monotone_hermite_slopes(k)),
     lambda x, f: evaluate_cubic(x, f[0], f[1])),
    ("power law", fit_power_law,
     lambda x, f: math.exp(f[0] + f[1] * math.log(x)) if x > 0 else 0.0),
]


def leave_one_concentration_out(knots):
    """Cross-validated RMSE per candidate. Interpolation only, as the Swift does."""
    scores = {}
    for name, build, evaluate in CURVE_BUILDERS:
        residuals = []
        for held in range(len(knots)):
            remaining = [k for i, k in enumerate(knots) if i != held]
            fitted = build(remaining)
            if fitted is None:
                continue
            x = knots[held][0]
            if not (remaining[0][0] < x < remaining[-1][0]):
                continue
            residuals.append(evaluate(x, fitted) - knots[held][1])
        scores[name] = ((sum(r * r for r in residuals) / len(residuals)) ** 0.5
                        if residuals else None)
    return scores


def check_phase_3d():
    failures = []

    def check(name, condition, detail):
        print(f"  [{'ok  ' if condition else 'FAIL'}] {name}: {detail}")
        if not condition:
            failures.append(name)

    print()
    print("Phase 3D: index, calibration and the NTU gate")
    print()

    # The index must rise with scattering and never be dominated by the counts.
    values = [scattering_index(r * 0.001, 2 / 0.456) for r in range(0, 200)]
    check("index rises monotonically", all(values[i] >= values[i - 1] for i in range(1, len(values))),
          f"{values[0]:.3f} to {values[-1]:.3f}")

    clear_many = scattering_index(0.001, 500 / 0.456)
    cloudy_none = scattering_index(0.05, 0)
    check("counts cannot outrank the bulk channel", clear_many < cloudy_none,
          f"clear sample with 500 specks/s reads {clear_many:.1f}, "
          f"cloudy with none reads {cloudy_none:.1f}")

    shares = []
    for residual, rate in [(0.001, 1), (0.012, 12), (0.12, 60)]:
        total = scattering_index(residual, rate / 0.456)
        speck = INDEX_SCALE * INDEX_WEIGHTS["specks"] * INDEX_WEIGHTS["speckScale"] * rate / 0.456
        shares.append(speck / total)
    check("the speck term stays secondary", max(shares) < 0.05,
          f"largest share {max(shares) * 100:.1f}%")

    # Curve selection.
    saturating = [(2, 0), (22, 1), (92, 5), (160, 10), (265, 20), (520, 50)]
    scores = leave_one_concentration_out(saturating)
    best = min((v, n) for n, v in scores.items() if v is not None)
    check("saturating data selects the monotone cubic", best[1] == "monotone cubic",
          ", ".join(f"{n} {v:.3f}" for n, v in scores.items() if v is not None))

    power = [(1, 0)] + [(40 * (n ** 0.8), n) for n in (1, 5, 10, 20, 50)]
    scores = leave_one_concentration_out(power)
    best = min((v, n) for n, v in scores.items() if v is not None)
    check("power-law data selects the power law", best[1] == "power law",
          ", ".join(f"{n} {v:.4f}" for n, v in scores.items() if v is not None))

    # Monotone cubic must not overshoot on awkward spacing.
    awkward = [(2, 0), (22, 1), (92, 5), (95, 5.2), (520, 50)]
    slopes = monotone_hermite_slopes(awkward)
    samples = [evaluate_cubic(2 + (520 - 2) * i / 500, awkward, slopes) for i in range(501)]
    check("monotone cubic never overshoots the data",
          min(samples) >= -1e-9 and max(samples) <= 50 + 1e-9
          and all(samples[i] >= samples[i - 1] - 1e-9 for i in range(1, len(samples))),
          f"range [{min(samples):.4f}, {max(samples):.4f}]")

    # Clamping, not extrapolation.
    slopes = monotone_hermite_slopes(saturating)
    check("evaluation clamps outside the fitted range",
          evaluate_cubic(-100, saturating, slopes) == 0
          and evaluate_cubic(10_000, saturating, slopes) == 50,
          "below reads 0 NTU, above reads 50 NTU, neither is reported as a measurement")

    # An estimate inside the range lands between the bracketing standards.
    estimate = evaluate_cubic(150, saturating, slopes)
    check("an in-range index interpolates between its neighbours", 5 < estimate < 10,
          f"index 150 -> {estimate:.3f} NTU (between the 5 and 10 NTU standards)")

    return failures


if __name__ == "__main__":
    import sys
    sys.exit(main())

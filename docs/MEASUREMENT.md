# Measurement: devices, protocol, range, interferences and uncertainty

> **Optical screening only — not a drinking-water safety test.** Nothing in this
> document should be read as a claim that Turbid establishes whether water is
> safe to drink.

## Supported devices

**Requirement: an iPhone running iOS 17 or later, in portrait, using a rear
camera.** Orientation is pinned because a measurement needs a fixed optical
path.

Turbid does not keep a list of supported iPhone models, and deliberately so. A
model list goes stale, and it says nothing about what a given device can
actually do. Instead every rear camera is probed at runtime and scored on what
it reports:

| Requirement | Why | If unmet |
|---|---|---|
| Has a torch, available, `.on` supported | The torch is the illumination source | Camera excluded |
| Can lock focus | An autofocus hunt mid-window changes the optical path | Camera excluded |
| Can lock exposure duration and ISO | Auto-exposure would track the sample's own brightness | Camera excluded |
| Can lock white-balance gains | A drifting white balance changes the luma channel | Camera excluded |
| Offers a bi-planar YUV format at the required size and rate | The analyzer reads the luma plane directly | Camera excluded |

Among the cameras that survive, the shortest minimum focus distance scores
highest, and a single physical sensor is preferred over a virtual device: a
virtual device can switch its constituent camera mid-measurement and silently
change the optics.

**If no camera qualifies, Turbid says so and stops.** It does not fall back to a
degraded measurement. The reason each rejected camera failed is recorded and
shown in the diagnostics sheet.

**Fallback behaviour that does exist:**

- Torch below the requested maximum — `maxAvailableTorchLevel` drops under
  thermal load. The delivered level is read back rather than assumed, recorded
  in the calibration binding, and a shortfall is surfaced. A calibration made at
  full output will refuse a measurement made at a reduced one.
- Warm-up timeout — if the camera never stops adjusting within the bounded
  wait, the run continues and the fact is logged; the exposure-stability gate
  catches the consequence.
- Simulator — no camera exists, so a synthetic frame source stands in. Debug
  builds on the Simulator only, and every surface showing a result from it
  carries the simulated-data banner.

## The measurement protocol

Version 2. The version is part of every calibration binding: changing any of
these durations invalidates every calibration fitted under the old one.

| Stage | Duration | What happens |
|---|---|---|
| Alignment | until the user starts | Torch on, controls free, per-frame gates drive live prompts |
| Torch settling | 1.5 s | Controls locked; the sensor and ISP settle on the illuminated scene |
| Background acquisition | 2.0 s | A per-pixel temporal median of stationary marks and reflections |
| Measurement | 9.0 s | The frames the result is computed from |
| **Total** | **12.5 s** | |

Stage boundaries follow frame presentation timestamps, never a wall clock or a
frame count. A dropped frame, a thermal throttle or a slow analyzer shortens the
*number of frames* in a stage, never the stage.

There is no ambient (torch-off) reference block. The field exists in
`CaptureProtocol` for a fixture protocol that subtracts one, but screening sets
it to zero: nothing in the analysis consumes an ambient reading, and a stage
labelled *ambient* captured with the torch on would put a false record in every
reading.

**Capture settings**: 1920×1080 at 30 fps where available, full-range bi-planar
YUV, set as an explicit `activeFormat` under `.inputPriority` so the system
cannot substitute another format behind a preset. HDR off — its scene-dependent
tone curve breaks the relation between pixel value and scattered light. Video
stabilisation off — it warps pixels between frames, which the analyzer would
read as particle motion.

**Analysis region**: a centred rectangle covering about half the frame width,
biased below centre because the torch sits above the rear lens on every current
iPhone. An optical mask excludes the meniscus strip and the direct torch
reflection. Frames are analysed at capture resolution inside that region;
statistics and motion run on a heavily box-averaged plane, detection never does.

**Working distance**: 120 mm. This is the distance the camera selection is made
against — a camera whose minimum focus distance exceeds it is rejected — and the
setup checklist states it.

**Sample preparation**, as the app instructs: a clean, clear, colourless
container, wiped dry; let it stand a minute so coarse bubbles clear; a matte
dark background; a dim room; the phone rested against something at about the
working distance and held still; the outlined region filled with liquid only.

## What is reported

**Screening Mode** produces a **Relative Scattering Index** — dimensionless, on
an arbitrary scale, whose only guaranteed property is that more scattering
produces a larger number *under the same capture configuration*. It is not NTU
and is never presented as NTU. Results are comparable only between runs made
with the same phone, the same container and the same technique.

**Tracked particle events** are reported as *Visible particles (tracked)*: a
count of bright events the camera could resolve and follow, per second and per
second per megapixel of region. A speck visible for fifty frames is one event.
**This is not a particle concentration and cannot be converted to one.**

**Calibrated Fixture Mode** produces an NTU estimate, and only through a single
gate that requires all of:

1. Calibrated Fixture Mode selected;
2. a profile that exists, matches this app version's schema, and has not
   expired;
3. every discrete identity matching exactly — iPhone model, camera, camera type,
   capture width and height, pixel format, frame rate, analysis region, fixture,
   fixture geometry, container, and all nine algorithm versions;
4. every settled value within tolerance — focus 0.02, exposure 5%, ISO 5%,
   white-balance gains 0.05, torch level 0.02, fill volume 5%, working distance
   5%;
5. capture quality passing;
6. the index inside the calibrated range;
7. an uncertainty that can actually be computed.

Fail any of them and the reason is shown where the number would have been.

## Valid calibration range

**A calibration is only valid over the range its standards covered.** Outside
it, the fitted curve clamps, and a clamped value presented as a measurement
would be a fabrication — so *Below validated range* or *Above validated range*
is reported instead, with the bound.

A calibration requires, and Turbid refuses to fit without:

- a blank (0 NTU, or the water the standards were made up in);
- at least **four** certified standards above zero, spanning the intended range;
- at least **three** separate readings of each;
- every standard inside its expiry date;
- an index that rises monotonically across the standards;
- adjacent levels separated by at least three replicate standard deviations.

The curve is chosen from three monotone candidates — piecewise linear,
Fritsch–Carlson monotone cubic, and a power law fitted on logarithms — by
**leave-one-concentration-out cross validation**, not by fit quality. Every
candidate reproduces the points it was built from almost perfectly, and that
predicts nothing.

**Standards must be commercially prepared and certified.** Formazin is made from
hydrazine sulfate, which is acutely toxic and a suspected carcinogen. Turbid does
not provide preparation instructions and never will. Use bought standards —
formazin or a certified styrene-divinylbenzene equivalent — according to the
manufacturer's own safety, handling and disposal instructions.

**Calibrations expire.** Standards degrade, fixtures shift and phones age. Every
profile carries an end date, and the app warns thirty days ahead.

## Known interferences

| Interference | Effect | What Turbid does |
|---|---|---|
| **Colour** | A tinted sample absorbs as well as scatters, reading differently from a colourless one at the same turbidity | Nothing. Documented only. |
| **Ambient light** | Light other than the torch reaching the region changes the illumination the calibration was made under | Nothing measures it. The checklist asks for a dim room. |
| **Bubbles** | Bright, round and moving — the main false positive | Classified by size, speed, straightness and direction against gravity, and rejected; counted separately |
| **Container marks, scratches, fixed reflections** | Bright and stationary | Removed by the background model; the residual is what is measured |
| **Specular torch reflection** | Saturates part of the region and breaks monotonicity | Masked out by geometry, and the saturation and hotspot gates reject what the mask misses |
| **Phone movement** | Reads as particle motion, and moves the background | Rejected above ~5% of frame width per second by the motion gate; slower creep is **not** caught |
| **Settling during the window** | The sample changes while being measured | Nothing. The 9 s window is short enough that it is usually small, and the sub-window repeatability figure exposes it when it is not. |
| **Thermal throttling** | Torch output and frame rate fall mid-run | Thermal state and system pressure stop a run in progress; the delivered torch level is recorded |
| **Condensation on the container** | Scatters light itself | Nothing. The checklist asks for a dry outside. |
| **Dissolved colour vs suspended solids** | Indistinguishable optically at one wavelength | Nothing. This is a property of the method, not a defect. |

## Uncertainty

**Screening Mode reports no uncertainty**, because there is nothing to express
it against: the index has arbitrary units. What it does report is
**repeatability** — the relative spread of the index across the overlapping
sub-windows of the same run — and confidence, which is the *smaller* of the
capture-quality confidence and that repeatability. A result is only as good as
the worse of "was this captured well" and "would it come out the same again".

**Calibrated Fixture Mode reports an expanded uncertainty in NTU**, combining
three terms in quadrature:

- **model error** — the cross-validated RMSE, the honest answer to "how wrong is
  the shape of this curve" when asked to predict a concentration it never saw;
- **measurement error** — the replicate spread at the nearest calibrated level,
  converted to NTU through the curve's local slope;
- **the standards' own certificate tolerance**, as a floor. A calibration can
  never be more certain than the standards it was made from.

Reported at a coverage factor of 2, which is the usual convention for an
interval intended to contain the true value about 95% of the time — *under the
assumption that these three terms are the whole story, which for a screening
instrument they are not.* Ambient light, sample colour, settling and container
variation are not in the budget.

**No empirical accuracy is claimed anywhere in this project, because none has
been measured.** Every threshold, every index weight and every clarity band is
an engineering starting point.

## Limitations

- **An iPhone is not a nephelometer.** EPA Method 180.1 specifies a defined
  light source, a defined 90° detection geometry and a defined optical path.
  A phone has none of them, and Turbid does not claim to implement that method.
- **Only particles the camera can resolve are tracked.** Colloidal and
  microscopic material, which dominates real turbidity, is invisible to it. The
  bulk scattering channel — not the particle count — is what carries the
  measurement, and it is what a calibration maps to NTU.
- **A slow container creep is not caught by any gate.** Below roughly 5% of the
  frame width per second the motion gate does not fire. The background-stability
  number would show it, but that number cannot tell a creeping container from a
  sample full of drifting particles, so it is reported rather than gated on.
- **Results are not comparable across phones, containers or techniques**, and in
  Screening Mode not across sessions either.
- **The three clarity states are Turbid's own presentation bands**, versioned and
  recorded on every reading. They are not health thresholds, not regulatory
  limits, and not a potability determination.
- **The fixture is asserted, not sensed.** In Calibrated Fixture Mode, choosing
  a profile *is* the claim that the fixture has been reassembled. Everything the
  phone can verify still is.
- **None of this has been validated against real samples**, and no part of the
  code has been compiled or run. See the README.

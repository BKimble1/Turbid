# Lucid

Lucid is an iPhone app that uses the camera and torch to screen the **optical
clarity** of a water sample.

> **Optical screening only — not a drinking-water safety test.**
> Lucid cannot detect bacteria, viruses, dissolved chemicals, heavy metals,
> PFAS or toxins, and it cannot tell you whether water is safe to drink.

## Build status

**Phase 3C of 4 — optical flow, vector tracking and bubble rejection.**

On top of the Phase 3B detector, this build adds motion: robust global-motion
estimation, a bounded multi-object tracker with per-axis Kalman filters,
multi-feature track classification, and temporal aggregation over overlapping
windows with a repeatability figure. It distinguishes stationary defects,
rising bubbles and suspended specks — imperfectly, and says so. There is still
**no NTU**.

| Phase | Scope | Status |
|-------|-------|--------|
| 1 | SwiftUI scaffold, camera permission, state machine, tests | Complete |
| 2 | AVFoundation capture session, camera selection, torch, control locking | Complete |
| 3A | Analysis region, capture protocol, quality gates, synthetic harness | Complete |
| 3B | Background subtraction and bright-speck detection | Complete |
| 3C | Optical flow, vector tracking, bubble rejection | Complete |
| 3D | Relative score, calibration, NTU gating, validation | Not started |
| 4 | Dashboard, advanced metrics, charts, calibration UI | Not started |

## Requirements

- Xcode 15 or later
- iOS 17.0 or later deployment target
- Swift language mode 5

## How to run it

1. On a Mac, open **`Lucid.xcodeproj`** by double-clicking it in Finder.
2. In the toolbar, choose a run destination — **any iPhone 15 or newer
   Simulator** is fine for Phase 1.
3. Press **⌘R** to run. You should see the Lucid screen with the camera-access
   status and a **Start Setup** button.
4. Press **⌘U** to run the tests. The test navigator (**⌘6**) should show all
   tests passing.
5. If Xcode asks about signing, select the **Lucid** target → **Signing &
   Capabilities** → tick *Automatically manage signing* and choose your Apple ID
   team. You may also need to change the bundle identifier from
   `com.lucid.Lucid` to something unique to you.

### What you should see

- **On the Simulator**: the home screen plus a purple **"SIMULATED DATA — NOT A
  MEASUREMENT"** section showing what the three result states will look like.
  The Simulator has no camera, so it runs a stub pipeline: *Start Setup* opens
  the measurement screen with a "Camera preview unavailable" placeholder.
- **On a physical iPhone**: *Start Setup* asks for camera permission, picks a
  rear camera, and opens the measurement screen with a **live preview**.
  *Start Measurement* turns the torch on at full power, lets the camera settle,
  locks focus/exposure/white balance, and then stops with *"Frame analysis is
  not part of this build."* — the correct Phase 2 outcome. The torch turns off.
  The wrench button (debug builds) opens **Capture Diagnostics**, showing the
  selected camera, its minimum focus distance, the active format, the locked
  control values, torch level, frame rate, dropped frames and thermal state.

## Regenerating the Xcode project

`Lucid.xcodeproj` is generated from the file tree rather than hand-edited, so
the project file and the sources cannot drift apart. After adding, renaming or
deleting a Swift file:

```sh
sh Tools/check.sh
```

That runs the source checks, regenerates the project and validates it. It needs
only Python 3 — no Xcode. Anyone who prefers XcodeGen can run
`xcodegen generate` against `project.yml` instead.

## Layout

```
Lucid/
  App/        LucidApp, AppEnvironment (dependency container)
  Domain/     Pure, hardware-free logic: measurement state machine, camera and
              format selection, control-lock clamping, capture lifecycle,
              frame-timing statistics, published snapshot types
    Analysis/ Region and optical mask, luma normalization and statistics,
              capture-protocol timeline, quality gates, frame observations,
              background model, band-pass filter, connected components,
              candidate features, bulk scattering metrics
      Tracking/ Global flow and gravity, constant-velocity filter, track model,
                multi-object tracker, classifier, metrics, window aggregation
  Services/   Camera authorization, settings, runtime environment, test fakes
  Camera/     The AVFoundation boundary: capability probing, CameraService,
              preview layer
  Analysis/   Frame analyzer, speck detector, gravity provider, pixel-buffer
              luma extraction, and the seeded synthetic-frame harness
  Features/   Measurement view model and views, diagnostics, Simulator demo
  Shared/     Design tokens, reusable components, OSLog categories
  Resources/  Asset catalogue
LucidTests/   Unit tests
Tools/        Project generator, project validator, source checks,
              Python cross-check of the analysis numerics
```

Selection, clamping, lifecycle and timing logic all live in `Domain/` as plain
values, so they are unit-tested without hardware. `Camera/` is the only place
that touches AVFoundation, and it publishes value types only — no
`CMSampleBuffer` or `CVPixelBuffer` crosses that boundary.

## Analysis pipeline (Phase 3A)

**No transfer function is inverted.** A video buffer is the output of the
camera's image-signal processor, not a radiance measurement: demosaicing, black
level, lens shading, noise reduction and a possibly scene-dependent tone curve
all sit between the photons and the pixel. Applying a nominal inverse would
produce numbers that *look* like linear radiance while being wrong by an
unknown factor. Lucid treats the normalized value as a repeatable **relative**
signal and gets absolute meaning from end-to-end calibration (Phase 3D). The
one property this requires is monotonicity, which is why clipping is a hard
rejection rather than a warning.

**Two working scales.** Statistics and motion run on a heavily box-averaged
64-pixel plane, where individual specks are averaged away and what remains is
whole-frame behaviour. Detection will run on the region at capture resolution:
downscaling before speck detection would destroy exactly the point-like signal
the measurement depends on.

**Both cross-frame metrics subtract a noise floor**, and neither works without
it:

- Sensor noise of standard deviation σ produces a Laplacian variance of `20σ²`
  on its own. At realistic noise levels that is more than an order of magnitude
  above any usable focus threshold, so an uncorrected focus gate can never fire
  — a completely defocused frame scores as sharp.
- Two consecutive frames of a perfectly still scene differ by their independent
  noise, with mean absolute difference `1.128σ`. That floor is larger than the
  signal from a visible camera pan, so an uncorrected motion gate cannot tell a
  still phone from a moving one.

`Tools/analysis_reference.py` is a Python port of these numerics that checks the
thresholds actually behave as claimed. Run it with `sh Tools/check.sh`.

**Three verdicts, not two.** A window is `usable`, `usableWithLowConfidence`, or
`invalid`. Low confidence and invalid are different things: a low-confidence
window produced a number that should be trusted less, an invalid one produced no
number at all. Confidence is the *minimum* headroom across the gates, not an
average — a window is only as trustworthy as its weakest measurement.

Every threshold is an engineering starting point, versioned so a measurement
records which set produced it. None has been validated against real samples.
They govern capture quality only and carry no health or regulatory meaning.

## Tracking (Phase 3C)

**Global motion is measured by sparse block matching, not by Vision.** The
design calls for `VNGenerateOpticalFlowRequest`, and this deviates from it
deliberately. A dense flow field is far more than the pipeline consumes — the
only thing taken from it is one robust median vector — and, more importantly,
Vision's optical-flow request is a *targeted* request whose result sign depends
on which of the two frames is the targeted one. That convention cannot be
confirmed without running it on a device, and a sign error would not fail
loudly: compensation would **double** the apparent camera motion instead of
removing it, and every velocity downstream would be wrong in a way that still
looked plausible. The block matcher's sign is pinned by a test. Adopting Vision
remains reasonable once it can be measured on hardware against this baseline;
the estimator sits behind a protocol so it can be swapped without touching the
tracker.

Three things make the matcher work, and it does not work without any of them:

- **A multi-frame baseline.** Camera drift is sub-pixel *per frame* — a 10 px/s
  drift moves the scene by a third of a pixel between consecutive frames, below
  what block matching can resolve. Matching against a reference held for several
  frames turns that into a few pixels. Measured accuracy on synthetic pans is
  within 3% of truth; per-frame matching was off by 30% and, for vertical
  motion, produced nonsense.
- **A Shi-Tomasi gate.** A patch containing only a horizontal scratch cannot say
  anything about horizontal displacement — the aperture problem — and unchecked
  it votes with an arbitrary value.
- **A robust median with an inlier count.** Patches spoiled by a passing
  particle are a minority. The fraction agreeing with the median is the
  confidence, and a low-confidence estimate is never subtracted from anything.

A clean container in a dark shroud may have too little texture for any patch to
pass the gate. That is reported as zero confidence, not guessed at.

**Classification uses several graded features, never one cutoff.** Bubbles and
particles overlap in every individual feature: there are small slow bubbles and
large fast specks. Speed, size, straightness and direction each contribute a
graded score; the winner must beat the runner-up by a margin, and anything that
does not is called **ambiguous** and counted separately. No separation is
claimed to be clean, because there is not one.

Direction only means something if gravity lies in the image plane. With the
phone flat and the camera looking down, a rising bubble barely moves in frame,
so the direction term is blended towards neutral by exactly how much of gravity
projects into the plane, and the confidence is reduced with it.

**Counts are events, not concentrations.** A speck visible for fifty frames is
one event. These are reported as *Visible particles (tracked)*; Phase 3D
calibrates the bulk scattering channel, not these counts.

## Detection pipeline (Phase 3B)

For a normalized frame `I` and background model `B`:

1. `D = I - B`, **signed**. Clipping at zero first would make the noise
   one-sided and break the robust noise estimate everything downstream is
   scaled by.
2. `P = max(D, 0)` feeds the **bulk** channel — total excess light, not
   band-passed, because that is exactly what a bulk scattering measurement
   wants.
3. `G = DoG(D)` feeds the **discrete** channel. The band-pass removes anything
   varying slowly across the frame, which is why an illumination gradient or a
   whole-frame exposure change produces no candidates at all.
4. `sigma = 1.4826 x MAD(G)`, threshold `T = 5 sigma`. Measured from each
   frame's own noise: a fixed pixel threshold would be far too strict at low
   ISO and far too permissive at high ISO.
5. Components of `G > T` are extracted and filtered on **normalized** features
   — area, diameter and distance as fractions of the region, never pixel
   counts, so the same configuration means the same physical thing at any
   capture resolution.

**The bulk channel, not the speck count, is what Phase 3D will calibrate.**
Turbidity is a bulk optical measurement and a camera cannot resolve or count the
microscopic and colloidal material that dominates it. Candidate counts are
reported as *Visible particles (tracked)*, never as a concentration.

**The background model.** A per-pixel temporal median over the acquisition
frames, because a particle drifting through a pixel affects a minority of the
samples and a median ignores a minority. The retained samples are **spread
across the whole acquisition window**: nine consecutive frames at 30 fps span
only 0.3 s, in which a slow speck barely moves, so it would sit in a majority of
the samples at its own position and be absorbed into the very model it is meant
to be measured against. The running update is sign-based (a stochastic median
tracker, so one bright frame moves the model by one step rather than by its own
brightness) and runs far more slowly at pixels currently classified as
foreground.

Calibration data for the thresholds, and the checks that they behave as claimed,
are in `Tools/analysis_reference.py`.

## Measurement protocol (Phase 2)

The capture path is deliberately pinned so that a future calibration can be
bound to it:

- **Camera**: chosen by probed capability, never by model name. A camera must
  have a torch and be able to lock focus, exposure and white balance, or it is
  excluded. Among the survivors, the shortest minimum focus distance and a
  single physical (non-virtual) sensor score highest — a virtual device can
  switch its constituent camera mid-measurement and silently change the optical
  path.
- **Format**: 1920×1080 at 30 fps, full-range bi-planar YUV where available, set
  as an explicit `activeFormat` under `.inputPriority` so the system cannot
  substitute another format behind a session preset. HDR is disabled: its
  scene-dependent tone curve would break the relation between pixel value and
  scattered light. Video stabilisation is disabled: it warps pixels between
  frames, which the analyzer would read as particle motion.
- **Sequence**: torch on → warm up (bounded) → lock focus, exposure and ISO,
  and white-balance gains → record what actually locked.
- **Torch**: requested at `maxAvailableTorchLevel`, which is the maximum
  available *right now*. Under thermal duress it is below 1.0, so the delivered
  level is read back rather than assumed, and a shortfall is surfaced.
- **Frame timing**: measured from real presentation timestamps in a fixed-size
  ring buffer. A camera throttling to 24 fps is reported as 24 fps.

## Privacy

The only privacy permission Lucid declares is `NSCameraUsageDescription`. iOS
has no separate torch permission — the torch is covered by camera access. Video
is processed on device; nothing is written to disk or transmitted.

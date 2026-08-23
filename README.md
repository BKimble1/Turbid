# Lucid

Lucid is an iPhone app that uses the camera and torch to screen the **optical
clarity** of a water sample.

> **Optical screening only — not a drinking-water safety test.**
> Lucid cannot detect bacteria, viruses, dissolved chemicals, heavy metals,
> PFAS or toxins, and it cannot tell you whether water is safe to drink.

## Build status

**Phase 4 of 4 — the complete interface, wired to the real pipeline.**

Camera frames now reach the analyzer and come back as a reading. The app has
onboarding with the full scientific disclosure, a setup step with live quality
prompts, a measurement flow with stage progress and a live graph, a Quick View
result, a Deep Dive with every number and version behind it, and a guided
calibration workflow against certified standards.

| Phase | Scope | Status |
|-------|-------|--------|
| 1 | SwiftUI scaffold, camera permission, state machine, tests | Complete |
| 2 | AVFoundation capture session, camera selection, torch, control locking | Complete |
| 3A | Analysis region, capture protocol, quality gates, synthetic harness | Complete |
| 3B | Background subtraction and bright-speck detection | Complete |
| 3C | Optical flow, vector tracking, bubble rejection | Complete |
| 3D | Relative score, calibration, NTU gating, validation | Complete |
| 4 | Onboarding, setup, measurement, results, charts, calibration UI | Complete |
| — | Release readiness (see `docs/RELEASE.md`) | 5 of 11 done, 6 blocked on hardware |

**Nothing in this repository has been compiled or run.** There is no Swift
toolchain and no Xcode on the machine it was written on. What that means, and
what stands in for a compiler, is set out under *What has and has not been
verified* below.

## Documentation

- **`docs/MEASUREMENT.md`** — supported devices and fallback behaviour, the
  capture protocol, what a valid calibration requires and over what range, the
  known interferences, how uncertainty is built, and the limitations.
- **`docs/ARCHITECTURE.md`** — how the pieces fit, where a frame goes, what is
  bounded by construction, and the full file inventory.
- **`docs/RELEASE.md`** — the release-quality checklist item by item, the App
  Store privacy and copy review, and exactly what to do on a Mac with a device
  and certified standards.

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

**On first launch**, the disclosure screen: what Lucid measures, the list of
things it cannot detect, why there is usually no NTU number, and how to get a
usable reading. It has to be acknowledged before the app is usable, and it
stays reachable from the home screen afterwards.

**On the Simulator**, there is no camera, so a synthetic frame source stands in
for the sensor. Frames are generated, written into a real bi-planar pixel
buffer, and travel the production path — the same extractor, analyzer and
quality gates a physical iPhone uses. A picker on the capture screen chooses
what the simulated sample contains (almost nothing, a few particles, many
particles, or a phone that is not being held still), and every screen showing a
result from those frames carries the purple **"SIMULATED DATA — NOT A
MEASUREMENT"** banner. That substitution requires a debug build *and* the
Simulator, so a shipped binary on a phone can never take it.

**On a physical iPhone**: *Start Setup* asks for camera permission, picks a rear
camera, turns the torch on and opens the setup step with a live preview, an
outlined analysis region, the checklist, and live prompts — *Hold steady*,
*Reduce glare*, *Sample too dark* — driven by the same per-frame gates the
analyzer applies. *Start Measurement* locks focus, exposure and white balance,
then runs the 12.5-second protocol with a stage-by-stage progress bar and a live
graph of the relative scattering index. At the end the torch goes off and the
result appears.

The wrench button (debug builds) opens **Capture Diagnostics**: the selected
camera, its minimum focus distance, the active format, the locked control
values, torch level, frame rate, dropped frames and thermal state.

### Running a measurement on a device

1. Fill a clean, clear, colourless container and let it stand a minute so
   bubbles rise out.
2. Put something matte and dark behind it, and dim the room. The torch should be
   the main light on the sample.
3. Open Lucid, tap **Start Setup**, and line the container up so the outlined
   region is filled with liquid only — no rim, no meniscus, no label.
4. Wait for **View looks good**, rest the phone against something, and tap
   **Start Measurement**. Hold still for about thirteen seconds.
5. Read the result. Tap **Deep Dive** for the numbers, the gates that judged
   them, and the versions of everything that produced them.

## Continuous integration and TestFlight

`codemagic.yaml` defines three workflows: unit tests on a simulator (the fast
gate, on every push), the interface tests (slower — each one runs a real
12.5-second analysis), and a TestFlight build that signs, uploads and stops
short of store submission.

Three things have to exist before the TestFlight workflow can work, and only
the account holder can create them: an App Store Connect API key in Codemagic
named `LucidAppStoreKey`, a bundle identifier you own (`com.lucid.Lucid` is a
placeholder and will not sign), and an app record for it. The file marks both
places the identifier has to change, and a build step fails loudly if the two
drift apart.

The bundle identifier and development team are generator inputs
(`LUCID_BUNDLE_ID`, `LUCID_DEVELOPMENT_TEAM`), not tracked constants, so CI sets
them without editing a file.

## Regenerating the Xcode project

`Lucid.xcodeproj` is generated from the file tree rather than hand-edited, so
the project file and the sources cannot drift apart. After adding, renaming or
deleting a Swift file:

```sh
sh Tools/check.sh
```

That runs the source checks, the structural audit, the numeric reference, then
regenerates the project and validates it. Only the audit needs anything beyond a
stock Python 3:

```sh
python3 -m pip install tree_sitter tree_sitter_swift
```

Without it the audit skips itself and says so, and the rest still runs. The app
icon is drawn by `python3 Tools/make_app_icon.py` (needs Pillow) and committed;
the project validator fails if it goes missing, because a simulator build only
warns about a missing icon and the rejection arrives at upload time.

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
   Calibration/ Relative scattering index, certified standards and replicates,
                monotone mappings, cross-validated fitter, uncertainty model,
                hardware binding and compatibility, NTU gate, clarity policy,
                turbidity reading, versioned persistence
  Services/   Camera authorization, settings, runtime environment, test fakes
  Camera/     The AVFoundation boundary: capability probing, CameraService,
              preview layer
  Analysis/   Frame analyzer, speck detector, alignment monitor, measurement
              pipeline, gravity provider, pixel-buffer luma extraction, and the
              seeded synthetic-frame harness
  Features/
    Onboarding/  The scientific disclosure, shown first and always reachable
    Setup/       The checklist and the alignment step with live prompts
    Measurement/ View model, capture screen, progress, root screen
    Result/      Quick View, Deep Dive, the live scattering chart
    Calibration/ Profile library, guided standards workflow, session model
    Diagnostics/ Capture diagnostics sheet (debug builds)
    Demo/        Simulator-only illustration of the three result states
  Shared/     Design tokens, reusable components, accessibility identifiers,
              OSLog categories
  Resources/  Asset catalogue, privacy manifest
LucidTests/     Unit tests
LucidUITests/   Interface tests, driven by launch-argument scenarios
Tools/        Project generator, project validator, source checks, structural
              Swift audit, app-icon drawing, Python cross-check of the numerics
docs/         Measurement protocol, architecture, release readiness
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

## Calibration and the NTU gate (Phase 3D)

**NTU is not an optional number — it is an enumeration.** `NTUAvailability` is
either a value with its uncertainty and validated range, or one of eight
reasons there is none. There is no code path that can produce a zero reading
like very clear water, and exactly one function in the app turns an index into
NTU. It requires *all* of:

1. Calibrated Fixture Mode selected;
2. a profile that exists, matches this app version's schema, and has not
   expired;
3. every critical capture parameter matching — camera, format, algorithm
   versions, region and fixture exactly; focus, exposure, ISO, white balance,
   torch level and working distance within documented tolerances;
4. capture quality passing;
5. the index inside the calibrated range — outside it the curve *clamps*, and a
   clamped value presented as a measurement would be a fabrication, so "below"
   or "above validated range" is reported instead;
6. an uncertainty that can actually be computed.

**Curve selection is by prediction, not by fit.** Three monotone candidates are
fitted — piecewise linear, Fritsch–Carlson monotone cubic, and a power law
fitted on logarithms — and chosen by **leave-one-concentration-out** cross
validation. Fit quality measures how well a curve reproduces the points it was
built from, which every candidate does almost perfectly and which predicts
nothing. There is no high-degree polynomial: a quartic through six points fits
them beautifully and says nothing about anything in between.

Every candidate is monotone *by construction*. A mapping that can wiggle would
let a slightly larger index give a smaller NTU — not a calibration error but a
nonsense result — and with six standards an unconstrained fit wiggles readily.

**Uncertainty** combines the cross-validated model error with the replicate
spread converted through the curve's local slope, floored by the standards'
own certificate tolerance, at a coverage factor of two. A calibration can never
be more certain than the standards it was made from.

**Lucid never describes how to prepare a standard.** Formazin is made from
hydrazine sulfate; calibration uses commercially prepared certified standards
used according to the manufacturer's own safety instructions.

**Category thresholds are Lucid's own presentation bands**, versioned and
recorded on every reading. They are not health thresholds, not regulatory
limits, and not a potability determination. In Screening Mode they describe
*observed scattering*; a test asserts no label contains "safe", "drink",
"potable", "pure", "clean" or "healthy".

**A profile in an older format is discarded, not migrated.** A calibration is an
empirical claim about a specific instrument; a format change that alters what a
field means invalidates the claim, so the app asks for the standards to be run
again rather than guessing.

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

**Background stability is reported, never gated on.** The model's stability —
what fraction of pixels held still while it was built — separates a still
container from a moving one, but it does *not* separate a still container from
one full of drifting particles: measured on the synthetic scenes, a sample full
of material scores 0.81 while a container creeping at 2% of the frame width per
second scores 0.90, and no threshold, coarse-plane reformulation or
majority-vote variant separates them. Gating on it therefore rejected exactly
the turbid samples the app exists to identify, so it does not. Container
movement is the motion gate's job; a creep too slow for that gate is a
documented limitation. (`QualityThresholds` version 2 dropped the limit.)

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

## The interface (Phase 4)

**One screen owns the camera.** `CaptureStageView` shows the live preview and
either the setup step or the running measurement beneath it, so the sample is
lined up in exactly the frame the measurement then runs on. The calibration
workflow embeds the same view rather than its own, because a calibration taken
through a different capture screen would be calibrating that screen.

**Frames never reach the interface.** `MeasurementPipeline` owns the analyzer,
runs on the capture pipeline's processing queue, and publishes small immutable
values over an `AsyncStream` with `bufferingNewest(1)` at about five times a
second — whatever rate the camera and analyzer are running at. A slow interface
can never make the analyzer wait or accumulate stale updates. The chart series
is a fixed-capacity ring buffer, so leaving the screen open cannot grow the
heap.

**The live graph plots the index, never NTU.** A running NTU would have to be
produced before the capture-quality verdict exists, and a number that appears,
moves and is then withheld at the end is worse than no number at all. The NTU
estimate belongs to the finished reading and appears there.

**Live prompts come from the gates, not from folklore.** The alignment monitor
applies the same `FrameGate` the analyzer applies, on the same region, and turns
each rejection into a short instruction — *Hold steady*, *Reduce glare*. At most
two are shown: a wall of warnings is not actionable while holding a phone still.
Every item on the setup checklist names the gate it exists to avoid, and a test
asserts each of those gates has an instruction.

**The Start button is never disabled by a quality gate.** The thresholds are
engineering starting points, not validated limits, and a gate that is slightly
wrong must not be able to lock someone out of their own device. The screen says
plainly whether the view is good, so starting anyway is a choice rather than an
accident.

**A rejected capture still shows its result**, with a banner saying the capture
did not meet the gates and why. The evidence for the rejection is in the reading,
and hiding it would leave nobody anything to act on.

**Accessibility.** Colour is never the only signal: every status carries a
symbol and a word. Dynamic Type is used throughout, all controls are at least
44 points, the chart has a spoken summary of its shape rather than a list of two
hundred numbers, and animation is switched off under Reduce Motion. Nothing
flashes.

## What has and has not been verified

Nothing here has been compiled or executed. There is no Swift toolchain and no
Xcode available, so **every claim about behaviour rests on review, on the static
checks, and on the Python reference — not on a passing test run.** What stands
in for a compiler:

- `Tools/swift_audit.py` — a real Swift parser (`tree-sitter-swift`), so this
  sees the code the way a compiler front end does rather than as text. It
  checks that every file parses; that every type referenced is either declared
  here or on a reviewed list of Apple and standard-library names, so a typo in
  a type name has nowhere to hide; that every `Type.method(...)` and `Type(...)`
  call matches a declaration in labels and order, allowing for defaults and
  trailing closures; that every conformer to a protocol declared here
  implements its requirements; that every `switch` over a local enum is
  exhaustive; and that no SwiftUI view builder is handed more than the ten
  children it accepts. Every one of those was self-tested by introducing the
  error and confirming the failure. It found two real compile errors.
- `Tools/check_sources.py` — balanced delimiters, no force unwraps or force
  casts in hardware and measurement code, no placeholders or `TODO`, Apple
  frameworks only, malformed numeric literals, memberwise initializer calls
  that name properties the struct actually declares in declaration order,
  agreement between the app's accessibility identifiers and the UI tests' copy
  of them, **no networking anywhere and no file writing on the frame path**, and
  **no user-facing copy claiming accuracy nobody has measured**. Each of those
  last two was self-tested by introducing a violation and confirming it fails.
- `Tools/generate_xcodeproj.py` and `Tools/validate_pbxproj.py` — the project
  file is generated from the file tree and then parsed back and checked, so it
  cannot drift from the sources. The validator also confirms the privacy
  manifest is actually copied into the app bundle and declares what Lucid
  actually does.
- `Tools/analysis_reference.py` — a Python port of every analysis calculation,
  run against the same synthetic scenes. This is what has actually caught
  defects: gates that could never have fired, a classifier whose combination
  rule undid its own requirement, a speck term that outvoted the bulk channel,
  and — in this phase — simulated scenes whose features all sat outside the
  analysis region, and a quality gate that would have rejected every turbid
  sample.

The Swift unit tests and UI tests are written but have never run. Treat them as
specifications until they do.

## Known limitations

- **An iPhone is not a nephelometer.** No calibrated light source, no fixed
  sample geometry, no defined detection angle. Screening Mode reports a relative
  index; NTU exists only behind the gate described above.
- **A slow container creep is not caught.** The motion gate catches movement
  above roughly 5% of the frame width per second. Below that, a creep can shift
  the scene across the two-second acquisition window without registering. The
  background-stability number would show it, but that number cannot tell a
  creeping container from a sample full of drifting particles, so it is reported
  rather than gated on — gating on it rejected exactly the turbid samples the
  app exists to identify. `Tools/analysis_reference.py` contains the
  measurements behind that decision.
- **No ambient-light interference gate.** The screening protocol captures no
  torch-off reference because nothing consumes one. Measuring in a bright room
  degrades the result without the app being able to say so; the setup checklist
  asks for a dim room instead.
- **Every threshold is unvalidated.** The quality gates, the index weights and
  the clarity bands are engineering starting points. None has been checked
  against real samples on real hardware.
- **The measured gravity reference has never been read from a real
  accelerometer.** It is wired in and its lifecycle is tested, but only the
  assumed-portrait fallback has ever produced a value here.
- **SF Symbol names have not been rendered.** They are drawn from the iOS 17
  set but have not been seen on a device; a wrong name renders as nothing.
- **Only the rear camera, portrait, on iOS 17 or later.** Orientation is pinned
  because a measurement needs a fixed optical path.

## Privacy

The only privacy permission Lucid declares is `NSCameraUsageDescription`. iOS
has no separate torch permission — the torch is covered by camera access. Video
is processed on device; nothing is written to disk or transmitted. The only
things Lucid stores are its calibration profiles, in the app's own support
directory, and one boolean recording that the disclosure has been read.

`Lucid/Resources/PrivacyInfo.xcprivacy` declares no tracking, no tracking
domains, no collected data types, and one required-reason API: `UserDefaults`,
for reason `CA92.1`. Lucid has no network code at all, and that is enforced —
`check_sources.py` fails the build if `URLSession`, `Network` or any of their
relatives appear, or if anything under `Lucid/Camera` or `Lucid/Analysis` writes
a file. See `docs/RELEASE.md` for the full review.

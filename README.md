# Lucid

Lucid is an iPhone app that uses the camera and torch to screen the **optical
clarity** of a water sample.

> **Optical screening only — not a drinking-water safety test.**
> Lucid cannot detect bacteria, viruses, dissolved chemicals, heavy metals,
> PFAS or toxins, and it cannot tell you whether water is safe to drink.

## Build status

**Phase 2 of 4 — AVFoundation hardware control.**

This build selects a camera, configures a capture session, shows a live
preview, warms up and locks focus/exposure/white balance, drives the torch at
the maximum currently available level, and reports frame timing. It contains
**no image analysis and no NTU calculation**. Those arrive in Phases 3–4.

| Phase | Scope | Status |
|-------|-------|--------|
| 1 | SwiftUI scaffold, camera permission, state machine, tests | Complete |
| 2 | AVFoundation capture session, camera selection, torch, control locking | Complete |
| 3 | Frame analysis (3A quality gates, 3B detection, 3C tracking, 3D calibration) | Not started |
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
  Services/   Camera authorization, settings, runtime environment, test fakes
  Camera/     The AVFoundation boundary: capability probing, CameraService,
              preview layer
  Features/   Measurement view model and views, diagnostics, Simulator demo
  Shared/     Design tokens, reusable components, OSLog categories
  Resources/  Asset catalogue
LucidTests/   Unit tests
Tools/        Project generator, project validator, source checks
```

Selection, clamping, lifecycle and timing logic all live in `Domain/` as plain
values, so they are unit-tested without hardware. `Camera/` is the only place
that touches AVFoundation, and it publishes value types only — no
`CMSampleBuffer` or `CVPixelBuffer` crosses that boundary.

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

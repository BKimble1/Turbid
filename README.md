# Lucid

Lucid is an iPhone app that uses the camera and torch to screen the **optical
clarity** of a water sample.

> **Optical screening only — not a drinking-water safety test.**
> Lucid cannot detect bacteria, viruses, dissolved chemicals, heavy metals,
> PFAS or toxins, and it cannot tell you whether water is safe to drink.

## Build status

**Phase 1 of 4 — SwiftUI scaffold and camera permissions.**

This build contains the app shell, the measurement state machine and the camera
authorization flow. It contains **no camera capture, no torch control, no image
analysis and no NTU calculation**. Those arrive in Phases 2–4.

| Phase | Scope | Status |
|-------|-------|--------|
| 1 | SwiftUI scaffold, camera permission, state machine, tests | Complete |
| 2 | AVFoundation capture session, camera selection, torch, control locking | Not started |
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

- **On the Simulator**: the scaffold plus a purple **"SIMULATED DATA — NOT A
  MEASUREMENT"** section showing what the three result states will look like.
  Tapping *Start Setup* shows the camera permission prompt, then stops with
  *"Live capture is not part of this build."* That is the correct Phase 1
  outcome.
- **On a physical iPhone**: the same, minus the simulated section — illustrative
  data is compiled out of any build that is not a debug Simulator build.

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
  Domain/     Measurement state machine, modes, clarity classes, failures
  Services/   Camera authorization, settings, runtime environment, test fakes
  Camera/     SwiftUI camera-preview boundary (placeholder until Phase 2)
  Features/   Measurement view model and views, Simulator demo
  Shared/     Design tokens, reusable components, OSLog categories
  Resources/  Asset catalogue
LucidTests/   Unit tests
Tools/        Project generator, project validator, source checks
```

## Privacy

The only privacy permission Lucid declares is `NSCameraUsageDescription`. iOS
has no separate torch permission — the torch is covered by camera access. Video
is processed on device; nothing is written to disk or transmitted.

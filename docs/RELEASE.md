# Release readiness

This is the master prompt's release-quality definition of done, item by item,
with what was actually done and what is blocked. **The project is not complete.**
Six of the eleven items cannot be closed without a Mac, an Xcode toolchain, a
physical iPhone and certified turbidity standards, none of which exist in the
environment this was written in.

## Status

| # | Item | Status |
|---|---|---|
| 1 | Run all unit/UI tests | **Blocked** here, **wired up** in CI — `codemagic.yaml` runs them on a simulator. Written, never executed. |
| 2 | Repeated physical-device tests on every supported camera path | **Blocked** — no device |
| 3 | Profile CPU, GPU, memory, thermal, frame drops, latency | **Blocked** — no device. Static audit done and one defect fixed; see below. |
| 4 | Verify no processing backlog or unbounded growth | **Done**, by construction and by check |
| 5 | Verify raw frames are neither stored nor transmitted | **Done**, and now machine-checked |
| 6 | Validate every calibration claim against real standards | **Blocked** — no standards. No claim is made. |
| 7 | Document devices, fallbacks, protocol, range, interferences, uncertainty, limitations | **Done** — `docs/MEASUREMENT.md` |
| 8 | App Store privacy/copy review | **Done** — below |
| 9 | Include a clear optical-screening disclaimer | **Done** |
| 10 | Final file inventory and architecture summary | **Done** — `docs/ARCHITECTURE.md` |
| 11 | Do not report unmeasured accuracy | **Done**, and now machine-checked |

## 3. Static audit, in place of profiling

Reading the frame path for the things a profiler would have found:

**Fixed: the measured gravity provider was never wired in.** Phase 3C built
`CoreMotionGravityProvider` because bubble rejection depends on how much of
gravity lies in the image plane — with the phone flat and the camera looking
down, a rising bubble barely moves in frame and the direction term means
nothing. But `FrameAnalyzer` defaults to `AssumedPortraitGravityProvider`, and
nothing overrode it, so the measured provider was dead code and every
classification ran on the assumption at full confidence. The provider now lives
in `AppEnvironment`, `live()` supplies the Core Motion one, and the view model
starts it when the torch comes on for alignment and stops it with the session —
device motion needs a moment to produce its first sample, so starting it at the
first frame would have spent the early window on the assumption anyway. A test
pins the lifecycle. The Simulator keeps the assumed provider, because it has no
accelerometer to measure with.

**No per-frame allocation** once the region size is known. The luma extractor,
both coarse planes, the crop buffer, the band-pass scratch, the noise scratch
and the background model are all reused and reallocated only when the geometry
changes. The coarse planes are double-buffered and swapped rather than assigned,
specifically so copy-on-write does not allocate on every frame.

**Nothing expensive on the MainActor.** The only work there per update is
copying the chart array (at most 240 small structs, five times a second) and
assigning value types.

**One thing to measure rather than assume**: every chart sample calls
`FrameAnalyzer.tracking()`, which re-runs classification over the live track set
(capped at 256) and sorts. That is five times a second during the measurement
window for a value only the graph uses. It should be tens of microseconds, but
"should be" is what the Time Profiler is for — if the analyzer turns out not to
fit inside a frame interval on the oldest supported device, this is the first
thing to cache.

**Thermal** is handled but unmeasured: thermal state and system pressure stop a
run in progress, and the delivered torch level is read back rather than assumed,
so a throttled torch invalidates a calibration match instead of silently
changing the measurement. Whether five consecutive runs actually reach a
throttling state is exactly what item 3 would answer.

## 4. Backlog and unbounded growth

Every accumulating structure has a fixed bound; they are listed in
`docs/ARCHITECTURE.md`. Two tests pin the behaviour that matters most:
`MeasurementPipelineTests.testTheChartIsBoundedEvenWhenTheRunIsLong` runs a
whole protocol through a 12-sample chart and asserts both the cap and that the
ring stays in time order, and
`MeasurementProgressTests.testTheBufferKeepsOnlyItsCapacityAndInArrivalOrder`
covers the buffer directly.

There is no processing backlog by construction: `alwaysDiscardsLateVideoFrames`
is true, and analysis runs synchronously on the capture pipeline's processing
queue. An analyzer that falls behind causes the system to drop frames — which
`FrameTimingCollector` counts and the dropped-frame gate acts on — rather than
letting a queue grow. The interface is fed through an `AsyncStream` with
`bufferingNewest(1)`, so a slow interface can neither stall the analyzer nor
accumulate stale updates.

**This is an argument from reading the code, not a measurement.** Item 3 is what
would confirm it.

## 5. Frames never leave the device

`Tools/check_sources.py` now fails the build if any file outside the test
targets references `URLSession`, `URLRequest`, `NWConnection` and the rest, or
imports `Network`, `CFNetwork`, `CoreTelephony` or `MultipeerConnectivity`; if
anything anywhere references `AVAssetWriter`, `AVCaptureMovieFileOutput`,
`AVCapturePhotoOutput`, `CGImageDestination`, `UIImageWriteToSavedPhotosAlbum`,
`PHPhotoLibrary` or `UIPasteboard`; or if anything under `Turbid/Camera` or
`Turbid/Analysis` writes a file at all. Both rules were self-tested by
introducing a violation and confirming the failure.

The only thing Turbid writes is `calibrations.json` in its own Application
Support directory, from `Turbid/Domain/Calibration/CalibrationStore.swift`, which
never sees a pixel. The only preference it writes is one boolean recording that
the disclosure has been read.

## 11. No unmeasured accuracy claims

`check_sources.py` scans every string literal under `Turbid/` for claim phrases —
*laboratory-grade*, *professional-grade*, *EPA-compliant*, *clinically proven*,
*highly accurate*, *accurate to within*, *certified results* and their variants —
and fails if one appears. Self-tested.

`ClarityCategoryEngineTests` separately asserts that no clarity label or result
description contains *safe*, *drink*, *potable*, *pure* or *healthy*, in either
the index-based or the NTU-based wording.

---

# App Store privacy and copy review

## Privacy manifest

`Turbid/Resources/PrivacyInfo.xcprivacy` is copied into the app bundle by the
app target's Resources build phase, which `Tools/validate_pbxproj.py` verifies —
a manifest that is not in a build phase is a file in the repository, not
something App Store Connect will ever see.

| Key | Value | Why |
|---|---|---|
| `NSPrivacyTracking` | `false` | Turbid has no network code at all |
| `NSPrivacyTrackingDomains` | empty | — |
| `NSPrivacyCollectedDataTypes` | empty | Nothing is collected. Calibration profiles stay on device and are not linked to anyone. |
| `NSPrivacyAccessedAPITypes` | `NSPrivacyAccessedAPICategoryUserDefaults` → `CA92.1` | One boolean, readable and writable only by this app |

**Deliberately not declared**: `FileTimestamp` — Turbid reads no file metadata;
`DiskSpace` — it checks none; `ActiveKeyboards` — it is not a keyboard;
`SystemBootTime` — it calls neither `mach_absolute_time()` nor
`systemUptime`. The stall watchdog uses `ContinuousClock`, which is not on
Apple's list of required-reason APIs. **Re-check this before submission**: how
Swift's runtime implements `ContinuousClock` is not part of its contract, and
if Apple's list ever names it, `NSPrivacyAccessedAPICategorySystemBootTime` with
reason `35F9.1` — *measure the amount of time that has elapsed between events
that occurred within the app* — is the accurate declaration.

## Info.plist

One purpose string, `NSCameraUsageDescription`, set as a build setting and
validated for content:

> Turbid uses the camera and torch to analyze light scattering in a water
> sample. Video is processed on this iPhone and is not saved or sent anywhere.

iOS has no separate torch permission — the torch is covered by camera access.
`Tools/validate_pbxproj.py` fails if any build setting introduces a Microphone,
PhotoLibrary, Location, Contacts or Bluetooth purpose key, so a permission
cannot be added without someone noticing.

**Corrected during this review.** The string previously ended *"...is not saved
unless you explicitly export diagnostics"*, describing a feature that does not
exist. A purpose string is the one piece of copy a reviewer reads closely, so it
now says only what the app does, and the validator fails if the word *export*
reappears. If a diagnostics export is ever built, the string changes with it.

## Copy review

Every string literal in the app was extracted and read. Findings:

- **The disclaimer appears on every result surface** and is carried by the
  reading type itself (`TurbidityReading.disclaimer`), so it cannot be omitted
  by a view that forgets it. The UI tests assert its presence on the result
  screen.
- **No string claims the water is safe, potable, clean or pure.** The words
  *safe* and *drink* appear only in denials: *"not a drinking-water safety
  test"*, *"cannot tell you whether water is safe to drink"*, *"Clear water can
  be unsafe, and safe water can look cloudy."*
- **NTU is never shown without either a number and its uncertainty, or the
  reason there is none.** `NTUAvailability` is an enumeration with eight
  no-number cases, each carrying its own explanation; there is no optional
  `Double` that could render as a zero.
- **Particle counts are always labelled *Visible particles (tracked)***, with
  the explanation that they are not a concentration, on both the Quick View and
  the Deep Dive.
- **The three clarity states describe optical clarity**, and in Screening Mode
  the result description says *observed scattering* rather than naming a
  concentration.
- **The calibration screen leads with safety** and states that Turbid does not
  provide standard-preparation instructions. No screen anywhere describes making
  a standard.
- **Two hard-coded durations were removed** during this review — the setup
  screen's accessibility hint and the calibration screen's time estimate both
  quoted "thirteen seconds" as a literal. They now derive from
  `CaptureProtocol.screening.totalSeconds`, rounded up, so a changed protocol
  cannot leave the interface quoting the old one.
- **No log line records image data, sample data, file paths or user text.** The
  logs carry camera names, format descriptions, state names and counts.

**Not reviewed**: an App Store listing, screenshots, keywords and the support
page do not exist yet. When they do, the same rule applies — the listing may
describe optical clarity screening and must not describe water testing, safety
or purity.

## Age rating and category

Not set. The obvious answers are Utilities, 4+, no third-party content, no user
generated content. Worth stating explicitly at submission that the app makes no
medical or health claim, because a water-related app will be looked at for one.

---

# Shipping to TestFlight

`codemagic.yaml` has the workflow. In order: regenerate the project with the
signing bundle identifier, fail if the project and the signing configuration
disagree about that identifier, run the unit tests, set a build number one above
the latest already in TestFlight, archive, export and upload. It stops at
TestFlight — nothing here submits to the store on a CI trigger, because this is
a screening instrument whose thresholds have never been validated against real
samples.

Four things had to be fixed before an upload could have worked at all, none of
which a simulator build would have complained about:

- **There was no app icon.** `AppIcon.appiconset` declared a 1024x1024 slot with
  no image in it. A simulator build only warns; App Store Connect rejects the
  archive for a missing `CFBundleIconName`. `Tools/make_app_icon.py` now draws
  one from the app's own palette, and the validator fails if it goes missing.
  Two things check it, at the two places it can go wrong. A unit test asserts
  the compiled `Assets.car` is in the built bundle, which is what proves
  `actool` ran on the catalogue at all. The upload workflow then reads the
  archive it is about to send: it fails if `Assets.car` is absent, and only
  once that has passed does it write `CFBundleIconName` and re-read it.

  That key is written by the workflow rather than by the build because on the
  Xcode 26 toolchain the build does not produce it. `actool` emits it into a
  partial Info.plist the build is supposed to merge, and measured on both a
  Simulator build and a device archive the catalogue compiled and the key was
  absent; `INFOPLIST_KEY_CFBundleIconName` does not reach it either, since that
  mechanism only serves keys the build system knows. App Store Connect requires
  the key, so it is supplied against the artifact actually being uploaded,
  where the claim can be checked rather than assumed.
- **Export compliance was unanswered.** Without
  `ITSAppUsesNonExemptEncryption`, every TestFlight build waits in *Missing
  Compliance* until somebody clicks through the question. Turbid implements no
  encryption and makes no network connections, so the answer is now in the
  Info.plist.
- **`agvtool` could not set a build number**, because the app target had no
  `VERSIONING_SYSTEM`. TestFlight refuses a build number it has seen before, so
  the second upload would have failed.
- **The bundle identifier was a tracked constant.** It is now a generator
  input defaulting to the production identifier `com.idlery.turbid`, so CI can
  sign against a different one without anyone editing a file.

What still has to be created by hand, because only the account holder can: an
App Store Connect API key added to Codemagic as `TurbidAppStoreKey`, the bundle
identifier `com.idlery.turbid` registered in the developer account, and an app
record for it. `codemagic.yaml` marks exactly
where each goes.

# What to do on a Mac with a device

The blocked items, in the order that finds problems fastest.

## 1. Build and run the tests

```sh
python3 -m pip install tree_sitter tree_sitter_swift
sh Tools/check.sh          # regenerate and validate the project first
open Turbid.xcodeproj
```

Then ⌘U. Expect compilation errors: nothing here has ever been through a
compiler. `Tools/swift_audit.py` parses every file with a real Swift grammar
and checks type references, call labels, protocol conformances, switch
exhaustiveness and view-builder arity, which removes whole categories of them —
but it does not type-check, so mismatched numeric types and SwiftUI inference
failures are still ahead of you. Fix them before reading anything into the test
results.

The UI tests need a Simulator and take several minutes — each one runs a real
12.5-second analysis of synthetic frames, and the Simulator is slow at it.

## 2. Device tests, every camera path

For each of an iPhone with an Ultra Wide rear camera and one without, and once
under thermal load (run the measurement three times back to back):

1. Permission: allow, deny, revoke mid-measurement in Settings, restore.
2. Confirm the diagnostics sheet names the physical camera actually selected,
   and that its minimum focus distance matches Apple's published figure.
3. Confirm the torch reaches `maxAvailableTorchLevel` and reports active; then
   warm the phone and confirm a lower delivered level is surfaced.
4. Confirm focus, exposure and white balance lock, and that the locked values
   are recorded.
5. Backgrounding, a phone call, Control Centre, Split View, and force-quit — the
   torch must be off within a frame of each.
6. Measure the same sample five times without touching the setup. Record the
   index each time. **The spread across those five is the repeatability figure
   that the whole design rests on, and nobody has measured it.**

## 3. Profiling

Instruments, on the oldest supported device:

- **Time Profiler** during a run — the analyzer must fit inside one frame
  interval at 15 fps analysed, or frames drop.
- **Allocations** — the allocation graph across a run should be flat after the
  first few frames. Any per-frame growth is a bug in the reuse.
- **Thermal state** across five consecutive runs — if the device reaches
  *serious*, the torch level falls and calibrations stop matching.
- **Frame drops** — `FrameTimingStatistics.dropRatio` is already recorded; check
  it against what Instruments sees.
- **Latency** — time from the last frame of the window to the result appearing.

## 4. Calibration validation

With certified standards, and only with certified standards:

1. Build a fixture that holds the phone, the container and the shroud in a
   repeatable arrangement. Without one, Calibrated Fixture Mode has nothing to
   be bound to.
2. Run the guided workflow: blank plus at least four standards spanning the
   intended range, three replicates each.
3. **Then measure held-out samples the curve was not fitted to** — standards at
   concentrations between the calibration points, prepared from the same
   certified stock. Compare the reported NTU and its stated uncertainty against
   the certificate values.
4. If the held-out error exceeds the stated uncertainty, the uncertainty model
   is wrong and must be widened before any number is shown to anyone.
5. Repeat on a second phone of the same model. If the two disagree beyond their
   uncertainties, the binding is not capturing everything that matters.

Only after step 4 does any accuracy statement become sayable — and it must then
be stated as measured, with the sample size, the range and the conditions.

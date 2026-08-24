# Architecture and file inventory

Turbid is a single iOS app target with a unit-test target and a UI-test target.
It has no third-party dependencies. `Turbid.xcodeproj` is generated from the file
tree by `Tools/generate_xcodeproj.py` and validated by
`Tools/validate_pbxproj.py`, so the project file cannot drift from the sources.

## The shape of it

```
                   MainActor                    │        serial queues
                                                │
  RootView ──▶ MeasurementViewModel             │
                │  │                            │
                │  └─▶ CalibrationLibrary ──▶ FileCalibrationStore
                │                               │
                │  attaches                     │
                ├───────────────────────────────┼──▶ AlignmentMonitor
                │                               │        (alignment only)
                │                               │
                └───────────────────────────────┼──▶ MeasurementPipeline
                                                │        └─▶ FrameAnalyzer
                     value types only           │              ├─ FrameGate
                  ◀── MeasurementProgress ──────┤              ├─ SpeckDetector
                  ◀── TurbidityReading ─────────┤              ├─ PatchFlowEstimator
                                                │              ├─ MultiObjectTracker
  CameraPreviewView ◀── AVCaptureSession ───────┤              └─ ScatteringWindowAggregator
                                                │
                          CameraService  ───────┘
                       (session queue +
                        processing queue)
```

Four rules hold the design together:

1. **`Camera/` is the only place that touches AVFoundation**, and everything
   crossing that boundary is a value type. No `CMSampleBuffer` and no
   `CVPixelBuffer` reaches the MainActor; a pixel buffer is handed to the frame
   consumer for the duration of one call and never retained.
2. **`Domain/` is hardware-free.** Camera selection, control-lock clamping, the
   capture lifecycle, every quality gate, the whole analysis mathematics and all
   of the calibration model are plain values, unit-tested without a device.
3. **Everything is behind a protocol at the injection points** — `CameraControlling`,
   `CameraAuthorizing`, `SettingsOpening`, `DisclosureRecording`,
   `CalibrationStoring`, `CaptureFrameConsuming`, `GravityProviding`,
   `GlobalFlowEstimating` — so the Simulator, previews and tests substitute
   stand-ins without the production types knowing.
4. **Anything that can produce a number is versioned**, and the versions are
   recorded on every reading and every calibration profile. A changed algorithm
   invalidates the calibrations fitted under the old one, by construction.

## Where a frame goes

`CameraService.captureOutput` → presentation timestamp recorded →
`CaptureFrameConsuming.consume(pixelBuffer:presentationSeconds:)` on the
processing queue → `PixelBufferLumaExtractor` copies the region's luma into a
reused buffer → `FrameAnalyzer` stages, gates, detects, tracks and aggregates →
`MeasurementPipeline` publishes a `MeasurementProgress` at about 5 Hz over an
`AsyncStream` with `bufferingNewest(1)` → the view model updates the interface.
At the end, `MeasurementPipeline.makeReading` assembles one `TurbidityReading`
and the NTU gate decides whether a number may exist.

Nothing between the sensor and the interface allocates per frame once the region
size is known: the extractor, the coarse planes, the crop buffer, the band-pass
scratch and the background model are all reused. `alwaysDiscardsLateVideoFrames`
is true and analysis is synchronous on the processing queue, so an analyzer that
falls behind drops frames rather than building a backlog.

## Bounded by construction

| Structure | Bound |
|---|---|
| `FrameTimingCollector` intervals | 240-entry ring |
| `ScatteringSampleBuffer` (chart) | 240-entry ring |
| `FrameAggregate` level and motion history | 600-entry ring |
| `ScatteringWindowAggregator.windows` | 16, oldest dropped |
| `Track.observations` | per-track capacity, oldest dropped |
| `MultiObjectTracker.tracks` | 256 live, excess counted in `tracksDroppedForCapacity` |
| `FrameAnalyzer.seenTrackIdentifiers` | distinct confirmed tracks in one run; cleared by `begin` |
| `CalibrationLibrary.profiles` | user-created, persisted |

## Inventory

```
Turbid/Analysis/  (7 files, 1390 lines)
    179  AlignmentMonitor.swift
    388  FrameAnalyzer.swift
     38  FrameAnalyzing.swift
     70  GravityProviding.swift
    278  MeasurementPipeline.swift
     76  PixelBufferLumaExtractor.swift
    361  SpeckDetector.swift

Turbid/Analysis/Synthetic/  (3 files, 413 lines)
     45  DeterministicRandom.swift
    226  SyntheticFrameFactory.swift
    142  SyntheticScene.swift

Turbid/App/  (3 files, 314 lines)
     89  AppEnvironment.swift
     21  TurbidApp.swift
    204  UITestConfiguration.swift

Turbid/Camera/  (4 files, 1119 lines)
     92  CameraCapabilityReporter.swift
     56  CameraControlling.swift
    124  CameraPreviewView.swift
    847  CameraService.swift

Turbid/Domain/  (18 files, 1443 lines)
     40  CameraAuthorization.swift
     55  CameraCapabilities.swift
    125  CameraControlLock.swift
     58  CameraError.swift
    157  CameraSelector.swift
     67  CaptureFormatDescriptor.swift
     86  CaptureFormatSelector.swift
     91  CaptureLifecycle.swift
     30  CaptureRequirements.swift
    118  CaptureSnapshot.swift
    163  FrameTiming.swift
     26  MeasurementEvent.swift
     64  MeasurementFailure.swift
     33  MeasurementMode.swift
     80  MeasurementRejectionReason.swift
     75  MeasurementState.swift
    103  MeasurementStateMachine.swift
     72  OpticalClarityClass.swift

Turbid/Domain/Analysis/  (15 files, 2417 lines)
    153  AnalysisRegion.swift
    229  BackgroundModel.swift
    137  BandPassFilter.swift
     75  BulkScatteringMetrics.swift
    150  CaptureProtocolTimeline.swift
    141  CaptureQuality.swift
    277  ConnectedComponents.swift
     46  FrameGate.swift
     80  FrameNormalization.swift
    224  FrameObservation.swift
    219  FrameQualityEvaluator.swift
     83  LumaImage.swift
    299  LumaStatistics.swift
    177  MeasurementProgress.swift
    127  SpeckCandidate.swift

Turbid/Domain/Analysis/Tracking/  (8 files, 1499 lines)
     87  ConstantVelocityFilter.swift
    102  GlobalFlow.swift
    204  MultiObjectTracker.swift
    400  PatchFlowEstimator.swift
    233  ScatteringWindowAggregator.swift
    220  Track.swift
    163  TrackClassifier.swift
     90  TrackingMetrics.swift

Turbid/Domain/Calibration/  (10 files, 1643 lines)
    168  CalibrationBinding.swift
    108  CalibrationBindingBuilder.swift
    280  CalibrationFit.swift
    170  CalibrationProfile.swift
    132  CalibrationStandard.swift
    176  CalibrationStore.swift
    107  ClarityPolicy.swift
    248  MonotonicMapping.swift
    127  RelativeScatteringIndex.swift
    127  TurbidityReading.swift

Turbid/Features/Calibration/  (3 files, 1058 lines)
    472  CalibrationRunView.swift
    329  CalibrationSessionViewModel.swift
    257  CalibrationView.swift

Turbid/Features/Demo/  (2 files, 118 lines)
     42  DemoScenario.swift
     76  DemoShowcaseView.swift

Turbid/Features/Diagnostics/  (1 files, 187 lines)
    187  CaptureDiagnosticsView.swift

Turbid/Features/Measurement/  (6 files, 1283 lines)
     74  CaptureStageView.swift
    115  MeasurementProgressView.swift
     38  MeasurementScreen.swift
    160  MeasurementStatePresentation.swift
    541  MeasurementViewModel.swift
    355  RootView.swift

Turbid/Features/Onboarding/  (1 files, 143 lines)
    143  OnboardingView.swift

Turbid/Features/Result/  (3 files, 634 lines)
    307  DeepDiveView.swift
    171  QuickViewResultView.swift
    156  ScatteringChartView.swift

Turbid/Features/Setup/  (2 files, 261 lines)
     77  SetupChecklist.swift
    184  SetupWizardView.swift

Turbid/Services/  (6 files, 306 lines)
    150  CalibrationLibrary.swift
     12  CameraAuthorizing.swift
     69  DisclosureAcknowledgement.swift
     25  RuntimeEnvironment.swift
     21  SettingsOpening.swift
     29  SystemCameraAuthorizationService.swift

Turbid/Services/Fakes/  (4 files, 595 lines)
    296  SimulatedFrameSource.swift
     34  StubCameraAuthorizationService.swift
    246  StubCameraService.swift
     19  StubSettingsOpener.swift

Turbid/Shared/  (4 files, 420 lines)
     69  AccessibilityIdentifiers.swift
    229  Components.swift
     14  Logging.swift
    108  Theme.swift

TurbidTests/  (36 files, 7049 lines)
    146  AlignmentMonitorTests.swift
    138  AnalysisRegionTests.swift
    138  CalibrationBindingBuilderTests.swift
    228  CalibrationFitterTests.swift
    194  CalibrationLibraryTests.swift
    318  CalibrationSessionTests.swift
    192  CalibrationStoreTests.swift
     52  CameraAuthorizationMappingTests.swift
    149  CameraControlLockPlannerTests.swift
    226  CameraPipelineIntegrationTests.swift
    179  CameraSelectorTests.swift
     98  CaptureFormatSelectorTests.swift
    101  CaptureHardwareTeardownTests.swift
    102  CaptureLifecycleTests.swift
    116  CaptureProtocolTimelineTests.swift
    209  ClarityCategoryEngineTests.swift
    103  ConstantVelocityFilterTests.swift
    573  FrameAnalyzerTests.swift
    351  FrameQualityEvaluatorTests.swift
    139  FrameTimingCollectorTests.swift
    110  InfoPlistTests.swift
    224  LumaStatisticsTests.swift
    242  MeasurementPipelineTests.swift
    144  MeasurementProgressTests.swift
    199  MeasurementStateMachineTests.swift
    123  MeasurementViewModelTests.swift
    130  MonotonicMappingTests.swift
    287  MultiObjectTrackerTests.swift
    275  NTUGateTests.swift
    197  PatchFlowEstimatorTests.swift
    120  RelativeScatteringIndexTests.swift
    173  ScatteringWindowAggregatorTests.swift
    110  SimulatedFrameSourceTests.swift
    453  SpeckDetectorTests.swift
    260  SyntheticFrameFactoryTests.swift
    250  TrackClassifierTests.swift

TurbidTests/Support/  (3 files, 405 lines)
    249  CalibrationFactory.swift
    121  CapabilityFactory.swift
     35  SpyGravityProvider.swift

TurbidUITests/  (5 files, 312 lines)
     49  CalibrationUITests.swift
     88  MeasurementFlowUITests.swift
     50  PermissionAndOnboardingUITests.swift
     55  TurbidUITestCase.swift
     70  UITestIdentifiers.swift

Tools/  (9 files, 3938 lines)
   1211  analysis_reference.py
    125  asc_build_number.py
     20  check.sh
    498  check_sources.py
    865  generate_xcodeproj.py
    105  make_app_icon.py
     76  select_simulator.py
    681  swift_audit.py
    357  validate_pbxproj.py

TOTAL 26947 lines
```

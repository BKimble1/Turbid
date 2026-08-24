import XCTest
@testable import Turbid

/// The chart buffer and the live prompts.
final class MeasurementProgressTests: XCTestCase {

    // MARK: - Bounded buffer

    func testTheBufferKeepsOnlyItsCapacityAndInArrivalOrder() {
        var buffer = ScatteringSampleBuffer(capacity: 4, smoothingFactor: 1)
        for step in 0..<10 {
            buffer.append(elapsedSeconds: Double(step), index: Double(step), ntu: nil)
        }

        XCTAssertEqual(buffer.count, 4, "a live graph must not grow without bound")
        XCTAssertEqual(buffer.samples.map(\.index), [6, 7, 8, 9],
                       "the oldest samples are the ones that go")
        XCTAssertEqual(buffer.latest?.index, 9)
    }

    func testIdentifiersKeepIncreasingSoTheChartNeverReusesOne() {
        var buffer = ScatteringSampleBuffer(capacity: 3)
        for step in 0..<7 {
            buffer.append(elapsedSeconds: Double(step), index: 1, ntu: nil)
        }
        let identifiers = buffer.samples.map(\.id)
        XCTAssertEqual(identifiers, [4, 5, 6])
        XCTAssertEqual(Set(identifiers).count, identifiers.count)
    }

    func testSmoothingIsDisplayOnlyAndTheRawValueSurvivesUntouched() {
        var buffer = ScatteringSampleBuffer(capacity: 10, smoothingFactor: 0.5)
        buffer.append(elapsedSeconds: 0, index: 10, ntu: nil)
        buffer.append(elapsedSeconds: 1, index: 20, ntu: nil)

        XCTAssertEqual(buffer.samples.map(\.index), [10, 20],
                       "the measured values must never be replaced by the smoothed ones")
        XCTAssertEqual(buffer.samples[0].smoothedIndex, 10, accuracy: 1e-9)
        XCTAssertEqual(buffer.samples[1].smoothedIndex, 15, accuracy: 1e-9)
    }

    func testResetClearsTheSmoothingAsWellAsTheSamples() {
        var buffer = ScatteringSampleBuffer(capacity: 5, smoothingFactor: 0.5)
        buffer.append(elapsedSeconds: 0, index: 100, ntu: nil)
        buffer.reset()
        buffer.append(elapsedSeconds: 0, index: 10, ntu: nil)

        XCTAssertEqual(buffer.count, 1)
        XCTAssertEqual(buffer.samples[0].smoothedIndex, 10, accuracy: 1e-9,
                       "a new run must not inherit the previous run's smoothing")
    }

    func testTheValueAxisAlwaysHasHeadroomAndIsNeverDegenerate() {
        var buffer = ScatteringSampleBuffer(capacity: 5)
        buffer.append(elapsedSeconds: 0, index: 7, ntu: nil)
        buffer.append(elapsedSeconds: 1, index: 7, ntu: nil)

        let flat = buffer.indexRange
        XCTAssertLessThan(flat.lowerBound, flat.upperBound,
                          "a chart cannot draw an empty range")

        buffer.append(elapsedSeconds: 2, index: 17, ntu: nil)
        let spread = buffer.indexRange
        XCTAssertGreaterThan(spread.upperBound, 17,
                             "the newest point must not sit on the top edge")
        XCTAssertGreaterThanOrEqual(spread.lowerBound, 0,
                                    "a scattering index is never negative")
    }

    // MARK: - Live prompts

    func testEveryGateThatSomebodyCanActOnHasAnInstruction() {
        let actionable: [MeasurementRejectionReason] = [
            .saturatedRegion, .torchHotspot, .regionTooDark, .regionTooBright,
            .outOfFocus, .cameraMoved, .exposureUnstable, .controlsUnlocked,
            .thermalLimit, .systemPressure, .excessiveDroppedFrames,
            .frameDeliveryDiscontinuous
        ]

        for reason in actionable {
            guard let hint = reason.livePrompt else {
                return XCTFail("\(reason.rawValue) has no live instruction")
            }
            XCTAssertFalse(hint.prompt.isEmpty)
            XCTAssertFalse(hint.symbolName.isEmpty,
                           "colour is never the only signal, so every hint needs a symbol")
            XCTAssertLessThanOrEqual(hint.prompt.count, 28,
                                     "a prompt has to be readable while holding a phone still")
        }
    }

    func testGatesNobodyCanActOnMidMeasurementHaveNoInstruction() {
        // Telling someone to fix the usable-frame ratio, or a calibration that
        // does not match, is not an instruction anyone can follow mid-run.
        XCTAssertNil(MeasurementRejectionReason.insufficientUsableFrames.livePrompt)
        XCTAssertNil(MeasurementRejectionReason.calibrationProfileMismatch.livePrompt)
    }

    /// The checklist earns its place by being about gates the app actually
    /// applies. An instruction that maps to nothing checkable is folklore.
    func testEverySetupInstructionGuardsAGateSomebodyCanAct() {
        XCTAssertFalse(SetupChecklist.items.isEmpty)

        for item in SetupChecklist.items {
            XCTAssertNotNil(item.guards.livePrompt,
                            "\(item.id) claims to guard \(item.guards.rawValue), which has no live prompt")
            XCTAssertFalse(item.instruction.isEmpty)
            XCTAssertFalse(item.symbolName.isEmpty)
        }

        XCTAssertEqual(Set(SetupChecklist.items.map(\.id)).count,
                       SetupChecklist.items.count,
                       "duplicate checklist identifiers would break the list's identity")
    }

    /// The working distance the checklist quotes is the one the camera was
    /// selected against. If they ever disagree, the app is asking for a
    /// distance the chosen optics were not picked for.
    func testTheChecklistQuotesTheWorkingDistanceTheCameraWasChosenFor() {
        let millimetres = CaptureRequirements.measurement.workingDistanceMillimetres
        XCTAssertEqual(SetupChecklist.workingDistanceText, "\(millimetres / 10) cm")

        let instruction = SetupChecklist.items
            .first { $0.id == "working-distance" }?
            .instruction
        XCTAssertNotNil(instruction)
        XCTAssertEqual(instruction?.contains(SetupChecklist.workingDistanceText), true,
                       "the instruction must name the distance, not imply it")
    }

    func testEveryStageIsDescribedInPlainLanguage() {
        for stage in CaptureStage.allCases {
            let progress = MeasurementProgress(
                stage: stage, overallProgress: 0, stageProgress: 0,
                elapsedSeconds: 0, remainingSeconds: 0, framesAnalysed: 0,
                usableFrames: 0, backgroundIsReady: false, hints: [], latestSample: nil
            )
            XCTAssertFalse(progress.stageDescription.isEmpty,
                           "\(stage.rawValue) has no description")
            XCTAssertFalse(progress.stageDescription.contains("."),
                           "stage descriptions are labels, not sentences")
        }
    }
}

import XCTest
@testable import Lucid

final class CaptureFormatSelectorTests: XCTestCase {

    private let requirements = CaptureRequirements.measurement

    func testNoFormatAtTheRequiredFrameRateReturnsNothing() {
        let formats = [CapabilityFactory.format(minFrameRate: 1, maxFrameRate: 24)]
        XCTAssertNil(CaptureFormatSelector.choose(from: formats, requirements: requirements))
    }

    func testEmptyFormatListReturnsNothing() {
        XCTAssertNil(CaptureFormatSelector.choose(from: [], requirements: requirements))
    }

    func testTheExactTargetResolutionIsPreferred() {
        let formats = [
            CapabilityFactory.format(id: 0, width: 1280, height: 720),
            CapabilityFactory.format(id: 1, width: 1920, height: 1080),
            CapabilityFactory.format(id: 2, width: 3840, height: 2160)
        ]
        let choice = CaptureFormatSelector.choose(from: formats, requirements: requirements)

        XCTAssertEqual(choice?.format.id, 1)
        XCTAssertTrue(choice?.notes.contains { $0.contains("exact") } ?? false)
    }

    func testFullRangeYUVIsPreferredOverVideoRange() {
        let formats = [
            CapabilityFactory.format(id: 0, pixelFormat: MeasurementPixelFormat.videoRangeYUV),
            CapabilityFactory.format(id: 1, pixelFormat: MeasurementPixelFormat.fullRangeYUV)
        ]
        let choice = CaptureFormatSelector.choose(from: formats, requirements: requirements)

        XCTAssertEqual(choice?.format.id, 1,
                       "full range keeps an extra stop of headroom before bright specks clip")
    }

    func testAnHDRFormatIsScoredBelowAnEquivalentNonHDROne() {
        let formats = [
            CapabilityFactory.format(id: 0, supportsVideoHDR: true),
            CapabilityFactory.format(id: 1, supportsVideoHDR: false)
        ]
        let choice = CaptureFormatSelector.choose(from: formats, requirements: requirements)

        XCTAssertEqual(choice?.format.id, 1,
                       "an HDR tone curve breaks the link between pixel value and scattered light")
    }

    func testAnOversizedFormatIsUsedWhenNothingBetterExists() {
        let formats = [CapabilityFactory.format(id: 0, width: 3840, height: 2160)]
        let choice = CaptureFormatSelector.choose(from: formats, requirements: requirements)

        XCTAssertEqual(choice?.format.id, 0)
        XCTAssertEqual(choice?.frameRate, 30)
    }

    func testAnUndersizedFormatIsPreferredOverAMuchLargerOne() {
        let formats = [
            CapabilityFactory.format(id: 0, width: 1280, height: 720),
            CapabilityFactory.format(id: 1, width: 4032, height: 3024)
        ]
        let choice = CaptureFormatSelector.choose(from: formats, requirements: requirements)

        XCTAssertEqual(choice?.format.id, 0,
                       "extra pixels cost analyzer time without adding optical information")
    }

    func testTiesAreBrokenByTheLowestFormatIndex() {
        let formats = [
            CapabilityFactory.format(id: 5),
            CapabilityFactory.format(id: 2)
        ]
        let choice = CaptureFormatSelector.choose(from: formats, requirements: requirements)

        XCTAssertEqual(choice?.format.id, 2, "a calibration profile depends on a stable choice")
    }

    func testAnUnknownPixelFormatIsUsableButNoted() {
        let formats = [CapabilityFactory.format(id: 0, pixelFormat: 0x42475241)]
        let choice = CaptureFormatSelector.choose(from: formats, requirements: requirements)

        XCTAssertNotNil(choice)
        XCTAssertTrue(choice?.notes.contains { $0.contains("non-preferred") } ?? false)
    }

    func testFourCharacterCodeRendering() {
        XCTAssertEqual(
            CaptureFormatDescriptor.fourCharacterCode(MeasurementPixelFormat.fullRangeYUV),
            "420f"
        )
        XCTAssertEqual(
            CaptureFormatDescriptor.fourCharacterCode(MeasurementPixelFormat.videoRangeYUV),
            "420v"
        )
    }
}

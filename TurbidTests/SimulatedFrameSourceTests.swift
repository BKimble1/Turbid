import CoreVideo
import XCTest
@testable import Turbid

/// The Simulator's stand-in for a camera.
///
/// What matters here is that it is a stand-in for the *sensor* only: the frames
/// it produces travel the production path, through a real bi-planar pixel
/// buffer and the real extractor. If the luma encoding here ever stopped being
/// the exact inverse of the extractor's, every simulated measurement would be
/// quietly wrong and nothing else would notice.
final class SimulatedFrameSourceTests: XCTestCase {

    func testTheBufferItProducesIsAFormatTheAnalyzerCanRead() throws {
        let source = SimulatedFrameSource(sample: .lightlyLoaded)
        let buffer = try XCTUnwrap(source.renderFrame(atIndex: 0))

        XCTAssertEqual(CVPixelBufferGetPixelFormatType(buffer),
                       MeasurementPixelFormat.fullRangeYUV)
        XCTAssertGreaterThanOrEqual(CVPixelBufferGetPlaneCount(buffer), 2,
                                    "the analyzer reads a bi-planar buffer's luma plane")

        let extractor = PixelBufferLumaExtractor()
        XCTAssertTrue(extractor.extract(from: buffer, using: .fullFrame))
        XCTAssertEqual(extractor.region.width, CVPixelBufferGetWidth(buffer))
        XCTAssertEqual(extractor.region.height, CVPixelBufferGetHeight(buffer))
    }

    func testWhatComesOutOfTheBufferIsWhatWasRenderedIntoIt() throws {
        let sample = SimulatedSample.heavilyLoaded
        let source = SimulatedFrameSource(sample: sample)
        let buffer = try XCTUnwrap(source.renderFrame(atIndex: 7))

        let extractor = PixelBufferLumaExtractor()
        XCTAssertTrue(extractor.extract(from: buffer, using: .fullFrame))

        let expected = SyntheticFrameFactory.render(sample.scene,
                                                    atTime: source.timestamp(forIndex: 7),
                                                    frameIndex: 7)
        XCTAssertEqual(extractor.region.width, expected.width)
        XCTAssertEqual(extractor.region.height, expected.height)

        // Eight bits of luma is one part in 255, so a round trip can lose half
        // a code. Anything larger means the encoding and the decoding disagree.
        var worst: Float = 0
        for index in expected.values.indices {
            worst = max(worst, abs(extractor.region.values[index] - expected.values[index]))
        }
        XCTAssertLessThanOrEqual(worst, 1.0 / 255.0 / 2 + 1e-6,
                                 "the write must be the exact inverse of the read")
    }

    func testTimestampsAdvanceAtTheDeclaredRateWhateverTheWallClockIsDoing() {
        let realTime = SimulatedFrameSource(frameRate: 30, timeScale: 1)
        let fast = SimulatedFrameSource(frameRate: 30, timeScale: 12)

        XCTAssertEqual(realTime.timestamp(forIndex: 30), 1.0, accuracy: 1e-9)
        XCTAssertEqual(fast.timestamp(forIndex: 30), 1.0, accuracy: 1e-9,
                       "compressing the wall clock must not compress the timeline")
    }

    func testEachSampleDiffersOnlyInWhatIsSuspendedInTheLiquid() {
        let clear = SimulatedSample.clear.scene
        let heavy = SimulatedSample.heavilyLoaded.scene

        XCTAssertEqual(clear.baseLevel, heavy.baseLevel)
        XCTAssertEqual(clear.noiseSigma, heavy.noiseSigma)
        XCTAssertEqual(clear.scratches, heavy.scratches,
                       "the container marks are a property of the container, not the sample")
        XCTAssertEqual(clear.stationaryBlobs, heavy.stationaryBlobs)
        XCTAssertLessThan(clear.specks.count, heavy.specks.count)
    }

    func testTheUnsteadySampleIsTheOnlyOneThatMoves() {
        for sample in SimulatedSample.allCases {
            let translation = sample.scene.globalTranslation
            let moves = translation.dx != 0 || translation.dy != 0
            XCTAssertEqual(moves, sample == .unsteady,
                           "\(sample.rawValue) should \(sample == .unsteady ? "" : "not ")move")
        }
    }

    func testAStoppedSourceDeliversNothing() {
        let source = SimulatedFrameSource(sample: .clear, frameRate: 30, timeScale: 50)
        let counter = CountingConsumer()
        source.attach(counter)
        source.stop()

        // The timer was never started, so nothing can have been delivered.
        XCTAssertEqual(counter.count, 0)
    }
}

/// Counts frames without keeping any of them.
private final class CountingConsumer: CaptureFrameConsuming, @unchecked Sendable {
    private let lock = NSLock()
    private var received = 0

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return received
    }

    func consume(pixelBuffer: CVPixelBuffer, presentationSeconds: Double) {
        lock.lock()
        received += 1
        lock.unlock()
    }
}

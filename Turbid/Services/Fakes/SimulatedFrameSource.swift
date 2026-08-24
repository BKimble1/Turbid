import CoreGraphics
import CoreVideo
import Foundation

/// One of the three optical outcomes, expressed as a synthetic scene.
///
/// These are scenes, not results. What the analyzer makes of them is up to the
/// analyzer: the names describe what was drawn, not what will be reported.
enum SimulatedSample: String, CaseIterable, Sendable, Identifiable {
    case clear
    case lightlyLoaded
    case heavilyLoaded
    /// Not a sample at all: the phone moving. Present so the quality gates can
    /// be seen doing their job without having to shake a Mac.
    case unsteady

    var id: String { rawValue }

    var title: String {
        switch self {
        case .clear: return "Almost nothing suspended"
        case .lightlyLoaded: return "A few particles"
        case .heavilyLoaded: return "Many particles"
        case .unsteady: return "Phone not held still"
        }
    }

    /// Every scene shares the same container marks and sensor noise, so the
    /// only thing that changes between them is what is suspended in the liquid.
    ///
    /// Everything is placed inside `AnalysisRegion.screeningDefault` and clear
    /// of its mask. A scene whose features all sit outside the region would be
    /// a featureless field to the analyzer, which reads as being out of focus:
    /// `Tools/analysis_reference.py` checks each of these against the gates on
    /// the cropped, masked region for exactly that reason.
    var scene: SyntheticScene {
        var scene = SyntheticScene(
            width: 320,
            height: 240,
            baseLevel: 0.14,
            noiseSigma: 0.004,
            vignette: 0.12,
            scratches: [
                // A mark on the container, crossing the region: the thing the
                // background model exists to subtract.
                SyntheticScratch(start: CGPoint(x: 0.28, y: 0.44),
                                 end: CGPoint(x: 0.72, y: 0.50),
                                 brightness: 0.30, widthPixels: 2.0)
            ],
            stationaryBlobs: [
                SyntheticStationaryBlob(center: CGPoint(x: 0.62, y: 0.62),
                                        radiusPixels: 3.0, brightness: 0.25)
            ],
            seed: 0x51CE
        )
        scene.specks = specks
        if self == .unsteady {
            // Well past `QualityThresholds.screening.maximumGlobalMotion`, so
            // every frame is rejected and the window verdict says so.
            // `Tools/analysis_reference.py` puts a 0.4 per-second translation
            // at about twice the limit.
            scene.globalTranslation = CGVector(dx: 0.35, dy: 0.25)
        }
        return scene
    }

    private var specks: [SyntheticSpeck] {
        let count: Int
        let brightness: Float
        switch self {
        case .clear: (count, brightness) = (2, 0.16)
        case .lightlyLoaded, .unsteady: (count, brightness) = (12, 0.30)
        case .heavilyLoaded: (count, brightness) = (30, 0.46)
        }

        // Laid out inside the analysis region and below its excluded ellipse.
        return (0..<count).map { index in
            let column = Double(index % 8)
            let row = Double(index / 8)
            return SyntheticSpeck(
                center: CGPoint(x: 0.30 + column * 0.055, y: 0.47 + row * 0.035),
                orbitRadius: 0.012 + Double(index % 3) * 0.004,
                angularSpeed: 0.9 + Double(index % 5) * 0.2,
                initialPhase: Double(index) * 0.7,
                drift: CGVector(dx: 0.002, dy: 0.004),
                // Small on purpose. These frames are a fraction of a real
                // capture's size, and the analyzer's coarse plane only averages
                // a speck away when the region is much larger than it: at this
                // size an oversized speck reads as the phone moving.
                radiusPixels: 1.0 + Float(index % 3) * 0.2,
                brightness: brightness
            )
        }
    }
}

/// Feeds deterministic synthetic frames to a `CaptureFrameConsuming`.
///
/// This exists so the whole measurement flow can be exercised on the Simulator,
/// which has no camera and no torch. It is only ever reachable through
/// `StubCameraService`, and `AppEnvironment.live()` substitutes that only when
/// `RuntimeEnvironment.allowsSimulatedData` is `true` — a debug build running on
/// the Simulator. A shipped build on a physical iPhone constructs the real
/// `CameraService`, and nothing here can run.
///
/// The frames travel the production path: a real bi-planar pixel buffer, the
/// real extractor, the real analyzer, the real quality gates. What is simulated
/// here is the sensor, never the measurement, and every surface that displays a
/// result from these frames carries the simulated-data banner.
final class SimulatedFrameSource: @unchecked Sendable {

    private let queue = DispatchQueue(label: "com.turbid.simulated-frames", qos: .userInitiated)
    private let lock = NSLock()
    /// Recorded from the presentation timestamps, exactly as the real service
    /// does. Without it a simulated reading would carry empty frame statistics
    /// and be rejected for a stall that never happened.
    private let timing = FrameTimingRecorder()

    private var scene: SyntheticScene
    /// Timestamps advance at this rate, whatever the wall clock is doing.
    private let frameRate: Double
    /// Wall-clock speed relative to `frameRate`. One is real time, which is
    /// what the Simulator uses; a test that wants a whole run in a second
    /// raises it. Presentation timestamps are unaffected, so the analyzer sees
    /// exactly the same sequence either way.
    private let timeScale: Double

    // Touched only on `queue`.
    private var timer: DispatchSourceTimer?
    private var frameIndex = 0
    private var pixelBuffer: CVPixelBuffer?

    // Guarded by `lock`.
    private var consumer: CaptureFrameConsuming?
    private var isRunning = false

    init(sample: SimulatedSample = .lightlyLoaded,
         frameRate: Double = 30,
         timeScale: Double = 1) {
        self.scene = sample.scene
        self.frameRate = max(1, frameRate)
        self.timeScale = max(0.01, timeScale)
    }

    func setSample(_ sample: SimulatedSample) {
        let scene = sample.scene
        queue.async { [weak self] in
            self?.scene = scene
            self?.pixelBuffer = nil
        }
    }

    func attach(_ consumer: CaptureFrameConsuming?) {
        lock.lock()
        self.consumer = consumer
        lock.unlock()
    }

    func start() {
        lock.lock()
        guard !isRunning else {
            lock.unlock()
            return
        }
        isRunning = true
        lock.unlock()

        queue.async { [weak self] in
            guard let self else { return }
            self.frameIndex = 0
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            let interval = 1.0 / (self.frameRate * self.timeScale)
            timer.schedule(deadline: .now() + interval, repeating: interval,
                           leeway: .microseconds(200))
            timer.setEventHandler { [weak self] in self?.emitFrame() }
            self.timer?.cancel()
            self.timer = timer
            timer.resume()
        }
    }

    func stop() {
        lock.lock()
        isRunning = false
        lock.unlock()

        queue.async { [weak self] in
            self?.timer?.cancel()
            self?.timer = nil
        }
    }

    // MARK: - Frame production

    private func emitFrame() {
        lock.lock()
        let consumer = self.consumer
        let running = isRunning
        lock.unlock()

        guard running, let consumer else { return }

        let index = frameIndex
        frameIndex += 1
        let seconds = timestamp(forIndex: index)
        timing.record(presentationSeconds: seconds)
        guard let buffer = renderFrame(atIndex: index) else { return }
        consumer.consume(pixelBuffer: buffer, presentationSeconds: seconds)
    }

    func frameStatistics() -> FrameTimingStatistics { timing.statistics() }

    func resetFrameStatistics() { timing.reset() }

    func timestamp(forIndex index: Int) -> Double { Double(index) / frameRate }

    /// Renders one frame into the reusable buffer.
    ///
    /// Separated from delivery so a test can check that what comes back out of
    /// the buffer is what went in: the luma encoding here has to be the exact
    /// inverse of the one the extractor applies, and nothing else would notice
    /// if it stopped being.
    ///
    /// - Important: runs on `queue`, or on any thread while the source is
    ///   stopped. It touches the reused buffer, which nothing else may be
    ///   reading at the same time.
    func renderFrame(atIndex index: Int) -> CVPixelBuffer? {
        let image = SyntheticFrameFactory.render(scene,
                                                 atTime: timestamp(forIndex: index),
                                                 frameIndex: index)
        guard let buffer = buffer(width: image.width, height: image.height),
              write(image, into: buffer) else { return nil }
        return buffer
    }

    /// One buffer, reused: allocating a new one per frame is exactly the
    /// pattern the real pipeline is written to avoid, and the simulated path
    /// should not have a different performance shape from the real one.
    private func buffer(width: Int, height: Int) -> CVPixelBuffer? {
        if let pixelBuffer,
           CVPixelBufferGetWidth(pixelBuffer) == width,
           CVPixelBufferGetHeight(pixelBuffer) == height {
            return pixelBuffer
        }

        var created: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
        ]
        let status = CVPixelBufferCreate(kCFAllocatorDefault,
                                         width, height,
                                         MeasurementPixelFormat.fullRangeYUV,
                                         attributes as CFDictionary,
                                         &created)
        guard status == kCVReturnSuccess, let created else {
            TurbidLog.camera.error("Simulated frame buffer could not be created.")
            return nil
        }
        pixelBuffer = created
        return created
    }

    /// Writes normalized luma into the Y plane and a neutral chroma plane.
    private func write(_ image: LumaImage, into buffer: CVPixelBuffer) -> Bool {
        guard CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess else { return false }
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let lumaPlane = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return false }
        let lumaBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let lumaHeight = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let lumaWidth = CVPixelBufferGetWidthOfPlane(buffer, 0)
        let luma = lumaPlane.assumingMemoryBound(to: UInt8.self)

        for row in 0..<min(lumaHeight, image.height) {
            let destination = luma + row * lumaBytesPerRow
            let source = row * image.width
            for column in 0..<min(lumaWidth, image.width) {
                // Full range: the whole 0...255 code range is luma, which is
                // the inverse of `FrameNormalization.normalize(code:range:)`.
                let value = min(max(image.values[source + column], 0), 1)
                destination[column] = UInt8((value * 255).rounded())
            }
        }

        if CVPixelBufferGetPlaneCount(buffer) > 1,
           let chromaPlane = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) {
            let chromaBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
            let chromaHeight = CVPixelBufferGetHeightOfPlane(buffer, 1)
            // 128 in both channels is neutral: the analyzer reads luma only,
            // but leaving chroma uninitialised would make the preview garbage.
            memset(chromaPlane, 128, chromaBytesPerRow * chromaHeight)
        }

        return true
    }
}

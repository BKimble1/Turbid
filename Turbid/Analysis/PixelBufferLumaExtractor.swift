import CoreVideo
import Foundation

/// Copies a region of a pixel buffer's luma plane into a reusable `LumaImage`.
///
/// Owns its destination buffer and refills it in place. Nothing is allocated
/// per frame once the region size is known, which is what keeps a 30 fps stream
/// from producing 30 large allocations a second.
final class PixelBufferLumaExtractor {

    private(set) var region = LumaImage(width: 0, height: 0)
    private(set) var lastPixelRect: PixelRect?

    /// Reads the luma plane of a bi-planar YUV buffer.
    ///
    /// - Returns: `false` when the buffer is not a format the analyzer can read,
    ///   rather than guessing at an unknown layout.
    @discardableResult
    func extract(from pixelBuffer: CVPixelBuffer, using analysisRegion: AnalysisRegion) -> Bool {
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        let range: FrameNormalization.LumaRange
        switch format {
        case MeasurementPixelFormat.fullRangeYUV:
            range = .full
        case MeasurementPixelFormat.videoRangeYUV:
            range = .video
        default:
            TurbidLog.analysis.error(
                "Unsupported pixel format \(CaptureFormatDescriptor.fourCharacterCode(format), privacy: .public)"
            )
            return false
        }

        guard CVPixelBufferGetPlaneCount(pixelBuffer) >= 1 else { return false }

        let planeWidth = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let planeHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        guard let pixelRect = analysisRegion.pixelRect(inWidth: planeWidth, height: planeHeight) else {
            return false
        }

        guard CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess else {
            return false
        }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else {
            return false
        }
        let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)

        prepareBuffer(for: pixelRect)

        let source = baseAddress.assumingMemoryBound(to: UInt8.self)
        region.values.withUnsafeMutableBufferPointer { destination in
            for row in 0..<pixelRect.height {
                let sourceRow = source + (pixelRect.y + row) * bytesPerRow + pixelRect.x
                let destinationRow = row * pixelRect.width
                for column in 0..<pixelRect.width {
                    destination[destinationRow + column] =
                        FrameNormalization.normalize(code: sourceRow[column], range: range)
                }
            }
        }

        return true
    }

    /// Reallocates only when the region's size actually changes.
    private func prepareBuffer(for pixelRect: PixelRect) {
        if lastPixelRect?.width != pixelRect.width || lastPixelRect?.height != pixelRect.height {
            region = LumaImage(width: pixelRect.width, height: pixelRect.height)
        }
        lastPixelRect = pixelRect
    }
}

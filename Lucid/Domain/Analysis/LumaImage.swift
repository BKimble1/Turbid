import Foundation

/// A single-channel image of normalized luma, row-major.
///
/// Values are nominally in `0...1`, where 1 is the brightest code the camera
/// can emit. They are **not** absolute optical power: see
/// `FrameNormalization` for why no transfer function is inverted.
struct LumaImage: Equatable, Sendable {
    let width: Int
    let height: Int
    /// `width * height` samples, row-major, top-left origin.
    var values: [Float]

    var count: Int { width * height }

    init(width: Int, height: Int, fill: Float = 0) {
        self.width = max(0, width)
        self.height = max(0, height)
        self.values = Array(repeating: fill, count: self.width * self.height)
    }

    /// - Returns: `nil` when `values` does not match `width * height`, so a
    ///   mismatched buffer can never be silently misread as an image.
    init?(width: Int, height: Int, values: [Float]) {
        guard width > 0, height > 0, values.count == width * height else { return nil }
        self.width = width
        self.height = height
        self.values = values
    }

    subscript(x: Int, y: Int) -> Float {
        get {
            precondition(x >= 0 && x < width && y >= 0 && y < height, "sample out of bounds")
            return values[y * width + x]
        }
        set {
            precondition(x >= 0 && x < width && y >= 0 && y < height, "sample out of bounds")
            values[y * width + x] = newValue
        }
    }

    /// Reads without bounds checking in hot loops; callers must have already
    /// validated the index.
    func sample(atIndex index: Int) -> Float { values[index] }

    mutating func fill(_ value: Float) {
        for index in values.indices { values[index] = value }
    }

    /// Box-averages into `destination`, which fixes the output size.
    ///
    /// Box averaging is the right reduction for the *statistics* plane: it is
    /// an unbiased estimate of local mean brightness and it suppresses sensor
    /// noise by roughly the square root of the box area. It is emphatically the
    /// wrong thing to do before speck detection, which is why detection runs on
    /// the full-resolution region instead.
    func boxAverage(into destination: inout LumaImage) {
        guard destination.width > 0, destination.height > 0,
              width > 0, height > 0 else { return }

        for outputY in 0..<destination.height {
            let startY = outputY * height / destination.height
            let endY = max(startY + 1, (outputY + 1) * height / destination.height)

            for outputX in 0..<destination.width {
                let startX = outputX * width / destination.width
                let endX = max(startX + 1, (outputX + 1) * width / destination.width)

                var total: Float = 0
                var samples = 0
                for y in startY..<min(endY, height) {
                    let rowOffset = y * width
                    for x in startX..<min(endX, width) {
                        total += values[rowOffset + x]
                        samples += 1
                    }
                }
                destination.values[outputY * destination.width + outputX] =
                    samples > 0 ? total / Float(samples) : 0
            }
        }
    }
}

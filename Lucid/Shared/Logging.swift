import Foundation
import OSLog

/// Central OSLog categories. Never log image data, sample values or user data.
enum LucidLog {
    static let subsystem = Bundle.main.bundleIdentifier ?? "com.lucid.Lucid"

    static let app = Logger(subsystem: subsystem, category: "app")
    static let permission = Logger(subsystem: subsystem, category: "permission")
    static let measurement = Logger(subsystem: subsystem, category: "measurement")
    static let camera = Logger(subsystem: subsystem, category: "camera")
    static let analysis = Logger(subsystem: subsystem, category: "analysis")
    static let calibration = Logger(subsystem: subsystem, category: "calibration")
}

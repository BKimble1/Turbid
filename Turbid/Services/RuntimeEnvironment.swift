import Foundation

/// Compile-time facts about how this binary was built and where it runs.
enum RuntimeEnvironment {
    static var isSimulator: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }

    static var isDebugBuild: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    /// Illustrative sample data may only ever be shown in a debug build running
    /// on the Simulator, so a shipped build on a physical iPhone cannot display
    /// anything that could be mistaken for a measurement.
    static var allowsSimulatedData: Bool { isSimulator && isDebugBuild }
}

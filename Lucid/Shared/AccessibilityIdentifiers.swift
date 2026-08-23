import Foundation

/// Accessibility identifiers shared by the views and the UI tests.
///
/// Declared once so a renamed control breaks the build rather than a test, and
/// so the UI tests never depend on user-visible copy — that copy has to be free
/// to change, and a test that pins it would make careful wording expensive.
enum AccessibilityID {
    enum Onboarding {
        static let screen = "onboarding.screen"
        static let acknowledge = "onboarding.acknowledge"
        static let continueButton = "onboarding.continue"
    }

    enum Root {
        static let screen = "root.screen"
        static let start = "root.start"
        static let openSettings = "root.openSettings"
        static let permissionStatus = "root.permissionStatus"
        static let modePicker = "root.modePicker"
        static let calibrationLink = "root.calibration"
        static let lastResult = "root.lastResult"
    }

    enum Setup {
        static let screen = "setup.screen"
        static let checklist = "setup.checklist"
        static let begin = "setup.begin"
        static let cancel = "setup.cancel"
        static let hint = "setup.hint"
    }

    enum Measurement {
        static let screen = "measurement.screen"
        static let stage = "measurement.stage"
        static let progress = "measurement.progress"
        static let chart = "measurement.chart"
        static let hints = "measurement.hints"
        static let cancel = "measurement.cancel"
    }

    enum Result {
        static let screen = "result.screen"
        static let headline = "result.headline"
        static let ntu = "result.ntu"
        static let index = "result.index"
        static let disclaimer = "result.disclaimer"
        static let deepDive = "result.deepDive"
        static let measureAgain = "result.measureAgain"
        static let done = "result.done"
        static let lowQuality = "result.lowQuality"
    }

    enum DeepDive {
        static let screen = "deepDive.screen"
        static let close = "deepDive.close"
        static let qualitySection = "deepDive.quality"
        static let provenanceSection = "deepDive.provenance"
    }

    enum Calibration {
        static let screen = "calibration.screen"
        static let profileList = "calibration.profiles"
        static let compatibility = "calibration.compatibility"
        static let startRun = "calibration.startRun"
        static let safetyNotice = "calibration.safetyNotice"
        static let requirements = "calibration.requirements"
    }
}

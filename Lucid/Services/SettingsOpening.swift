import Foundation
import UIKit

/// Opens the app's page in the Settings app. Behind a protocol so the denied and
/// restricted flows can be tested without launching Settings.
protocol SettingsOpening: Sendable {
    func openAppSettings()
}

struct SystemSettingsOpener: SettingsOpening {
    func openAppSettings() {
        Task { @MainActor in
            guard let url = URL(string: UIApplication.openSettingsURLString),
                  UIApplication.shared.canOpenURL(url) else {
                LucidLog.app.error("Unable to open the Settings URL for this app.")
                return
            }
            UIApplication.shared.open(url)
        }
    }
}

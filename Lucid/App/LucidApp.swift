import SwiftUI

@main
struct LucidApp: App {
    private let environment: AppEnvironment

    init() {
        // The UI-test environment requires both a debug Simulator build and an
        // explicit launch argument, so a shipped binary always takes the live
        // path regardless of what is on the command line.
        environment = UITestConfiguration.isActive
            ? UITestConfiguration.environment(scenario: UITestConfiguration.scenario)
            : AppEnvironment.live()
    }

    var body: some Scene {
        WindowGroup {
            RootView(environment: environment)
        }
    }
}

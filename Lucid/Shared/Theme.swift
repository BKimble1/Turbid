import SwiftUI

/// Design tokens. Every spacing, radius and semantic colour used by the app
/// comes from here so the Phase 4 visual pass has a single place to change.
enum Theme {
    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 16
        static let lg: CGFloat = 24
        static let xl: CGFloat = 32
    }

    enum Radius {
        static let card: CGFloat = 16
        static let control: CGFloat = 12
    }

    enum Palette {
        /// System-adaptive so Light and Dark both stay legible without a
        /// hand-tuned asset catalogue this early.
        static let surface = Color(uiColor: .secondarySystemBackground)
        static let separator = Color(uiColor: .separator)
        static let primaryText = Color(uiColor: .label)
        static let secondaryText = Color(uiColor: .secondaryLabel)
        static let accent = Color.cyan
        static let warning = Color.orange
        static let critical = Color.red
        static let positive = Color.green
        /// Used only by clearly-labelled simulated content.
        static let simulated = Color.purple
    }

    enum Layout {
        /// Minimum hit target required by the Human Interface Guidelines.
        static let minimumTouchTarget: CGFloat = 44
    }
}

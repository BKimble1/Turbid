import SwiftUI
import UIKit

/// Design tokens.
///
/// Every colour, spacing and radius in the app comes from here. Colours are
/// built as dynamic `UIColor`s rather than asset-catalogue entries so that the
/// exact value, and the reason for it, is visible in source.
///
/// The direction is a deep navy and charcoal ground with cyan and blue accents.
/// Dark appearance is where that reads best, so it is defined first; the light
/// palette is not a lightened copy of it. Cyan on white is close to invisible,
/// so light appearance moves the accent to a deep blue and keeps the navy for
/// text. Both are chosen to keep body text near or above a 7:1 contrast ratio
/// against its own background, and interactive tint above 4.5:1.
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

    enum Layout {
        /// Minimum hit target required by the Human Interface Guidelines.
        static let minimumTouchTarget: CGFloat = 44
        /// Height of the live preview on the measurement screen.
        static let previewHeight: CGFloat = 340
        static let chartHeight: CGFloat = 180
    }

    enum Palette {
        /// The app's ground. Deep navy in dark, near-white in light.
        static let background = dynamic(dark: 0x0A0F1A, light: 0xF4F6FA)
        /// Cards and grouped rows.
        static let surface = dynamic(dark: 0x141B29, light: 0xFFFFFF)
        /// A second level of grouping inside a card.
        static let surfaceElevated = dynamic(dark: 0x1D2637, light: 0xEDF1F7)
        static let separator = dynamic(dark: 0x2A3547, light: 0xD5DCE8)

        static let primaryText = dynamic(dark: 0xF2F5FA, light: 0x0F1724)
        static let secondaryText = dynamic(dark: 0xA3B0C4, light: 0x4A5668)

        /// Interactive tint. Cyan in dark, a deeper blue in light so it stays
        /// legible on a white card.
        static let accent = dynamic(dark: 0x4FD8E8, light: 0x0A6C9E)
        /// Used behind the accent, never for text.
        static let accentMuted = dynamic(dark: 0x1B4E5C, light: 0xD3ECF6)

        static let warning = dynamic(dark: 0xF2B441, light: 0x8A5A00)
        static let critical = dynamic(dark: 0xFF7B72, light: 0xB3261E)
        static let positive = dynamic(dark: 0x5CD6A9, light: 0x0B6B4F)
        /// Only ever used by content that is clearly labelled as simulated.
        static let simulated = dynamic(dark: 0xC79BFF, light: 0x6B3FA0)

        /// The colour for a clarity state. Always paired with a symbol and a
        /// word, never used as the only signal.
        static func clarity(_ clarity: OpticalClarityClass) -> Color {
            switch clarity {
            case .crystalClear: return positive
            case .slightlyTurbid: return warning
            case .highParticleCount: return critical
            }
        }

        /// The raw and smoothed chart series, distinguishable without colour by
        /// line weight and dashing as well.
        static let chartRaw = dynamic(dark: 0x5E7290, light: 0x93A2B8)
        static let chartSmoothed = accent

        private static func dynamic(dark: UInt32, light: UInt32) -> Color {
            Color(uiColor: UIColor { traits in
                traits.userInterfaceStyle == .dark ? UIColor(rgb: dark) : UIColor(rgb: light)
            })
        }
    }

    /// Motion that is switched off entirely under Reduce Motion.
    ///
    /// Returning `nil` rather than a zero-duration animation: SwiftUI treats
    /// `nil` as "do not animate this change at all", which is what Reduce
    /// Motion asks for.
    enum Motion {
        static func progress(reduceMotion: Bool) -> Animation? {
            reduceMotion ? nil : .easeInOut(duration: 0.25)
        }
    }
}

private extension UIColor {
    /// Opaque colour from a 24-bit `0xRRGGBB` literal, in the extended sRGB
    /// space SwiftUI already works in.
    convenience init(rgb: UInt32) {
        self.init(
            red: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1
        )
    }
}

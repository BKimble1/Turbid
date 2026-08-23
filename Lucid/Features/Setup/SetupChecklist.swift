import Foundation

/// What the person holding the phone has to do before a measurement is worth
/// taking.
///
/// Every item exists because a specific quality gate fires when it is ignored,
/// and each one names that gate. Guidance that cannot be traced to something the
/// app actually checks is guidance nobody needs to follow.
struct SetupChecklistItem: Identifiable, Equatable, Sendable {
    let id: String
    let instruction: String
    let symbolName: String
    /// The gate this item exists to avoid.
    let guards: MeasurementRejectionReason
}

enum SetupChecklist {
    static let items: [SetupChecklistItem] = [
        SetupChecklistItem(
            id: "clean-container",
            instruction: "Use a clean, clear, colourless container and wipe the outside dry.",
            symbolName: "sparkles",
            guards: .torchHotspot
        ),
        SetupChecklistItem(
            id: "settle",
            instruction: "Let the sample stand for a minute so bubbles rise out of it.",
            symbolName: "bubbles.and.sparkles",
            guards: .saturatedRegion
        ),
        SetupChecklistItem(
            id: "dark-room",
            instruction: "Measure in a dim room. The torch should be the main light on the sample.",
            symbolName: "moon.stars",
            guards: .exposureUnstable
        ),
        SetupChecklistItem(
            id: "dark-background",
            instruction: "Put something matte and dark behind the container.",
            symbolName: "square.fill",
            guards: .regionTooBright
        ),
        SetupChecklistItem(
            id: "angle",
            instruction: "Hold the phone so the torch does not reflect straight back off the glass.",
            symbolName: "arrow.triangle.2.circlepath",
            guards: .torchHotspot
        ),
        SetupChecklistItem(
            id: "steady",
            instruction: "Rest the phone against something. Hold it still for the whole measurement.",
            symbolName: "hand.raised",
            guards: .cameraMoved
        ),
        SetupChecklistItem(
            id: "fill-region",
            instruction: "Fill the outlined region with liquid only — no rim, no meniscus, no label.",
            symbolName: "viewfinder",
            guards: .outOfFocus
        )
    ]
}

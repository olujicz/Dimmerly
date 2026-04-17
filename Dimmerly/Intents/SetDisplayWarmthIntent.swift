//
//  SetDisplayWarmthIntent.swift
//  Dimmerly
//
//  App Intent to set warmth for a specific display via Shortcuts.app.
//

import AppIntents
import CoreGraphics

struct SetDisplayWarmthIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Display Warmth"
    static let description: IntentDescription = .init("Sets the color warmth of a specific display.")

    @Parameter(title: "Display")
    var display: DisplayEntity

    @Parameter(
        title: "Warmth",
        description: "Warmth percentage (0–100)",
        default: 0.0,
        controlStyle: .slider,
        inclusiveRange: (0.0, 100.0)
    )
    var warmth: Double

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let displayID = CGDirectDisplayID(display.id) else {
            throw DisplayIntentError.invalidDisplay
        }
        let value = warmth / 100.0
        BrightnessManager.shared.setWarmth(for: displayID, to: value)
        return .result()
    }
}

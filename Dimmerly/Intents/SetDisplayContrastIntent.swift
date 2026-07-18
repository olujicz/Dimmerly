//
//  SetDisplayContrastIntent.swift
//  Dimmerly
//
//  App Intent to set contrast for a specific display via Shortcuts.app.
//

import AppIntents
import CoreGraphics

struct SetDisplayContrastIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Display Contrast"
    static let description: IntentDescription = .init("Sets the contrast of a specific display.")

    @Parameter(title: "Display")
    var display: DisplayEntity

    @Parameter(
        title: "Contrast",
        description: "Contrast percentage (0–100, 50 = neutral)",
        default: 50.0,
        controlStyle: .slider,
        inclusiveRange: (0.0, 100.0)
    )
    var contrast: Double

    @MainActor
    func perform() async throws -> some IntentResult {
        try perform(using: LiveDisplayIntentCommand.shared)
        return .result()
    }

    @MainActor
    func perform(using command: DisplayIntentCommanding) throws {
        let displayID = try ConnectedDisplayResolver.resolve(display) {
            command.connectedDisplayIDs
        }
        command.setContrast(contrast / 100, for: displayID)
    }
}

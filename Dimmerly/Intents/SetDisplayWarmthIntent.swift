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
        try perform(using: LiveDisplayIntentCommand.shared)
        return .result()
    }

    @MainActor
    func perform(using command: DisplayIntentCommanding) throws {
        let displayID = try ConnectedDisplayResolver.resolve(display) {
            command.connectedDisplayIDs
        }
        command.setWarmth(warmth / 100, for: displayID)
    }
}

//
//  SetDisplayBrightnessIntent.swift
//  Dimmerly
//
//  App Intent to set brightness for a specific display via Shortcuts.app.
//

import AppIntents
import CoreGraphics

struct SetDisplayBrightnessIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Display Brightness"
    static let description: IntentDescription = .init("Sets the brightness of a specific display.")

    @Parameter(title: "Display")
    var display: DisplayEntity

    @Parameter(
        title: "Brightness",
        description: "Brightness percentage (10–100)",
        default: 100.0,
        controlStyle: .slider,
        inclusiveRange: (10.0, 100.0)
    )
    var brightness: Double

    @MainActor
    func perform() async throws -> some IntentResult {
        try perform(using: LiveDisplayIntentCommand.shared)
        return .result()
    }

    @MainActor
    func perform(using command: DisplayIntentCommanding) throws {
        guard BrightnessManager.brightnessPercentageRange.contains(brightness) else {
            throw DisplayIntentError.brightnessOutOfRange
        }
        let displayID = try ConnectedDisplayResolver.resolve(display) {
            command.connectedDisplayIDs
        }
        command.setBrightness(brightness / 100, for: displayID)
    }
}

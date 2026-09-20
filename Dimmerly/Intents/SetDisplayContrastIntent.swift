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

    #if compiler(>=6.4)
        @available(macOS 27.0, *)
        static let allowedExecutionTargets: IntentExecutionTargets = .main
    #endif

    static var parameterSummary: some ParameterSummary {
        Summary("Set the contrast of \(\.$display) to \(\.$contrast) percent")
    }

    @Parameter(
        title: "Display",
        requestValueDialog: "Which display should I control?",
        requestDisambiguationDialog: "Which display do you want to control?"
    )
    var display: DisplayEntity

    @Parameter(
        title: "Contrast",
        description: "Contrast percentage (0–100, 50 = neutral)",
        default: 50.0,
        controlStyle: .slider,
        inclusiveRange: (0.0, 100.0),
        requestValueDialog: "What contrast percentage should I set?"
    )
    var contrast: Double

    @MainActor
    func perform() async throws -> some IntentResult {
        try perform(using: LiveDisplayIntentCommand.shared)
        return .result()
    }

    @MainActor
    func perform(using command: DisplayIntentCommanding) throws {
        guard (0.0 ... 100.0).contains(contrast) else {
            throw DisplayIntentError.contrastOutOfRange
        }
        let displayID = try ConnectedDisplayResolver.resolve(display) {
            command.connectedDisplayDescriptors
        }
        command.setContrast(contrast / 100, for: displayID)
    }
}

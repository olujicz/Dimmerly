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

    #if compiler(>=6.4)
        @available(macOS 27.0, *)
        static let allowedExecutionTargets: IntentExecutionTargets = .main
    #endif

    static var parameterSummary: some ParameterSummary {
        Summary("Set the warmth of \(\.$display) to \(\.$warmth) percent")
    }

    @Parameter(
        title: "Display",
        requestValueDialog: "Which display should I control?",
        requestDisambiguationDialog: "Which display do you want to control?"
    )
    var display: DisplayEntity

    @Parameter(
        title: "Warmth",
        description: "Warmth percentage (0–100)",
        default: 0.0,
        controlStyle: .slider,
        inclusiveRange: (0.0, 100.0),
        requestValueDialog: "What warmth percentage should I set?"
    )
    var warmth: Double

    @MainActor
    func perform() async throws -> some IntentResult {
        try perform(using: LiveDisplayIntentCommand.shared)
        return .result()
    }

    @MainActor
    func perform(using command: DisplayIntentCommanding) throws {
        guard (0.0 ... 100.0).contains(warmth) else {
            throw DisplayIntentError.warmthOutOfRange
        }
        let displayID = try ConnectedDisplayResolver.resolve(display) {
            command.connectedDisplayIDs
        }
        command.setWarmth(warmth / 100, for: displayID)
    }
}

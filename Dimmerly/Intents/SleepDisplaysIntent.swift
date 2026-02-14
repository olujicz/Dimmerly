//
//  SleepDisplaysIntent.swift
//  Dimmerly
//
//  App Intent to sleep/dim all displays via Shortcuts.app.
//

import AppIntents

struct SleepDisplaysIntent: AppIntent {
    static let title: LocalizedStringResource = "Sleep Displays"
    static let description: IntentDescription = .init("Dims or sleeps all connected displays using Dimmerly.")

    @MainActor
    func perform() async throws -> some IntentResult {
        DisplayAction.performSleep(settings: AppSettings.shared)
        return .result()
    }
}

//
//  SleepDisplaysIntent.swift
//  Dimmerly
//
//  App Intent to sleep/dim all displays via Shortcuts.app.
//

import AppIntents

struct SleepDisplaysIntent: AppIntent {
    #if APPSTORE
        static let title: LocalizedStringResource = "Dim Displays"
        static let description: IntentDescription = .init("Dims all connected displays using Dimmerly.")
    #else
        static let title: LocalizedStringResource = "Sleep Displays"
        static let description: IntentDescription = .init("Dims or sleeps all connected displays using Dimmerly.")
    #endif

    #if compiler(>=6.4)
        @available(macOS 27.0, *)
        static let allowedExecutionTargets: IntentExecutionTargets = .main
    #endif

    @MainActor
    func perform() async throws -> some IntentResult {
        DisplayAction.performSleep(settings: AppSettings.shared)
        return .result()
    }
}

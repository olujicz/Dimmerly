//
//  DisplayController.swift
//  Dimmerly
//
//  Controller for managing display sleep and dim operations.
//

import AppKit
import Foundation

/// Shared sleep/dim logic used by menu button, global shortcut, Shortcuts.app, and widgets
enum DisplayAction {
    @MainActor
    static func performSleep(settings: AppSettings) {
        #if APPSTORE
        // Sandbox prevents spawning pmset — always use gamma-based screen blanking
        ScreenBlanker.shared.ignoreMouseMovement = settings.ignoreMouseMovement
        ScreenBlanker.shared.useFadeTransition = settings.fadeTransition && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        ScreenBlanker.shared.blank()
        #else
        if settings.preventScreenLock {
            ScreenBlanker.shared.ignoreMouseMovement = settings.ignoreMouseMovement
            ScreenBlanker.shared.useFadeTransition = settings.fadeTransition && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            ScreenBlanker.shared.blank()
        } else {
            Task {
                let result = await DisplayController.sleepDisplays()
                if case .failure(let error) = result {
                    AlertPresenter.showError(error)
                }
            }
        }
        #endif
    }
}

#if !APPSTORE
/// Controller responsible for putting displays to sleep via pmset
struct DisplayController {
    /// Injectable process runner for testing. When non-nil, called instead of spawning pmset.
    nonisolated(unsafe) static var processRunner: ((@Sendable () async -> Result<Void, DisplayError>))?

    /// Puts all connected displays to sleep asynchronously using `pmset displaysleepnow`.
    static func sleepDisplays() async -> Result<Void, DisplayError> {
        // Allow tests to intercept without actually sleeping displays
        if let runner = processRunner {
            return await runner()
        }

        let pmsetPath = "/usr/bin/pmset"
        guard FileManager.default.isExecutableFile(atPath: pmsetPath) else {
            return .failure(.pmsetNotFound)
        }

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: pmsetPath)
                process.arguments = ["displaysleepnow"]

                do {
                    try process.run()
                    process.waitUntilExit()
                    if process.terminationStatus == 0 {
                        continuation.resume(returning: .success(()))
                    } else {
                        continuation.resume(returning: .failure(.pmsetFailed(status: process.terminationStatus)))
                    }
                } catch {
                    continuation.resume(returning: .failure(.unknownError(error.localizedDescription)))
                }
            }
        }
    }
}
#endif

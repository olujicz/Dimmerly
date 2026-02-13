//
//  DisplayController.swift
//  Dimmerly
//
//  Controller for managing display sleep and dim operations.
//

import AppKit
import Foundation

/// Shared display sleep/blanking logic for all app entry points.
///
/// This enum provides a single consistent implementation for the "sleep displays" action,
/// which can be triggered from:
/// - Menu bar button
/// - Global keyboard shortcut
/// - App Intents (Shortcuts.app, Siri)
/// - Home Screen widgets
///
/// Build configuration behavior:
/// - **App Store build**: Always uses gamma-based blanking (sandbox prevents pmset)
/// - **Direct download build**: Respects user preference (pmset vs blanking)
enum DisplayAction {
    /// Performs the display sleep/blank action based on app settings and build configuration.
    ///
    /// Decision tree:
    /// 1. If App Store build → always use ScreenBlanker (sandbox restriction)
    /// 2. If "Prevent Screen Lock" enabled → use ScreenBlanker (user preference)
    /// 3. Otherwise → use pmset displaysleepnow (real display sleep)
    ///
    /// User preferences applied to ScreenBlanker:
    /// - `ignoreMouseMovement`: Whether to ignore mouse movement (only wake on click/key)
    /// - `fadeTransition`: Whether to animate fade (respects Reduce Motion setting)
    /// - `requireEscapeToDismiss`: Whether Escape key is required (vs any input)
    ///
    /// - Parameter settings: Current app settings
    @MainActor
    static func performSleep(settings: AppSettings) {
        #if APPSTORE
        // Sandbox prevents spawning pmset — always use gamma-based screen blanking
        ScreenBlanker.shared.ignoreMouseMovement = settings.ignoreMouseMovement
        ScreenBlanker.shared.useFadeTransition = settings.fadeTransition && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        ScreenBlanker.shared.requireEscapeToDismiss = settings.requireEscapeToDismiss
        ScreenBlanker.shared.blank()
        #else
        if settings.preventScreenLock {
            // User wants blanking to avoid triggering screen lock
            ScreenBlanker.shared.ignoreMouseMovement = settings.ignoreMouseMovement
            ScreenBlanker.shared.useFadeTransition = settings.fadeTransition && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            ScreenBlanker.shared.requireEscapeToDismiss = settings.requireEscapeToDismiss
            ScreenBlanker.shared.blank()
        } else {
            // Use real display sleep via pmset
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
/// Controller responsible for putting displays to sleep via the pmset command-line tool.
///
/// This controller is only compiled for direct download builds (not App Store builds),
/// because the App Sandbox prevents spawning command-line tools like pmset.
///
/// Mechanism:
/// - Executes `/usr/bin/pmset displaysleepnow` to trigger native display sleep
/// - This is the same command macOS uses internally for display sleep timers
/// - Unlike ScreenBlanker (gamma-based), this actually powers down displays
///
/// Advantages over ScreenBlanker:
/// - Real power savings (displays physically turn off)
/// - System integration (respects pmset config, triggers sleep sensors)
/// - No GPU usage (gamma-based blanking keeps GPU active)
///
/// Disadvantages:
/// - Triggers screen lock on macOS Sonoma+ (security policy change)
/// - Not available in App Store builds (sandbox restriction)
struct DisplayController {
    /// Injectable process runner for testing.
    ///
    /// When non-nil, this closure is called instead of spawning pmset. This allows
    /// unit tests to verify sleep logic without actually putting displays to sleep.
    ///
    /// Safety: Marked `nonisolated(unsafe)` because:
    /// - Only mutated during test setup (before concurrent access begins)
    /// - Becomes effectively read-only for the test duration
    /// - Tests run serially, preventing data races
    nonisolated(unsafe) static var processRunner: ((@Sendable () async -> Result<Void, DisplayError>))?

    /// Puts all connected displays to sleep using `pmset displaysleepnow`.
    ///
    /// This method:
    /// 1. Verifies pmset exists at /usr/bin/pmset
    /// 2. Spawns pmset process with "displaysleepnow" argument
    /// 3. Waits for completion on a background queue (non-blocking)
    /// 4. Returns success/failure based on exit code
    ///
    /// Error cases:
    /// - `.pmsetNotFound`: pmset binary doesn't exist or isn't executable
    /// - `.pmsetFailed(status)`: pmset ran but returned non-zero exit code
    /// - `.unknownError(message)`: Process spawn failed (e.g., insufficient permissions)
    ///
    /// - Returns: Result indicating success or specific failure type
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
            // Execute on background queue to avoid blocking the main thread
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

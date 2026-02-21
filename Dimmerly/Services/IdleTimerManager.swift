//
//  IdleTimerManager.swift
//  Dimmerly
//
//  Monitors system idle time and triggers auto-dim after a configurable inactivity period.
//  Uses CoreGraphics HID event APIs to detect user activity (keyboard, mouse, trackpad).
//
//  Design decisions:
//  - Poll every 10 seconds (balance between responsiveness and CPU usage)
//  - Fire once per idle period (prevents repeated triggers if user stays idle)
//  - Reset on activity (allows firing again after next idle period)
//

import CoreGraphics
import Foundation

/// Manages automatic display blanking after a period of user inactivity.
///
/// How it works:
/// 1. Polls system idle time every 10 seconds via CGEventSource
/// 2. Compares idle time to configured threshold (user setting in minutes)
/// 3. Fires callback once when threshold is crossed
/// 4. Waits for activity before allowing another fire (prevents spam)
///
/// HID event source: CGEventSource.secondsSinceLastEventType(.hidSystemState) tracks
/// all Human Interface Device input: keyboard, mouse, trackpad, but excludes programmatic
/// events (doesn't count fake events from accessibility APIs or remote control software).
///
/// Thread safety: All methods must be called from the main actor.
@MainActor
class IdleTimerManager {
    /// Callback invoked once when the idle threshold is reached
    var onIdleThresholdReached: (() -> Void)?

    /// Polling timer (fires every 10 seconds to check idle time)
    private var timer: Timer?

    /// Idle threshold in seconds (converted from user setting in minutes)
    private var thresholdSeconds: TimeInterval = 300 // 5 minutes default

    /// Tracks whether callback has fired for the current idle period.
    /// Reset to false when user activity is detected, allowing callback to fire again
    /// after next idle period.
    private var hasFiredForCurrentIdle = false

    /// Cached settings values for change detection
    private var lastEnabled: Bool?
    private var lastMinutes: Int?

    /// Notification observer for UserDefaults changes
    private var settingsObserver: NSObjectProtocol?

    /// Starts monitoring idle time
    func start(thresholdMinutes: Int) {
        stop()
        thresholdSeconds = TimeInterval(thresholdMinutes * 60)
        hasFiredForCurrentIdle = false

        // Poll every 10 seconds
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkIdleTime()
            }
        }
    }

    /// Stops monitoring idle time
    func stop() {
        timer?.invalidate()
        timer = nil
        hasFiredForCurrentIdle = false
    }

    /// Begins observing settings changes and auto-starts/stops based on current values.
    ///
    /// - Parameters:
    ///   - readEnabled: Closure that returns the current idle-timer-enabled setting
    ///   - readMinutes: Closure that returns the current idle-timer minutes setting
    func observeSettings(readEnabled: @escaping () -> Bool, readMinutes: @escaping () -> Int) {
        let enabled = readEnabled()
        let minutes = readMinutes()
        lastEnabled = enabled
        lastMinutes = minutes

        if enabled {
            start(thresholdMinutes: minutes)
        }

        settingsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleSettingsChange(readEnabled: readEnabled, readMinutes: readMinutes)
            }
        }
    }

    private func handleSettingsChange(readEnabled: () -> Bool, readMinutes: () -> Int) {
        let enabled = readEnabled()
        let minutes = readMinutes()
        guard enabled != lastEnabled || minutes != lastMinutes else { return }
        lastEnabled = enabled
        lastMinutes = minutes
        if enabled {
            start(thresholdMinutes: minutes)
        } else {
            stop()
        }
    }

    /// Checks current system idle time and fires callback if threshold is crossed.
    ///
    /// Firing logic:
    /// - If idle time >= threshold AND not yet fired: Fire callback and set flag
    /// - If idle time < threshold: Reset flag (user became active)
    ///
    /// This ensures the callback fires exactly once per idle period, even if the user
    /// remains idle for hours. Once activity is detected, the flag resets and the callback
    /// can fire again after the next idle period.
    private func checkIdleTime() {
        // Query system for seconds since last HID event (keyboard, mouse, trackpad)
        let idleSeconds = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .null)

        if idleSeconds >= thresholdSeconds {
            if !hasFiredForCurrentIdle {
                hasFiredForCurrentIdle = true
                onIdleThresholdReached?()
            }
            // User is still idle: do nothing (already fired once)
        } else {
            // User became active again — reset for next idle period
            hasFiredForCurrentIdle = false
        }
    }

    // MARK: - Lifecycle

    // Note: deinit intentionally omitted to avoid @MainActor data race warnings in Swift 6.
    // This manager is held by @StateObject in DimmerlyApp for the app's lifetime, so deinit
    // never executes. Cleanup is handled explicitly via stop() when idle timer is disabled.
}

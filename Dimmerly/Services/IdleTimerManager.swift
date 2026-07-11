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
    typealias IdleSecondsProvider = @MainActor () -> TimeInterval

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

    /// Cached configuration for change detection (so identical calls are no-ops).
    private var lastEnabled: Bool?
    private var lastMinutes: Int?

    /// Reads current system idle time. Injectable so tests can simulate idle/active
    /// states without depending on real HID hardware state.
    private let idleSecondsProvider: IdleSecondsProvider

    init(idleSecondsProvider: @escaping IdleSecondsProvider = IdleTimerManager.systemIdleSeconds) {
        self.idleSecondsProvider = idleSecondsProvider
    }

    /// Seconds since the last HID input event (keyboard, mouse, trackpad).
    ///
    /// Uses `kCGAnyInputEventType` (represented here as `CGEventType(rawValue: ~0)`) rather
    /// than `.null`, which reports seconds since the last *null-type* event — effectively
    /// always a stale, enormous value unrelated to real user activity.
    static func systemIdleSeconds() -> TimeInterval {
        let anyInputEventType = CGEventType(rawValue: ~UInt32(0))!
        return CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: anyInputEventType)
    }

    /// Starts monitoring idle time
    func start(thresholdMinutes: Int) {
        stop()
        thresholdSeconds = TimeInterval(thresholdMinutes * 60)
        hasFiredForCurrentIdle = false

        // Poll every 10 seconds. Added to `.common` run loop modes so idle checks (and the
        // auto-dim they trigger) keep firing during a modal alert or menu tracking/slider
        // dragging, not just while the run loop is in its default mode.
        let newTimer = Timer(timeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkIdleTime()
            }
        }
        RunLoop.main.add(newTimer, forMode: .common)
        timer = newTimer
    }

    /// Stops monitoring idle time
    func stop() {
        timer?.invalidate()
        timer = nil
        hasFiredForCurrentIdle = false
    }

    /// Applies the current idle-timer setting. Called by the app on launch and whenever
    /// `AppSettings.idleTimerEnabled` or `.idleTimerMinutes` changes.
    ///
    /// Short-circuits when the resolved state is identical to the last call so that
    /// unrelated observable updates don't needlessly restart the timer.
    func apply(enabled: Bool, thresholdMinutes: Int) {
        guard enabled != lastEnabled || thresholdMinutes != lastMinutes else { return }
        lastEnabled = enabled
        lastMinutes = thresholdMinutes
        if enabled {
            start(thresholdMinutes: thresholdMinutes)
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
    func checkIdleTime() {
        // Query system for seconds since last HID event (keyboard, mouse, trackpad)
        let idleSeconds = idleSecondsProvider()

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

    // No deinit needed: the manager is held by @State in DimmerlyApp for the app's
    // lifetime, and the timer stops when `apply(enabled: false, ...)` is called.
}

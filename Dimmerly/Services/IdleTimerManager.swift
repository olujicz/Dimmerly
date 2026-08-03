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

    /// Incremented by `stop()`, so each timer's callbacks carry the generation they were
    /// scheduled under. `Timer` isn't `Sendable` and so can't be compared across the hop to the
    /// main actor; an `Int` can. Readable for tests, writable only here.
    private(set) var timerGeneration = 0

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
    /// Uses `kCGAnyInputEventType` (represented here as `CGEventType(rawValue: UInt32.max)`) rather
    /// than `.null`, which reports seconds since the last *null-type* event — effectively
    /// always a stale, enormous value unrelated to real user activity.
    static func systemIdleSeconds() -> TimeInterval {
        // The `else` branch is unreachable today: `UInt32.max` is a defined case
        // (`kCGEventTapDisabledByUserInput`), so the failable init always succeeds. It exists
        // only so a future SDK that drops that raw value degrades instead of trapping. Zero is
        // the safe direction to fail in — it reads as "user is active", so auto-dim stays put
        // rather than blanking the screen out from under someone.
        guard let anyInputEventType = CGEventType(rawValue: UInt32.max) else {
            return 0
        }
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
        // The inner `[weak self]` matters: without it the hop would hold a strong reference
        // to this manager for the hop's duration. `generation` is captured immutably, so the
        // callback carries the identity of the timer that scheduled it.
        let generation = timerGeneration
        let newTimer = Timer(timeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleTimerFired(generation: generation)
            }
        }
        RunLoop.main.add(newTimer, forMode: .common)
        timer = newTimer
    }

    /// Runs an idle check on behalf of the polling timer, after the hop to the main actor.
    ///
    /// Comparing generations discards callbacks from a timer that `stop()` invalidated, or that
    /// `start()` has since replaced: a restart repopulates `timer`, so a plain `!= nil` check
    /// would let a stale callback measure idle time against a freshly reset threshold. Callbacks
    /// already in flight when `stop()` runs are the reachable case — the timer fires on the main
    /// thread and enqueues a hop, which `stop()` can beat to the main actor.
    func handleTimerFired(generation: Int) {
        guard generation == timerGeneration else { return }
        checkIdleTime()
    }

    /// Stops monitoring idle time
    func stop() {
        timer?.invalidate()
        timer = nil
        // Retires the outgoing timer's generation so any callback still in flight is discarded.
        timerGeneration += 1
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

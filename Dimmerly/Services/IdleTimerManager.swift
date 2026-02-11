//
//  IdleTimerManager.swift
//  Dimmerly
//
//  Monitors system idle time and triggers auto-dim after a configurable period.
//  Uses CGEventSource to check seconds since last HID event.
//

import Foundation
import CoreGraphics

@MainActor
class IdleTimerManager: ObservableObject {
    /// Callback when idle threshold is reached
    var onIdleThresholdReached: (() -> Void)?

    private var timer: Timer?
    private var thresholdSeconds: TimeInterval = 300 // 5 minutes default
    private var hasFiredForCurrentIdle = false

    /// Tracking state for UserDefaults observation
    private var lastEnabled: Bool?
    private var lastMinutes: Int?
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

    private func checkIdleTime() {
        let idleSeconds = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .null)

        if idleSeconds >= thresholdSeconds {
            if !hasFiredForCurrentIdle {
                hasFiredForCurrentIdle = true
                onIdleThresholdReached?()
            }
        } else {
            // User became active again — reset for next idle period
            hasFiredForCurrentIdle = false
        }
    }

    // deinit omitted to avoid @MainActor data race (Swift 6).
    // The manager is held by @StateObject for the app lifetime, so deinit is never reached.
}

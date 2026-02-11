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
}

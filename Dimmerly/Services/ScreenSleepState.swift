//
//  ScreenSleepState.swift
//  Dimmerly
//
//  Tracks whether the Mac or only its displays are asleep, so background polling
//  (DDC reads, built-in backlight sync) can pause instead of waking monitors or the CPU.
//

import AppKit

@MainActor
final class ScreenSleepState {
    static let shared = ScreenSleepState()

    /// True from a sleep notification until the matching wake notification.
    private(set) var isAsleep = false

    private let notificationCenter: NotificationCenter
    private var observers: [NSObjectProtocol] = []

    init(notificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter) {
        self.notificationCenter = notificationCenter
        let transitions: [(Notification.Name, Bool)] = [
            (NSWorkspace.willSleepNotification, true),
            (NSWorkspace.screensDidSleepNotification, true),
            (NSWorkspace.didWakeNotification, false),
            (NSWorkspace.screensDidWakeNotification, false),
        ]
        for (name, asleep) in transitions {
            observers.append(notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.isAsleep = asleep }
            })
        }
    }

    /// Polling for hardware values is pointless, and for DDC harmful, while the screens
    /// are asleep or Dimmerly has them blanked. Polling resumes on the next tick after wake.
    static var shouldPausePolling: Bool {
        shared.isAsleep || ScreenBlanker.shared.isBlanking
    }
}

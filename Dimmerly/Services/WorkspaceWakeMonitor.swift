//
//  WorkspaceWakeMonitor.swift
//  Dimmerly
//
//  Coalesces system and screen wake notifications into one delayed callback.
//

import AppKit

@MainActor
final class WorkspaceWakeMonitor {
    private let notificationCenter: NotificationCenter
    private let delay: Duration
    /// Optional second pass, measured from the first. Display re-enumeration can still be in
    /// flight when `delay` elapses — macOS has been observed wiping the gamma table several
    /// seconds after a display came back — so one early re-apply is not always enough.
    private let settleDelay: Duration?
    private let onWakeDetected: () -> Void
    private let onWakeReady: () -> Void

    private var observers: [NSObjectProtocol] = []
    private var wakeTask: Task<Void, Never>?
    private var isRunning = false

    init(
        notificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        delay: Duration,
        settleDelay: Duration? = nil,
        onWakeDetected: @escaping () -> Void = {},
        onWakeReady: @escaping () -> Void
    ) {
        self.notificationCenter = notificationCenter
        self.delay = delay
        self.settleDelay = settleDelay
        self.onWakeDetected = onWakeDetected
        self.onWakeReady = onWakeReady
    }

    func start() {
        guard observers.isEmpty else { return }
        isRunning = true

        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            let observer = notificationCenter.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.scheduleWakeUpdate()
                }
            }
            observers.append(observer)
        }
    }

    func stop() {
        isRunning = false
        for observer in observers {
            notificationCenter.removeObserver(observer)
        }
        observers.removeAll()
        wakeTask?.cancel()
        wakeTask = nil
    }

    private func scheduleWakeUpdate() {
        guard isRunning else { return }
        onWakeDetected()
        wakeTask?.cancel()
        wakeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            onWakeReady()

            if let settleDelay {
                try? await Task.sleep(for: settleDelay)
                guard !Task.isCancelled else { return }
                onWakeReady()
            }
            wakeTask = nil
        }
    }
}

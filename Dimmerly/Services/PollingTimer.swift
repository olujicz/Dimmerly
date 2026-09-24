//
//  PollingTimer.swift
//  Dimmerly
//
//  Repeating main-run-loop timer whose ticks run synchronously on the main actor.
//

import Foundation

@MainActor
final class PollingTimer {
    private var timer: Timer?

    var isRunning: Bool {
        timer != nil
    }

    /// Starts polling every `interval` seconds, replacing any timer already running.
    ///
    /// The timer is added to `.common` run loop modes (not just the `.default` mode that
    /// `Timer.scheduledTimer` uses) so ticks keep firing during a modal alert (`.modalPanel`)
    /// or menu tracking/slider dragging (`.eventTracking`) instead of silently pausing.
    ///
    /// Ticks run synchronously rather than hopping to the main actor through a `Task`, so no
    /// tick can still be in flight once `stop()` returns and owners can reset their state
    /// right after stopping. The owner should capture itself weakly in `action`.
    func start(interval: TimeInterval, action: @escaping @MainActor () -> Void) {
        stop()
        let newTimer = Timer(timeInterval: interval, repeats: true) { [weak self] timer in
            // The run loop retains the timer, so invalidate it if the owner went away
            // without stopping instead of letting it tick forever.
            guard self != nil else {
                timer.invalidate()
                return
            }
            // A timer on the main run loop always fires on the main thread.
            MainActor.assumeIsolated(action)
        }
        RunLoop.main.add(newTimer, forMode: .common)
        timer = newTimer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }
}

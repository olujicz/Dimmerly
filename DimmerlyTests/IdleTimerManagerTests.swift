//
//  IdleTimerManagerTests.swift
//  DimmerlyTests
//
//  Unit tests for IdleTimerManager threshold-crossing and fire-once behavior.
//

@testable import Dimmerly
import XCTest

/// Mutable idle-seconds box so the injected provider closure has nothing to capture
/// by reference, avoiding Swift 6 sendable-closure capture warnings in tests.
@MainActor
private final class IdleSecondsBox {
    var value: TimeInterval = 0
}

@MainActor
final class IdleTimerManagerTests: XCTestCase {
    func testDoesNotFireBelowThreshold() {
        let box = IdleSecondsBox()
        var fireCount = 0
        let manager = IdleTimerManager(idleSecondsProvider: { box.value })
        manager.onIdleThresholdReached = { fireCount += 1 }
        manager.start(thresholdMinutes: 5)

        box.value = 299
        manager.checkIdleTime()

        XCTAssertEqual(fireCount, 0)
    }

    func testFiresExactlyOnceWhenThresholdCrossed() {
        let box = IdleSecondsBox()
        var fireCount = 0
        let manager = IdleTimerManager(idleSecondsProvider: { box.value })
        manager.onIdleThresholdReached = { fireCount += 1 }
        manager.start(thresholdMinutes: 5)

        box.value = 300
        manager.checkIdleTime()
        box.value = 600
        manager.checkIdleTime()
        box.value = 900
        manager.checkIdleTime()

        XCTAssertEqual(fireCount, 1)
    }

    func testFiresAgainAfterActivityResetsIdlePeriod() {
        let box = IdleSecondsBox()
        var fireCount = 0
        let manager = IdleTimerManager(idleSecondsProvider: { box.value })
        manager.onIdleThresholdReached = { fireCount += 1 }
        manager.start(thresholdMinutes: 5)

        box.value = 300
        manager.checkIdleTime()
        XCTAssertEqual(fireCount, 1)

        // User becomes active again.
        box.value = 0
        manager.checkIdleTime()

        // User goes idle again and crosses the threshold a second time.
        box.value = 300
        manager.checkIdleTime()

        XCTAssertEqual(fireCount, 2)
    }

    /// A timer callback that reaches the main actor after `stop()` — or after `start()` swapped
    /// in a replacement timer — must be discarded rather than checked against the current
    /// threshold. `handleTimerFired` compares generations to enforce that.
    func testIgnoresCallbackFromATimerThatIsNoLongerCurrent() {
        let box = IdleSecondsBox()
        var fireCount = 0
        let manager = IdleTimerManager(idleSecondsProvider: { box.value })
        manager.onIdleThresholdReached = { fireCount += 1 }

        manager.start(thresholdMinutes: 5)
        let retiredGeneration = manager.timerGeneration
        // Restarting retires the previous timer, so its in-flight callbacks are now stale.
        manager.start(thresholdMinutes: 5)

        box.value = 900
        manager.handleTimerFired(generation: retiredGeneration)
        XCTAssertEqual(fireCount, 0, "A retired timer's callback must not check idle time")

        // The live timer's callback still works, so the guard isn't passing vacuously.
        manager.handleTimerFired(generation: manager.timerGeneration)
        XCTAssertEqual(fireCount, 1)
    }

    /// `stop()` retires the current generation, so a callback that was already hopping to the
    /// main actor when the user disabled auto-dim is dropped instead of blanking the screen.
    func testIgnoresCallbackInFlightWhenStopped() {
        let box = IdleSecondsBox()
        var fireCount = 0
        let manager = IdleTimerManager(idleSecondsProvider: { box.value })
        manager.onIdleThresholdReached = { fireCount += 1 }

        manager.start(thresholdMinutes: 5)
        let generationInFlight = manager.timerGeneration
        manager.stop()

        box.value = 900
        manager.handleTimerFired(generation: generationInFlight)

        XCTAssertEqual(fireCount, 0)
    }

    func testStopPreventsFurtherFiring() {
        let box = IdleSecondsBox()
        var fireCount = 0
        let manager = IdleTimerManager(idleSecondsProvider: { box.value })
        manager.onIdleThresholdReached = { fireCount += 1 }
        manager.start(thresholdMinutes: 5)
        manager.stop()

        box.value = 900
        manager.checkIdleTime()

        XCTAssertEqual(fireCount, 1)
    }
}

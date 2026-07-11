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

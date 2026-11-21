//
//  IdleTimerManagerTests.swift
//  DimmerlyTests
//
//  Unit tests for IdleTimerManager threshold-crossing and fire-once behavior.
//

@testable import Dimmerly
import IOKit.pwr_mgt
import XCTest

/// Mutable idle-seconds box so the injected provider closure has nothing to capture
/// by reference, avoiding Swift 6 sendable-closure capture warnings in tests.
@MainActor
private final class IdleSecondsBox {
    var value: TimeInterval = 0
}

@MainActor
private final class FlagBox {
    var value = false
}

@MainActor
final class IdleTimerManagerTests: XCTestCase {
    func testDoesNotFireWhileDisplaySleepIsPrevented() {
        let idle = IdleSecondsBox()
        let prevented = FlagBox()
        var fireCount = 0
        let manager = IdleTimerManager(
            idleSecondsProvider: { idle.value },
            displaySleepPreventedProvider: { prevented.value }
        )
        manager.onIdleThresholdReached = { fireCount += 1 }
        manager.start(thresholdMinutes: 5)

        idle.value = 600
        prevented.value = true
        manager.checkIdleTime()
        manager.checkIdleTime()
        XCTAssertEqual(fireCount, 0, "A playing video must not be blanked")

        prevented.value = false
        manager.checkIdleTime()
        XCTAssertEqual(fireCount, 1, "Fires once the assertion is released and the user is still idle")
        manager.stop()
    }

    func testSystemProbeSeesADisplaySleepAssertion() {
        var assertionID = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertPreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "DimmerlyTests display sleep probe" as CFString,
            &assertionID
        )
        XCTAssertEqual(result, kIOReturnSuccess)
        XCTAssertTrue(IdleTimerManager.systemDisplaySleepPrevented())
        IOPMAssertionRelease(assertionID)
    }

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

    func testInvalidIdleTimeDoesNotTriggerAutoDim() {
        let box = IdleSecondsBox()
        var fireCount = 0
        let manager = IdleTimerManager(idleSecondsProvider: { box.value })
        manager.onIdleThresholdReached = { fireCount += 1 }
        manager.start(thresholdMinutes: 5)

        box.value = .nan
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

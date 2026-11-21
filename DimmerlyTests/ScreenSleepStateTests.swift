//
//  ScreenSleepStateTests.swift
//  DimmerlyTests
//
//  Unit tests for ScreenSleepState sleep/wake tracking.
//

import AppKit
@testable import Dimmerly
import XCTest

@MainActor
final class ScreenSleepStateTests: XCTestCase {
    func testTracksScreenSleepAndWake() {
        let center = NotificationCenter()
        let state = ScreenSleepState(notificationCenter: center)
        XCTAssertFalse(state.isAsleep)

        center.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        XCTAssertTrue(state.isAsleep, "Polling must pause once the displays sleep")

        center.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        XCTAssertFalse(state.isAsleep)
    }

    func testTracksSystemSleepAndWake() {
        let center = NotificationCenter()
        let state = ScreenSleepState(notificationCenter: center)

        center.post(name: NSWorkspace.willSleepNotification, object: nil)
        XCTAssertTrue(state.isAsleep)

        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        XCTAssertFalse(state.isAsleep)
    }
}

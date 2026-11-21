//
//  ScreenBlankerCaptureTests.swift
//  DimmerlyTests
//
//  Keyboard-capture verification for blanking sessions whose wake input only reaches Dimmerly
//  while it is the active app with a key overlay.
//

import AppKit
@testable import Dimmerly
import XCTest

@MainActor
final class ScreenBlankerCaptureTests: XCTestCase {
    private func makeHarness() -> ScreenBlankerHarness {
        ScreenBlankerHarness.make()
    }

    private func settle() async {
        for _ in 0 ..< 10 {
            await Task.yield()
        }
    }

    func testGlobalBlankEndsWhenActivationNeverEstablishesCapture() async {
        let harness = makeHarness()
        harness.input.requiresActiveApp = true
        harness.clock.completesSleepsImmediately = true
        harness.windows.appIsActive = false
        harness.sut.blank()
        XCTAssertTrue(harness.sut.isBlanking, "The check waits for AppKit before it judges")

        await settle()

        XCTAssertFalse(harness.sut.isBlanking)
        XCTAssertEqual(harness.input.stopCount, 1)
        XCTAssertEqual(harness.gamma.restoredDisplayIDs, [7, 9])
        XCTAssertEqual(harness.cursor.unhideCount, 1)
        XCTAssertTrue(harness.failures.errors.isEmpty)
    }

    func testGlobalBlankKeepsGoingWhenActivationEstablishesCapture() async {
        let harness = makeHarness()
        harness.input.requiresActiveApp = true
        harness.clock.completesSleepsImmediately = true
        harness.sut.blank()

        await settle()

        XCTAssertTrue(harness.sut.isBlanking)
        XCTAssertEqual(harness.input.stopCount, 0)
    }

    func testGlobalBlankPromotesAnOverlayWhenActiveButNoneIsKey() async {
        let harness = makeHarness()
        harness.input.requiresActiveApp = true
        harness.clock.completesSleepsImmediately = true
        harness.sut.blank()
        harness.windows.keyDisplayID = nil

        await settle()

        XCTAssertTrue(harness.sut.isBlanking)
        XCTAssertEqual(harness.windows.keyDisplayID, 7)
    }

    func testFullyCoveredPerDisplaySessionEndsWhenActivationNeverEstablishesCapture() async {
        let harness = makeHarness()
        harness.input.requiresActiveApp = true
        harness.clock.completesSleepsImmediately = true
        harness.windows.appIsActive = false
        harness.sut.blankDisplay(7)
        harness.sut.blankDisplay(9)
        XCTAssertTrue(harness.sut.isBlankingAnyDisplay)

        await settle()

        XCTAssertFalse(harness.sut.isBlankingAnyDisplay)
        XCTAssertEqual(harness.input.stopCount, 1)
        XCTAssertEqual(harness.cursor.unhideCount, 1)
    }

    func testCaptureCheckIsNotUsedWhenWakeInputDoesNotNeedTheActiveApp() async {
        let harness = makeHarness()
        harness.clock.completesSleepsImmediately = true
        harness.windows.appIsActive = false
        harness.sut.blank()

        await settle()

        XCTAssertTrue(harness.sut.isBlanking)
        XCTAssertEqual(harness.clock.sleepCallCount, 0)
    }

    func testEarlierSessionsCaptureCheckCannotEndALaterSession() async {
        let harness = makeHarness()
        harness.input.requiresActiveApp = true
        harness.sut.blank()
        await settle()
        harness.sut.dismiss(force: true)
        await settle()

        harness.windows.appIsActive = false
        harness.sut.blank()
        await settle()

        XCTAssertTrue(harness.sut.isBlanking, "Only the new session's own check may end it")
    }

    func testUnplugAfterAppKitClearedKeyStatusPromotesASurvivingOverlay() async {
        let harness = makeHarness()
        harness.input.requiresActiveApp = true
        harness.clock.completesSleepsImmediately = true
        harness.sut.blank()
        await settle()
        // AppKit moved key status away from the overlay before the unplug is reported.
        harness.windows.keyDisplayID = nil
        harness.displays.activeDisplayIDs = [7]

        await harness.postScreenParametersChange()

        XCTAssertTrue(harness.sut.isBlanking)
        XCTAssertEqual(harness.windows.keyDisplayID, 7)
    }

    func testUnplugEndsSessionWhenNoOverlayCanTakeTheKeyStatus() async {
        let harness = makeHarness()
        harness.input.requiresActiveApp = true
        harness.clock.completesSleepsImmediately = true
        harness.sut.blank()
        await settle()
        harness.windows.appIsActive = false
        harness.displays.activeDisplayIDs = [7]

        await harness.postScreenParametersChange()

        XCTAssertFalse(harness.sut.isBlanking)
    }

    func testUnplugRemovingTheKeyOverlayHandsTheKeyToTheSurvivor() async {
        let harness = makeHarness()
        harness.input.requiresActiveApp = true
        harness.clock.completesSleepsImmediately = true
        harness.sut.blank()
        await settle()
        XCTAssertEqual(harness.windows.keyDisplayID, 7)
        harness.displays.activeDisplayIDs = [9]

        await harness.postScreenParametersChange()

        XCTAssertTrue(harness.sut.isBlanking)
        XCTAssertEqual(harness.windows.keyDisplayID, 9)
    }

    func testForcedPerDisplayDismissalTearsDownWithoutPromotingAnOverlay() async {
        let harness = makeHarness()
        harness.input.requiresActiveApp = true
        harness.clock.completesSleepsImmediately = true
        harness.sut.blankDisplay(7)
        harness.sut.blankDisplay(9)
        await settle()
        let promotionsBefore = harness.windows.promoteCount

        harness.sut.dismiss(force: true)

        XCTAssertEqual(harness.windows.promoteCount, promotionsBefore)
        XCTAssertNil(harness.windows.keyDisplayID)
        XCTAssertTrue(harness.windows.shownDisplayIDs.isEmpty)
        XCTAssertFalse(harness.sut.isBlankingAnyDisplay)
    }

    func testGlobalTeardownDoesNotPromoteAnOverlay() async {
        let harness = makeHarness()
        harness.input.requiresActiveApp = true
        harness.clock.completesSleepsImmediately = true
        harness.sut.blank()
        await settle()
        let promotionsBefore = harness.windows.promoteCount

        harness.displays.activeDisplayIDs = []
        await harness.postScreenParametersChange()

        XCTAssertFalse(harness.sut.isBlanking)
        XCTAssertEqual(harness.windows.promoteCount, promotionsBefore)
    }
}

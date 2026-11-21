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

    // MARK: - Capture lost without Dimmerly resigning (Mission Control, overviews)

    /// Waits for the start-up verification to finish. It waits for the condition itself, so no
    /// particular number of scheduler turns decides which check ran.
    private func waitForVerifiedCapture(_ harness: ScreenBlankerHarness) async {
        for _ in 0 ..< 10000 where !harness.sut.isCaptureMonitoringLive {
            await Task.yield()
        }
        XCTAssertTrue(harness.sut.isCaptureMonitoringLive, "Start-up verification never finished")
    }

    private func makeVerifiedHarness() async -> ScreenBlankerHarness {
        let harness = makeHarness()
        harness.input.requiresActiveApp = true
        harness.clock.completesSleepsImmediately = true
        harness.sut.blank()
        await waitForVerifiedCapture(harness)
        XCTAssertTrue(harness.sut.isBlanking)
        return harness
    }

    func testSpaceChangeEndsBlankWhenCaptureWasLostWithoutResigning() async {
        let harness = await makeVerifiedHarness()
        // Mission Control takes the keyboard but Dimmerly never gets a resign notification.
        harness.windows.appIsActive = false
        harness.windows.keyDisplayID = nil

        harness.postActiveSpaceChange()

        XCTAssertFalse(harness.sut.isBlanking)
        XCTAssertEqual(harness.input.stopCount, 1)
        XCTAssertEqual(harness.gamma.restoredDisplayIDs, [7, 9])
    }

    func testSpaceChangeKeepsBlankingWhileCaptureHolds() async {
        let harness = await makeVerifiedHarness()

        harness.postActiveSpaceChange()

        XCTAssertTrue(harness.sut.isBlanking)
        XCTAssertEqual(harness.input.stopCount, 0)
    }

    func testSpaceChangeLeavesBlankingAloneWhenWakeInputDoesNotNeedTheActiveApp() {
        let harness = makeHarness()
        harness.sut.blank()
        harness.windows.appIsActive = false
        harness.windows.keyDisplayID = nil

        harness.postActiveSpaceChange()

        XCTAssertTrue(harness.sut.isBlanking)
    }

    func testSpaceChangeDuringFadeInDoesNotJudgeCapture() {
        let harness = makeHarness()
        harness.input.requiresActiveApp = true
        harness.sut.useFadeTransition = true
        // The fake clock never finishes the fade, so the session stays in it.
        harness.sut.blank()
        XCTAssertTrue(harness.windows.shownDisplayIDs.isEmpty, "No overlay exists during the fade")

        harness.postActiveSpaceChange()

        XCTAssertTrue(harness.sut.isBlanking)
        XCTAssertEqual(harness.input.stopCount, 0)
        XCTAssertFalse(harness.sut.isCaptureMonitoringLive)
    }

    func testSpaceChangeBeforeStartUpVerificationFinishesDoesNotJudgeCapture() {
        let harness = makeHarness()
        harness.input.requiresActiveApp = true
        // The fake clock holds the start-up verification, which owns activation.
        harness.sut.blank()
        harness.windows.appIsActive = false
        harness.windows.keyDisplayID = nil

        harness.postActiveSpaceChange()

        XCTAssertTrue(harness.sut.isBlanking)
        XCTAssertEqual(harness.input.stopCount, 0)
    }

    func testOneTransientOcclusionDoesNotEndBlanking() async {
        let harness = await makeVerifiedHarness()
        harness.windows.overlaysAreVisible = false

        harness.sut.recheckCapture()

        XCTAssertTrue(harness.sut.isBlanking)
    }

    func testOcclusionThatPersistsAcrossTimedChecksEndsBlanking() async {
        let harness = await makeVerifiedHarness()
        harness.windows.overlaysAreVisible = false

        harness.sut.recheckCapture()
        harness.sut.recheckCapture()

        XCTAssertFalse(harness.sut.isBlanking)
        XCTAssertEqual(harness.input.stopCount, 1)
    }

    func testOcclusionThatClearsBetweenChecksStartsCountingAgain() async {
        let harness = await makeVerifiedHarness()

        harness.windows.overlaysAreVisible = false
        harness.sut.recheckCapture()
        harness.windows.overlaysAreVisible = true
        harness.sut.recheckCapture()
        harness.windows.overlaysAreVisible = false
        harness.sut.recheckCapture()

        XCTAssertTrue(harness.sut.isBlanking)
    }

    func testSpaceChangeNotificationsDoNotAddUpToAnOcclusionDismissal() async {
        let harness = await makeVerifiedHarness()
        harness.windows.overlaysAreVisible = false

        for _ in 0 ..< 5 {
            harness.postActiveSpaceChange()
        }

        XCTAssertTrue(harness.sut.isBlanking)
        XCTAssertEqual(harness.input.stopCount, 0)
    }

    func testEscapeFromTheFallbackWakesWhileActiveKeyAndVisibleAreUnchanged() async throws {
        let harness = await makeVerifiedHarness()
        // Mission Control consumed an Escape the local monitor never saw, and changed nothing
        // the blanker can observe: still active, still key, still visible.
        XCTAssertEqual(harness.windows.inputCaptureStatus, .held)
        harness.sut.recheckCapture()
        harness.postActiveSpaceChange()
        XCTAssertTrue(harness.sut.isBlanking, "Nothing visible says capture was lost")
        harness.clock.now += 1

        try harness.input.sendWake()

        XCTAssertFalse(harness.sut.isBlanking)
        XCTAssertEqual(harness.input.stopCount, 1)
        XCTAssertEqual(harness.gamma.restoredDisplayIDs, [7, 9])
    }

    func testEscapeHotKeyIsReleasedBeforeABlankThatFollowsATeardown() async {
        let hotKeys = FakeEscapeHotKeyRegistry()
        let monitor = ScriptedEscapeInputMonitor(hotKey: hotKeys.makeHotKey())
        let harness = ScreenBlankerHarness.make(input: monitor)
        harness.clock.completesSleepsImmediately = true

        harness.sut.blank()
        await waitForVerifiedCapture(harness)
        XCTAssertEqual(hotKeys.liveCount, 1)
        harness.sut.dismiss(force: true)
        XCTAssertEqual(hotKeys.liveCount, 0, "Teardown releases Escape")

        harness.sut.blank()
        XCTAssertEqual(hotKeys.liveCount, 1)
        XCTAssertEqual(hotKeys.installCount, 2)
        harness.windows.appIsActive = false
        harness.windows.keyDisplayID = nil
        harness.postAppResignedActive()
        XCTAssertEqual(hotKeys.liveCount, 0, "Losing focus releases Escape")
        XCTAssertEqual(hotKeys.maxLiveCount, 1, "Never two registrations at once")
    }

    func testEscapeHotKeyWakesTheSessionAndReleasesItself() {
        let hotKeys = FakeEscapeHotKeyRegistry()
        let monitor = ScriptedEscapeInputMonitor(hotKey: hotKeys.makeHotKey())
        let harness = ScreenBlankerHarness.make(input: monitor)
        harness.sut.blank()
        harness.clock.now += 1

        hotKeys.fire()

        XCTAssertFalse(harness.sut.isBlanking)
        XCTAssertEqual(hotKeys.liveCount, 0)
    }
}

// MARK: - Escape hot key

@MainActor
final class EscapeWakeHotKeyTests: XCTestCase {
    func testRegistersOnceAndReleasesOnUnregister() {
        let registry = FakeEscapeHotKeyRegistry()
        let hotKey = registry.makeHotKey()

        XCTAssertTrue(hotKey.register {})
        XCTAssertTrue(hotKey.isRegistered)
        XCTAssertEqual(registry.liveCount, 1)

        hotKey.unregister()
        hotKey.unregister()

        XCTAssertFalse(hotKey.isRegistered)
        XCTAssertEqual(registry.liveCount, 0)
        XCTAssertEqual(registry.removeCount, 1)
    }

    func testRegisteringAgainReplacesTheEarlierRegistration() {
        let registry = FakeEscapeHotKeyRegistry()
        let hotKey = registry.makeHotKey()

        hotKey.register {}
        hotKey.register {}

        XCTAssertEqual(registry.liveCount, 1)
        XCTAssertEqual(registry.maxLiveCount, 1)
    }

    func testRefusedRegistrationReportsFailureAndHoldsNothing() {
        let registry = FakeEscapeHotKeyRegistry()
        registry.refuses = true
        let hotKey = registry.makeHotKey()

        XCTAssertFalse(hotKey.register {})

        XCTAssertFalse(hotKey.isRegistered)
        hotKey.unregister()
        XCTAssertEqual(registry.removeCount, 0)
    }

    func testRefusedRegistrationAfterAnEarlierOneReleasesTheEarlierOne() {
        let registry = FakeEscapeHotKeyRegistry()
        let hotKey = registry.makeHotKey()
        hotKey.register {}
        registry.refuses = true

        XCTAssertFalse(hotKey.register {})

        XCTAssertEqual(registry.liveCount, 0)
    }

    func testTriggeringRunsTheHandler() {
        let registry = FakeEscapeHotKeyRegistry()
        let hotKey = registry.makeHotKey()
        var woke = 0
        hotKey.register { woke += 1 }

        registry.fire()

        XCTAssertEqual(woke, 1)
    }

    #if APPSTORE
        func testAppStoreMonitorFallsBackToTheLocalMonitorWhenEscapeIsRefused() throws {
            let registry = FakeEscapeHotKeyRegistry()
            registry.refuses = true
            let monitor = SystemBlankingInputMonitor(escapeHotKey: registry.makeHotKey())
            defer { monitor.stop() }

            XCTAssertNoThrow(try monitor.start(
                policy: .escapeOnly, onWake: {}, onSuppressedInput: {}, onFailure: { _ in }
            ))
            XCTAssertEqual(registry.liveCount, 0)
        }

        func testAppStoreMonitorRegistersEscapeForTheSessionOnly() throws {
            let registry = FakeEscapeHotKeyRegistry()
            let monitor = SystemBlankingInputMonitor(escapeHotKey: registry.makeHotKey())
            var woke = 0

            try monitor.start(
                policy: .escapeOnly, onWake: { woke += 1 }, onSuppressedInput: {}, onFailure: { _ in }
            )
            XCTAssertEqual(registry.liveCount, 1)
            registry.fire()
            XCTAssertEqual(woke, 1)

            try monitor.start(
                policy: .escapeOnly, onWake: { woke += 1 }, onSuppressedInput: {}, onFailure: { _ in }
            )
            XCTAssertEqual(registry.liveCount, 1, "Restarting never stacks registrations")

            monitor.stop()
            XCTAssertEqual(registry.liveCount, 0)
        }
    #endif
}

/// Stands in for Carbon: counts live registrations and lets a test deliver the key.
@MainActor
final class FakeEscapeHotKeyRegistry {
    private final class Token {}

    var refuses = false
    private(set) var installCount = 0
    private(set) var removeCount = 0
    private(set) var maxLiveCount = 0
    private var live: [ObjectIdentifier: (token: Token, handler: @MainActor () -> Void)] = [:]

    var liveCount: Int {
        live.count
    }

    func makeHotKey() -> EscapeWakeHotKey {
        EscapeWakeHotKey(
            installer: { [self] handler in
                guard !refuses else { return nil }
                installCount += 1
                let token = Token()
                live[ObjectIdentifier(token)] = (token, handler)
                maxLiveCount = max(maxLiveCount, live.count)
                return token
            },
            remover: { [self] registration in
                guard let token = registration as? Token else { return }
                removeCount += 1
                live[ObjectIdentifier(token)] = nil
            }
        )
    }

    /// Delivers Escape to every live registration, as the system would.
    func fire() {
        for entry in live.values {
            entry.handler()
        }
    }
}

/// An input monitor that registers Escape the way the App Store monitor does, for sessions
/// that need to see the hot key come and go with the blanker's own teardown paths.
@MainActor
final class ScriptedEscapeInputMonitor: BlankingInputMonitoring {
    private let hotKey: EscapeWakeHotKey

    init(hotKey: EscapeWakeHotKey) {
        self.hotKey = hotKey
    }

    var requiresActiveApp: Bool {
        true
    }

    func start(
        policy _: BlankingInputPolicy,
        onWake: @escaping @MainActor () -> Void,
        onSuppressedInput _: @escaping @MainActor () -> Void,
        onFailure _: @escaping @MainActor (BlankingInputMonitorError) -> Void
    ) throws {
        hotKey.register(onEscape: onWake)
    }

    func stop() {
        hotKey.unregister()
    }
}

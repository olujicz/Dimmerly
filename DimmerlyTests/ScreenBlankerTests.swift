//
//  ScreenBlankerTests.swift
//  DimmerlyTests
//
//  Unit tests for ScreenBlanker state and recovery logic.
//

@testable import Dimmerly
import XCTest

@MainActor
final class ScreenBlankerTests: XCTestCase {
    private func makeHarness() -> ScreenBlankerHarness {
        let input = FakeBlankingInputMonitor()
        let windows = FakeBlankingWindowController()
        let gamma = FakeDisplayGammaController()
        let cursor = FakeCursorController()
        let clock = FakeBlankingClock(now: 100)
        let displays = FakeActiveDisplayProvider(activeDisplayIDs: [7, 9])
        let failures = FailureRecorder()
        let sut = ScreenBlanker(
            inputMonitor: input,
            windows: windows,
            gamma: gamma,
            cursor: cursor,
            clock: clock,
            displays: displays,
            failurePresenter: { error in failures.errors.append(error) }
        )
        return ScreenBlankerHarness(
            sut: sut,
            input: input,
            windows: windows,
            gamma: gamma,
            cursor: cursor,
            clock: clock,
            failures: failures
        )
    }

    func testBlankFromIdleStartsMonitoringAndBlanksEveryDisplay() {
        let harness = makeHarness()
        harness.sut.blank()

        XCTAssertTrue(harness.sut.isBlanking)
        XCTAssertEqual(harness.input.startPolicies, [.anyInput(ignorePointerMovement: false)])
        XCTAssertEqual(harness.windows.beginSessionCount, 1)
        XCTAssertEqual(harness.windows.shownDisplayIDs, [7, 9])
        XCTAssertEqual(harness.gamma.blankedDisplayIDs, [7, 9])
        XCTAssertEqual(harness.cursor.hideCount, 1)
    }

    func testDuplicateBlankRequestIsIdempotent() {
        let harness = makeHarness()
        harness.sut.blank()
        harness.sut.blank()

        XCTAssertEqual(harness.input.startPolicies.count, 1)
        XCTAssertEqual(harness.windows.beginSessionCount, 1)
        XCTAssertEqual(harness.gamma.blankedDisplayIDs, [7, 9])
        XCTAssertEqual(harness.cursor.hideCount, 1)
    }

    func testWakeDuringGracePeriodDoesNotDismiss() throws {
        let harness = makeHarness()
        harness.sut.blank()

        try harness.input.sendWake()

        XCTAssertTrue(harness.sut.isBlanking)
        XCTAssertEqual(harness.input.stopCount, 0)
        XCTAssertTrue(harness.gamma.restoredDisplayIDs.isEmpty)
    }

    func testWakeAfterGracePeriodRestoresExactlyOnce() throws {
        let harness = makeHarness()
        harness.sut.blank()
        harness.clock.now = 100.5

        try harness.input.sendWake()
        harness.sut.dismiss(force: true)

        XCTAssertFalse(harness.sut.isBlanking)
        XCTAssertEqual(harness.input.stopCount, 1)
        XCTAssertEqual(harness.windows.removeAllCount, 1)
        XCTAssertEqual(harness.windows.endSessionCount, 1)
        XCTAssertEqual(harness.gamma.restoredDisplayIDs, [7, 9])
        XCTAssertEqual(harness.cursor.unhideCount, 1)
    }

    func testForcedDismissBypassesGracePeriod() {
        let harness = makeHarness()
        harness.sut.blank()

        harness.sut.dismiss(force: true)

        XCTAssertFalse(harness.sut.isBlanking)
        XCTAssertEqual(harness.input.stopCount, 1)
        XCTAssertEqual(harness.gamma.restoredDisplayIDs, [7, 9])
    }

    func testMonitorStartupFailureDoesNotBlankAndPresentsFailure() {
        let harness = makeHarness()
        harness.input.startError = .accessibilityPermissionDenied

        harness.sut.blank()

        XCTAssertFalse(harness.sut.isBlanking)
        XCTAssertEqual(harness.failures.errors, [.accessibilityPermissionDenied])
        XCTAssertTrue(harness.gamma.blankedDisplayIDs.isEmpty)
        XCTAssertEqual(harness.windows.beginSessionCount, 0)
        XCTAssertEqual(harness.cursor.hideCount, 0)
    }

    func testRuntimeMonitorFailureForcesSafeRecovery() throws {
        let harness = makeHarness()
        harness.sut.blank()

        try harness.input.sendFailure(.invalidated)

        XCTAssertFalse(harness.sut.isBlanking)
        XCTAssertEqual(harness.failures.errors, [.invalidated])
        XCTAssertEqual(harness.input.stopCount, 1)
        XCTAssertEqual(harness.gamma.restoredDisplayIDs, [7, 9])
        XCTAssertEqual(harness.cursor.unhideCount, 1)
    }

    func testDisconnectedDisplayCannotEnterBlankedState() {
        let harness = makeHarness()
        harness.sut.blankDisplay(42)

        XCTAssertFalse(harness.sut.isDisplayBlanked(42))
        XCTAssertTrue(harness.gamma.blankedDisplayIDs.isEmpty)
        XCTAssertTrue(harness.windows.shownDisplayIDs.isEmpty)
    }

    func testMissingOverlayDuringFullBlankForcesSafeRecovery() {
        let harness = makeHarness()
        harness.windows.failingDisplayIDs = [9]

        harness.sut.blank()

        XCTAssertFalse(harness.sut.isBlanking)
        XCTAssertEqual(harness.failures.errors, [.unavailable])
        XCTAssertEqual(harness.input.stopCount, 1)
        XCTAssertEqual(harness.windows.removeAllCount, 1)
        XCTAssertEqual(harness.cursor.unhideCount, 1)
    }

    func testBlankingEveryDisplayStartsPerDisplayRecovery() {
        let harness = makeHarness()
        harness.sut.requireEscapeToDismiss = true

        harness.sut.blankDisplay(7)
        harness.sut.blankDisplay(9)

        XCTAssertFalse(harness.sut.isBlanking)
        XCTAssertEqual(harness.sut.blankedDisplayIDs, [7, 9])
        XCTAssertEqual(harness.input.startPolicies, [.escapeOnly])
        XCTAssertEqual(harness.cursor.hideCount, 1)
    }

    func testForcedDismissDuringFadeCancelsWithoutLateBlanking() async {
        let harness = makeHarness()
        harness.sut.useFadeTransition = true

        harness.sut.blank()
        while harness.clock.sleepCallCount == 0 {
            await Task.yield()
        }
        harness.sut.dismiss(force: true)
        for _ in 0 ..< 100 where harness.clock.cancelledSleepCount == 0 {
            await Task.yield()
        }

        XCTAssertFalse(harness.sut.isBlanking)
        XCTAssertTrue(harness.gamma.blankedDisplayIDs.isEmpty)
        XCTAssertEqual(harness.clock.cancelledSleepCount, 1)
    }

    func testSingleBuiltInDisplayRequiresPerDisplayRecovery() {
        XCTAssertTrue(
            ScreenBlanker.shouldEnablePerDisplayRecovery(
                blankedDisplayIDs: [7],
                activeDisplayIDs: [7]
            )
        )
    }

    func testMissingBlankedDisplayDoesNotEnablePerDisplayRecovery() {
        XCTAssertFalse(
            ScreenBlanker.shouldEnablePerDisplayRecovery(
                blankedDisplayIDs: [7],
                activeDisplayIDs: [7, 9]
            )
        )
    }

    func testEscapeOnlyWakesOnlyForEscapeKeyDownAndSuppressesCoveredInput() {
        XCTAssertEqual(
            BlankingInputDecision.resolve(event: .keyDown(keyCode: 53), policy: .escapeOnly),
            .suppressAndWake
        )
        XCTAssertEqual(
            BlankingInputDecision.resolve(event: .keyDown(keyCode: 12), policy: .escapeOnly),
            .suppress
        )
        XCTAssertEqual(
            BlankingInputDecision.resolve(event: .otherMouseDown, policy: .escapeOnly),
            .suppress
        )
        XCTAssertEqual(
            BlankingInputDecision.resolve(event: .scrollWheel, policy: .escapeOnly),
            .suppress
        )
    }

    func testAnyInputWakesAndSuppressesEveryCoveredEvent() {
        let coveredEvents: [BlankingInputEvent] = [
            .keyDown(keyCode: 12), .keyUp(keyCode: 12), .flagsChanged,
            .leftMouseDown, .leftMouseUp, .leftMouseDragged,
            .rightMouseDown, .rightMouseUp, .rightMouseDragged,
            .otherMouseDown, .otherMouseUp, .otherMouseDragged,
            .mouseMoved, .scrollWheel,
        ]

        for event in coveredEvents {
            XCTAssertEqual(
                BlankingInputDecision.resolve(
                    event: event,
                    policy: .anyInput(ignorePointerMovement: false)
                ),
                .suppressAndWake,
                "Unexpected decision for \(event)"
            )
        }
    }

    func testIgnoredPointerMovementPassesThroughWithoutWaking() {
        XCTAssertEqual(
            BlankingInputDecision.resolve(
                event: .mouseMoved,
                policy: .anyInput(ignorePointerMovement: true)
            ),
            .passThrough
        )
    }

    func testUnsupportedSystemAndGestureEventsPassThrough() {
        for event in [BlankingInputEvent.systemDefined, .gesture] {
            XCTAssertEqual(
                BlankingInputDecision.resolve(event: event, policy: .escapeOnly),
                .passThrough
            )
        }
    }

    func testTapDisableEventsBecomeRecoverableFailures() {
        XCTAssertEqual(
            BlankingInputDecision.resolve(event: .tapDisabledByTimeout, policy: .escapeOnly),
            .fail(.timedOut)
        )
        XCTAssertEqual(
            BlankingInputDecision.resolve(event: .tapDisabledByUserInput, policy: .escapeOnly),
            .fail(.invalidated)
        )
    }

    #if !APPSTORE
        func testDirectMonitorAllowsAnotherWakeSignalAfterAnEarlyWake() async throws {
            var wakeCount = 0
            let wakesDelivered = expectation(description: "Both wake signals are delivered")
            wakesDelivered.expectedFulfillmentCount = 2
            let context = EventTapContext(
                policy: .anyInput(ignorePointerMovement: false),
                onWake: {
                    wakeCount += 1
                    wakesDelivered.fulfill()
                },
                onFailure: { _ in XCTFail("Unexpected monitor failure") }
            )
            let keyEvent = try XCTUnwrap(CGEvent(
                keyboardEventSource: nil,
                virtualKey: 0,
                keyDown: true
            ))

            XCTAssertNil(context.handle(type: .keyDown, event: keyEvent))
            XCTAssertNil(context.handle(type: .keyDown, event: keyEvent))
            await fulfillment(of: [wakesDelivered], timeout: 1)

            XCTAssertEqual(wakeCount, 2)
        }

        func testAccessibilityFailureLinksToAccessibilityPrivacyPane() {
            XCTAssertEqual(
                BlankingInputMonitorError.accessibilityPermissionDenied.settingsURL?.absoluteString,
                "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
            )
            XCTAssertNil(BlankingInputMonitorError.timedOut.settingsURL)
        }
    #endif

    func testSettingsDocumentsAppStoreInputFilteringLimit() throws {
        let repositoryURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let settingsURL = repositoryURL.appendingPathComponent("Dimmerly/Views/SettingsDisplayTab.swift")
        let source = try String(contentsOf: settingsURL, encoding: .utf8)

        XCTAssertTrue(
            source.contains("macOS system shortcuts and media keys may still be handled by the system."),
            "App Store settings must not promise system-wide input suppression"
        )
    }
}

@MainActor
private struct ScreenBlankerHarness {
    let sut: ScreenBlanker
    let input: FakeBlankingInputMonitor
    let windows: FakeBlankingWindowController
    let gamma: FakeDisplayGammaController
    let cursor: FakeCursorController
    let clock: FakeBlankingClock
    let failures: FailureRecorder
}

@MainActor
private final class FailureRecorder {
    var errors: [BlankingInputMonitorError] = []
}

@MainActor
private final class FakeBlankingInputMonitor: BlankingInputMonitoring {
    var startPolicies: [BlankingInputPolicy] = []
    var startError: BlankingInputMonitorError?
    var stopCount = 0
    private var onWake: (@MainActor () -> Void)?
    private var onFailure: (@MainActor (BlankingInputMonitorError) -> Void)?

    func start(
        policy: BlankingInputPolicy,
        onWake: @escaping @MainActor () -> Void,
        onFailure: @escaping @MainActor (BlankingInputMonitorError) -> Void
    ) throws {
        if let startError {
            throw startError
        }
        startPolicies.append(policy)
        self.onWake = onWake
        self.onFailure = onFailure
    }

    func stop() {
        stopCount += 1
        onWake = nil
        onFailure = nil
    }

    func sendWake() throws {
        let action = try XCTUnwrap(onWake)
        action()
    }

    func sendFailure(_ error: BlankingInputMonitorError) throws {
        let action = try XCTUnwrap(onFailure)
        action(error)
    }
}

@MainActor
private final class FakeBlankingWindowController: BlankingWindowControlling {
    var beginSessionCount = 0
    var shownDisplayIDs: [CGDirectDisplayID] = []
    var removeAllCount = 0
    var endSessionCount = 0
    var failingDisplayIDs: Set<CGDirectDisplayID> = []

    func beginBlankingSession() {
        beginSessionCount += 1
    }

    func showWindow(for displayID: CGDirectDisplayID, showsEscapeHint _: Bool) -> Bool {
        guard !failingDisplayIDs.contains(displayID) else { return false }
        shownDisplayIDs.append(displayID)
        return true
    }

    func removeWindow(for displayID: CGDirectDisplayID) {
        shownDisplayIDs.removeAll { $0 == displayID }
    }

    func removeAllWindows() {
        removeAllCount += 1
        shownDisplayIDs.removeAll()
    }

    func endBlankingSession() {
        endSessionCount += 1
    }
}

@MainActor
private final class FakeDisplayGammaController: DisplayGammaControlling {
    var blankedDisplayIDs: [CGDirectDisplayID] = []
    var restoredDisplayIDs: [CGDirectDisplayID] = []

    func blank(_ displayID: CGDirectDisplayID) {
        blankedDisplayIDs.append(displayID)
    }

    func apply(brightness _: Double, warmth _: Double, contrast _: Double, to _: CGDirectDisplayID) {}

    func restore(_ displayID: CGDirectDisplayID) {
        restoredDisplayIDs.append(displayID)
    }
}

@MainActor
private final class FakeCursorController: CursorVisibilityControlling {
    var hideCount = 0
    var unhideCount = 0

    func hide() {
        hideCount += 1
    }

    func unhide() {
        unhideCount += 1
    }
}

@MainActor
private final class FakeBlankingClock: BlankingClock {
    var now: TimeInterval
    var sleepCallCount = 0
    var cancelledSleepCount = 0

    init(now: TimeInterval) {
        self.now = now
    }

    func sleep(for _: Duration) async throws {
        sleepCallCount += 1
        do {
            try await Task.sleep(for: .seconds(60))
        } catch {
            cancelledSleepCount += 1
            throw error
        }
    }
}

@MainActor
private final class FakeActiveDisplayProvider: ActiveDisplayProviding {
    var activeDisplayIDs: [CGDirectDisplayID]

    init(activeDisplayIDs: [CGDirectDisplayID]) {
        self.activeDisplayIDs = activeDisplayIDs
    }

    func hasScreen(for displayID: CGDirectDisplayID) -> Bool {
        activeDisplayIDs.contains(displayID)
    }
}

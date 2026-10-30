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
        let notificationCenter = NotificationCenter()
        let sut = ScreenBlanker(
            inputMonitor: input,
            windows: windows,
            gamma: gamma,
            cursor: cursor,
            clock: clock,
            displays: displays,
            notificationCenter: notificationCenter,
            failurePresenter: { error in failures.errors.append(error) }
        )
        return ScreenBlankerHarness(
            sut: sut,
            input: input,
            windows: windows,
            gamma: gamma,
            cursor: cursor,
            clock: clock,
            displays: displays,
            failures: failures,
            notificationCenter: notificationCenter
        )
    }

    func testBlankFromIdleStartsMonitoringAndBlanksEveryDisplay() {
        let harness = makeHarness()
        harness.sut.blank()

        XCTAssertTrue(harness.sut.isBlanking)
        XCTAssertEqual(harness.input.startPolicies, [.anyInput(ignorePointerMovement: false)])
        XCTAssertEqual(harness.windows.beginSessionCount, 1)
        XCTAssertEqual(harness.windows.shownDisplayIDs, [7, 9])
        XCTAssertEqual(harness.windows.events, ["show:7", "show:9", "begin"])
        XCTAssertEqual(harness.gamma.blankedDisplayIDs, [7, 9])
        XCTAssertEqual(harness.cursor.hideCount, 1)
    }

    func testInputSwallowedWithoutWakingRevealsTheWakeHint() throws {
        let harness = makeHarness()
        harness.sut.requireEscapeToDismiss = true
        harness.sut.blank()

        try harness.input.sendSuppressedInput()

        XCTAssertTrue(harness.sut.isBlanking)
        XCTAssertEqual(harness.windows.revealWakeHintCount, 1)
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

    func testPerDisplayRequestsDuringFullBlankDoNotReplaceFullBlankRecovery() throws {
        let harness = makeHarness()
        harness.sut.blank()

        harness.sut.blankDisplay(7)
        harness.sut.blankDisplay(9)

        XCTAssertTrue(harness.sut.isBlanking)
        XCTAssertTrue(harness.sut.blankedDisplayIDs.isEmpty)
        XCTAssertEqual(harness.input.startPolicies.count, 1)
        XCTAssertEqual(harness.windows.shownDisplayIDs, [7, 9])
        XCTAssertEqual(harness.gamma.blankedDisplayIDs, [7, 9])

        harness.clock.now = 100.5
        try harness.input.sendWake()

        XCTAssertFalse(harness.sut.isBlanking)
        XCTAssertTrue(harness.sut.blankedDisplayIDs.isEmpty)
        XCTAssertEqual(harness.input.stopCount, 1)
    }

    func testPerDisplayRecoveryResetsStateSoFullBlankCanStartAgain() throws {
        let harness = makeHarness()
        harness.sut.blankDisplay(7)
        harness.sut.blankDisplay(9)

        harness.clock.now = 100.5
        try harness.input.sendWake()

        XCTAssertFalse(harness.sut.isBlanking)
        XCTAssertTrue(harness.sut.blankedDisplayIDs.isEmpty)

        harness.sut.blank()

        XCTAssertTrue(harness.sut.isBlanking)
        XCTAssertEqual(harness.input.startPolicies.count, 2)
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

    func testForcedDismissClearsPartialPerDisplayBlanking() {
        let harness = makeHarness()
        harness.sut.blankDisplay(7)

        harness.sut.dismiss(force: true)

        XCTAssertFalse(harness.sut.isBlanking)
        XCTAssertTrue(harness.sut.blankedDisplayIDs.isEmpty)
        XCTAssertEqual(harness.gamma.restoredDisplayIDs, [7])
        XCTAssertTrue(harness.windows.shownDisplayIDs.isEmpty)
    }

    func testForcedDismissClearsFullPerDisplayBlanking() {
        let harness = makeHarness()
        harness.sut.blankDisplay(7)
        harness.sut.blankDisplay(9)

        harness.sut.dismiss(force: true)

        XCTAssertFalse(harness.sut.isBlanking)
        XCTAssertTrue(harness.sut.blankedDisplayIDs.isEmpty)
        XCTAssertEqual(harness.gamma.restoredDisplayIDs, [7, 9])
        XCTAssertEqual(harness.input.stopCount, 1)
    }

    // MARK: - Control Center dim toggle

    func testBlankingAnyDisplayCoversGlobalAndPerDisplaySessions() {
        let global = makeHarness()
        XCTAssertFalse(global.sut.isBlankingAnyDisplay)
        global.sut.blank()
        XCTAssertTrue(global.sut.isBlankingAnyDisplay)

        let perDisplay = makeHarness()
        perDisplay.sut.blankDisplay(7)
        XCTAssertFalse(perDisplay.sut.isBlanking, "A single blanked display is not a global session")
        XCTAssertTrue(perDisplay.sut.isBlankingAnyDisplay)
    }

    func testSetDimmedOffWakesEveryDisplayTheBlankerCovered() {
        let harness = makeHarness()
        harness.sut.blankDisplay(7)
        var sleepCount = 0

        DisplayAction.setDimmed(false, settings: AppSettings(), blanker: harness.sut) { _ in sleepCount += 1 }

        XCTAssertFalse(harness.sut.isBlankingAnyDisplay)
        XCTAssertEqual(harness.gamma.restoredDisplayIDs, [7])
        XCTAssertEqual(sleepCount, 0)
    }

    func testSetDimmedOnRunsTheSharedDimActionOnlyWhenNothingIsBlanked() {
        let harness = makeHarness()
        var sleepCount = 0

        DisplayAction.setDimmed(true, settings: AppSettings(), blanker: harness.sut) { _ in sleepCount += 1 }
        XCTAssertEqual(sleepCount, 1)

        harness.sut.blankDisplay(7)
        DisplayAction.setDimmed(true, settings: AppSettings(), blanker: harness.sut) { _ in sleepCount += 1 }
        XCTAssertEqual(sleepCount, 1, "A toggle that already reads as on must not start a second session")
    }

    // MARK: - Displays arriving during a global blank

    func testDisplayWithoutScreenYetDoesNotEndGlobalBlank() {
        let harness = makeHarness()
        harness.sut.blank()

        // CoreGraphics reports the new display before AppKit lists an NSScreen for it.
        harness.displays.activeDisplayIDs = [7, 9, 11]
        harness.displays.displayIDsWithoutScreen = [11]
        harness.windows.failingDisplayIDs = [11]
        harness.sut.displayTopologyDidChange()

        XCTAssertTrue(harness.sut.isBlanking)
        XCTAssertTrue(harness.failures.errors.isEmpty)
        XCTAssertEqual(harness.input.stopCount, 0)
        XCTAssertTrue(harness.gamma.restoredDisplayIDs.isEmpty)
        XCTAssertEqual(harness.windows.shownDisplayIDs, [7, 9])
        XCTAssertEqual(harness.gamma.blankedDisplayIDs, [7, 9])
    }

    func testDisplayIsBlankedOnceItsScreenAppears() async throws {
        let harness = makeHarness()
        harness.sut.requireEscapeToDismiss = true
        harness.sut.blank()
        harness.displays.activeDisplayIDs = [7, 9, 11]
        harness.displays.displayIDsWithoutScreen = [11]
        harness.windows.failingDisplayIDs = [11]
        harness.sut.displayTopologyDidChange()

        // AppKit catches up and announces the new screen without another CoreGraphics callback.
        harness.displays.displayIDsWithoutScreen = []
        harness.windows.failingDisplayIDs = []
        await harness.postScreenParametersChange()

        XCTAssertTrue(harness.sut.isBlanking)
        XCTAssertEqual(harness.windows.shownDisplayIDs, [7, 9, 11])
        XCTAssertEqual(harness.gamma.blankedDisplayIDs, [7, 9, 11])
        XCTAssertEqual(harness.windows.beginSessionCount, 1)
        XCTAssertEqual(harness.input.startPolicies, [.escapeOnly])

        // The existing wake path still covers the display added mid-session.
        harness.clock.now = 100.5
        try harness.input.sendWake()

        XCTAssertFalse(harness.sut.isBlanking)
        XCTAssertEqual(harness.gamma.restoredDisplayIDs, [7, 9, 11])
        XCTAssertEqual(harness.windows.removeAllCount, 1)
        XCTAssertTrue(harness.failures.errors.isEmpty)
    }

    func testOverlayFailureForArrivingDisplayEndsBlankWithoutInputFilteringError() {
        let harness = makeHarness()
        harness.sut.blank()

        harness.displays.activeDisplayIDs = [7, 9, 11]
        harness.windows.failingDisplayIDs = [11]
        harness.sut.displayTopologyDidChange()

        XCTAssertFalse(harness.sut.isBlanking)
        XCTAssertTrue(harness.failures.errors.isEmpty, "A window failure is not an input-filtering failure")
        XCTAssertEqual(harness.input.stopCount, 1)
        XCTAssertEqual(harness.gamma.restoredDisplayIDs, [7, 9, 11])
        XCTAssertEqual(harness.cursor.unhideCount, 1)
    }

    // MARK: - Blanking while a display has no screen yet

    func testBlankSkipsDisplayWithoutScreenAndCoversItOnceItAppears() async {
        let harness = makeHarness()
        // Turn Displays Off right after plugging in: CoreGraphics lists 9, AppKit has no screen.
        harness.displays.displayIDsWithoutScreen = [9]
        harness.windows.failingDisplayIDs = [9]

        harness.sut.blank()

        XCTAssertTrue(harness.sut.isBlanking)
        XCTAssertTrue(harness.failures.errors.isEmpty)
        XCTAssertEqual(harness.input.stopCount, 0)
        XCTAssertEqual(harness.windows.events, ["show:7", "begin"])
        XCTAssertEqual(harness.gamma.blankedDisplayIDs, [7])

        harness.displays.displayIDsWithoutScreen = []
        harness.windows.failingDisplayIDs = []
        await harness.postScreenParametersChange()

        XCTAssertTrue(harness.sut.isBlanking)
        XCTAssertEqual(harness.windows.shownDisplayIDs, [7, 9])
        XCTAssertEqual(harness.gamma.blankedDisplayIDs, [7, 9])
        XCTAssertEqual(harness.windows.beginSessionCount, 1)
    }

    func testFadeSkipsDisplayWithoutScreenAndCoversItOnceItAppears() async {
        let harness = makeHarness()
        harness.sut.useFadeTransition = true
        harness.clock.completesSleepsImmediately = true
        harness.displays.displayIDsWithoutScreen = [9]
        harness.windows.failingDisplayIDs = [9]

        harness.sut.blank()
        for _ in 0 ..< 1000 where harness.windows.beginSessionCount == 0 {
            await Task.yield()
        }

        XCTAssertTrue(harness.sut.isBlanking)
        XCTAssertTrue(harness.failures.errors.isEmpty)
        XCTAssertEqual(harness.input.stopCount, 0)
        XCTAssertEqual(harness.windows.events, ["show:7", "begin"])
        XCTAssertEqual(harness.gamma.blankedDisplayIDs, [7])
        XCTAssertEqual(Set(harness.gamma.applications.map(\.displayID)), [7], "Only a covered display fades")

        harness.displays.displayIDsWithoutScreen = []
        harness.windows.failingDisplayIDs = []
        await harness.postScreenParametersChange()

        XCTAssertEqual(harness.windows.shownDisplayIDs, [7, 9])
        XCTAssertEqual(harness.gamma.blankedDisplayIDs, [7, 9])
        XCTAssertEqual(harness.windows.beginSessionCount, 1)
    }

    func testOverlayFailureAtEndOfFadeEndsBlankWithoutInputFilteringError() async {
        let harness = makeHarness()
        harness.sut.useFadeTransition = true
        harness.clock.completesSleepsImmediately = true
        harness.windows.failingDisplayIDs = [9]

        harness.sut.blank()
        for _ in 0 ..< 1000 where harness.sut.isBlanking {
            await Task.yield()
        }

        XCTAssertFalse(harness.sut.isBlanking)
        XCTAssertTrue(harness.failures.errors.isEmpty, "A window failure is not an input-filtering failure")
        XCTAssertEqual(harness.input.stopCount, 1)
        XCTAssertEqual(harness.windows.removeAllCount, 1)
        XCTAssertEqual(harness.gamma.restoredDisplayIDs, [7, 9])
        XCTAssertEqual(harness.cursor.unhideCount, 1)
    }

    func testBlankWithNoScreenForAnyDisplayStartsNothing() async {
        let harness = makeHarness()
        harness.displays.displayIDsWithoutScreen = [7, 9]
        harness.windows.failingDisplayIDs = [7, 9]

        harness.sut.blank()

        XCTAssertFalse(harness.sut.isBlanking)
        XCTAssertTrue(harness.failures.errors.isEmpty)
        XCTAssertTrue(harness.input.startPolicies.isEmpty, "No input may be swallowed while nothing is covered")
        XCTAssertEqual(harness.cursor.hideCount, 0)
        XCTAssertTrue(harness.gamma.blankedDisplayIDs.isEmpty)
        XCTAssertEqual(harness.windows.beginSessionCount, 0)

        // A screen appearing later does not start a blank the user can no longer see coming.
        harness.displays.displayIDsWithoutScreen = []
        harness.windows.failingDisplayIDs = []
        await harness.postScreenParametersChange()

        XCTAssertFalse(harness.sut.isBlanking)
        XCTAssertTrue(harness.windows.shownDisplayIDs.isEmpty)
    }

    func testScreenParametersChangeWithoutBlankingDoesNothing() async {
        let harness = makeHarness()

        await harness.postScreenParametersChange()

        XCTAssertTrue(harness.windows.shownDisplayIDs.isEmpty)
        XCTAssertTrue(harness.gamma.blankedDisplayIDs.isEmpty)
        XCTAssertTrue(harness.input.startPolicies.isEmpty)
    }

    func testTopologyChangeArmsRecoveryWhenTheLastVisibleDisplayDisconnects() {
        let harness = makeHarness()
        harness.sut.blankDisplay(7)

        harness.displays.activeDisplayIDs = [7]
        harness.sut.displayTopologyDidChange()

        XCTAssertEqual(harness.sut.blankedDisplayIDs, [7])
        XCTAssertEqual(harness.input.startPolicies, [.anyInput(ignorePointerMovement: false)])
        XCTAssertEqual(harness.windows.beginSessionCount, 1)
        XCTAssertEqual(harness.cursor.hideCount, 1)
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
        XCTAssertTrue(harness.failures.errors.isEmpty, "A window failure is not an input-filtering failure")
        XCTAssertEqual(harness.input.stopCount, 1)
        XCTAssertEqual(harness.windows.removeAllCount, 1)
        XCTAssertEqual(harness.gamma.restoredDisplayIDs, [7, 9])
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

    func testFadeCapturesStartingGammaWhileRestoreUsesLatestProviderValues() async {
        let harness = makeHarness()
        harness.sut.useFadeTransition = true
        harness.clock.completesSleepsImmediately = true
        let initialBrightness: [CGDirectDisplayID: Double] = [7: 0.2, 9: 0.3]
        let initialWarmth: [CGDirectDisplayID: Double] = [7: 0.1, 9: 0.2]
        let initialContrast: [CGDirectDisplayID: Double] = [7: 0.4, 9: 0.5]
        var brightness = initialBrightness
        var warmth = initialWarmth
        var contrast = initialContrast
        harness.sut.brightnessForDisplay = { brightness[$0] ?? 1 }
        harness.sut.warmthForDisplay = { warmth[$0] ?? 0 }
        harness.sut.contrastForDisplay = { contrast[$0] ?? 0.5 }
        harness.clock.onSleep = {
            // Simulate an ongoing preset moving all axes between fade frames.
            brightness = [7: 0.9, 9: 0.9]
            warmth = [7: 0.8, 9: 0.8]
            contrast = [7: 0.9, 9: 0.9]
        }

        harness.sut.blank()
        // The fade must capture its starting output synchronously, before its task runs.
        brightness = [7: 0.7, 9: 0.7]
        warmth = [7: 0.4, 9: 0.4]
        contrast = [7: 0.6, 9: 0.6]
        for _ in 0 ..< 1000 where harness.gamma.blankedDisplayIDs.isEmpty {
            await Task.yield()
        }

        XCTAssertEqual(harness.gamma.blankedDisplayIDs, [7, 9])
        XCTAssertEqual(harness.gamma.applications.count, 60)
        for (index, application) in harness.gamma.applications.enumerated() {
            let progress = Double(index / 2 + 1) / 30
            XCTAssertEqual(application.brightness,
                           (initialBrightness[application.displayID] ?? 1) * (1 - progress), accuracy: 0.0001)
            XCTAssertEqual(application.warmth, initialWarmth[application.displayID])
            XCTAssertEqual(application.contrast, initialContrast[application.displayID])
        }

        harness.sut.dismiss(force: true)

        for application in harness.gamma.applications.suffix(2) {
            XCTAssertEqual(application.brightness, 0.9)
            XCTAssertEqual(application.warmth, 0.8)
            XCTAssertEqual(application.contrast, 0.9)
        }
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

    func testLocalInputOverlayStaysVisibleAndRequestsStrongActivation() {
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.hidesOnDeactivate = true
        var activationCount = 0

        BlankingWindowPresentation.prepareForLocalInputCapture(window)
        BlankingWindowPresentation.activateForLocalInputCapture(window) {
            activationCount += 1
        }

        XCTAssertFalse(window.hidesOnDeactivate)
        XCTAssertEqual(activationCount, 1)
        XCTAssertTrue(window.isVisible)
        window.orderOut(nil)
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
                onSuppressedInput: { XCTFail("Any-input policy should not swallow input") },
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

        func testDirectMonitorReportsInputSwallowedInEscapeOnlyMode() async throws {
            let suppressed = expectation(description: "Swallowed input is reported")
            let context = EventTapContext(
                policy: .escapeOnly,
                onWake: { XCTFail("Only Escape should wake") },
                onSuppressedInput: { suppressed.fulfill() },
                onFailure: { _ in XCTFail("Unexpected monitor failure") }
            )
            let keyEvent = try XCTUnwrap(CGEvent(
                keyboardEventSource: nil,
                virtualKey: 0,
                keyDown: true
            ))

            XCTAssertNil(context.handle(type: .keyDown, event: keyEvent))
            await fulfillment(of: [suppressed], timeout: 1)
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

    func testWakeHintAnimationUsesXcode16CompatibleSynchronousAPI() throws {
        let repositoryURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = repositoryURL
            .appendingPathComponent("Dimmerly/Services/BlankingSystemControllers.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("completionHandler: nil"))
        XCTAssertFalse(source.contains("await NSAnimationContext.runAnimationGroup"))
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
    let displays: FakeActiveDisplayProvider
    let failures: FailureRecorder
    let notificationCenter: NotificationCenter

    /// Delivers AppKit's screen-parameters notification the way it arrives in the app, then lets
    /// any main-queue delivery run.
    func postScreenParametersChange() async {
        notificationCenter.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        for _ in 0 ..< 10 {
            await Task.yield()
        }
    }
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
    private var onSuppressedInput: (@MainActor () -> Void)?
    private var onFailure: (@MainActor (BlankingInputMonitorError) -> Void)?

    func start(
        policy: BlankingInputPolicy,
        onWake: @escaping @MainActor () -> Void,
        onSuppressedInput: @escaping @MainActor () -> Void,
        onFailure: @escaping @MainActor (BlankingInputMonitorError) -> Void
    ) throws {
        if let startError {
            throw startError
        }
        startPolicies.append(policy)
        self.onWake = onWake
        self.onSuppressedInput = onSuppressedInput
        self.onFailure = onFailure
    }

    func stop() {
        stopCount += 1
        onWake = nil
        onSuppressedInput = nil
        onFailure = nil
    }

    func sendSuppressedInput() throws {
        let action = try XCTUnwrap(onSuppressedInput)
        action()
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
    var events: [String] = []
    var removeAllCount = 0
    var endSessionCount = 0
    var failingDisplayIDs: Set<CGDirectDisplayID> = []

    func beginBlankingSession() {
        beginSessionCount += 1
        events.append("begin")
    }

    func showWindow(for displayID: CGDirectDisplayID, showsEscapeHint _: Bool) -> Bool {
        guard !failingDisplayIDs.contains(displayID) else { return false }
        shownDisplayIDs.append(displayID)
        events.append("show:\(displayID)")
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

    var revealWakeHintCount = 0

    func revealWakeHint() {
        revealWakeHintCount += 1
    }
}

@MainActor
private final class FakeDisplayGammaController: DisplayGammaControlling {
    struct Application {
        let displayID: CGDirectDisplayID
        let brightness: Double
        let warmth: Double
        let contrast: Double
    }

    var blankedDisplayIDs: [CGDirectDisplayID] = []
    var restoredDisplayIDs: [CGDirectDisplayID] = []
    var applications: [Application] = []

    func blank(_ displayID: CGDirectDisplayID) {
        blankedDisplayIDs.append(displayID)
    }

    func apply(brightness: Double, warmth: Double, contrast: Double, to displayID: CGDirectDisplayID) {
        applications.append(Application(
            displayID: displayID, brightness: brightness, warmth: warmth, contrast: contrast
        ))
    }

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
    var completesSleepsImmediately = false
    var onSleep: (() -> Void)?

    init(now: TimeInterval) {
        self.now = now
    }

    func sleep(for _: Duration) async throws {
        sleepCallCount += 1
        onSleep?()
        if completesSleepsImmediately {
            return
        }
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
    /// Active displays AppKit has not published an NSScreen for yet.
    var displayIDsWithoutScreen: Set<CGDirectDisplayID> = []

    init(activeDisplayIDs: [CGDirectDisplayID]) {
        self.activeDisplayIDs = activeDisplayIDs
    }

    func hasScreen(for displayID: CGDirectDisplayID) -> Bool {
        activeDisplayIDs.contains(displayID) && !displayIDsWithoutScreen.contains(displayID)
    }
}

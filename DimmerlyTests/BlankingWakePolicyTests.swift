//
//  BlankingWakePolicyTests.swift
//  DimmerlyTests
//
//  What wakes a dimmed display: any input in the App Store edition, any input or Escape only
//  in the direct download, and which events "Ignore mouse movement" lets through.
//

@testable import Dimmerly
import XCTest

extension BlankingInputPolicy {
    /// What a session starts with when Escape-only was asked for. The App Store edition has no
    /// Escape-only wake, so it falls back to any input and keeps the movement preference.
    static func expectedWhenEscapeOnlyIsRequested(ignoringMovement: Bool) -> BlankingInputPolicy {
        #if APPSTORE
            .anyInput(ignorePointerMovement: ignoringMovement)
        #else
            .escapeOnly
        #endif
    }
}

@MainActor
final class BlankingWakePolicyTests: XCTestCase {
    private func makeHarness() -> ScreenBlankerHarness {
        ScreenBlankerHarness.make()
    }

    func testScrollStillWakesWhenPointerMovementIsIgnored() {
        // "Ignore mouse movement" ignores pointer movement only; Settings says scrolling wakes.
        XCTAssertEqual(
            BlankingInputDecision.resolve(
                event: .scrollWheel,
                policy: .anyInput(ignorePointerMovement: true)
            ),
            .suppressAndWake
        )
    }

    func testClickWakesWhenPointerMovementIsIgnored() {
        let clicks: [BlankingInputEvent] = [
            .leftMouseDown, .leftMouseUp, .leftMouseDragged,
            .rightMouseDown, .rightMouseUp, .rightMouseDragged,
            .otherMouseDown, .otherMouseUp, .otherMouseDragged,
        ]

        for event in clicks {
            XCTAssertEqual(
                BlankingInputDecision.resolve(
                    event: event,
                    policy: .anyInput(ignorePointerMovement: true)
                ),
                .suppressAndWake,
                "Unexpected decision for \(event)"
            )
        }
    }

    func testSessionPolicyFollowsTheEditionsEscapeOnlySupport() {
        for ignoring in [false, true] {
            XCTAssertEqual(
                BlankingInputPolicy.forSession(requireEscape: false, ignorePointerMovement: ignoring),
                .anyInput(ignorePointerMovement: ignoring)
            )
            XCTAssertEqual(
                BlankingInputPolicy.forSession(requireEscape: true, ignorePointerMovement: ignoring),
                .expectedWhenEscapeOnlyIsRequested(ignoringMovement: ignoring)
            )
        }
        #if APPSTORE
            XCTAssertFalse(BlankingInputPolicy.supportsEscapeOnly)
        #else
            XCTAssertTrue(BlankingInputPolicy.supportsEscapeOnly)
        #endif
    }

    func testClickOnTheOverlayWakesInAnyInputModeWithMovementIgnored() throws {
        let harness = makeHarness()
        harness.sut.ignoreMouseMovement = true
        harness.sut.blank()

        let policy = try XCTUnwrap(harness.input.startPolicies.first)
        XCTAssertEqual(policy, .anyInput(ignorePointerMovement: true))
        XCTAssertEqual(BlankingInputDecision.resolve(event: .mouseMoved, policy: policy), .passThrough)
        XCTAssertEqual(BlankingInputDecision.resolve(event: .leftMouseDown, policy: policy), .suppressAndWake)

        harness.clock.now = 100.5
        try harness.input.sendWake()

        XCTAssertFalse(harness.sut.isBlanking)
        XCTAssertEqual(harness.gamma.restoredDisplayIDs, [7, 9])
        XCTAssertEqual(harness.cursor.unhideCount, 1)
    }

    func testRequestedEscapeOnlyBecomesAnyInputWithAClickWakeInTheAppStoreEdition() throws {
        let harness = makeHarness()
        harness.sut.requireEscapeToDismiss = true
        harness.sut.ignoreMouseMovement = true
        harness.sut.blank()

        let policy = try XCTUnwrap(harness.input.startPolicies.first)
        XCTAssertEqual(policy, .expectedWhenEscapeOnlyIsRequested(ignoringMovement: true))
        #if APPSTORE
            XCTAssertEqual(BlankingInputDecision.resolve(event: .leftMouseDown, policy: policy), .suppressAndWake)
            XCTAssertEqual(
                BlankingInputDecision.resolve(event: .keyDown(keyCode: 12), policy: policy),
                .suppressAndWake
            )
            XCTAssertEqual(harness.windows.escapeHintFlags, [false, false], "No Esc hint where Esc is not required")
        #else
            XCTAssertEqual(BlankingInputDecision.resolve(event: .leftMouseDown, policy: policy), .suppress)
            XCTAssertEqual(harness.windows.escapeHintFlags, [true, true])
        #endif
    }

    func testWakePolicyHandedToTheBlankerNeverRequiresEscapeInTheAppStoreEdition() throws {
        let suiteName = "ScreenBlankerTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(defaults: defaults)
        // As if the preference were set after launch, bypassing the launch migration.
        settings.requireEscapeToDismiss = true
        let harness = makeHarness()

        DisplayAction.applyWakePolicy(from: settings, to: harness.sut)

        #if APPSTORE
            XCTAssertFalse(settings.wakesOnlyOnEscape)
            XCTAssertFalse(harness.sut.requireEscapeToDismiss)
        #else
            XCTAssertTrue(settings.wakesOnlyOnEscape)
            XCTAssertTrue(harness.sut.requireEscapeToDismiss)
        #endif
    }

    func testOverlayViewAcceptsTheFirstMouseAndReportsEveryKindOfPress() throws {
        let view = BlankingOverlayContentView()
        var pressCount = 0
        view.onMouseDown = { pressCount += 1 }

        // Without this, the press that merely activates Dimmerly would be swallowed.
        XCTAssertTrue(view.acceptsFirstMouse(for: nil))

        func press(_ type: NSEvent.EventType) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(
                with: type, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            ))
        }
        let left = try press(.leftMouseDown)
        let right = try press(.rightMouseDown)
        let other = try press(.otherMouseDown)
        view.mouseDown(with: left)
        view.rightMouseDown(with: right)
        view.otherMouseDown(with: other)

        XCTAssertEqual(pressCount, 3)
    }

    // MARK: - Clicking a dimmed display's overlay

    func testPressingTheOverlayOfAPartiallyBlankedDisplayWakesThatDisplay() {
        let harness = makeHarness()
        harness.sut.blankDisplay(7)
        harness.clock.now = 100.5

        harness.windows.pressOverlay(of: 7)

        XCTAssertFalse(harness.sut.isBlankingAnyDisplay)
        XCTAssertTrue(harness.sut.blankedDisplayIDs.isEmpty)
        XCTAssertEqual(harness.gamma.restoredDisplayIDs, [7])
        XCTAssertTrue(harness.windows.shownDisplayIDs.isEmpty)
        XCTAssertTrue(harness.input.startPolicies.isEmpty, "A partial session never armed the monitor")
    }

    func testPressingOneOverlayLeavesOtherPartiallyBlankedDisplaysDark() {
        let harness = makeHarness()
        harness.displays.activeDisplayIDs = [7, 9, 11]
        harness.sut.blankDisplay(7)
        harness.sut.blankDisplay(9)
        harness.clock.now = 100.5

        harness.windows.pressOverlay(of: 7)

        XCTAssertEqual(harness.sut.blankedDisplayIDs, [9])
        XCTAssertEqual(harness.gamma.restoredDisplayIDs, [7])
        XCTAssertEqual(harness.windows.shownDisplayIDs, [9])
    }

    func testPressingAnOverlayDuringTheGracePeriodDoesNotWake() {
        let harness = makeHarness()
        harness.sut.blankDisplay(7)
        // The click that dimmed the display must not wake it again as it lands on the overlay.
        harness.clock.now = 100.2

        harness.windows.pressOverlay(of: 7)

        XCTAssertEqual(harness.sut.blankedDisplayIDs, [7])
        XCTAssertTrue(harness.gamma.restoredDisplayIDs.isEmpty)

        harness.clock.now = 100.5
        harness.windows.pressOverlay(of: 7)

        XCTAssertTrue(harness.sut.blankedDisplayIDs.isEmpty)
    }

    func testTheGracePeriodOfAnOverlayPressStartsWhenThatDisplayWasBlanked() {
        let harness = makeHarness()
        harness.displays.activeDisplayIDs = [7, 9, 11]
        harness.sut.blankDisplay(7)
        harness.clock.now = 105
        harness.sut.blankDisplay(9)

        // Display 7 has been dark for seconds; display 9 only just went dark.
        harness.windows.pressOverlay(of: 9)
        XCTAssertEqual(harness.sut.blankedDisplayIDs, [7, 9])
        harness.windows.pressOverlay(of: 7)
        XCTAssertEqual(harness.sut.blankedDisplayIDs, [9])
    }

    func testOverlayPressIsLeftToTheInputMonitorOnceEveryDisplayIsCovered() throws {
        let harness = makeHarness()
        harness.sut.blankDisplay(7)
        harness.sut.blankDisplay(9)
        harness.clock.now = 100.5

        harness.windows.pressOverlay(of: 7)

        XCTAssertEqual(harness.sut.blankedDisplayIDs, [7, 9], "The armed monitor owns wake input")
        XCTAssertTrue(harness.gamma.restoredDisplayIDs.isEmpty)
        try harness.input.sendWake()
        XCTAssertTrue(harness.sut.blankedDisplayIDs.isEmpty)
    }

    func testOverlayPressIsIgnoredDuringAGlobalSession() {
        let harness = makeHarness()
        harness.sut.blank()
        harness.clock.now = 100.5

        harness.windows.pressOverlay(of: 7)

        XCTAssertTrue(harness.sut.isBlanking)
        XCTAssertTrue(harness.gamma.restoredDisplayIDs.isEmpty)
    }

    func testOverlayPressForADisplayThatIsNotBlankedDoesNothing() {
        let harness = makeHarness()
        harness.sut.blankDisplay(7)
        harness.clock.now = 100.5

        harness.sut.overlayWasPressed(9)

        XCTAssertEqual(harness.sut.blankedDisplayIDs, [7])
        XCTAssertTrue(harness.gamma.restoredDisplayIDs.isEmpty)
    }

    func testBlankerRegistersItselfForOverlayPresses() {
        let harness = makeHarness()
        XCTAssertNotNil(harness.windows.onOverlayMouseDown)
    }
}

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
}

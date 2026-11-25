//
//  DimWakeInstructionTests.swift
//  DimmerlyTests
//
//  The dim button's wake instruction must describe what a blanking session actually does.
//

import AppKit
@testable import Dimmerly
import XCTest

@MainActor
final class DimWakeInstructionTests: XCTestCase {
    private func makeHarness() -> ScreenBlankerHarness {
        ScreenBlankerHarness.make()
    }

    func testDimWakeInstructionMatchesWhatTheSessionDoes() throws {
        XCTAssertEqual(
            ScreenBlanker.dimWakeInstruction(wakesOnlyOnEscape: false, completesCoverage: false),
            .clickOrAnyKey
        )
        XCTAssertEqual(
            ScreenBlanker.dimWakeInstruction(wakesOnlyOnEscape: false, completesCoverage: true),
            .clickOrAnyKey
        )
        XCTAssertEqual(
            ScreenBlanker.dimWakeInstruction(wakesOnlyOnEscape: true, completesCoverage: false),
            .restoreFromMenuThenEscape
        )
        XCTAssertEqual(
            ScreenBlanker.dimWakeInstruction(wakesOnlyOnEscape: true, completesCoverage: true),
            .escape
        )

        #if !APPSTORE
            // Escape only with two displays: dimming one is partial, so the hint says to restore from
            // the menu, and the session indeed ignores a click and runs no keyboard monitor.
            let harness = makeHarness()
            harness.sut.requireEscapeToDismiss = true
            let active = harness.displays.activeDisplayIDs
            XCTAssertGreaterThanOrEqual(active.count, 2)
            let first = try XCTUnwrap(active.first)
            XCTAssertFalse(ScreenBlanker.shouldEnablePerDisplayRecovery(
                blankedDisplayIDs: [first], activeDisplayIDs: active
            ))
            harness.sut.blankDisplay(first)
            harness.clock.now += 1
            harness.windows.pressOverlay(of: first)
            XCTAssertTrue(harness.sut.isDisplayBlanked(first))
            XCTAssertTrue(harness.input.startPolicies.isEmpty)

            // Dimming the rest completes coverage: the hint says Esc and the monitor honors it.
            XCTAssertTrue(ScreenBlanker.shouldEnablePerDisplayRecovery(
                blankedDisplayIDs: Set(active), activeDisplayIDs: active
            ))
            for id in active.dropFirst() {
                harness.sut.blankDisplay(id)
            }
            XCTAssertEqual(harness.input.startPolicies, [.escapeOnly])

            // A one-display Mac is full coverage from the first dim.
            let single = makeHarness()
            single.sut.requireEscapeToDismiss = true
            single.displays.activeDisplayIDs = [7]
            XCTAssertTrue(ScreenBlanker.shouldEnablePerDisplayRecovery(blankedDisplayIDs: [7], activeDisplayIDs: [7]))
            single.sut.blankDisplay(7)
            XCTAssertEqual(single.input.startPolicies, [.escapeOnly])
        #endif
    }
}

//
//  MenuBarPanelTests.swift
//  DimmerlyTests
//
//  Unit tests for menu bar panel interaction helpers.
//

@testable import Dimmerly
import XCTest

final class MenuBarPanelTests: XCTestCase {
    func testSliderSyncGateSuppressesProgrammaticChangeOnce() {
        var gate = SliderSyncGate()

        gate.markProgrammaticSync()

        XCTAssertFalse(gate.shouldPropagateChange())
        XCTAssertTrue(gate.shouldPropagateChange())
    }

    func testSliderSyncGateAllowsUserChangeWithoutProgrammaticSync() {
        var gate = SliderSyncGate()

        XCTAssertTrue(gate.shouldPropagateChange())
    }
}

//
//  ScreenBlankerTests.swift
//  DimmerlyTests
//
//  Unit tests for ScreenBlanker recovery logic.
//

@testable import Dimmerly
import XCTest

@MainActor
final class ScreenBlankerTests: XCTestCase {
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
}

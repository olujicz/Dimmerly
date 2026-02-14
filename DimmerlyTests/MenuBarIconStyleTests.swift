//
//  MenuBarIconStyleTests.swift
//  DimmerlyTests
//
//  Unit tests for MenuBarIconStyle enum.
//

@testable import Dimmerly
import XCTest

final class MenuBarIconStyleTests: XCTestCase {
    func testAllCasesCount() {
        XCTAssertEqual(MenuBarIconStyle.allCases.count, 5)
    }

    func testAllCasesMembership() {
        let cases = MenuBarIconStyle.allCases
        XCTAssertTrue(cases.contains(.defaultIcon))
        XCTAssertTrue(cases.contains(.monitor))
        XCTAssertTrue(cases.contains(.moonFilled))
        XCTAssertTrue(cases.contains(.moonOutline))
        XCTAssertTrue(cases.contains(.sunMoon))
    }

    func testRawValueRoundTrip() {
        for style in MenuBarIconStyle.allCases {
            let raw = style.rawValue
            let restored = MenuBarIconStyle(rawValue: raw)
            XCTAssertEqual(restored, style, "Round-trip failed for \(style)")
        }
    }

    func testSystemImageNames() {
        XCTAssertNil(MenuBarIconStyle.defaultIcon.systemImageName,
                     "Default icon should use custom asset (nil)")
        XCTAssertEqual(MenuBarIconStyle.monitor.systemImageName, "display")
        XCTAssertEqual(MenuBarIconStyle.moonFilled.systemImageName, "moon.fill")
        XCTAssertEqual(MenuBarIconStyle.moonOutline.systemImageName, "moon")
        XCTAssertEqual(MenuBarIconStyle.sunMoon.systemImageName, "moon.haze")
    }

    func testIdEqualsRawValue() {
        for style in MenuBarIconStyle.allCases {
            XCTAssertEqual(style.id, style.rawValue,
                           "id should equal rawValue for \(style)")
        }
    }
}

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
        XCTAssertEqual(MenuBarIconStyle.allCases.count, 6)
    }

    func testAllCasesMembership() {
        let cases = MenuBarIconStyle.allCases
        XCTAssertTrue(cases.contains(.defaultIcon))
        XCTAssertTrue(cases.contains(.classic))
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
        XCTAssertNil(MenuBarIconStyle.classic.systemImageName,
                     "Classic icon should use custom asset (nil)")
        XCTAssertEqual(MenuBarIconStyle.monitor.systemImageName, "display")
        XCTAssertEqual(MenuBarIconStyle.moonFilled.systemImageName, "moon.fill")
        XCTAssertEqual(MenuBarIconStyle.moonOutline.systemImageName, "moon")
        XCTAssertEqual(MenuBarIconStyle.sunMoon.systemImageName, "moon.haze")
    }

    func testAssetNames() {
        XCTAssertEqual(MenuBarIconStyle.defaultIcon.assetName, "MenuBarIcon")
        XCTAssertEqual(MenuBarIconStyle.classic.assetName, "MenuBarIconClassic")
        XCTAssertNil(MenuBarIconStyle.monitor.assetName)
        XCTAssertNil(MenuBarIconStyle.moonFilled.assetName)
        XCTAssertNil(MenuBarIconStyle.moonOutline.assetName)
        XCTAssertNil(MenuBarIconStyle.sunMoon.assetName)
    }

    func testIdEqualsRawValue() {
        for style in MenuBarIconStyle.allCases {
            XCTAssertEqual(style.id, style.rawValue,
                           "id should equal rawValue for \(style)")
        }
    }
}

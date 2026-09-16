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
        XCTAssertEqual(MenuBarIconStyle.allCases.count, 7)
    }

    func testAllCasesMembership() {
        let cases = MenuBarIconStyle.allCases
        XCTAssertTrue(cases.contains(.defaultIcon))
        XCTAssertTrue(cases.contains(.classic))
        XCTAssertTrue(cases.contains(.monitor))
        XCTAssertTrue(cases.contains(.moonFilled))
        XCTAssertTrue(cases.contains(.moonOutline))
        XCTAssertTrue(cases.contains(.sunMoon))
        XCTAssertTrue(cases.contains(.sunSplit))
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
        XCTAssertNil(MenuBarIconStyle.sunSplit.systemImageName,
                     "Split sun should use a custom asset (nil)")
    }

    func testAssetNames() {
        XCTAssertEqual(MenuBarIconStyle.defaultIcon.assetName, "MenuBarIcon")
        XCTAssertEqual(MenuBarIconStyle.classic.assetName, "MenuBarIconClassic")
        XCTAssertNil(MenuBarIconStyle.monitor.assetName)
        XCTAssertNil(MenuBarIconStyle.moonFilled.assetName)
        XCTAssertNil(MenuBarIconStyle.moonOutline.assetName)
        XCTAssertNil(MenuBarIconStyle.sunMoon.assetName)
        XCTAssertEqual(MenuBarIconStyle.sunSplit.assetName, "MenuBarIconSplit")
    }

    func testIdEqualsRawValue() {
        for style in MenuBarIconStyle.allCases {
            XCTAssertEqual(style.id, style.rawValue,
                           "id should equal rawValue for \(style)")
        }
    }

    func testActiveAssetNames() {
        XCTAssertEqual(MenuBarIconStyle.defaultIcon.activeAssetName, "MenuBarIconActive",
                       "Default style should have an active-state asset")
        XCTAssertNil(MenuBarIconStyle.classic.activeAssetName,
                     "Classic style stays static")
        XCTAssertNil(MenuBarIconStyle.monitor.activeAssetName)
        XCTAssertNil(MenuBarIconStyle.moonFilled.activeAssetName)
        XCTAssertNil(MenuBarIconStyle.moonOutline.activeAssetName)
        XCTAssertNil(MenuBarIconStyle.sunMoon.activeAssetName)
        XCTAssertNil(MenuBarIconStyle.sunSplit.activeAssetName,
                     "Split sun already reads as dimmed and stays static")
    }

    func testStylesWithActiveAssetAlsoHaveAnIdleAsset() {
        for style in MenuBarIconStyle.allCases where style.activeAssetName != nil {
            XCTAssertNotNil(style.assetName,
                            "\(style) has an active asset but no idle asset to fall back to")
        }
    }

    func testResolvedAssetNameUsesActiveVariantWhenActive() {
        XCTAssertEqual(MenuBarIconStyle.defaultIcon.resolvedAssetName(isActive: true),
                       "MenuBarIconActive")
    }

    func testResolvedAssetNameUsesIdleVariantWhenNotActive() {
        XCTAssertEqual(MenuBarIconStyle.defaultIcon.resolvedAssetName(isActive: false),
                       "MenuBarIcon")
    }

    func testResolvedAssetNameFallsBackToIdleForStylesWithoutAnActiveVariant() {
        XCTAssertEqual(MenuBarIconStyle.classic.resolvedAssetName(isActive: true),
                       "MenuBarIconClassic",
                       "Classic has no active variant and should keep its idle asset")
    }

    func testResolvedAssetNameIsNilForSymbolBackedStyles() {
        XCTAssertNil(MenuBarIconStyle.monitor.resolvedAssetName(isActive: true))
        XCTAssertNil(MenuBarIconStyle.moonFilled.resolvedAssetName(isActive: false))
    }
}

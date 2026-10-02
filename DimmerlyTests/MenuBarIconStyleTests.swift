//
//  MenuBarIconStyleTests.swift
//  DimmerlyTests
//
//  Unit tests for MenuBarIconStyle enum and the custom symbols it names.
//

import AppKit
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

    /// Every asset the styles name must exist in the app's asset catalog as a template
    /// symbol, so it tints with the menu bar and scales like a system symbol.
    @MainActor
    func testEveryCustomIconLoadsAsATemplateSymbol() throws {
        let names = Set(MenuBarIconStyle.allCases.flatMap { [$0.assetName, $0.activeAssetName] }.compactMap(\.self))
        XCTAssertEqual(names, ["MenuBarIcon", "MenuBarIconActive", "MenuBarIconClassic", "MenuBarIconSplit"])

        for name in names.sorted() {
            let image = try XCTUnwrap(NSImage(named: name), "\(name) is missing from the asset catalog")
            XCTAssertTrue(image.isTemplate, "\(name) must render as a template image")

            // A bitmap keeps its size under a symbol configuration; a symbol is redrawn at
            // the requested point size.
            let small = try XCTUnwrap(image.withSymbolConfiguration(.init(pointSize: 13, weight: .regular)))
            let large = try XCTUnwrap(image.withSymbolConfiguration(.init(pointSize: 26, weight: .regular)))
            XCTAssertGreaterThan(large.size.width, small.size.width * 1.8, "\(name) should be a scalable symbol")

            // At the 13 pt default that MenuBarExtra draws with, each icon stays as wide as
            // the 18 pt image it replaced, so the status item keeps its footprint.
            XCTAssertEqual(image.size.width, 18, accuracy: 0.5, "\(name) changed its menu bar width")
        }
    }
}

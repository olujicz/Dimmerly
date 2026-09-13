//
//  DimmerlyAppTests.swift
//  DimmerlyTests
//
//  Unit tests for the status bar icon's right-click quick actions menu.
//

import AppIntents
import AppKit
@testable import Dimmerly
import XCTest

@MainActor
final class DimmerlyAppTests: XCTestCase {
    func testSettingsPromotesWindowAfterSwiftUIAttachesIt() throws {
        let repositoryURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = repositoryURL.appendingPathComponent("Dimmerly/Views/SettingsView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains(".settingsWindowPresentation()"))
        XCTAssertTrue(source.contains("override func viewDidMoveToWindow()"))
        XCTAssertTrue(source.contains("window.orderFrontRegardless()"))
        XCTAssertFalse(source.contains(".onAppear {\n            NSApp.activate()\n        }"))
    }

    func testMenuBarExtraAccessUsesThePublicReleaseBeforeMacOS27SPI() throws {
        let repositoryURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let packageURL = repositoryURL.appendingPathComponent(
            "Dimmerly.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
        )
        let resolvedPackage = try String(contentsOf: packageURL, encoding: .utf8)

        XCTAssertTrue(resolvedPackage.contains("\"version\" : \"1.3.0\""))
        XCTAssertFalse(resolvedPackage.contains("\"version\" : \"1.3.1\""))
    }

    func testTurnOffTitleReflectsPreventScreenLockSetting() throws {
        // Isolated suite so this test doesn't read or overwrite the developer's real
        // preventScreenLock setting in UserDefaults.standard.
        let suiteName = "DimmerlyAppTests-\(UUID().uuidString)"
        let testDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { testDefaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(defaults: testDefaults)

        #if APPSTORE
            settings.preventScreenLock = false
            XCTAssertEqual(StatusItemQuickActions.turnOffTitle(settings: settings), "Dim Displays")
        #else
            settings.preventScreenLock = false
            XCTAssertEqual(StatusItemQuickActions.turnOffTitle(settings: settings), "Turn Displays Off")

            settings.preventScreenLock = true
            XCTAssertEqual(StatusItemQuickActions.turnOffTitle(settings: settings), "Dim Displays")
        #endif
    }

    func testQuickActionsMenuOrderMatchesHIGConventions() {
        let quickActions = StatusItemQuickActions()

        let menu = quickActions.makeQuickActionsMenu(turnOffTitle: "Turn Displays Off")

        // Action items first (most-used first), a separator, then Quit last —
        // matches Apple HIG guidance for grouping and destructive/exit actions.
        XCTAssertEqual(menu.items.map(\.title), [
            "Turn Displays Off",
            "Settings…",
            "",
            "Quit Dimmerly",
        ])
        XCTAssertTrue(menu.items[2].isSeparatorItem)
        XCTAssertEqual(menu.items[3].keyEquivalent, "q")
    }

    func testQuickActionsMenuItemsTargetTheirHandlers() {
        let quickActions = StatusItemQuickActions()

        let menu = quickActions.makeQuickActionsMenu(turnOffTitle: "Turn Displays Off")

        XCTAssertTrue(menu.items[0].target === quickActions)
        XCTAssertTrue(menu.items[1].target === quickActions)
        XCTAssertTrue(menu.items[3].target === NSApp)
    }

    func testQuickActionsSelectTheContextMenuPresentationOnMacOS27() {
        if #available(macOS 27.0, *) {
            XCTAssertEqual(StatusItemQuickActionsPresentation.current, .contextMenu)
        } else {
            XCTAssertEqual(StatusItemQuickActionsPresentation.current, .statusItemMenu)
        }
    }

    @available(macOS, deprecated: 26.0)
    func testWidgetIntentsKeepTheLegacyForegroundFallback() {
        XCTAssertTrue(DimDisplaysWidgetIntent.openAppWhenRun)
        XCTAssertTrue(ApplyPresetWidgetIntent.openAppWhenRun)
    }

    #if compiler(>=6.4)
        @available(macOS 27.0, *)
        func testWidgetIntentExecutionPolicyMapsAppAndExtensionTargets() {
            XCTAssertEqual(
                WidgetIntentExecutionPolicy.mainApp.intentExecutionTargets,
                .main
            )
            XCTAssertEqual(
                WidgetIntentExecutionPolicy.widgetKitExtension.intentExecutionTargets,
                .widgetKitExtension
            )
            XCTAssertEqual(WidgetIntentExecutionPolicy.current, .mainApp)
        }

        @available(macOS 27.0, *)
        func testWidgetIntentsTargetTheMainAppOnMacOS27() {
            XCTAssertEqual(DimDisplaysWidgetIntent.allowedExecutionTargets, .main)
            XCTAssertEqual(ApplyPresetWidgetIntent.allowedExecutionTargets, .main)
        }

        @available(macOS 27.0, *)
        func testPresetEntityQueryConformsToSpotlightRecoveryProtocolOnMacOS27() {
            let query: any IndexedEntityQuery = PresetEntityQuery()
            XCTAssertNotNil(query)
        }

        @available(macOS 27.0, *)
        func testMainIntentsAndQueriesTargetTheMainAppOnMacOS27() {
            XCTAssertEqual(DisplayEntityQuery.allowedExecutionTargets, .main)
            XCTAssertEqual(PresetEntityQuery.allowedExecutionTargets, .main)
            XCTAssertEqual(SleepDisplaysIntent.allowedExecutionTargets, .main)
            XCTAssertEqual(SetDisplayBrightnessIntent.allowedExecutionTargets, .main)
            XCTAssertEqual(SetDisplayWarmthIntent.allowedExecutionTargets, .main)
            XCTAssertEqual(SetDisplayContrastIntent.allowedExecutionTargets, .main)
            XCTAssertEqual(ToggleDimIntent.allowedExecutionTargets, .main)
            XCTAssertEqual(ApplyPresetIntent.allowedExecutionTargets, .main)
        }
    #endif

    func testParameterizedIntentsExposeConstructibleConversationalSummaries() {
        _ = SetDisplayBrightnessIntent.parameterSummary
        _ = SetDisplayWarmthIntent.parameterSummary
        _ = SetDisplayContrastIntent.parameterSummary
        _ = ToggleDimIntent.parameterSummary
        _ = ApplyPresetIntent.parameterSummary
    }

    func testConversationalIntentsArePublishedAsAppShortcuts() {
        XCTAssertEqual(DimmerlyShortcuts.appShortcuts.count, 6)
    }
}

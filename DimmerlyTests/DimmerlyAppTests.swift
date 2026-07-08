//
//  DimmerlyAppTests.swift
//  DimmerlyTests
//
//  Unit tests for the status bar icon's right-click quick actions menu.
//

import AppKit
@testable import Dimmerly
import XCTest

@MainActor
final class DimmerlyAppTests: XCTestCase {
    func testTurnOffTitleReflectsPreventScreenLockSetting() {
        let settings = AppSettings()

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
}

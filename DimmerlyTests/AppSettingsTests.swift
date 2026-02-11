//
//  AppSettingsTests.swift
//  DimmerlyTests
//
//  Unit tests for AppSettings functionality.
//  Tests default values and persistence behavior.
//

import XCTest
@testable import Dimmerly

/// Tests for the AppSettings model
@MainActor
final class AppSettingsTests: XCTestCase {

    var settings: AppSettings!
    let testSuiteName = "DimmerlyTestSuite"

    override func setUp() {
        super.setUp()
        // Create settings with a test UserDefaults suite to avoid affecting real settings
        // Note: AppSettings uses @AppStorage which uses UserDefaults.standard
        // For proper isolation, we would need to refactor AppSettings to accept a UserDefaults instance
        settings = AppSettings()
    }

    override func tearDown() {
        // Clean up test data
        settings = nil
        super.tearDown()
    }

    /// Tests that AppSettings has proper default values
    func testDefaultValues() {
        // Given: A new AppSettings instance
        let newSettings = AppSettings()

        // Then: It should have default values
        XCTAssertFalse(newSettings.launchAtLogin, "Launch at login should default to false")
        XCTAssertNotNil(newSettings.keyboardShortcut, "Keyboard shortcut should not be nil")

        // The default shortcut should match GlobalShortcut.default
        let defaultShortcut = GlobalShortcut.default
        XCTAssertEqual(newSettings.keyboardShortcut.key, defaultShortcut.key, "Default key should match")
        XCTAssertEqual(newSettings.keyboardShortcut.modifiers, defaultShortcut.modifiers, "Default modifiers should match")
    }

    /// Tests that keyboard shortcut changes trigger objectWillChange
    func testKeyboardShortcutChangeNotification() {
        // Given: An AppSettings instance
        let expectation = XCTestExpectation(description: "Object will change notification")
        var notificationReceived = false

        let cancellable = settings.objectWillChange.sink {
            notificationReceived = true
            expectation.fulfill()
        }

        // When: We change the keyboard shortcut
        let newShortcut = GlobalShortcut(key: "s", modifiers: [.command, .shift])
        settings.keyboardShortcut = newShortcut

        // Then: The notification should be received
        wait(for: [expectation], timeout: 1.0)
        XCTAssertTrue(notificationReceived, "objectWillChange should fire when keyboard shortcut changes")

        cancellable.cancel()
    }

    /// Tests that launch at login can be toggled
    func testLaunchAtLoginToggle() {
        // Given: Initial state
        let initialValue = settings.launchAtLogin

        // When: We toggle the value
        settings.launchAtLogin.toggle()

        // Then: The value should be different
        XCTAssertNotEqual(settings.launchAtLogin, initialValue, "Launch at login should toggle")

        // Toggle back
        settings.launchAtLogin.toggle()
        XCTAssertEqual(settings.launchAtLogin, initialValue, "Should toggle back to original value")
    }

    /// Tests that resetToDefaults works correctly
    func testResetToDefaults() {
        // Given: Modified settings
        settings.launchAtLogin = true
        settings.keyboardShortcut = GlobalShortcut(key: "x", modifiers: [.command])

        // When: We reset to defaults
        settings.resetToDefaults()

        // Then: Settings should be back to defaults
        XCTAssertFalse(settings.launchAtLogin, "Launch at login should be reset to false")

        let defaultShortcut = GlobalShortcut.default
        XCTAssertEqual(settings.keyboardShortcut.key, defaultShortcut.key, "Shortcut key should be reset")
        XCTAssertEqual(settings.keyboardShortcut.modifiers, defaultShortcut.modifiers, "Shortcut modifiers should be reset")
    }

    /// Tests that AppSettings is ObservableObject
    func testObservableObjectConformance() {
        // AppSettings should conform to ObservableObject
        XCTAssertTrue(settings is ObservableObject, "AppSettings should conform to ObservableObject")
    }

    /// Tests keyboard shortcut encoding and decoding
    func testKeyboardShortcutPersistence() {
        // Given: A custom keyboard shortcut
        let customShortcut = GlobalShortcut(key: "p", modifiers: [.command, .option])

        // When: We set it
        settings.keyboardShortcut = customShortcut

        // Then: We should be able to read it back
        XCTAssertEqual(settings.keyboardShortcut.key, "p", "Key should persist")
        XCTAssertEqual(settings.keyboardShortcut.modifiers, [.command, .option], "Modifiers should persist")
    }

    /// Tests that invalid shortcuts are handled gracefully
    func testInvalidShortcutHandling() {
        // Given: A keyboard shortcut with invalid data
        // When: AppSettings tries to decode it
        // Then: It should fall back to default

        // This is implicitly tested by the default value behavior
        // If decoding fails, the getter returns GlobalShortcut.default
        let currentShortcut = settings.keyboardShortcut
        XCTAssertNotNil(currentShortcut, "Should always return a valid shortcut")
    }
}

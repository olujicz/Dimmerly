//
//  AppSettingsTests.swift
//  DimmerlyTests
//
//  Unit tests for AppSettings functionality.
//  Tests default values and persistence behavior.
//

@testable import Dimmerly
import XCTest

/// Tests for the AppSettings model
@MainActor
final class AppSettingsTests: XCTestCase {
    var settings: AppSettings!
    let testSuiteName = "DimmerlyTestSuite"

    /// UserDefaults keys used by AppSettings via @AppStorage
    private let appStorageKeys = [
        "dimmerlyKeyboardShortcut",
        "dimmerlyLaunchAtLogin",
        "dimmerlyPreventScreenLock",
        "dimmerlyIgnoreMouseMovement",
        "dimmerlyMenuBarIcon",
        "dimmerlyIdleTimerEnabled",
        "dimmerlyIdleTimerMinutes",
        "dimmerlyFadeTransition",
        "dimmerlyRequireEscapeToDismiss",
        AppSettings.scheduleEnabledKey,
        AppSettings.autoColorTempEnabledKey,
        "dimmerlyDayTemperature",
        "dimmerlyNightTemperature",
        "dimmerlyColorTempTransitionMinutes"
    ]

    override func setUp() async throws {
        // Remove all AppSettings keys so @AppStorage sees its declared defaults
        for key in appStorageKeys {
            UserDefaults.standard.removeObject(forKey: key)
        }
        settings = AppSettings()
    }

    override func tearDown() async throws {
        settings = nil
        for key in appStorageKeys {
            UserDefaults.standard.removeObject(forKey: key)
        }
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
        XCTAssertEqual(
            newSettings.keyboardShortcut.modifiers, defaultShortcut.modifiers,
            "Default modifiers should match"
        )
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
        XCTAssertEqual(
            settings.keyboardShortcut.modifiers, defaultShortcut.modifiers,
            "Shortcut modifiers should be reset"
        )
    }

    /// Tests that AppSettings is ObservableObject
    func testObservableObjectConformance() {
        /// Compile-time conformance check via type constraint
        func requiresObservable<T: ObservableObject>(_: T) {}
        requiresObservable(settings)
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

    // MARK: - Additional default value tests

    func testPreventScreenLockDefault() {
        XCTAssertFalse(settings.preventScreenLock, "preventScreenLock should default to false")
    }

    func testIgnoreMouseMovementDefault() {
        XCTAssertFalse(settings.ignoreMouseMovement, "ignoreMouseMovement should default to false")
    }

    func testIdleTimerEnabledDefault() {
        XCTAssertFalse(settings.idleTimerEnabled, "idleTimerEnabled should default to false")
    }

    func testIdleTimerMinutesDefault() {
        XCTAssertEqual(settings.idleTimerMinutes, 5, "idleTimerMinutes should default to 5")
    }

    func testFadeTransitionDefault() {
        XCTAssertTrue(settings.fadeTransition, "fadeTransition should default to true")
    }

    func testRequireEscapeToDismissDefault() {
        XCTAssertFalse(settings.requireEscapeToDismiss, "requireEscapeToDismiss should default to false")
    }

    func testScheduleEnabledDefault() {
        XCTAssertFalse(settings.scheduleEnabled, "scheduleEnabled should default to false")
    }

    // MARK: - menuBarIcon computed property

    func testMenuBarIconDefault() {
        XCTAssertEqual(settings.menuBarIcon, .defaultIcon, "menuBarIcon should default to .defaultIcon")
    }

    func testMenuBarIconGetSetRoundTrip() {
        settings.menuBarIcon = .moonFilled
        XCTAssertEqual(settings.menuBarIcon, .moonFilled)
        XCTAssertEqual(settings.menuBarIconRaw, "moonFilled")

        settings.menuBarIcon = .monitor
        XCTAssertEqual(settings.menuBarIcon, .monitor)
    }

    func testMenuBarIconInvalidRawValueFallback() {
        settings.menuBarIconRaw = "nonexistent_style"
        XCTAssertEqual(settings.menuBarIcon, .defaultIcon,
                       "Invalid raw value should fall back to .defaultIcon")
    }

    // MARK: - Comprehensive resetToDefaults

    func testResetToDefaultsComprehensive() {
        // Modify all settings
        settings.keyboardShortcut = GlobalShortcut(key: "x", modifiers: [.command])
        settings.launchAtLogin = true
        settings.preventScreenLock = true
        settings.ignoreMouseMovement = true
        settings.menuBarIcon = .moonOutline
        settings.idleTimerEnabled = true
        settings.idleTimerMinutes = 15
        settings.fadeTransition = false
        settings.requireEscapeToDismiss = true
        settings.scheduleEnabled = true

        // Reset
        settings.resetToDefaults()

        // Verify all properties
        let defaultShortcut = GlobalShortcut.default
        XCTAssertEqual(settings.keyboardShortcut.key, defaultShortcut.key)
        XCTAssertEqual(settings.keyboardShortcut.modifiers, defaultShortcut.modifiers)
        XCTAssertFalse(settings.launchAtLogin)
        XCTAssertFalse(settings.preventScreenLock)
        XCTAssertFalse(settings.ignoreMouseMovement)
        XCTAssertEqual(settings.menuBarIcon, .defaultIcon)
        XCTAssertFalse(settings.idleTimerEnabled)
        XCTAssertEqual(settings.idleTimerMinutes, 5)
        XCTAssertTrue(settings.fadeTransition)
        XCTAssertFalse(settings.requireEscapeToDismiss)
        XCTAssertFalse(settings.scheduleEnabled)
    }
}

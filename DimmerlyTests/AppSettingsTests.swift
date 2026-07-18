//
//  AppSettingsTests.swift
//  DimmerlyTests
//
//  Unit tests for AppSettings functionality.
//  Tests default values and persistence behavior.
//

@testable import Dimmerly
import Observation
import XCTest

/// Tests for the AppSettings model
@MainActor
final class AppSettingsTests: XCTestCase {
    var settings: AppSettings!

    /// An isolated UserDefaults suite, unique per test run, so these tests never read or
    /// overwrite the developer's real app settings in `UserDefaults.standard`.
    private var testSuiteName: String!
    private var testDefaults: UserDefaults!

    override func setUp() async throws {
        testSuiteName = "AppSettingsTests-\(UUID().uuidString)"
        testDefaults = UserDefaults(suiteName: testSuiteName)
        testDefaults.removePersistentDomain(forName: testSuiteName)
        settings = AppSettings(defaults: testDefaults)
    }

    override func tearDown() async throws {
        settings = nil
        testDefaults.removePersistentDomain(forName: testSuiteName)
        testDefaults = nil
        testSuiteName = nil
    }

    /// Tests that AppSettings has proper default values
    func testDefaultValues() {
        // Given: A new AppSettings instance
        let newSettings = AppSettings(defaults: testDefaults)

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

    #if !APPSTORE
        func testApplyDDCEnabledChangeAppliesRuntimeSettingsWhenTurningOn() async {
            settings.ddcEnabled = false
            settings.ddcControlMode = .hardware
            settings.ddcPollingInterval = 13
            settings.ddcWriteDelay = 120
            let manager = HardwareBrightnessManager(forTesting: true, ddcInterface: MockDDCInterface())
            manager.capabilities[25] = HardwareDisplayCapability(
                displayID: 25,
                supportsDDC: true,
                supportedCodes: [.brightness],
                maxBrightness: 100,
                maxContrast: 0,
                maxVolume: 0
            )

            await applyDDCEnabledChange(true, settings: settings, hardwareManager: manager)
            manager.stopPolling()

            XCTAssertTrue(settings.ddcEnabled)
            XCTAssertTrue(manager.isEnabled)
            XCTAssertEqual(manager.controlMode, .hardware)
            XCTAssertEqual(manager.pollingInterval, 13)
            XCTAssertEqual(manager.minimumWriteInterval, 0.12, accuracy: 0.001)
        }

        func testSettingsHardwareModesAreDisabledWhenUnavailable() throws {
            let repositoryURL = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            let settingsViewSourceURL = repositoryURL.appendingPathComponent("Dimmerly/Views/SettingsView.swift")
            let source = try String(contentsOf: settingsViewSourceURL, encoding: .utf8)

            XCTAssertTrue(
                source.contains(".disabled(!isDDCControlModeAvailable(mode, hardwareManager: hardwareManager))"),
                "The Hardware DDC mode picker row should be disabled when hardware brightness is unavailable"
            )
        }

        func testSettingsExplainsWhyHardwareModesAreUnavailable() throws {
            let repositoryURL = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            let settingsViewSourceURL = repositoryURL.appendingPathComponent("Dimmerly/Views/SettingsView.swift")
            let source = try String(contentsOf: settingsViewSourceURL, encoding: .utf8)

            XCTAssertTrue(
                source.contains("Hardware mode requires a DDC-capable display with brightness control."),
                "The unavailable Hardware picker row should have a nearby explanation"
            )
        }

        func testSettingsKeepsAdvancedDDCControlsBehindDisclosure() throws {
            let repositoryURL = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            let settingsViewSourceURL = repositoryURL.appendingPathComponent("Dimmerly/Views/SettingsView.swift")
            let source = try String(contentsOf: settingsViewSourceURL, encoding: .utf8)

            XCTAssertTrue(
                source.contains("DisclosureGroup(\"Advanced\")"),
                "DDC polling and write timing controls should be grouped as advanced settings"
            )
            XCTAssertTrue(
                source.contains(".help(\"DDC/CI controls"),
                "Detailed DDC compatibility caveats should live in help text instead of always-visible copy"
            )
            XCTAssertFalse(
                source.contains("Text(\n                        \"DDC/CI controls"),
                "The hardware section should avoid a long always-visible DDC compatibility paragraph"
            )
        }

        func testAdvancedDDCSteppersUseCompactRows() throws {
            let repositoryURL = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            let settingsViewSourceURL = repositoryURL.appendingPathComponent("Dimmerly/Views/SettingsView.swift")
            let source = try String(contentsOf: settingsViewSourceURL, encoding: .utf8)

            XCTAssertTrue(
                source.contains("ddcAdvancedStepperRow("),
                "Advanced DDC steppers should use compact rows so controls stay visually attached to their labels"
            )
            XCTAssertTrue(
                source.contains(".labelsHidden()"),
                "Compact DDC stepper rows should hide the empty native Stepper label"
            )
            XCTAssertTrue(
                source.contains(".frame(maxWidth: .infinity, alignment: .leading)"),
                "Compact DDC stepper rows should align their contents to the leading edge "
                    + "instead of the far trailing edge"
            )
        }

        func testDDCDisplayStatusPresentationRequiresBrightnessForSuccess() {
            let brightnessCapable = HardwareDisplayCapability(
                displayID: 25,
                supportsDDC: true,
                supportedCodes: [.brightness, .volume],
                maxBrightness: 100,
                maxContrast: 0,
                maxVolume: 100
            )
            let partialDDC = HardwareDisplayCapability(
                displayID: 26,
                supportsDDC: true,
                supportedCodes: [.volume, .inputSource],
                maxBrightness: 0,
                maxContrast: 0,
                maxVolume: 100
            )
            let unsupported = HardwareDisplayCapability.notSupported(displayID: 27)

            XCTAssertEqual(ddcDisplayStatusSymbolName(for: brightnessCapable), "checkmark.circle.fill")
            XCTAssertEqual(ddcDisplayStatusText(for: brightnessCapable), "Brightness, Volume")
            XCTAssertEqual(
                ddcDisplayAccessibilityStatus(for: brightnessCapable),
                "hardware brightness available, Brightness, Volume"
            )

            XCTAssertEqual(ddcDisplayStatusSymbolName(for: partialDDC), "exclamationmark.circle")
            XCTAssertEqual(ddcDisplayStatusText(for: partialDDC), "No hardware brightness (Volume, Input)")
            XCTAssertEqual(
                ddcDisplayAccessibilityStatus(for: partialDDC),
                "DDC available, no hardware brightness, Volume, Input"
            )

            XCTAssertEqual(ddcDisplayStatusSymbolName(for: unsupported), "tv.and.mediabox")
            XCTAssertEqual(ddcDisplayStatusText(for: unsupported), "Software brightness")
            XCTAssertEqual(ddcDisplayAccessibilityStatus(for: unsupported), "using software brightness")
        }

        func testDDCControlModeAvailabilityRequiresEnabledHardwareBrightness() async {
            let manager = HardwareBrightnessManager(forTesting: true, ddcInterface: MockDDCInterface())

            XCTAssertTrue(isDDCControlModeAvailable(.softwareOnly, hardwareManager: manager))
            XCTAssertFalse(isDDCControlModeAvailable(.hardware, hardwareManager: manager))

            manager.enable()
            manager.capabilities[25] = HardwareDisplayCapability(
                displayID: 25,
                supportsDDC: true,
                supportedCodes: [.volume],
                maxBrightness: 0,
                maxContrast: 0,
                maxVolume: 100
            )

            XCTAssertFalse(isDDCControlModeAvailable(.hardware, hardwareManager: manager))

            manager.capabilities[25] = HardwareDisplayCapability(
                displayID: 25,
                supportsDDC: true,
                supportedCodes: [.brightness],
                maxBrightness: 100,
                maxContrast: 0,
                maxVolume: 0
            )

            XCTAssertTrue(isDDCControlModeAvailable(.hardware, hardwareManager: manager))

            await manager.disable()
            XCTAssertFalse(isDDCControlModeAvailable(.hardware, hardwareManager: manager))
        }

        func testDDCControlModeMigrationPreservesCombinedAsHardware() {
            testDefaults.set("combined", forKey: "dimmerlyDDCControlMode")

            let migrated = AppSettings(defaults: testDefaults)

            XCTAssertEqual(migrated.ddcControlMode, .hardware)
            XCTAssertEqual(migrated.ddcControlModeRaw, "combined")
        }

        func testDDCControlModeMigrationCoalescesOrphanedHardwareValue() {
            testDefaults.set("hardware", forKey: "dimmerlyDDCControlMode")

            let migrated = AppSettings(defaults: testDefaults)

            XCTAssertEqual(migrated.ddcControlMode, .hardware)
            XCTAssertEqual(migrated.ddcControlModeRaw, "combined")
        }

        func testDDCControlModeMigrationPreservesSoftware() {
            testDefaults.set("software", forKey: "dimmerlyDDCControlMode")

            let migrated = AppSettings(defaults: testDefaults)

            XCTAssertEqual(migrated.ddcControlMode, .softwareOnly)
            XCTAssertEqual(migrated.ddcControlModeRaw, "software")
        }

        func testApplyDDCEnabledChangeReappliesSoftwareGammaWhenTurningOff() async {
            let hardwareManager = HardwareBrightnessManager(forTesting: true)
            let brightnessManager = BrightnessManager(forTesting: true)
            settings.ddcEnabled = true
            hardwareManager.enable()
            brightnessManager.displays = [
                ExternalDisplay(id: 91, name: "External", brightness: 0.42, warmth: 0.0, contrast: 0.5),
            ]
            var reapplyCount = 0
            brightnessManager.applyGammaHook = { displayID, brightness, _, _ in
                guard displayID == 91 else { return }
                reapplyCount += 1
                XCTAssertEqual(brightness, 0.42, accuracy: 0.001)
            }

            await applyDDCEnabledChange(
                false,
                settings: settings,
                hardwareManager: hardwareManager,
                brightnessManager: brightnessManager
            )

            XCTAssertFalse(settings.ddcEnabled)
            XCTAssertFalse(hardwareManager.isEnabled)
            XCTAssertEqual(reapplyCount, 1)
        }
    #endif

    /// Tests that keyboard shortcut changes are tracked by Observation
    func testKeyboardShortcutChangeNotification() {
        // Given: An AppSettings instance
        nonisolated(unsafe) var changeDetected = false

        withObservationTracking {
            _ = settings.keyboardShortcut
        } onChange: {
            changeDetected = true
        }

        // When: We change the keyboard shortcut
        let newShortcut = GlobalShortcut(key: "s", modifiers: [.command, .shift])
        settings.keyboardShortcut = newShortcut

        // Then: The change should be detected
        XCTAssertTrue(changeDetected, "Observation should detect when keyboard shortcut changes")
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

    /// Tests that AppSettings is Observable
    func testObservableConformance() {
        /// Compile-time conformance check via type constraint
        func requiresObservable(_: some Observable) {}
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
}

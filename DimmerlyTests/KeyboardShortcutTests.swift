//
//  KeyboardShortcutTests.swift
//  DimmerlyTests
//
//  Unit tests for GlobalShortcut functionality.
//  Tests shortcut creation, validation, and formatting.
//

import AppKit
import Carbon.HIToolbox
@testable import Dimmerly
import XCTest

/// Tests for the GlobalShortcut model
/// Synthesizes a key-down `NSEvent` for feeding into a captured monitor handler or straight
/// into `GlobalShortcut.matches(event:)` (keyCode 2 is 'd' on the ANSI layout).
private func makeKeyDownEvent(
    keyCode: UInt16,
    modifierFlags: NSEvent.ModifierFlags,
    charactersIgnoringModifiers: String = ""
) -> NSEvent {
    NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: modifierFlags,
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        characters: "",
        charactersIgnoringModifiers: charactersIgnoringModifiers,
        isARepeat: false,
        keyCode: keyCode
    )!
}

final class GlobalShortcutTests: XCTestCase {
    /// Tests that the default shortcut is configured correctly
    func testDefaultShortcut() {
        // Given: The default shortcut
        let defaultShortcut = GlobalShortcut.default

        // Then: It should be Cmd+Opt+Shift+D
        XCTAssertEqual(defaultShortcut.key, "d", "Default key should be 'd'")
        XCTAssertTrue(defaultShortcut.modifiers.contains(.command), "Should contain command modifier")
        XCTAssertTrue(defaultShortcut.modifiers.contains(.option), "Should contain option modifier")
        XCTAssertTrue(defaultShortcut.modifiers.contains(.shift), "Should contain shift modifier")
        XCTAssertEqual(defaultShortcut.modifiers.count, 3, "Should have exactly 3 modifiers")
        XCTAssertEqual(defaultShortcut.keyCode, UInt16(kVK_ANSI_D), "Default key code should be ANSI-D")
    }

    /// Tests display string formatting
    func testDisplayString() {
        // Test default shortcut display
        let defaultShortcut = GlobalShortcut.default
        let displayString = defaultShortcut.displayString

        XCTAssertTrue(displayString.contains("⌘"), "Display string should contain command symbol")
        XCTAssertTrue(displayString.contains("⌥"), "Display string should contain option symbol")
        XCTAssertTrue(displayString.contains("⇧"), "Display string should contain shift symbol")
        XCTAssertTrue(displayString.contains("D"), "Display string should contain uppercase key")

        // Test custom shortcut
        let customShortcut = GlobalShortcut(key: "s", modifiers: [.control, .command])
        let customDisplay = customShortcut.displayString

        XCTAssertTrue(customDisplay.contains("⌃"), "Should contain control symbol")
        XCTAssertTrue(customDisplay.contains("⌘"), "Should contain command symbol")
        XCTAssertTrue(customDisplay.contains("S"), "Should contain uppercase key")
        XCTAssertFalse(customDisplay.contains("⌥"), "Should not contain option symbol")
    }

    /// Tests that display string uses correct modifier order
    func testDisplayStringModifierOrder() {
        // Given: A shortcut with all modifiers
        let shortcut = GlobalShortcut(key: "a", modifiers: [.command, .control, .option, .shift])

        // When: We get the display string
        let display = shortcut.displayString

        // Then: Modifiers should appear in standard order: Control, Option, Shift, Command
        let controlIndex = display.firstIndex(of: "⌃")
        let optionIndex = display.firstIndex(of: "⌥")
        let shiftIndex = display.firstIndex(of: "⇧")
        let commandIndex = display.firstIndex(of: "⌘")

        XCTAssertNotNil(controlIndex)
        XCTAssertNotNil(optionIndex)
        XCTAssertNotNil(shiftIndex)
        XCTAssertNotNil(commandIndex)

        if let ctrl = controlIndex, let opt = optionIndex, let shft = shiftIndex, let cmd = commandIndex {
            XCTAssertTrue(ctrl < opt, "Control should come before Option")
            XCTAssertTrue(opt < shft, "Option should come before Shift")
            XCTAssertTrue(shft < cmd, "Shift should come before Command")
        }
    }

    /// Tests Codable conformance (encoding and decoding)
    func testCodableConformance() throws {
        // Given: A keyboard shortcut
        let originalShortcut = GlobalShortcut(key: "r", modifiers: [.command, .shift])

        // When: We encode it
        let encoder = JSONEncoder()
        let data = try encoder.encode(originalShortcut)

        // Then: We should be able to decode it back
        let decoder = JSONDecoder()
        let decodedShortcut = try decoder.decode(GlobalShortcut.self, from: data)

        XCTAssertEqual(decodedShortcut.key, originalShortcut.key, "Decoded key should match")
        XCTAssertEqual(decodedShortcut.modifiers, originalShortcut.modifiers, "Decoded modifiers should match")
        XCTAssertEqual(decodedShortcut.keyCode, originalShortcut.keyCode, "Decoded key code should match")
        XCTAssertEqual(decodedShortcut, originalShortcut, "Codable round trip should preserve equality")
    }

    /// Tests backwards compatibility — decoding old string-based modifier format
    func testBackwardsCompatibleDecoding() throws {
        // Given: JSON in the old format with string modifiers
        let oldFormatJSON = """
        {"key":"d","modifiers":["command","option","shift"]}
        """
        let data = try XCTUnwrap(oldFormatJSON.data(using: .utf8))

        // When: We decode it
        let shortcut = try JSONDecoder().decode(GlobalShortcut.self, from: data)

        // Then: It should decode correctly since ShortcutModifier raw values match
        XCTAssertEqual(shortcut.key, "d")
        XCTAssertEqual(shortcut.modifiers, [.command, .option, .shift])
    }

    func testLegacyKeyCodeRemainsAbsentWhenReencoded() throws {
        for json in [
            #"{"key":"d","modifiers":["command"]}"#,
            #"{"key":"d","modifiers":["command"],"keyCode":null}"#,
        ] {
            let shortcut = try JSONDecoder().decode(GlobalShortcut.self, from: Data(json.utf8))
            XCTAssertNil(shortcut.keyCode)

            let data = try JSONEncoder().encode(shortcut)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertNil(object["keyCode"])
            XCTAssertEqual(object["key"] as? String, "d")
        }
    }

    /// Tests Equatable conformance
    func testEquatableConformance() {
        // Given: Two identical shortcuts
        let shortcut1 = GlobalShortcut(key: "d", modifiers: [.command, .option, .shift])
        let shortcut2 = GlobalShortcut(key: "d", modifiers: [.command, .option, .shift])

        // Then: They should be equal
        XCTAssertEqual(shortcut1, shortcut2, "Identical shortcuts should be equal")

        // Given: Two different shortcuts
        let shortcut3 = GlobalShortcut(key: "s", modifiers: [.command])

        // Then: They should not be equal
        XCTAssertNotEqual(shortcut1, shortcut3, "Different shortcuts should not be equal")
    }

    /// Tests validation (shortcuts should have at least one modifier)
    func testValidation() {
        // Given: A shortcut with modifiers
        let validShortcut = GlobalShortcut(key: "d", modifiers: [.command])

        // Then: It should be valid
        XCTAssertTrue(validShortcut.isValid, "Shortcut with modifiers should be valid")

        // Given: A shortcut without modifiers
        let invalidShortcut = GlobalShortcut(key: "d", modifiers: [])

        // Then: It should be invalid
        XCTAssertFalse(invalidShortcut.isValid, "Shortcut without modifiers should be invalid")
    }

    /// Tests creation from key code and modifier flags
    func testFromKeyCodeAndModifiers() {
        // Test creating shortcut from NSEvent-like data
        // Note: Stable ANSI physical key codes are used

        // Test Command+D (keyCode 2 is 'd')
        let modifierFlags: NSEvent.ModifierFlags = [.command]
        if let shortcut = GlobalShortcut.from(keyCode: 2, modifierFlags: modifierFlags) {
            XCTAssertEqual(shortcut.key, "d", "Should create shortcut with 'd' key")
            XCTAssertTrue(shortcut.modifiers.contains(.command), "Should contain command modifier")
        } else {
            XCTFail("Should create valid shortcut from key code 2")
        }

        // Test with multiple modifiers
        let multiModifiers: NSEvent.ModifierFlags = [.command, .option, .shift]
        if let shortcut = GlobalShortcut.from(keyCode: 2, modifierFlags: multiModifiers) {
            XCTAssertEqual(shortcut.key, "d", "Should create shortcut with 'd' key")
            XCTAssertTrue(shortcut.modifiers.contains(.command), "Should contain command")
            XCTAssertTrue(shortcut.modifiers.contains(.option), "Should contain option")
            XCTAssertTrue(shortcut.modifiers.contains(.shift), "Should contain shift")
        } else {
            XCTFail("Should create valid shortcut with multiple modifiers")
        }
    }

    func testRecordedShortcutsUseLayoutLabelButMatchThePhysicalKey() throws {
        let us = try XCTUnwrap(
            GlobalShortcut.from(
                keyCode: UInt16(kVK_ANSI_A),
                modifierFlags: [.command],
                charactersIgnoringModifiers: "a"
            )
        )
        XCTAssertEqual(us.key, "a")
        XCTAssertEqual(us.keyCode, UInt16(kVK_ANSI_A))

        let azerty = try XCTUnwrap(
            GlobalShortcut.from(
                keyCode: UInt16(kVK_ANSI_A),
                modifierFlags: [.command],
                charactersIgnoringModifiers: "q"
            )
        )
        XCTAssertEqual(azerty.key, "q")
        XCTAssertEqual(azerty.displayString, "⌘Q")
        XCTAssertTrue(
            azerty.matches(
                keyCode: UInt16(kVK_ANSI_A),
                modifierFlags: [.command]
            )
        )
        XCTAssertFalse(
            azerty.matches(
                keyCode: UInt16(kVK_ANSI_Q),
                modifierFlags: [.command]
            )
        )

        let qwertz = try XCTUnwrap(
            GlobalShortcut.from(
                keyCode: UInt16(kVK_ANSI_Y),
                modifierFlags: [.command],
                charactersIgnoringModifiers: "z"
            )
        )
        XCTAssertEqual(qwertz.key, "z")
        XCTAssertEqual(qwertz.keyCode, UInt16(kVK_ANSI_Y))
    }

    func testLayoutLabelsOnlyOverridePrintableKeys() throws {
        let functionKeys: [(UInt16, String)] = [
            (UInt16(kVK_F1), "f1"), (UInt16(kVK_F2), "f2"),
            (UInt16(kVK_F3), "f3"), (UInt16(kVK_F4), "f4"),
            (UInt16(kVK_F5), "f5"), (UInt16(kVK_F6), "f6"),
            (UInt16(kVK_F7), "f7"), (UInt16(kVK_F8), "f8"),
            (UInt16(kVK_F9), "f9"), (UInt16(kVK_F10), "f10"),
            (UInt16(kVK_F11), "f11"), (UInt16(kVK_F12), "f12"),
        ]
        for (keyCode, keyString) in functionKeys {
            let functionKey = try XCTUnwrap(
                GlobalShortcut.from(
                    keyCode: keyCode,
                    modifierFlags: [.command],
                    charactersIgnoringModifiers: "not-" + keyString
                )
            )
            XCTAssertEqual(functionKey.key, keyString)
        }

        let returnKey = try XCTUnwrap(
            GlobalShortcut.from(
                keyCode: UInt16(kVK_Return),
                modifierFlags: [.command],
                charactersIgnoringModifiers: "x"
            )
        )
        let escape = try XCTUnwrap(
            GlobalShortcut.from(
                keyCode: UInt16(kVK_Escape),
                modifierFlags: [.command],
                charactersIgnoringModifiers: "x"
            )
        )

        XCTAssertEqual(returnKey.key, "return")
        XCTAssertEqual(escape.key, "escape")
    }

    func testShiftedNumericKeyRetainsBasePhysicalLabel() throws {
        let shortcut = try XCTUnwrap(
            GlobalShortcut.from(
                keyCode: UInt16(kVK_ANSI_1),
                modifierFlags: [.command, .shift],
                charactersIgnoringModifiers: "!"
            )
        )

        XCTAssertEqual(shortcut.key, "1")
        XCTAssertEqual(shortcut.displayString, "⇧⌘1")
    }

    func testLegacyEventMatchingUsesANSIPhysicalKeyNotLayoutLabel() throws {
        let legacy = try JSONDecoder().decode(
            GlobalShortcut.self,
            from: Data(#"{"key":"q","modifiers":["command"]}"#.utf8)
        )
        let azertyPhysicalQEvent = makeKeyDownEvent(
            keyCode: UInt16(kVK_ANSI_Q),
            modifierFlags: [.command],
            charactersIgnoringModifiers: "a"
        )
        let azertyPhysicalAEvent = makeKeyDownEvent(
            keyCode: UInt16(kVK_ANSI_A),
            modifierFlags: [.command],
            charactersIgnoringModifiers: "q"
        )

        XCTAssertTrue(legacy.matches(event: azertyPhysicalQEvent))
        XCTAssertFalse(legacy.matches(event: azertyPhysicalAEvent))
    }

    func testLegacyStringShortcutDecodesWithoutPhysicalKeyCode() throws {
        let data = Data(#"{"key":"d","modifiers":["command"]}"#.utf8)
        let shortcut = try JSONDecoder().decode(GlobalShortcut.self, from: data)

        XCTAssertNil(shortcut.keyCode)
        XCTAssertTrue(shortcut.matches(keyCode: UInt16(kVK_ANSI_D), modifierFlags: [.command]))
    }

    /// Tests that unsupported key codes return nil
    func testUnsupportedKeyCode() {
        // Given: An unsupported key code (e.g., 999)
        let modifierFlags: NSEvent.ModifierFlags = [.command]

        // When: We try to create a shortcut
        let shortcut = GlobalShortcut.from(keyCode: 999, modifierFlags: modifierFlags)

        // Then: It should return nil
        XCTAssertNil(shortcut, "Unsupported key codes should return nil")
    }

    /// Tests various supported key codes
    func testSupportedKeyCodes() {
        // Test letter keys (a-z)
        let letterKeyCode: UInt16 = 0 // 'a'
        if let shortcut = GlobalShortcut.from(keyCode: letterKeyCode, modifierFlags: [.command]) {
            XCTAssertEqual(shortcut.key, "a", "Should recognize letter key 'a'")
        } else {
            XCTFail("Should recognize letter key codes")
        }

        // Test number keys
        let numberKeyCode: UInt16 = 29 // '0'
        if let shortcut = GlobalShortcut.from(keyCode: numberKeyCode, modifierFlags: [.command]) {
            XCTAssertEqual(shortcut.key, "0", "Should recognize number key '0'")
        } else {
            XCTFail("Should recognize number key codes")
        }
    }

    // MARK: - ShortcutModifier tests

    /// Tests ShortcutModifier raw values match expected strings
    func testShortcutModifierRawValues() {
        XCTAssertEqual(ShortcutModifier.command.rawValue, "command")
        XCTAssertEqual(ShortcutModifier.option.rawValue, "option")
        XCTAssertEqual(ShortcutModifier.shift.rawValue, "shift")
        XCTAssertEqual(ShortcutModifier.control.rawValue, "control")
    }

    /// Tests ShortcutModifier Codable conformance
    func testShortcutModifierCodable() throws {
        let modifiers: Set<ShortcutModifier> = [.command, .shift]
        let data = try JSONEncoder().encode(modifiers)
        let decoded = try JSONDecoder().decode(Set<ShortcutModifier>.self, from: data)
        XCTAssertEqual(decoded, modifiers)
    }

    // MARK: - isReservedSystemShortcut tests

    /// Tests that known reserved shortcuts are detected
    func testReservedSystemShortcutDetected() {
        let cmdC = GlobalShortcut(key: "c", modifiers: [.command])
        XCTAssertTrue(cmdC.isReservedSystemShortcut, "Cmd+C should be reserved")

        let cmdQ = GlobalShortcut(key: "q", modifiers: [.command])
        XCTAssertTrue(cmdQ.isReservedSystemShortcut, "Cmd+Q should be reserved")

        let cmdShiftZ = GlobalShortcut(key: "z", modifiers: [.command, .shift])
        XCTAssertTrue(cmdShiftZ.isReservedSystemShortcut, "Cmd+Shift+Z should be reserved")
    }

    /// Tests that custom non-reserved shortcuts are allowed
    func testCustomShortcutAllowed() {
        let cmdOptShiftD = GlobalShortcut(key: "d", modifiers: [.command, .option, .shift])
        XCTAssertFalse(cmdOptShiftD.isReservedSystemShortcut, "Cmd+Opt+Shift+D should not be reserved")

        let ctrlShiftK = GlobalShortcut(key: "k", modifiers: [.control, .shift])
        XCTAssertFalse(ctrlShiftK.isReservedSystemShortcut, "Ctrl+Shift+K should not be reserved")
    }
}

extension GlobalShortcutTests {
    func testLegacyAndCurrentShortcutCompareEqualForConflictDetection() throws {
        let legacy = try JSONDecoder().decode(
            GlobalShortcut.self,
            from: Data(#"{"key":"d","modifiers":["command"]}"#.utf8)
        )
        let current = GlobalShortcut(key: "d", modifiers: [.command])

        XCTAssertEqual(legacy, current)
    }

    func testLegacyShortcutEqualityUsesANSIPhysicalKeyForNonANSICurrentShortcuts() throws {
        let legacy = try JSONDecoder().decode(
            GlobalShortcut.self,
            from: Data(#"{"key":"q","modifiers":["command"]}"#.utf8)
        )
        let azertyPhysicalQ = try XCTUnwrap(
            GlobalShortcut.from(
                keyCode: UInt16(kVK_ANSI_Q),
                modifierFlags: [.command],
                charactersIgnoringModifiers: "a"
            )
        )
        let azertyPhysicalA = try XCTUnwrap(
            GlobalShortcut.from(
                keyCode: UInt16(kVK_ANSI_A),
                modifierFlags: [.command],
                charactersIgnoringModifiers: "q"
            )
        )
        let samePhysicalKeyWithDifferentLabel = GlobalShortcut(
            key: "q",
            modifiers: [.command],
            keyCode: UInt16(kVK_ANSI_Q)
        )

        XCTAssertEqual(legacy, azertyPhysicalQ)
        XCTAssertEqual(azertyPhysicalQ, legacy)
        XCTAssertEqual(azertyPhysicalQ, samePhysicalKeyWithDifferentLabel)
        XCTAssertEqual(legacy, samePhysicalKeyWithDifferentLabel)
        XCTAssertNotEqual(legacy, azertyPhysicalA)
        XCTAssertNotEqual(azertyPhysicalA, legacy)
        XCTAssertEqual(
            legacy == azertyPhysicalQ,
            legacy.matches(keyCode: UInt16(kVK_ANSI_Q), modifierFlags: [.command])
        )
        XCTAssertEqual(
            legacy == azertyPhysicalA,
            legacy.matches(keyCode: UInt16(kVK_ANSI_A), modifierFlags: [.command])
        )
    }
}

@MainActor
final class KeyboardShortcutManagerTests: XCTestCase {
    private final class MonitorToken {}

    private final class PermissionProbe: @unchecked Sendable {
        var isGranted = false
    }

    func testLocalMonitorSwallowsMatchingShortcutEvent() throws {
        var capturedHandler: ((NSEvent) -> NSEvent?)?
        let manager = KeyboardShortcutManager(
            shortcut: GlobalShortcut(key: "d", modifiers: [.command, .option, .shift]),
            permissionChecker: { true },
            globalMonitorInstaller: { _ in MonitorToken() },
            localMonitorInstaller: { handler in
                capturedHandler = handler
                return MonitorToken()
            },
            monitorRemover: { _ in }
        )

        var triggerCount = 0
        manager.startMonitoring { triggerCount += 1 }

        let handler = try XCTUnwrap(capturedHandler)
        let matchingEvent = makeKeyDownEvent(keyCode: 2, modifierFlags: [.command, .option, .shift])
        let result = handler(matchingEvent)

        XCTAssertNil(result, "A matching shortcut event must be swallowed, not passed through")
        XCTAssertEqual(triggerCount, 1, "The shortcut callback must still fire")
    }

    func testLocalMonitorPassesThroughNonMatchingEvent() throws {
        var capturedHandler: ((NSEvent) -> NSEvent?)?
        let manager = KeyboardShortcutManager(
            shortcut: GlobalShortcut(key: "d", modifiers: [.command, .option, .shift]),
            permissionChecker: { true },
            globalMonitorInstaller: { _ in MonitorToken() },
            localMonitorInstaller: { handler in
                capturedHandler = handler
                return MonitorToken()
            },
            monitorRemover: { _ in }
        )

        var triggerCount = 0
        manager.startMonitoring { triggerCount += 1 }

        let handler = try XCTUnwrap(capturedHandler)
        let nonMatchingEvent = makeKeyDownEvent(keyCode: 0, modifierFlags: [.command])
        let result = handler(nonMatchingEvent)

        XCTAssertNotNil(result, "A non-matching event must pass through so other UI can use it")
        XCTAssertEqual(triggerCount, 0, "The shortcut callback must not fire")
    }

    func testRefreshPermissionRestartsMainShortcutMonitoringAfterPermissionIsGranted() {
        let permissionProbe = PermissionProbe()
        var globalMonitorInstallCount = 0
        var localMonitorInstallCount = 0

        let manager = KeyboardShortcutManager(
            permissionChecker: { @MainActor @Sendable in permissionProbe.isGranted },
            globalMonitorInstaller: { _ in
                globalMonitorInstallCount += 1
                return MonitorToken()
            },
            localMonitorInstaller: { _ in
                localMonitorInstallCount += 1
                return MonitorToken()
            },
            monitorRemover: { _ in }
        )

        manager.startMonitoring {}
        XCTAssertFalse(manager.hasAccessibilityPermission)
        XCTAssertEqual(globalMonitorInstallCount, 0)
        XCTAssertEqual(localMonitorInstallCount, 0)

        permissionProbe.isGranted = true
        manager.refreshAccessibilityPermissionAndRestartIfNeeded()

        XCTAssertTrue(manager.hasAccessibilityPermission)
        XCTAssertEqual(globalMonitorInstallCount, 1)
        XCTAssertEqual(localMonitorInstallCount, 1)
    }

    func testRefreshPermissionRestartsPresetShortcutMonitoringAfterPermissionIsGranted() {
        let permissionProbe = PermissionProbe()
        var globalMonitorInstallCount = 0
        var localMonitorInstallCount = 0

        let manager = PresetShortcutManager(
            permissionChecker: { @MainActor @Sendable in permissionProbe.isGranted },
            globalMonitorInstaller: { _ in
                globalMonitorInstallCount += 1
                return MonitorToken()
            },
            localMonitorInstaller: { _ in
                localMonitorInstallCount += 1
                return MonitorToken()
            },
            monitorRemover: { _ in }
        )
        let preset = BrightnessPreset(
            name: "Night",
            shortcut: GlobalShortcut(key: "1", modifiers: [.command, .option])
        )

        manager.updateShortcuts(from: [preset])
        XCTAssertEqual(globalMonitorInstallCount, 0)
        XCTAssertEqual(localMonitorInstallCount, 0)

        permissionProbe.isGranted = true
        manager.refreshAccessibilityPermissionAndRestartIfNeeded()

        XCTAssertEqual(globalMonitorInstallCount, 1)
        XCTAssertEqual(localMonitorInstallCount, 1)
    }

    func testPresetShortcutUpdateDoesNotRestartMonitorForUnchangedBindings() {
        var installCount = 0
        var removalCount = 0
        let manager = PresetShortcutManager(
            permissionChecker: { true },
            globalMonitorInstaller: { _ in
                installCount += 1
                return MonitorToken()
            },
            localMonitorInstaller: { _ in
                installCount += 1
                return MonitorToken()
            },
            monitorRemover: { _ in removalCount += 1 }
        )
        let preset = BrightnessPreset(
            name: "Night",
            shortcut: GlobalShortcut(key: "1", modifiers: [.command, .option])
        )

        manager.updateShortcuts(from: [preset])
        var renamedPreset = preset
        renamedPreset.name = "Evening"
        manager.updateShortcuts(from: [renamedPreset])

        XCTAssertEqual(installCount, 2)
        XCTAssertEqual(removalCount, 0)
    }

    func testPresetShortcutUpdateRestartsMonitorWhenBindingsAreReordered() {
        var installCount = 0
        var removalCount = 0
        let manager = PresetShortcutManager(
            permissionChecker: { true },
            globalMonitorInstaller: { _ in
                installCount += 1
                return MonitorToken()
            },
            localMonitorInstaller: { _ in
                installCount += 1
                return MonitorToken()
            },
            monitorRemover: { _ in removalCount += 1 }
        )
        let night = BrightnessPreset(
            name: "Night",
            shortcut: GlobalShortcut(key: "1", modifiers: [.command, .option])
        )
        let day = BrightnessPreset(
            name: "Day",
            shortcut: GlobalShortcut(key: "2", modifiers: [.command, .option])
        )

        manager.updateShortcuts(from: [night, day])
        manager.updateShortcuts(from: [day, night])

        XCTAssertEqual(installCount, 4)
        XCTAssertEqual(removalCount, 2)
    }

    func testPresetLocalMonitorSwallowsMatchingShortcutEvent() throws {
        var capturedHandler: ((NSEvent) -> NSEvent?)?
        let manager = PresetShortcutManager(
            permissionChecker: { true },
            globalMonitorInstaller: { _ in MonitorToken() },
            localMonitorInstaller: { handler in
                capturedHandler = handler
                return MonitorToken()
            },
            monitorRemover: { _ in }
        )
        let presetID = UUID()
        let preset = BrightnessPreset(
            id: presetID,
            name: "Night",
            shortcut: GlobalShortcut(key: "1", modifiers: [.command, .option])
        )

        var triggeredID: UUID?
        manager.onPresetTriggered = { triggeredID = $0 }
        manager.updateShortcuts(from: [preset])

        let handler = try XCTUnwrap(capturedHandler)
        let matchingEvent = makeKeyDownEvent(keyCode: UInt16(kVK_ANSI_1), modifierFlags: [.command, .option])
        let result = handler(matchingEvent)

        XCTAssertNil(result, "A matching preset shortcut event must be swallowed, not passed through")
        XCTAssertEqual(triggeredID, presetID)
    }

    func testPresetLocalMonitorPassesThroughNonMatchingEvent() throws {
        var capturedHandler: ((NSEvent) -> NSEvent?)?
        let manager = PresetShortcutManager(
            permissionChecker: { true },
            globalMonitorInstaller: { _ in MonitorToken() },
            localMonitorInstaller: { handler in
                capturedHandler = handler
                return MonitorToken()
            },
            monitorRemover: { _ in }
        )
        let preset = BrightnessPreset(
            name: "Night",
            shortcut: GlobalShortcut(key: "1", modifiers: [.command, .option])
        )

        var triggeredID: UUID?
        manager.onPresetTriggered = { triggeredID = $0 }
        manager.updateShortcuts(from: [preset])

        let handler = try XCTUnwrap(capturedHandler)
        let nonMatchingEvent = makeKeyDownEvent(keyCode: UInt16(kVK_ANSI_2), modifierFlags: [.command, .option])
        let result = handler(nonMatchingEvent)

        XCTAssertNotNil(result, "A non-matching event must pass through so other UI can use it")
        XCTAssertNil(triggeredID, "No preset should be triggered")
    }

    func testBothShortcutManagersSuppressActionsWhileRecording() throws {
        let recorderID = UUID()
        defer {
            ShortcutRecordingCoordinator.shared.setRecording(false, for: recorderID)
        }

        var mainHandler: ((NSEvent) -> NSEvent?)?
        let mainManager = KeyboardShortcutManager(
            shortcut: GlobalShortcut(key: "d", modifiers: [.command]),
            permissionChecker: { true },
            globalMonitorInstaller: { _ in MonitorToken() },
            localMonitorInstaller: { handler in
                mainHandler = handler
                return MonitorToken()
            },
            monitorRemover: { _ in }
        )
        var mainTriggerCount = 0
        mainManager.startMonitoring { mainTriggerCount += 1 }

        var presetHandler: ((NSEvent) -> NSEvent?)?
        let presetManager = PresetShortcutManager(
            permissionChecker: { true },
            globalMonitorInstaller: { _ in MonitorToken() },
            localMonitorInstaller: { handler in
                presetHandler = handler
                return MonitorToken()
            },
            monitorRemover: { _ in }
        )
        let presetID = UUID()
        var triggeredPresetID: UUID?
        presetManager.onPresetTriggered = { triggeredPresetID = $0 }
        presetManager.updateShortcuts(from: [
            BrightnessPreset(
                id: presetID,
                name: "Night",
                shortcut: GlobalShortcut(key: "d", modifiers: [.command])
            ),
        ])

        let event = makeKeyDownEvent(keyCode: UInt16(kVK_ANSI_D), modifierFlags: [.command])
        ShortcutRecordingCoordinator.shared.setRecording(true, for: recorderID)

        XCTAssertNotNil(try XCTUnwrap(mainHandler)(event))
        XCTAssertNotNil(try XCTUnwrap(presetHandler)(event))
        XCTAssertEqual(mainTriggerCount, 0)
        XCTAssertNil(triggeredPresetID)

        ShortcutRecordingCoordinator.shared.setRecording(false, for: recorderID)
        XCTAssertNil(try XCTUnwrap(mainHandler)(event))
        XCTAssertNil(try XCTUnwrap(presetHandler)(event))
        XCTAssertEqual(mainTriggerCount, 1)
        XCTAssertEqual(triggeredPresetID, presetID)
    }
}

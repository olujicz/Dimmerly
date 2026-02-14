//
//  KeyboardShortcutTests.swift
//  DimmerlyTests
//
//  Unit tests for GlobalShortcut functionality.
//  Tests shortcut creation, validation, and formatting.
//

import AppKit
@testable import Dimmerly
import XCTest

/// Tests for the GlobalShortcut model
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
        // Note: Carbon.HIToolbox key codes are used

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

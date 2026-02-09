//
//  KeyboardShortcut.swift
//  Dimmerly
//
//  Model representing a keyboard shortcut configuration.
//  Supports encoding/decoding for UserDefaults persistence.
//

import Foundation
import AppKit
import Carbon.HIToolbox

/// Represents a keyboard shortcut with key and modifier keys
struct KeyboardShortcut: Codable, Equatable {
    /// The primary key (e.g., "d", "s", "return")
    let key: String

    /// Modifier keys (e.g., "command", "option", "shift", "control")
    let modifiers: Set<String>

    /// The default keyboard shortcut: Cmd+Opt+Shift+D
    static let `default` = KeyboardShortcut(
        key: "d",
        modifiers: ["command", "option", "shift"]
    )

    /// A human-readable string representation of the shortcut (e.g., "⌘⌥⇧D")
    var displayString: String {
        var result = ""

        // Order matters for conventional display: Control, Option, Shift, Command
        if modifiers.contains("control") {
            result += "⌃"
        }
        if modifiers.contains("option") {
            result += "⌥"
        }
        if modifiers.contains("shift") {
            result += "⇧"
        }
        if modifiers.contains("command") {
            result += "⌘"
        }

        // Append the key (capitalized for display)
        result += key.uppercased()

        return result
    }

    /// Creates a keyboard shortcut from key code and modifier flags
    ///
    /// - Parameters:
    ///   - keyCode: The Carbon key code
    ///   - modifierFlags: The NSEvent.ModifierFlags
    /// - Returns: A KeyboardShortcut if the key code can be mapped to a character
    static func from(keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags) -> KeyboardShortcut? {
        // Map common key codes to their string representations
        let keyString: String

        switch Int(keyCode) {
        case kVK_ANSI_A: keyString = "a"
        case kVK_ANSI_B: keyString = "b"
        case kVK_ANSI_C: keyString = "c"
        case kVK_ANSI_D: keyString = "d"
        case kVK_ANSI_E: keyString = "e"
        case kVK_ANSI_F: keyString = "f"
        case kVK_ANSI_G: keyString = "g"
        case kVK_ANSI_H: keyString = "h"
        case kVK_ANSI_I: keyString = "i"
        case kVK_ANSI_J: keyString = "j"
        case kVK_ANSI_K: keyString = "k"
        case kVK_ANSI_L: keyString = "l"
        case kVK_ANSI_M: keyString = "m"
        case kVK_ANSI_N: keyString = "n"
        case kVK_ANSI_O: keyString = "o"
        case kVK_ANSI_P: keyString = "p"
        case kVK_ANSI_Q: keyString = "q"
        case kVK_ANSI_R: keyString = "r"
        case kVK_ANSI_S: keyString = "s"
        case kVK_ANSI_T: keyString = "t"
        case kVK_ANSI_U: keyString = "u"
        case kVK_ANSI_V: keyString = "v"
        case kVK_ANSI_W: keyString = "w"
        case kVK_ANSI_X: keyString = "x"
        case kVK_ANSI_Y: keyString = "y"
        case kVK_ANSI_Z: keyString = "z"
        case kVK_ANSI_0: keyString = "0"
        case kVK_ANSI_1: keyString = "1"
        case kVK_ANSI_2: keyString = "2"
        case kVK_ANSI_3: keyString = "3"
        case kVK_ANSI_4: keyString = "4"
        case kVK_ANSI_5: keyString = "5"
        case kVK_ANSI_6: keyString = "6"
        case kVK_ANSI_7: keyString = "7"
        case kVK_ANSI_8: keyString = "8"
        case kVK_ANSI_9: keyString = "9"
        case kVK_Return: keyString = "return"
        case kVK_Space: keyString = "space"
        case kVK_Escape: keyString = "escape"
        default:
            return nil // Unsupported key code
        }

        // Extract modifier flags
        var modifiers: Set<String> = []
        if modifierFlags.contains(.command) {
            modifiers.insert("command")
        }
        if modifierFlags.contains(.option) {
            modifiers.insert("option")
        }
        if modifierFlags.contains(.shift) {
            modifiers.insert("shift")
        }
        if modifierFlags.contains(.control) {
            modifiers.insert("control")
        }

        return KeyboardShortcut(key: keyString, modifiers: modifiers)
    }

    /// Checks if this shortcut matches the given NSEvent
    ///
    /// - Parameter event: The keyboard event to check
    /// - Returns: true if the event matches this shortcut
    func matches(event: NSEvent) -> Bool {
        guard let shortcut = KeyboardShortcut.from(keyCode: event.keyCode, modifierFlags: event.modifierFlags) else {
            return false
        }
        return self == shortcut
    }

    /// Validates that the shortcut has at least one modifier
    /// (shortcuts without modifiers are generally not recommended as global shortcuts)
    var isValid: Bool {
        return !modifiers.isEmpty
    }
}

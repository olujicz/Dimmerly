//
//  KeyboardShortcut.swift
//  Dimmerly
//
//  Model representing a keyboard shortcut configuration.
//  Supports encoding/decoding for UserDefaults persistence.
//

import Foundation
#if !WIDGET_EXTENSION
import AppKit
import Carbon.HIToolbox
#endif

/// Modifier keys for keyboard shortcuts
enum ShortcutModifier: String, Codable, Hashable, Sendable {
    case command
    case option
    case shift
    case control
}

/// Represents a keyboard shortcut with key and modifier keys
struct GlobalShortcut: Codable, Equatable, Sendable {
    /// The primary key (e.g., "d", "s", "return")
    let key: String

    /// Modifier keys (e.g., .command, .option, .shift, .control)
    let modifiers: Set<ShortcutModifier>

    /// The default keyboard shortcut: Cmd+Opt+Shift+D
    static let `default` = GlobalShortcut(
        key: "d",
        modifiers: [.command, .option, .shift]
    )

    #if !WIDGET_EXTENSION
    /// Mapping from Carbon key codes to string representations
    private static let keyCodeMap: [Int: String] = [
        kVK_ANSI_A: "a", kVK_ANSI_B: "b", kVK_ANSI_C: "c", kVK_ANSI_D: "d",
        kVK_ANSI_E: "e", kVK_ANSI_F: "f", kVK_ANSI_G: "g", kVK_ANSI_H: "h",
        kVK_ANSI_I: "i", kVK_ANSI_J: "j", kVK_ANSI_K: "k", kVK_ANSI_L: "l",
        kVK_ANSI_M: "m", kVK_ANSI_N: "n", kVK_ANSI_O: "o", kVK_ANSI_P: "p",
        kVK_ANSI_Q: "q", kVK_ANSI_R: "r", kVK_ANSI_S: "s", kVK_ANSI_T: "t",
        kVK_ANSI_U: "u", kVK_ANSI_V: "v", kVK_ANSI_W: "w", kVK_ANSI_X: "x",
        kVK_ANSI_Y: "y", kVK_ANSI_Z: "z",
        kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3",
        kVK_ANSI_4: "4", kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7",
        kVK_ANSI_8: "8", kVK_ANSI_9: "9",
        kVK_Return: "return", kVK_Space: "space", kVK_Escape: "escape",
        kVK_F1: "f1", kVK_F2: "f2", kVK_F3: "f3", kVK_F4: "f4",
        kVK_F5: "f5", kVK_F6: "f6", kVK_F7: "f7", kVK_F8: "f8",
        kVK_F9: "f9", kVK_F10: "f10", kVK_F11: "f11", kVK_F12: "f12",
    ]
    #endif

    /// A human-readable string representation of the shortcut (e.g., "⌘⌥⇧D")
    var displayString: String {
        var result = ""

        // Order matters for conventional display: Control, Option, Shift, Command
        if modifiers.contains(.control) {
            result += "⌃"
        }
        if modifiers.contains(.option) {
            result += "⌥"
        }
        if modifiers.contains(.shift) {
            result += "⇧"
        }
        if modifiers.contains(.command) {
            result += "⌘"
        }

        // Append the key (capitalized for display)
        result += key.uppercased()

        return result
    }

    #if !WIDGET_EXTENSION
    /// Creates a keyboard shortcut from key code and modifier flags
    ///
    /// - Parameters:
    ///   - keyCode: The Carbon key code
    ///   - modifierFlags: The NSEvent.ModifierFlags
    /// - Returns: A GlobalShortcut if the key code can be mapped to a character
    static func from(keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags) -> GlobalShortcut? {
        guard let keyString = keyCodeMap[Int(keyCode)] else {
            return nil
        }

        // Extract modifier flags
        var modifiers: Set<ShortcutModifier> = []
        if modifierFlags.contains(.command) {
            modifiers.insert(.command)
        }
        if modifierFlags.contains(.option) {
            modifiers.insert(.option)
        }
        if modifierFlags.contains(.shift) {
            modifiers.insert(.shift)
        }
        if modifierFlags.contains(.control) {
            modifiers.insert(.control)
        }

        return GlobalShortcut(key: keyString, modifiers: modifiers)
    }

    /// Checks if this shortcut matches the given NSEvent
    ///
    /// - Parameter event: The keyboard event to check
    /// - Returns: true if the event matches this shortcut
    func matches(event: NSEvent) -> Bool {
        guard let shortcut = GlobalShortcut.from(keyCode: event.keyCode, modifierFlags: event.modifierFlags) else {
            return false
        }
        return self == shortcut
    }
    #endif

    /// Validates that the shortcut has at least one modifier
    /// (shortcuts without modifiers are generally not recommended as global shortcuts)
    var isValid: Bool {
        return !modifiers.isEmpty
    }

    /// Checks if this shortcut conflicts with a standard macOS system shortcut
    var isReservedSystemShortcut: Bool {
        let reserved: [(key: String, modifiers: Set<ShortcutModifier>)] = [
            // Editing
            ("c", [.command]), ("v", [.command]), ("x", [.command]),
            ("z", [.command]), ("a", [.command]), ("z", [.command, .shift]),
            // File operations
            ("n", [.command]), ("o", [.command]), ("s", [.command]),
            ("p", [.command]), ("w", [.command]),
            // App lifecycle
            ("q", [.command]), ("h", [.command]), ("m", [.command]),
            (",", [.command]),
            // Find
            ("f", [.command]), ("g", [.command]),
            // System-wide
            ("tab", [.command]), ("space", [.command]),
        ]

        return reserved.contains { $0.key == self.key && $0.modifiers == self.modifiers }
    }
}

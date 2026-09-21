//
//  KeyboardShortcut.swift
//  Dimmerly
//
//  Model representing a global keyboard shortcut configuration.
//  Supports encoding/decoding for UserDefaults persistence and widget compatibility.
//
//  ANSI key codes: Uses a stable numeric mapping shared by the app and widget targets.
//  Widget extension: Conditional compilation excludes AppKit in the widget target.
//

import Foundation
#if !WIDGET_EXTENSION
    import AppKit
#endif

/// Modifier keys for keyboard shortcuts (⌘⌥⇧⌃).
///
/// Design: Stored as enum instead of flags/bitmask for:
/// - Clean Codable support (no custom encoding needed)
/// - Type-safe Set operations
/// - Straightforward hashing and equality semantics
enum ShortcutModifier: String, Codable, Hashable {
    case command
    case option
    case shift
    case control
}

/// Represents a global keyboard shortcut with a key and modifier combination.
///
/// Design decisions:
/// - **Physical key semantics for newly recorded shortcuts**: Stores the ANSI key code so a
///   shortcut remains attached to the same physical key when the keyboard layout changes.
/// - **Layout-provided labels**: For layout-dependent printable keys, stores the event's
///   `charactersIgnoringModifiers` value as a readable label for US, AZERTY, and QWERTZ.
/// - **Legacy compatibility**: Older string-only values decode with a nil key code and continue
///   using the historical ANSI character mapping until the user records them again.
/// - **Set for modifiers**: Unordered set matches macOS behavior (Cmd+Opt = Opt+Cmd)
/// - **Codable**: Persists to UserDefaults as JSON
///
/// Validation:
/// - `isValid`: Requires at least one modifier (prevents bare keys like "d" as global shortcuts)
/// - `isReservedSystemShortcut`: Checks against common macOS system shortcuts
struct GlobalShortcut: Codable, Equatable {
    /// The primary key (e.g., "d", "s", "return", "f1").
    /// Lowercase for letters, semantic names for special keys.
    let key: String

    /// Modifier keys pressed with the key.
    /// Order doesn't matter (Set handles comparison correctly).
    let modifiers: Set<ShortcutModifier>

    /// Physical ANSI key code for shortcuts recorded by the current version. Nil means the
    /// value came from the legacy string-only Codable representation.
    let keyCode: UInt16?

    /// The default keyboard shortcut: Cmd+Opt+Shift+D.
    /// Three modifiers reduce conflicts with system and app shortcuts.
    static let `default` = GlobalShortcut(
        key: "d",
        modifiers: [.command, .option, .shift]
    )

    /// Stable historical ANSI key codes shared by the app and widget targets.
    private static let legacyKeyCodeMap: [String: UInt16] = [
        "a": 0, "b": 11, "c": 8, "d": 2,
        "e": 14, "f": 3, "g": 5, "h": 4,
        "i": 34, "j": 38, "k": 40, "l": 37,
        "m": 46, "n": 45, "o": 31, "p": 35,
        "q": 12, "r": 15, "s": 1, "t": 17,
        "u": 32, "v": 9, "w": 13, "x": 7,
        "y": 16, "z": 6,
        "0": 29, "1": 18, "2": 19, "3": 20,
        "4": 21, "5": 23, "6": 22, "7": 26,
        "8": 28, "9": 25,
        "return": 36, "space": 49, "escape": 53,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118,
        "f5": 96, "f6": 97, "f7": 98, "f8": 100,
        "f9": 101, "f10": 109, "f11": 103, "f12": 111,
    ]

    /// Reverse of `legacyKeyCodeMap`. The key codes are distinct, so this is a faithful inverse.
    private static let legacyKeyByCode: [UInt16: String] =
        Dictionary(uniqueKeysWithValues: legacyKeyCodeMap.map { ($0.value, $0.key) })

    init(key: String, modifiers: Set<ShortcutModifier>, keyCode: UInt16? = nil) {
        self.key = key
        self.modifiers = modifiers
        self.keyCode = keyCode ?? Self.legacyKeyCodeMap[key]
    }

    private init(legacyKey key: String, modifiers: Set<ShortcutModifier>, keyCode: UInt16?) {
        self.key = key
        self.modifiers = modifiers
        self.keyCode = keyCode
    }

    /// Canonical physical ANSI key identity for equality and conflict detection.
    private var physicalKeyCode: UInt16? {
        if let keyCode {
            return keyCode
        }
        return Self.legacyKeyCodeMap[key]
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        guard lhs.modifiers == rhs.modifiers else { return false }
        // A physical code on either side wins, so a coded shortcut never equals a label-only one.
        if lhs.physicalKeyCode != nil || rhs.physicalKeyCode != nil {
            return lhs.physicalKeyCode == rhs.physicalKeyCode
        }
        return lhs.key == rhs.key
    }

    private enum CodingKeys: String, CodingKey {
        case key
        case modifiers
        case keyCode
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            legacyKey: container.decode(String.self, forKey: .key),
            modifiers: container.decode(Set<ShortcutModifier>.self, forKey: .modifiers),
            keyCode: container.decodeIfPresent(UInt16.self, forKey: .keyCode)
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(key, forKey: .key)
        try container.encode(modifiers, forKey: .modifiers)
        try container.encodeIfPresent(keyCode, forKey: .keyCode)
    }

    /// A human-readable string representation of the shortcut (e.g., "⌘⌥⇧D").
    ///
    /// Format: Modifier symbols followed by uppercase key
    /// - Control: ⌃
    /// - Option: ⌥
    /// - Shift: ⇧
    /// - Command: ⌘
    ///
    /// Modifier order: Follows Apple Human Interface Guidelines convention:
    /// Control → Option → Shift → Command (left to right)
    /// This is the standard order used in macOS menus and system preferences.
    var displayString: String {
        var result = ""

        // Apple HIG convention: Control, Option, Shift, Command
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

        // Append the key (capitalized for visual consistency)
        result += key.uppercased()

        return result
    }

    #if !WIDGET_EXTENSION
        /// Creates a keyboard shortcut from key code and modifier flags
        ///
        /// - Parameters:
        ///   - keyCode: The ANSI physical key code
        ///   - modifierFlags: The NSEvent.ModifierFlags
        /// - Returns: A GlobalShortcut if the key code can be mapped to a character
        static func from(
            keyCode: UInt16,
            modifierFlags: NSEvent.ModifierFlags,
            charactersIgnoringModifiers: String? = nil
        ) -> GlobalShortcut? {
            guard let keyString = legacyKeyByCode[keyCode] else { return nil }

            let keyLabel = Self.layoutDependentLabel(
                for: keyString,
                charactersIgnoringModifiers: charactersIgnoringModifiers
            )
            return GlobalShortcut(
                key: keyLabel,
                modifiers: Self.modifiers(from: modifierFlags),
                keyCode: keyCode
            )
        }

        /// Matches a raw event using the canonical physical ANSI key code.
        func matches(
            keyCode pressedKeyCode: UInt16,
            modifierFlags: NSEvent.ModifierFlags
        ) -> Bool {
            guard physicalKeyCode == pressedKeyCode else { return false }
            return modifiers == Self.modifiers(from: modifierFlags)
        }

        /// Checks if this shortcut matches the given NSEvent
        ///
        /// - Parameter event: The keyboard event to check
        /// - Returns: true if the event matches this shortcut
        func matches(event: NSEvent) -> Bool {
            matches(
                keyCode: event.keyCode,
                modifierFlags: event.modifierFlags
            )
        }

        private static func layoutDependentLabel(
            for keyString: String,
            charactersIgnoringModifiers: String?
        ) -> String {
            guard keyString.count == 1,
                  keyString.first?.isLetter == true,
                  let layoutLabel = charactersIgnoringModifiers?
                  .trimmingCharacters(in: .whitespacesAndNewlines)
                  .lowercased(),
                  !layoutLabel.isEmpty
            else {
                return keyString
            }
            return layoutLabel
        }

        private static func modifiers(from modifierFlags: NSEvent.ModifierFlags) -> Set<ShortcutModifier> {
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
            return modifiers
        }
    #endif

    /// Validates that the shortcut has at least one modifier
    /// (shortcuts without modifiers are generally not recommended as global shortcuts)
    var isValid: Bool {
        !modifiers.isEmpty
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

        return reserved.contains { $0.key == key && $0.modifiers == modifiers }
    }
}

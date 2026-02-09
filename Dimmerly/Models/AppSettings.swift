//
//  AppSettings.swift
//  Dimmerly
//
//  Application settings persisted to UserDefaults.
//  Observable for SwiftUI integration.
//

import Foundation
import SwiftUI

/// Application settings stored in UserDefaults
@MainActor
class AppSettings: ObservableObject {
    /// The configured keyboard shortcut for sleeping displays
    @AppStorage("dimmerlyKeyboardShortcut")
    private var shortcutData: Data = try! JSONEncoder().encode(KeyboardShortcut.default)

    /// Whether the app should launch automatically at login
    @AppStorage("dimmerlyLaunchAtLogin")
    var launchAtLogin: Bool = false

    /// The current keyboard shortcut
    var keyboardShortcut: KeyboardShortcut {
        get {
            guard let shortcut = try? JSONDecoder().decode(KeyboardShortcut.self, from: shortcutData) else {
                return .default
            }
            return shortcut
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else {
                return
            }
            shortcutData = data
            objectWillChange.send()
        }
    }

    /// Resets all settings to their default values
    func resetToDefaults() {
        keyboardShortcut = .default
        launchAtLogin = false
    }
}

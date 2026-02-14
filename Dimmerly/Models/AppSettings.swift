//
//  AppSettings.swift
//  Dimmerly
//
//  Application settings persisted to UserDefaults.
//  Observable for SwiftUI integration.
//

import Foundation
import SwiftUI

/// Available menu bar icon styles
enum MenuBarIconStyle: String, CaseIterable, Identifiable {
    case defaultIcon = "default"
    case monitor
    case moonFilled
    case moonOutline
    case sunMoon

    var id: String {
        rawValue
    }

    /// SF Symbol name, or nil for the custom asset
    var systemImageName: String? {
        switch self {
        case .defaultIcon: return nil
        case .monitor: return "display"
        case .moonFilled: return "moon.fill"
        case .moonOutline: return "moon"
        case .sunMoon: return "moon.haze"
        }
    }

    var displayName: LocalizedStringKey {
        switch self {
        case .defaultIcon: return "Default"
        case .monitor: return "Monitor"
        case .moonFilled: return "Moon (Filled)"
        case .moonOutline: return "Moon (Outline)"
        case .sunMoon: return "Moon & Haze"
        }
    }
}

/// Application settings stored in UserDefaults
@MainActor
class AppSettings: ObservableObject {
    static let shared = AppSettings()
    // Pre-encoded default shortcut data (avoids force-try at property init)
    // swiftlint:disable:next force_try
    private static let defaultShortcutData = try! JSONEncoder().encode(GlobalShortcut.default)

    /// The configured keyboard shortcut for sleeping displays
    @AppStorage("dimmerlyKeyboardShortcut")
    private var shortcutData: Data = AppSettings.defaultShortcutData

    /// Whether the app should launch automatically at login
    @AppStorage("dimmerlyLaunchAtLogin")
    var launchAtLogin: Bool = false

    /// Whether to blank screens instead of sleeping displays (prevents session lock)
    @AppStorage("dimmerlyPreventScreenLock")
    var preventScreenLock: Bool = false

    /// Whether to ignore mouse movement when screens are dimmed (only wake on click or keyboard)
    @AppStorage("dimmerlyIgnoreMouseMovement")
    var ignoreMouseMovement: Bool = false

    /// Selected menu bar icon style
    @AppStorage("dimmerlyMenuBarIcon")
    var menuBarIconRaw: String = MenuBarIconStyle.defaultIcon.rawValue

    /// Whether auto-dim after inactivity is enabled
    @AppStorage("dimmerlyIdleTimerEnabled")
    var idleTimerEnabled: Bool = false

    /// Minutes of inactivity before auto-dim triggers
    @AppStorage("dimmerlyIdleTimerMinutes")
    var idleTimerMinutes: Int = 5

    /// Whether to use a fade transition when dimming displays
    @AppStorage("dimmerlyFadeTransition")
    var fadeTransition: Bool = true

    /// Whether to require Escape key to dismiss blanking (instead of any input)
    @AppStorage("dimmerlyRequireEscapeToDismiss")
    var requireEscapeToDismiss: Bool = false

    /// Whether schedule-based auto-dimming is enabled
    @AppStorage("dimmerlyScheduleEnabled")
    var scheduleEnabled: Bool = false

    /// Computed property for the selected menu bar icon style
    var menuBarIcon: MenuBarIconStyle {
        get { MenuBarIconStyle(rawValue: menuBarIconRaw) ?? .defaultIcon }
        set {
            menuBarIconRaw = newValue.rawValue
            objectWillChange.send()
        }
    }

    /// The current keyboard shortcut
    var keyboardShortcut: GlobalShortcut {
        get {
            guard let shortcut = try? JSONDecoder().decode(GlobalShortcut.self, from: shortcutData) else {
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
        preventScreenLock = false
        ignoreMouseMovement = false
        menuBarIconRaw = MenuBarIconStyle.defaultIcon.rawValue
        idleTimerEnabled = false
        idleTimerMinutes = 5
        fadeTransition = true
        requireEscapeToDismiss = false
        scheduleEnabled = false
    }
}

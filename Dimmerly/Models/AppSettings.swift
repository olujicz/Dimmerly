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

    // MARK: - UserDefaults Keys

    /// Key constants for settings that are observed by external managers.
    /// These match the @AppStorage keys below and must be kept in sync.
    nonisolated static let scheduleEnabledKey = "dimmerlyScheduleEnabled"
    nonisolated static let autoColorTempEnabledKey = "dimmerlyAutoColorTempEnabled"

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
    @AppStorage(AppSettings.scheduleEnabledKey)
    var scheduleEnabled: Bool = false

    /// Whether automatic color temperature adjustment is enabled
    @AppStorage(AppSettings.autoColorTempEnabledKey)
    var autoColorTempEnabled: Bool = false

    /// Daytime color temperature in Kelvin (used when sun is up)
    @AppStorage("dimmerlyDayTemperature")
    var dayTemperature: Int = 6500

    /// Nighttime color temperature in Kelvin (used after sunset)
    @AppStorage("dimmerlyNightTemperature")
    var nightTemperature: Int = 2700

    /// Duration in minutes for sunrise/sunset color temperature transitions
    @AppStorage("dimmerlyColorTempTransitionMinutes")
    var colorTempTransitionMinutes: Int = 40

    #if !APPSTORE
        /// Whether DDC/CI hardware display control is enabled.
        /// When disabled, all displays use software-only gamma control.
        @AppStorage("dimmerlyDDCEnabled")
        var ddcEnabled: Bool = false

        /// The active DDC control mode (software, hardware, or combined).
        /// Only meaningful when ddcEnabled is true.
        @AppStorage("dimmerlyDDCControlMode")
        var ddcControlModeRaw: String = DDCControlMode.combined.rawValue

        /// How often to poll displays for hardware value changes (seconds).
        /// Longer intervals reduce I2C traffic but delay detecting OSD changes.
        @AppStorage("dimmerlyDDCPollingInterval")
        var ddcPollingInterval: Int = 5

        /// Minimum delay between DDC write operations (milliseconds).
        /// Higher values are safer for monitors with slow MCUs.
        @AppStorage("dimmerlyDDCWriteDelay")
        var ddcWriteDelay: Int = 50

        /// Computed property for the DDC control mode
        var ddcControlMode: DDCControlMode {
            get { DDCControlMode(rawValue: ddcControlModeRaw) ?? .combined }
            set {
                ddcControlModeRaw = newValue.rawValue
                objectWillChange.send()
            }
        }
    #endif

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
        autoColorTempEnabled = false
        dayTemperature = 6500
        nightTemperature = 2700
        colorTempTransitionMinutes = 40
        #if !APPSTORE
            ddcEnabled = false
            ddcControlModeRaw = DDCControlMode.combined.rawValue
            ddcPollingInterval = 5
            ddcWriteDelay = 50
        #endif
    }
}

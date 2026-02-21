//
//  AppSettings.swift
//  Dimmerly
//
//  Application settings persisted to UserDefaults.
//  Observable for SwiftUI integration.
//
//  Migration note: @AppStorage is incompatible with @Observable (it relies on
//  ObservableObject's objectWillChange). All properties are now plain stored
//  properties with didSet handlers that persist to UserDefaults.
//

import Foundation
import Observation
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
@Observable
class AppSettings {
    static let shared = AppSettings()

    // MARK: - UserDefaults Keys

    /// Key constants for settings that are observed by external managers.
    nonisolated static let scheduleEnabledKey = "dimmerlyScheduleEnabled"
    nonisolated static let autoColorTempEnabledKey = "dimmerlyAutoColorTempEnabled"

    // swiftlint:disable:next force_try
    private static let defaultShortcutData = try! JSONEncoder().encode(GlobalShortcut.default)

    private let defaults = UserDefaults.standard

    // MARK: - Settings Properties

    /// The configured keyboard shortcut data for sleeping displays
    private var shortcutData: Data {
        didSet { defaults.set(shortcutData, forKey: "dimmerlyKeyboardShortcut") }
    }

    /// Whether the app should launch automatically at login
    var launchAtLogin: Bool {
        didSet { defaults.set(launchAtLogin, forKey: "dimmerlyLaunchAtLogin") }
    }

    /// Whether to blank screens instead of sleeping displays (prevents session lock)
    var preventScreenLock: Bool {
        didSet { defaults.set(preventScreenLock, forKey: "dimmerlyPreventScreenLock") }
    }

    /// Whether to ignore mouse movement when screens are dimmed (only wake on click or keyboard)
    var ignoreMouseMovement: Bool {
        didSet { defaults.set(ignoreMouseMovement, forKey: "dimmerlyIgnoreMouseMovement") }
    }

    /// Selected menu bar icon style (raw string)
    var menuBarIconRaw: String {
        didSet { defaults.set(menuBarIconRaw, forKey: "dimmerlyMenuBarIcon") }
    }

    /// Whether auto-dim after inactivity is enabled
    var idleTimerEnabled: Bool {
        didSet { defaults.set(idleTimerEnabled, forKey: "dimmerlyIdleTimerEnabled") }
    }

    /// Minutes of inactivity before auto-dim triggers
    var idleTimerMinutes: Int {
        didSet { defaults.set(idleTimerMinutes, forKey: "dimmerlyIdleTimerMinutes") }
    }

    /// Whether to use a fade transition when dimming displays
    var fadeTransition: Bool {
        didSet { defaults.set(fadeTransition, forKey: "dimmerlyFadeTransition") }
    }

    /// Whether to require Escape key to dismiss blanking (instead of any input)
    var requireEscapeToDismiss: Bool {
        didSet { defaults.set(requireEscapeToDismiss, forKey: "dimmerlyRequireEscapeToDismiss") }
    }

    /// Whether schedule-based auto-dimming is enabled
    var scheduleEnabled: Bool {
        didSet { defaults.set(scheduleEnabled, forKey: Self.scheduleEnabledKey) }
    }

    /// Whether automatic color temperature adjustment is enabled
    var autoColorTempEnabled: Bool {
        didSet { defaults.set(autoColorTempEnabled, forKey: Self.autoColorTempEnabledKey) }
    }

    /// Daytime color temperature in Kelvin (used when sun is up)
    var dayTemperature: Int {
        didSet { defaults.set(dayTemperature, forKey: "dimmerlyDayTemperature") }
    }

    /// Nighttime color temperature in Kelvin (used after sunset)
    var nightTemperature: Int {
        didSet { defaults.set(nightTemperature, forKey: "dimmerlyNightTemperature") }
    }

    /// Duration in minutes for sunrise/sunset color temperature transitions
    var colorTempTransitionMinutes: Int {
        didSet { defaults.set(colorTempTransitionMinutes, forKey: "dimmerlyColorTempTransitionMinutes") }
    }

    #if !APPSTORE
        /// Whether DDC/CI hardware display control is enabled.
        /// When disabled, all displays use software-only gamma control.
        var ddcEnabled: Bool {
            didSet { defaults.set(ddcEnabled, forKey: "dimmerlyDDCEnabled") }
        }

        /// The active DDC control mode raw value (software, hardware, or combined).
        /// Only meaningful when ddcEnabled is true.
        var ddcControlModeRaw: String {
            didSet { defaults.set(ddcControlModeRaw, forKey: "dimmerlyDDCControlMode") }
        }

        /// How often to poll displays for hardware value changes (seconds).
        /// Longer intervals reduce I2C traffic but delay detecting OSD changes.
        var ddcPollingInterval: Int {
            didSet { defaults.set(ddcPollingInterval, forKey: "dimmerlyDDCPollingInterval") }
        }

        /// Minimum delay between DDC write operations (milliseconds).
        /// Higher values are safer for monitors with slow MCUs.
        var ddcWriteDelay: Int {
            didSet { defaults.set(ddcWriteDelay, forKey: "dimmerlyDDCWriteDelay") }
        }

        /// Computed property for the DDC control mode
        var ddcControlMode: DDCControlMode {
            get { DDCControlMode(rawValue: ddcControlModeRaw) ?? .combined }
            set { ddcControlModeRaw = newValue.rawValue }
        }
    #endif

    // MARK: - Computed Properties

    /// Computed property for the selected menu bar icon style
    var menuBarIcon: MenuBarIconStyle {
        get { MenuBarIconStyle(rawValue: menuBarIconRaw) ?? .defaultIcon }
        set { menuBarIconRaw = newValue.rawValue }
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
        }
    }

    // MARK: - Initialization

    init() {
        let d = UserDefaults.standard

        // Load shortcut data (Data type needs special handling)
        shortcutData = d.data(forKey: "dimmerlyKeyboardShortcut") ?? Self.defaultShortcutData

        // Bool properties (UserDefaults.bool returns false for missing keys, matching @AppStorage defaults)
        launchAtLogin = d.bool(forKey: "dimmerlyLaunchAtLogin")
        preventScreenLock = d.bool(forKey: "dimmerlyPreventScreenLock")
        ignoreMouseMovement = d.bool(forKey: "dimmerlyIgnoreMouseMovement")
        idleTimerEnabled = d.bool(forKey: "dimmerlyIdleTimerEnabled")
        fadeTransition = d.object(forKey: "dimmerlyFadeTransition") != nil
            ? d.bool(forKey: "dimmerlyFadeTransition") : true
        requireEscapeToDismiss = d.bool(forKey: "dimmerlyRequireEscapeToDismiss")
        scheduleEnabled = d.bool(forKey: Self.scheduleEnabledKey)
        autoColorTempEnabled = d.bool(forKey: Self.autoColorTempEnabledKey)

        // String properties
        menuBarIconRaw = d.string(forKey: "dimmerlyMenuBarIcon") ?? MenuBarIconStyle.defaultIcon.rawValue

        // Int properties (need default value handling since UserDefaults.integer returns 0 for missing)
        idleTimerMinutes = d.object(forKey: "dimmerlyIdleTimerMinutes") != nil
            ? d.integer(forKey: "dimmerlyIdleTimerMinutes") : 5
        dayTemperature = d.object(forKey: "dimmerlyDayTemperature") != nil
            ? d.integer(forKey: "dimmerlyDayTemperature") : 6500
        nightTemperature = d.object(forKey: "dimmerlyNightTemperature") != nil
            ? d.integer(forKey: "dimmerlyNightTemperature") : 2700
        colorTempTransitionMinutes = d.object(forKey: "dimmerlyColorTempTransitionMinutes") != nil
            ? d.integer(forKey: "dimmerlyColorTempTransitionMinutes") : 40

        #if !APPSTORE
            ddcEnabled = d.bool(forKey: "dimmerlyDDCEnabled")
            ddcControlModeRaw = d.string(forKey: "dimmerlyDDCControlMode") ?? DDCControlMode.combined.rawValue
            ddcPollingInterval = d.object(forKey: "dimmerlyDDCPollingInterval") != nil
                ? d.integer(forKey: "dimmerlyDDCPollingInterval") : 5
            ddcWriteDelay = d.object(forKey: "dimmerlyDDCWriteDelay") != nil
                ? d.integer(forKey: "dimmerlyDDCWriteDelay") : 50
        #endif
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

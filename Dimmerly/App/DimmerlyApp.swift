//
//  DimmerlyApp.swift
//  Dimmerly
//
//  Main application entry point.
//  Provides menu bar interface and settings window.
//

import AppKit
import SwiftUI

@main
struct DimmerlyApp: App {
    /// Application settings shared across all views
    @StateObject private var settings = AppSettings.shared

    /// Manager for global keyboard shortcuts
    @StateObject private var shortcutManager = KeyboardShortcutManager()

    /// Manager for external display brightness
    @StateObject private var brightnessManager = BrightnessManager.shared

    /// Manager for brightness presets
    @StateObject private var presetManager = PresetManager.shared

    /// Manager for idle timer auto-dim
    @StateObject private var idleTimerManager = IdleTimerManager()

    /// Manager for preset keyboard shortcuts
    @StateObject private var presetShortcutManager = PresetShortcutManager()

    /// Provider for location data (solar calculations)
    @StateObject private var locationProvider = LocationProvider.shared

    /// Manager for time-based dimming schedules
    @StateObject private var scheduleManager = ScheduleManager()

    /// Manager for automatic color temperature adjustment
    @StateObject private var colorTempManager = ColorTemperatureManager.shared

    /// Guard against duplicate observer registration if onAppear fires more than once
    @State private var isConfigured = false

    var body: some Scene {
        // Menu bar extra (the main interface) — window style for slider support
        MenuBarExtra {
            MenuBarPanel()
                .environmentObject(settings)
                .environmentObject(brightnessManager)
                .environmentObject(presetManager)
                .environmentObject(colorTempManager)
        } label: {
            menuBarLabel
                .onAppear {
                    guard !isConfigured else { return }
                    isConfigured = true
                    // Load saved shortcut before starting monitoring (Issue 1)
                    shortcutManager.updateShortcut(settings.keyboardShortcut)
                    startGlobalShortcutMonitoring()
                    configureIdleTimer()
                    configurePresetShortcuts()
                    configureScheduleManager()
                    configureColorTemperature()
                    observeWidgetNotifications()
                }
        }
        .menuBarExtraStyle(.window)

        // Settings window
        Settings {
            SettingsView()
                .environmentObject(settings)
                .environmentObject(shortcutManager)
                .environmentObject(presetManager)
                .environmentObject(brightnessManager)
                .environmentObject(scheduleManager)
                .environmentObject(locationProvider)
                .environmentObject(colorTempManager)
        }
    }

    /// Menu bar icon view that adapts to the user's selected icon style.
    ///
    /// Displays either an SF Symbol (for built-in styles) or a custom asset (for default style).
    @ViewBuilder
    private var menuBarLabel: some View {
        if let systemImage = settings.menuBarIcon.systemImageName {
            Image(systemName: systemImage)
                .accessibilityLabel("Dimmerly")
        } else {
            Image("MenuBarIcon")
                .accessibilityLabel("Dimmerly")
        }
    }

    /// Configures the global keyboard shortcut monitor to trigger display sleep.
    ///
    /// The shortcut is loaded from settings before monitoring starts (see Issue #1 fix).
    /// Requires accessibility permissions to function.
    private func startGlobalShortcutMonitoring() {
        shortcutManager.startMonitoring { [settings] in
            DisplayAction.performSleep(settings: settings)
        }
    }

    /// Configures the idle timer to automatically sleep displays after inactivity.
    ///
    /// Sets up:
    /// 1. Callback for when idle threshold is reached
    /// 2. Settings observation to start/stop timer and update timeout value
    ///
    /// Design pattern: Passes closures to read settings rather than injecting AppSettings
    /// directly, reducing coupling and making the manager more testable.
    private func configureIdleTimer() {
        idleTimerManager.onIdleThresholdReached = { [settings] in
            DisplayAction.performSleep(settings: settings)
        }
        idleTimerManager.observeSettings(
            readEnabled: { AppSettings.shared.idleTimerEnabled },
            readMinutes: { AppSettings.shared.idleTimerMinutes }
        )
    }

    /// Observes distributed notifications from widgets to handle cross-process actions.
    ///
    /// Widgets run in a separate process (extension) and communicate with the main app via:
    /// - Distributed notifications (trigger actions)
    /// - Shared UserDefaults container (pass parameters)
    ///
    /// Two notification types:
    /// 1. **Dim notification**: Widget's "Sleep Displays" button was tapped
    /// 2. **Preset notification**: Widget's preset button was tapped (preset ID in shared defaults)
    ///
    /// Design note: Using DistributedNotificationCenter instead of Darwin notifications
    /// provides better type safety and automatic main queue dispatch.
    private func observeWidgetNotifications() {
        // Widget "Sleep Displays" button
        DistributedNotificationCenter.default().addObserver(
            forName: SharedConstants.dimNotification,
            object: nil, queue: .main
        ) { [settings] _ in
            Task { @MainActor in
                DisplayAction.performSleep(settings: settings)
            }
        }

        // Widget preset button (preset ID passed via shared defaults)
        DistributedNotificationCenter.default().addObserver(
            forName: SharedConstants.presetNotification,
            object: nil, queue: .main
        ) { [presetManager, brightnessManager] _ in
            Task { @MainActor in
                // Read preset ID from shared defaults (set by widget before posting notification)
                let defaults = SharedConstants.sharedDefaults
                guard let presetIDString = defaults?.string(
                    forKey: SharedConstants.widgetPresetCommandKey
                ),
                    let uuid = UUID(uuidString: presetIDString),
                    let preset = presetManager.presets.first(where: { $0.id == uuid })
                else {
                    return
                }
                presetManager.applyPreset(preset, to: brightnessManager, animated: true)
                // Clean up after processing (prevents applying same preset on next app launch)
                SharedConstants.sharedDefaults?.removeObject(forKey: SharedConstants.widgetPresetCommandKey)
            }
        }
    }

    /// Configures the schedule manager to automatically apply presets at scheduled times.
    ///
    /// Sets up:
    /// 1. Callback for when a schedule triggers (applies the referenced preset)
    /// 2. Settings observation to start/stop polling based on user preference
    private func configureScheduleManager() {
        scheduleManager.onScheduleTriggered = { [presetManager, brightnessManager] presetID in
            guard let preset = presetManager.presets.first(where: { $0.id == presetID }) else { return }
            presetManager.applyPreset(preset, to: brightnessManager, animated: true)
        }
        scheduleManager.observeSettings(
            readEnabled: { UserDefaults.standard.bool(forKey: AppSettings.scheduleEnabledKey) }
        )
    }

    /// Configures the color temperature manager to automatically adjust warmth at sunrise/sunset.
    ///
    /// Sets up settings observation to start/stop polling based on user preference.
    private func configureColorTemperature() {
        colorTempManager.observeSettings(
            readEnabled: { UserDefaults.standard.bool(forKey: AppSettings.autoColorTempEnabledKey) }
        )
    }

    /// Configures the preset shortcut manager to apply presets via global keyboard shortcuts.
    ///
    /// Sets up:
    /// 1. Callback for when a preset shortcut is triggered (applies that preset)
    /// 2. Preset observation to register/unregister shortcuts when presets change
    ///
    /// Each preset can have an optional keyboard shortcut that works globally (even when
    /// the app isn't focused). Requires accessibility permissions.
    private func configurePresetShortcuts() {
        presetShortcutManager.onPresetTriggered = { [presetManager, brightnessManager] presetID in
            guard let preset = presetManager.presets.first(where: { $0.id == presetID }) else { return }
            presetManager.applyPreset(preset, to: brightnessManager, animated: true)
        }
        presetShortcutManager.observePresets(
            readPresets: { PresetManager.shared.presets }
        )
    }
}

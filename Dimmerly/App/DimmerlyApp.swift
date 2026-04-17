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
    @State private var settings = AppSettings.shared

    /// Manager for global keyboard shortcuts
    @State private var shortcutManager = KeyboardShortcutManager()

    /// Manager for external display brightness
    @State private var brightnessManager = BrightnessManager.shared

    /// Manager for brightness presets
    @State private var presetManager = PresetManager.shared

    /// Manager for idle timer auto-dim (not @Observable — held for lifecycle only)
    @State private var idleTimerManager = IdleTimerManager()

    /// Manager for preset keyboard shortcuts (not @Observable — held for lifecycle only)
    @State private var presetShortcutManager = PresetShortcutManager()

    /// Provider for location data (solar calculations)
    @State private var locationProvider = LocationProvider.shared

    /// Manager for time-based dimming schedules
    @State private var scheduleManager = ScheduleManager()

    /// Manager for automatic color temperature adjustment
    @State private var colorTempManager = ColorTemperatureManager.shared

    #if !APPSTORE
        /// Manager for DDC/CI hardware display control (direct distribution only)
        @State private var hardwareManager = HardwareBrightnessManager.shared
    #endif

    /// Guard against duplicate observer registration if onAppear fires more than once
    @State private var isConfigured = false

    /// Distributed notification observer for widget "Sleep Displays" action
    @State private var widgetDimObserver: NSObjectProtocol?

    /// Distributed notification observer for widget preset application
    @State private var widgetPresetObserver: NSObjectProtocol?

    var body: some Scene {
        // Menu bar extra (the main interface) — window style for slider support
        MenuBarExtra {
            MenuBarPanel()
                .environment(settings)
                .environment(brightnessManager)
                .environment(presetManager)
                .environment(colorTempManager)
            #if !APPSTORE
                .environment(hardwareManager)
            #endif
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
                    // Initial sync for settings-driven managers. `.onChange` below
                    // keeps them current for subsequent edits without needing each
                    // manager to observe UserDefaults directly.
                    syncManagerStateFromSettings()
                    #if !APPSTORE
                        configureHardwareControl()
                    #endif
                }
                .onChange(of: settings.idleTimerEnabled) { _, _ in
                    idleTimerManager.apply(
                        enabled: settings.idleTimerEnabled,
                        thresholdMinutes: settings.idleTimerMinutes
                    )
                }
                .onChange(of: settings.idleTimerMinutes) { _, _ in
                    idleTimerManager.apply(
                        enabled: settings.idleTimerEnabled,
                        thresholdMinutes: settings.idleTimerMinutes
                    )
                }
                .onChange(of: settings.scheduleEnabled) { _, _ in
                    scheduleManager.apply(enabled: settings.scheduleEnabled)
                }
                .onChange(of: settings.autoColorTempEnabled) { _, _ in
                    colorTempManager.apply(enabled: settings.autoColorTempEnabled)
                }
                .onChange(of: presetManager.presets) { _, newValue in
                    presetShortcutManager.updateShortcuts(from: newValue)
                }
        }
        .menuBarExtraStyle(.window)

        // Settings window
        Settings {
            SettingsView()
                .environment(settings)
                .environment(shortcutManager)
                .environment(presetManager)
                .environment(brightnessManager)
                .environment(scheduleManager)
                .environment(locationProvider)
                .environment(colorTempManager)
            #if !APPSTORE
                .environment(hardwareManager)
            #endif
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

    /// Wires the idle-timer callback. Actual start/stop is driven by `.onChange(of:)`
    /// on `settings.idleTimerEnabled` / `.idleTimerMinutes` in the scene body, plus
    /// a one-time `syncManagerStateFromSettings()` at launch.
    private func configureIdleTimer() {
        idleTimerManager.onIdleThresholdReached = { [settings] in
            DisplayAction.performSleep(settings: settings)
        }
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
        widgetDimObserver = DistributedNotificationCenter.default().addObserver(
            forName: SharedConstants.dimNotification,
            object: nil, queue: .main
        ) { [settings] _ in
            Task { @MainActor in
                DisplayAction.performSleep(settings: settings)
            }
        }

        // Widget preset button (preset ID passed via shared defaults)
        widgetPresetObserver = DistributedNotificationCenter.default().addObserver(
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

    /// Wires the schedule-triggered callback. `.onChange` on `settings.scheduleEnabled`
    /// handles start/stop; the one-time sync in `syncManagerStateFromSettings` handles launch.
    private func configureScheduleManager() {
        scheduleManager.onScheduleTriggered = { [presetManager, brightnessManager] presetID in
            guard let preset = presetManager.presets.first(where: { $0.id == presetID }) else { return }
            presetManager.applyPreset(preset, to: brightnessManager, animated: true)
        }
    }

    /// Color-temperature start/stop is driven entirely by `.onChange` on
    /// `settings.autoColorTempEnabled` and the one-time sync at launch.
    private func configureColorTemperature() {
        // No wiring needed — manager is self-contained once enabled.
    }

    /// Wires the preset-shortcut-triggered callback. `.onChange` on `presetManager.presets`
    /// handles re-registration whenever presets/shortcuts change.
    private func configurePresetShortcuts() {
        presetShortcutManager.onPresetTriggered = { [presetManager, brightnessManager] presetID in
            guard let preset = presetManager.presets.first(where: { $0.id == presetID }) else { return }
            presetManager.applyPreset(preset, to: brightnessManager, animated: true)
        }
    }

    /// One-time sync of settings-driven managers at app launch.
    ///
    /// `.onChange` modifiers only fire when a value changes, so we need this initial pass
    /// to pick up whatever state was persisted from the previous session.
    private func syncManagerStateFromSettings() {
        idleTimerManager.apply(
            enabled: settings.idleTimerEnabled,
            thresholdMinutes: settings.idleTimerMinutes
        )
        scheduleManager.apply(enabled: settings.scheduleEnabled)
        colorTempManager.apply(enabled: settings.autoColorTempEnabled)
        presetShortcutManager.updateShortcuts(from: presetManager.presets)
    }

    // MARK: - Hardware Control (DDC/CI)

    #if !APPSTORE
        /// Configures DDC/CI hardware display control for the direct distribution build.
        ///
        /// Sets up:
        /// 1. Initial DDC probe if hardware control was previously enabled
        /// 2. Syncs control mode and polling interval from settings
        /// 3. Starts background polling for OSD-initiated hardware changes
        ///
        /// DDC requires IOKit access incompatible with the App Sandbox, so this
        /// method is only compiled in direct distribution builds.
        private func configureHardwareControl() {
            guard settings.ddcEnabled else { return }
            hardwareManager.isEnabled = true
            hardwareManager.controlMode = settings.ddcControlMode
            hardwareManager.pollingInterval = TimeInterval(settings.ddcPollingInterval)
            hardwareManager.probeAllDisplays()
            hardwareManager.startPolling()
        }
    #endif
}

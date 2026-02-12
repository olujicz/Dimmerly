//
//  DimmerlyApp.swift
//  Dimmerly
//
//  Main application entry point.
//  Provides menu bar interface and settings window.
//

import SwiftUI
import AppKit

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

    /// Guard against duplicate observer registration if onAppear fires more than once
    @State private var isConfigured = false

    var body: some Scene {
        // Menu bar extra (the main interface) — window style for slider support
        MenuBarExtra {
            MenuBarPanel()
                .environmentObject(settings)
                .environmentObject(brightnessManager)
                .environmentObject(presetManager)
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
        }
    }

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

    private func startGlobalShortcutMonitoring() {
        shortcutManager.startMonitoring { [settings] in
            DisplayAction.performSleep(settings: settings)
        }
    }

    private func configureIdleTimer() {
        idleTimerManager.onIdleThresholdReached = { [settings] in
            DisplayAction.performSleep(settings: settings)
        }
        idleTimerManager.observeSettings(
            readEnabled: { AppSettings.shared.idleTimerEnabled },
            readMinutes: { AppSettings.shared.idleTimerMinutes }
        )
    }

    private func observeWidgetNotifications() {
        DistributedNotificationCenter.default().addObserver(
            forName: SharedConstants.dimNotification,
            object: nil, queue: .main
        ) { [settings] _ in
            Task { @MainActor in
                DisplayAction.performSleep(settings: settings)
            }
        }

        DistributedNotificationCenter.default().addObserver(
            forName: SharedConstants.presetNotification,
            object: nil, queue: .main
        ) { [presetManager, brightnessManager] _ in
            Task { @MainActor in
                guard let presetIDString = SharedConstants.sharedDefaults?.string(forKey: SharedConstants.widgetPresetCommandKey),
                      let uuid = UUID(uuidString: presetIDString),
                      let preset = presetManager.presets.first(where: { $0.id == uuid }) else {
                    return
                }
                presetManager.applyPreset(preset, to: brightnessManager)
                SharedConstants.sharedDefaults?.removeObject(forKey: SharedConstants.widgetPresetCommandKey)
            }
        }
    }

    private func configureScheduleManager() {
        scheduleManager.onScheduleTriggered = { [presetManager, brightnessManager] presetID in
            guard let preset = presetManager.presets.first(where: { $0.id == presetID }) else { return }
            presetManager.applyPreset(preset, to: brightnessManager)
        }
        scheduleManager.observeSettings(
            readEnabled: { UserDefaults.standard.bool(forKey: "dimmerlyScheduleEnabled") }
        )
    }

    private func configurePresetShortcuts() {
        presetShortcutManager.onPresetTriggered = { [presetManager, brightnessManager] presetID in
            guard let preset = presetManager.presets.first(where: { $0.id == presetID }) else { return }
            presetManager.applyPreset(preset, to: brightnessManager)
        }
        presetShortcutManager.observePresets(
            readPresets: { PresetManager.shared.presets }
        )
    }
}

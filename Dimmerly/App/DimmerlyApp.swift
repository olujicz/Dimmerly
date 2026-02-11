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
        }
    }

    @ViewBuilder
    private var menuBarLabel: some View {
        if let systemImage = settings.menuBarIcon.systemImageName {
            Image(systemName: systemImage)
        } else {
            Image("MenuBarIcon")
        }
    }

    private func startGlobalShortcutMonitoring() {
        shortcutManager.startMonitoring { [settings] in
            performSleepDisplays(settings: settings)
        }
    }

    private func configureIdleTimer() {
        idleTimerManager.onIdleThresholdReached = { [settings] in
            performSleepDisplays(settings: settings)
        }
        if settings.idleTimerEnabled {
            idleTimerManager.start(thresholdMinutes: settings.idleTimerMinutes)
        }

        // Track last-known values to avoid redundant work on unrelated UserDefaults changes
        var lastEnabled = settings.idleTimerEnabled
        var lastMinutes = settings.idleTimerMinutes

        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak idleTimerManager] _ in
            Task { @MainActor in
                guard let idleTimerManager else { return }
                let settings = AppSettings.shared
                guard settings.idleTimerEnabled != lastEnabled || settings.idleTimerMinutes != lastMinutes else { return }
                lastEnabled = settings.idleTimerEnabled
                lastMinutes = settings.idleTimerMinutes
                if settings.idleTimerEnabled {
                    idleTimerManager.start(thresholdMinutes: settings.idleTimerMinutes)
                } else {
                    idleTimerManager.stop()
                }
            }
        }
    }

    private func configurePresetShortcuts() {
        presetShortcutManager.onPresetTriggered = { [presetManager, brightnessManager] presetID in
            guard let preset = presetManager.presets.first(where: { $0.id == presetID }) else { return }
            presetManager.applyPreset(preset, to: brightnessManager)
        }
        presetShortcutManager.updateShortcuts(from: presetManager.presets)

        // Track last-known presets to avoid redundant re-registration
        var lastPresetData = try? JSONEncoder().encode(PresetManager.shared.presets)

        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak presetShortcutManager] _ in
            Task { @MainActor in
                guard let presetShortcutManager else { return }
                let currentData = try? JSONEncoder().encode(PresetManager.shared.presets)
                guard currentData != lastPresetData else { return }
                lastPresetData = currentData
                presetShortcutManager.updateShortcuts(from: PresetManager.shared.presets)
            }
        }
    }
}

/// Shared sleep/blank logic used by both menu button and global shortcut
@MainActor
func performSleepDisplays(settings: AppSettings) {
    #if APPSTORE
    // Sandbox prevents spawning pmset — always use gamma-based screen blanking
    ScreenBlanker.shared.ignoreMouseMovement = settings.ignoreMouseMovement
    ScreenBlanker.shared.useFadeTransition = settings.fadeTransition
    ScreenBlanker.shared.blank()
    #else
    if settings.preventScreenLock {
        ScreenBlanker.shared.ignoreMouseMovement = settings.ignoreMouseMovement
        ScreenBlanker.shared.useFadeTransition = settings.fadeTransition
        ScreenBlanker.shared.blank()
    } else {
        Task {
            let result = await DisplayController.sleepDisplays()
            if case .failure(let error) = result {
                AlertPresenter.showError(error)
            }
        }
    }
    #endif
}

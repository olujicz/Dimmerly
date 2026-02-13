//
//  PresetShortcutManager.swift
//  Dimmerly
//
//  Monitors global keyboard events and triggers preset application
//  when a preset's assigned shortcut is pressed.
//

import Foundation
import AppKit

@MainActor
class PresetShortcutManager: ObservableObject {
    /// Callback when a preset shortcut is triggered
    var onPresetTriggered: ((UUID) -> Void)?

    /// Currently registered preset shortcuts
    private var presetShortcuts: [(id: UUID, shortcut: GlobalShortcut)] = []

    /// Global event monitor (active when app is not frontmost)
    private var globalEventMonitor: Any?
    /// Local event monitor (active when app is frontmost)
    private var localEventMonitor: Any?

    /// Tracking state for UserDefaults observation
    private var lastPresetData: Data?
    private var presetsObserver: NSObjectProtocol?

    /// Updates the registered shortcuts from current presets
    func updateShortcuts(from presets: [BrightnessPreset]) {
        presetShortcuts = presets.compactMap { preset in
            guard let shortcut = preset.shortcut else { return nil }
            return (id: preset.id, shortcut: shortcut)
        }

        // Restart monitoring if we have shortcuts
        if presetShortcuts.isEmpty {
            stopMonitoring()
        } else {
            startMonitoring()
        }
    }

    /// Begins observing preset changes and auto-updates shortcuts.
    ///
    /// - Parameter readPresets: Closure that returns the current list of presets
    func observePresets(readPresets: @escaping () -> [BrightnessPreset]) {
        let presets = readPresets()
        updateShortcuts(from: presets)
        lastPresetData = try? JSONEncoder().encode(presets)

        presetsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handlePresetsChange(readPresets: readPresets)
            }
        }
    }

    private func handlePresetsChange(readPresets: () -> [BrightnessPreset]) {
        let presets = readPresets()
        let currentData = try? JSONEncoder().encode(presets)
        guard currentData != lastPresetData else { return }
        lastPresetData = currentData
        updateShortcuts(from: presets)
    }

    private func startMonitoring() {
        stopMonitoring()

        guard KeyboardShortcutManager.checkAccessibilityPermission() else { return }

        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let keyCode = event.keyCode
            let modifierFlags = event.modifierFlags
            Task { @MainActor in
                self?.handleKeyEvent(keyCode: keyCode, modifierFlags: modifierFlags)
            }
        }

        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let keyCode = event.keyCode
            let modifierFlags = event.modifierFlags
            Task { @MainActor in
                self?.handleKeyEvent(keyCode: keyCode, modifierFlags: modifierFlags)
            }
            return event
        }
    }

    private func stopMonitoring() {
        if let monitor = globalEventMonitor {
            NSEvent.removeMonitor(monitor)
            globalEventMonitor = nil
        }
        if let monitor = localEventMonitor {
            NSEvent.removeMonitor(monitor)
            localEventMonitor = nil
        }
    }

    private func handleKeyEvent(keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags) {
        guard let pressed = GlobalShortcut.from(keyCode: keyCode, modifierFlags: modifierFlags) else { return }
        for (id, shortcut) in presetShortcuts {
            if shortcut == pressed {
                onPresetTriggered?(id)
                return
            }
        }
    }

    // deinit omitted to avoid @MainActor data race (Swift 6).
    // The manager is held by @StateObject for the app lifetime, so deinit is never reached.
}

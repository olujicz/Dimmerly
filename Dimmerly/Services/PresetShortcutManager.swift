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

    /// Global event monitor
    private var eventMonitor: Any?

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

    private func startMonitoring() {
        stopMonitoring()

        guard KeyboardShortcutManager.checkAccessibilityPermission() else { return }

        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            Task { @MainActor in
                self?.handleKeyEvent(event)
            }
        }
    }

    private func stopMonitoring() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }

    private func handleKeyEvent(_ event: NSEvent) {
        for (id, shortcut) in presetShortcuts {
            if shortcut.matches(event: event) {
                onPresetTriggered?(id)
                return
            }
        }
    }

    // deinit omitted to avoid @MainActor data race (Swift 6).
    // The manager is held by @StateObject for the app lifetime, so deinit is never reached.
    // Cleanup is handled by stopMonitoring().
}

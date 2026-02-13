//
//  PresetShortcutManager.swift
//  Dimmerly
//
//  Monitors global keyboard events for preset-specific shortcuts.
//  Each preset can have its own optional keyboard shortcut (e.g., Cmd+Opt+1, Cmd+Opt+2).
//
//  Differences from KeyboardShortcutManager:
//  - KeyboardShortcutManager: Single global shortcut for display sleep
//  - PresetShortcutManager: Multiple shortcuts, one per preset (up to 10)
//
//  Conflict detection: Currently no conflict detection between preset shortcuts.
//  Users can accidentally assign the same shortcut to multiple presets, in which case
//  the first matching preset in the array will be triggered.
//

import Foundation
import AppKit

/// Manages keyboard shortcuts for individual brightness presets.
///
/// This manager:
/// - Monitors all preset shortcuts simultaneously
/// - Updates automatically when presets change (add/remove/edit shortcuts)
/// - Stops monitoring when no presets have shortcuts assigned
/// - Requires accessibility permissions (same as KeyboardShortcutManager)
///
/// Change detection: Uses JSON encoding comparison to detect preset changes.
/// This catches all modifications: shortcut changes, preset deletion, reordering.
///
/// Thread safety: All methods must be called from the main actor.
@MainActor
class PresetShortcutManager: ObservableObject {
    /// Callback invoked when a preset shortcut is pressed (passes preset ID)
    var onPresetTriggered: ((UUID) -> Void)?

    /// Currently registered preset shortcuts (filtered from full preset list).
    /// Only includes presets that have a shortcut assigned.
    private var presetShortcuts: [(id: UUID, shortcut: GlobalShortcut)] = []

    /// Global event monitor (active when app is not frontmost)
    private var globalEventMonitor: Any?

    /// Local event monitor (active when app is frontmost)
    private var localEventMonitor: Any?

    /// Last known preset data (JSON) for change detection
    private var lastPresetData: Data?

    /// Notification observer for UserDefaults changes
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

    // MARK: - Lifecycle
    // Note: deinit intentionally omitted to avoid @MainActor data race warnings in Swift 6.
    // This manager is held by @StateObject in DimmerlyApp for the app's lifetime, so deinit
    // never executes. Cleanup is handled explicitly via stopMonitoring() when presets are empty.
}

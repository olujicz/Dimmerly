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
//  Shortcut uniqueness is enforced by PresetManager before this service receives bindings.
//

import AppKit
import Foundation
import Observation

#if !APPSTORE
    /// Manages keyboard shortcuts for individual brightness presets.
    ///
    /// This manager:
    /// - Monitors all preset shortcuts simultaneously
    /// - Updates automatically when presets change (add/remove/edit shortcuts)
    /// - Stops monitoring when no presets have shortcuts assigned
    /// - Requires accessibility permissions (same as KeyboardShortcutManager)
    ///
    /// Change detection: Compares the ordered (preset ID, shortcut) bindings, so shortcut
    /// changes, deletions, and reordering restart monitoring while unrelated edits do not.
    ///
    /// Thread safety: All methods must be called from the main actor.
    @MainActor
    @Observable
    class PresetShortcutManager {
        /// Callback invoked when a preset shortcut is pressed (passes preset ID)
        var onPresetTriggered: ((UUID) -> Void)?

        /// Owns the event monitors. Its bindings are the active (preset ID, shortcut) pairs in
        /// preset order, compared against incoming bindings so unrelated preset edits don't
        /// needlessly restart monitoring.
        private let monitor: NSEventShortcutMonitor

        init(monitor: NSEventShortcutMonitor = NSEventShortcutMonitor()) {
            self.monitor = monitor
            monitor.onTriggered = { [weak self] id in self?.onPresetTriggered?(id) }
        }

        /// Updates the registered shortcuts from the current preset list.
        func updateShortcuts(from presets: [BrightnessPreset]) {
            let bindings: [NSEventShortcutMonitor.Binding] = presets.compactMap { preset in
                guard let shortcut = preset.shortcut else { return nil }
                return .init(id: preset.id, shortcut: shortcut)
            }

            guard bindings != monitor.bindings else { return }
            monitor.bindings = bindings

            if bindings.isEmpty {
                monitor.stop()
            } else {
                monitor.start()
            }
        }

        /// Rechecks Accessibility permission and starts preset shortcut monitoring
        /// when permission was granted after the shortcut set was already registered, or stops
        /// it if permission was revoked. Called automatically on permission-change notifications.
        func refreshAccessibilityPermissionAndRestartIfNeeded() {
            monitor.refreshAccessibilityPermissionAndRestartIfNeeded()
        }

        // MARK: - Lifecycle

        // Note: deinit intentionally omitted to avoid @MainActor data race warnings in Swift 6.
        // This manager is owned by AppServices for the app's lifetime, so deinit
        // never executes. Cleanup is handled by stopping the monitor when presets are empty.
    }

#endif

#if APPSTORE
    /// Registers sandbox-safe Carbon hotkeys for presets with assigned shortcuts.
    @MainActor
    @Observable
    final class PresetShortcutManager {
        var onPresetTriggered: ((UUID) -> Void)?
        private let monitor: CarbonShortcutMonitor
        var hasInvalidShortcuts: Bool {
            monitor.hasInvalidShortcuts
        }

        var hasRegistrationFailure: Bool {
            !monitor.failedBindingIDs.isEmpty
        }

        init(monitor: CarbonShortcutMonitor = CarbonShortcutMonitor()) {
            self.monitor = monitor
            monitor.onTriggered = { [weak self] id in self?.onPresetTriggered?(id) }
        }

        func updateShortcuts(from presets: [BrightnessPreset]) {
            monitor.updateBindings(presets.compactMap { preset in
                guard let shortcut = preset.shortcut else { return nil }
                return .init(id: preset.id, shortcut: shortcut)
            })
        }

        func retryFailedRegistrations() {
            monitor.retryFailedRegistrations()
        }
    }
#endif

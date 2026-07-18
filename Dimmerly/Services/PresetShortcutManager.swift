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
@Observable
class PresetShortcutManager {
    typealias PermissionChecker = @MainActor () -> Bool
    typealias GlobalMonitorInstaller = @MainActor (@escaping (NSEvent) -> Void) -> Any?
    typealias LocalMonitorInstaller = @MainActor (@escaping (NSEvent) -> NSEvent?) -> Any?
    typealias MonitorRemover = @MainActor (Any) -> Void

    /// Callback invoked when a preset shortcut is pressed (passes preset ID)
    var onPresetTriggered: ((UUID) -> Void)?

    /// Currently registered preset shortcuts (filtered from full preset list).
    /// Only includes presets that have a shortcut assigned.
    private var presetShortcuts: [(id: UUID, shortcut: GlobalShortcut)] = []

    /// Global event monitor (active when app is not frontmost)
    private var globalEventMonitor: Any?

    /// Local event monitor (active when app is frontmost)
    private var localEventMonitor: Any?

    /// Representation of a (preset, shortcut) pair used to short-circuit identical
    /// updates so unrelated preset edits don't needlessly restart monitoring.
    /// Only Equatable is needed — arrays of Equatable elements are themselves Equatable.
    private struct ShortcutBinding: Equatable {
        let presetID: UUID
        let shortcut: GlobalShortcut
    }

    /// Cached signature of the last applied shortcut set.
    private var lastShortcutSignature: [ShortcutBinding] = []

    private let permissionChecker: PermissionChecker
    private let globalMonitorInstaller: GlobalMonitorInstaller
    private let localMonitorInstaller: LocalMonitorInstaller
    private let monitorRemover: MonitorRemover

    init(
        permissionChecker: @escaping PermissionChecker = KeyboardShortcutManager.checkAccessibilityPermission,
        globalMonitorInstaller: @escaping GlobalMonitorInstaller = { handler in
            NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: handler)
        },
        localMonitorInstaller: @escaping LocalMonitorInstaller = { handler in
            NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: handler)
        },
        monitorRemover: @escaping MonitorRemover = { monitor in
            NSEvent.removeMonitor(monitor)
        }
    ) {
        self.permissionChecker = permissionChecker
        self.globalMonitorInstaller = globalMonitorInstaller
        self.localMonitorInstaller = localMonitorInstaller
        self.monitorRemover = monitorRemover
    }

    /// Updates the registered shortcuts from the current preset list.
    func updateShortcuts(from presets: [BrightnessPreset]) {
        let bindings: [ShortcutBinding] = presets.compactMap { preset in
            guard let shortcut = preset.shortcut else { return nil }
            return ShortcutBinding(presetID: preset.id, shortcut: shortcut)
        }

        guard bindings != lastShortcutSignature else { return }
        lastShortcutSignature = bindings
        presetShortcuts = bindings.map { (id: $0.presetID, shortcut: $0.shortcut) }

        if presetShortcuts.isEmpty {
            stopMonitoring()
        } else {
            startMonitoring()
        }
    }

    private func startMonitoring() {
        stopMonitoring()

        guard permissionChecker() else { return }

        globalEventMonitor = globalMonitorInstaller { [weak self] event in
            let keyCode = event.keyCode
            let modifierFlags = event.modifierFlags
            Task { @MainActor in
                _ = self?.handleKeyEvent(keyCode: keyCode, modifierFlags: modifierFlags)
            }
        }

        // Matched events are swallowed (return nil) instead of always passing through —
        // otherwise a preset shortcut both applies the preset and reaches whatever UI
        // element has focus. The match check runs synchronously via
        // `MainActor.assumeIsolated`, since NSEvent local monitor callbacks always fire
        // on the main thread.
        localEventMonitor = localMonitorInstaller { [weak self] event in
            let keyCode = event.keyCode
            let modifierFlags = event.modifierFlags
            let matched = MainActor.assumeIsolated {
                self?.handleKeyEvent(keyCode: keyCode, modifierFlags: modifierFlags) ?? false
            }
            return matched ? nil : event
        }
    }

    private func stopMonitoring() {
        if let monitor = globalEventMonitor {
            monitorRemover(monitor)
            globalEventMonitor = nil
        }
        if let monitor = localEventMonitor {
            monitorRemover(monitor)
            localEventMonitor = nil
        }
    }

    /// Rechecks Accessibility permission and starts preset shortcut monitoring
    /// when permission was granted after the shortcut set was already registered.
    func refreshAccessibilityPermissionAndRestartIfNeeded() {
        guard permissionChecker() else {
            stopMonitoring()
            return
        }
        guard !presetShortcuts.isEmpty,
              globalEventMonitor == nil,
              localEventMonitor == nil
        else {
            return
        }
        startMonitoring()
    }

    /// - Returns: `true` if the event matched a registered preset shortcut (and the callback fired).
    @discardableResult
    private func handleKeyEvent(keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags) -> Bool {
        guard let pressed = GlobalShortcut.from(keyCode: keyCode, modifierFlags: modifierFlags) else { return false }
        for (id, shortcut) in presetShortcuts where shortcut == pressed {
            onPresetTriggered?(id)
            return true
        }
        return false
    }

    // MARK: - Lifecycle

    // Note: deinit intentionally omitted to avoid @MainActor data race warnings in Swift 6.
    // This manager is held by @StateObject in DimmerlyApp for the app's lifetime, so deinit
    // never executes. Cleanup is handled explicitly via stopMonitoring() when presets are empty.
}

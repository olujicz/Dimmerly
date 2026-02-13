//
//  KeyboardShortcutManager.swift
//  Dimmerly
//
//  Manager for global keyboard shortcut monitoring.
//  Requires accessibility permissions to function.
//

import Foundation
import AppKit

/// Manages global keyboard shortcuts for the application
@MainActor
class KeyboardShortcutManager: ObservableObject {
    /// The currently registered keyboard shortcut
    @Published var currentShortcut: GlobalShortcut

    /// Whether accessibility permissions have been granted
    @Published var hasAccessibilityPermission: Bool = false

    /// The global event monitor for keyboard events (active when app is not frontmost)
    private var globalEventMonitor: Any?
    /// The local event monitor for keyboard events (active when app is frontmost)
    private var localEventMonitor: Any?

    /// Callback to invoke when the shortcut is triggered
    private var onShortcutTriggered: (() -> Void)?

    /// Initializes the manager with a keyboard shortcut
    ///
    /// - Parameter shortcut: The keyboard shortcut to monitor
    init(shortcut: GlobalShortcut = .default) {
        self.currentShortcut = shortcut
        self.hasAccessibilityPermission = Self.checkAccessibilityPermission()
    }

    /// Checks if the app has accessibility permissions
    ///
    /// - Returns: true if permissions are granted
    static func checkAccessibilityPermission() -> Bool {
        return AXIsProcessTrusted()
    }

    /// Requests accessibility permissions from the user
    ///
    /// This will show the system dialog prompting the user to grant access
    static func requestAccessibilityPermission() {
        let options = ["AXTrustedCheckOptionPrompt": true]
        AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    /// Starts monitoring for the configured keyboard shortcut
    ///
    /// - Parameter onTriggered: Callback to invoke when the shortcut is pressed
    func startMonitoring(onTriggered: @escaping () -> Void) {
        self.onShortcutTriggered = onTriggered
        stopMonitoring()

        // Check for permissions (don't prompt — let the user enable via Settings)
        hasAccessibilityPermission = Self.checkAccessibilityPermission()

        if !hasAccessibilityPermission {
            return
        }

        // Global monitor for when another app is frontmost
        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let keyCode = event.keyCode
            let modifierFlags = event.modifierFlags
            Task { @MainActor in
                self?.handleKeyEvent(keyCode: keyCode, modifierFlags: modifierFlags)
            }
        }

        // Local monitor for when Dimmerly is frontmost
        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let keyCode = event.keyCode
            let modifierFlags = event.modifierFlags
            Task { @MainActor in
                self?.handleKeyEvent(keyCode: keyCode, modifierFlags: modifierFlags)
            }
            return event
        }
    }

    /// Stops monitoring for keyboard shortcuts
    func stopMonitoring() {
        if let monitor = globalEventMonitor {
            NSEvent.removeMonitor(monitor)
            globalEventMonitor = nil
        }
        if let monitor = localEventMonitor {
            NSEvent.removeMonitor(monitor)
            localEventMonitor = nil
        }
    }

    /// Updates the monitored keyboard shortcut
    ///
    /// This will restart monitoring with the new shortcut if monitoring is active
    ///
    /// - Parameter shortcut: The new keyboard shortcut to monitor
    func updateShortcut(_ shortcut: GlobalShortcut) {
        self.currentShortcut = shortcut

        // Restart monitoring if it was active
        if (globalEventMonitor != nil || localEventMonitor != nil),
            let callback = onShortcutTriggered {
            startMonitoring(onTriggered: callback)
        }
    }

    /// Handles incoming keyboard events and triggers the callback if they match the current shortcut.
    ///
    /// This method:
    /// 1. Constructs a GlobalShortcut from the raw key code and modifiers
    /// 2. Compares it to the currently registered shortcut
    /// 3. Invokes the callback if they match
    ///
    /// Design note: We reconstruct a shortcut from the event rather than directly comparing
    /// key codes and modifiers to ensure consistent comparison logic (GlobalShortcut's Equatable).
    ///
    /// - Parameters:
    ///   - keyCode: Raw keyboard key code from NSEvent
    ///   - modifierFlags: Modifier keys (⌘⌥⌃⇧) from NSEvent
    private func handleKeyEvent(keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags) {
        guard let shortcut = GlobalShortcut.from(keyCode: keyCode, modifierFlags: modifierFlags),
              currentShortcut == shortcut else {
            return
        }
        onShortcutTriggered?()
    }

    // MARK: - Lifecycle
    // Note: deinit intentionally omitted to avoid @MainActor data race warnings in Swift 6.
    // This manager is held by @StateObject in DimmerlyApp for the app's lifetime, so deinit
    // never executes. Cleanup is handled explicitly via stopMonitoring() when needed.
}

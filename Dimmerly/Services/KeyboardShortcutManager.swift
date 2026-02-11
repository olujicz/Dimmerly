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

    /// The global event monitor for keyboard events
    private var eventMonitor: Any?

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

        // Check for permissions (don't prompt — let the user enable via Settings)
        hasAccessibilityPermission = Self.checkAccessibilityPermission()

        if !hasAccessibilityPermission {
            return
        }

        // Stop existing monitor if any
        stopMonitoring()

        // Create a global event monitor for key down events
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            Task { @MainActor in
                guard let self else { return }
                if self.currentShortcut.matches(event: event) {
                    self.onShortcutTriggered?()
                }
            }
        }
    }

    /// Stops monitoring for keyboard shortcuts
    func stopMonitoring() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
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
        if eventMonitor != nil, let callback = onShortcutTriggered {
            startMonitoring(onTriggered: callback)
        }
    }

    /// Cleans up the event monitor.
    /// Called via stopMonitoring(); deinit omitted to avoid @MainActor data race (Swift 6).
    /// The manager is held by @StateObject for the app lifetime, so deinit is never reached.
}

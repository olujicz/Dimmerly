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
class KeyboardShortcutManager: ObservableObject {
    /// The currently registered keyboard shortcut
    @Published var currentShortcut: KeyboardShortcut

    /// Whether accessibility permissions have been granted
    @Published var hasAccessibilityPermission: Bool = false

    /// The global event monitor for keyboard events
    private var eventMonitor: Any?

    /// Callback to invoke when the shortcut is triggered
    private var onShortcutTriggered: (() -> Void)?

    /// Initializes the manager with a keyboard shortcut
    ///
    /// - Parameter shortcut: The keyboard shortcut to monitor
    init(shortcut: KeyboardShortcut = .default) {
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
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    /// Starts monitoring for the configured keyboard shortcut
    ///
    /// - Parameter onTriggered: Callback to invoke when the shortcut is pressed
    func startMonitoring(onTriggered: @escaping () -> Void) {
        self.onShortcutTriggered = onTriggered

        // Check for permissions
        hasAccessibilityPermission = Self.checkAccessibilityPermission()

        if !hasAccessibilityPermission {
            // Request permissions if not granted
            Self.requestAccessibilityPermission()
            return
        }

        // Stop existing monitor if any
        stopMonitoring()

        // Create a global event monitor for key down events
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return }

            // Check if the event matches our shortcut
            if self.currentShortcut.matches(event: event) {
                // Trigger the callback
                self.onShortcutTriggered?()
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
    func updateShortcut(_ shortcut: KeyboardShortcut) {
        self.currentShortcut = shortcut

        // Restart monitoring if it was active
        if eventMonitor != nil, let callback = onShortcutTriggered {
            startMonitoring(onTriggered: callback)
        }
    }

    /// Cleans up resources when the manager is deallocated
    deinit {
        stopMonitoring()
    }
}

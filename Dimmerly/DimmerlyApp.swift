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
    @StateObject private var settings = AppSettings()

    /// Manager for global keyboard shortcuts
    @StateObject private var shortcutManager = KeyboardShortcutManager()

    var body: some Scene {
        // Menu bar extra (the main interface)
        MenuBarExtra {
            MenuContent()
                .environmentObject(settings)
                .environmentObject(shortcutManager)
        } label: {
            Image(systemName: "moon.stars")
        }

        // Settings window
        Settings {
            SettingsView()
                .environmentObject(settings)
                .environmentObject(shortcutManager)
        }
    }

    init() {
        // Note: StateObject initialization happens automatically
        // We can perform additional setup in the initializer if needed
    }
}

/// The content of the menu bar dropdown
struct MenuContent: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var shortcutManager: KeyboardShortcutManager

    var body: some View {
        Button("Turn Displays Off") {
            handleSleepDisplays()
        }
        .keyboardShortcut("d", modifiers: [.command, .option, .shift])

        Divider()

        if #available(macOS 14.0, *) {
            SettingsLink {
                Text("Settings...")
            }
            .keyboardShortcut(",", modifiers: .command)
        } else {
            Button("Settings...") {
                NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
            }
            .keyboardShortcut(",", modifiers: .command)
        }

        Divider()

        Button("Quit Dimmerly") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: .command)
    }

    /// Handles the sleep displays action with error handling
    private func handleSleepDisplays() {
        let result = DisplayController.sleepDisplays()

        switch result {
        case .success:
            // Success - displays are sleeping
            break
        case .failure(let error):
            // Show error alert to user
            AlertPresenter.showError(error)
        }
    }

    /// Sets up the global keyboard shortcut monitoring
    private func setupKeyboardShortcut() {
        shortcutManager.startMonitoring {
            handleSleepDisplays()
        }
    }
}

#Preview {
    MenuContent()
        .environmentObject(AppSettings())
        .environmentObject(KeyboardShortcutManager())
}

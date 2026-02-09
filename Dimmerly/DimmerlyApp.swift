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
            Image("MenuBarIcon")
                .onAppear {
                    startGlobalShortcutMonitoring()
                }
        }

        // Settings window
        Settings {
            SettingsView()
                .environmentObject(settings)
                .environmentObject(shortcutManager)
        }
    }

    private func startGlobalShortcutMonitoring() {
        shortcutManager.startMonitoring { [settings] in
            if settings.preventScreenLock {
                ScreenBlanker.shared.blank()
            } else {
                let result = DisplayController.sleepDisplays()
                if case .failure(let error) = result {
                    AlertPresenter.showError(error)
                }
            }
        }
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
        .keyboardShortcut(.return, modifiers: [])

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

        Button("About Dimmerly") {
            NSApp.activate(ignoringOtherApps: true)
            let credits = NSMutableAttributedString()

            let description = NSAttributedString(
                string: "A minimal macOS menu bar utility for quickly putting your displays to sleep.\n\n",
                attributes: [
                    .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                    .foregroundColor: NSColor.secondaryLabelColor,
                ]
            )
            credits.append(description)

            let linkText = NSAttributedString(
                string: "GitHub",
                attributes: [
                    .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                    .link: URL(string: "https://github.com/olujicz/Dimmerly")!,
                ]
            )
            credits.append(linkText)

            NSApp.orderFrontStandardAboutPanel(options: [
                .credits: credits,
            ])
        }

        Divider()

        Button("Quit Dimmerly") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: .command)
    }

    private func handleSleepDisplays() {
        if settings.preventScreenLock {
            ScreenBlanker.shared.blank()
        } else {
            let result = DisplayController.sleepDisplays()
            if case .failure(let error) = result {
                AlertPresenter.showError(error)
            }
        }
    }
}

#Preview {
    MenuContent()
        .environmentObject(AppSettings())
        .environmentObject(KeyboardShortcutManager())
}

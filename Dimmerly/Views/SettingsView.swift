//
//  SettingsView.swift
//  Dimmerly
//
//  Settings window for configuring app preferences.
//  Includes keyboard shortcut configuration and launch-at-login toggle.
//

import SwiftUI

/// Main settings view for the application
struct SettingsView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var shortcutManager: KeyboardShortcutManager

    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem {
                    Label("General", systemImage: "gear")
                }

            KeyboardShortcutsSettingsView()
                .tabItem {
                    Label("Shortcuts", systemImage: "keyboard")
                }

            AboutSettingsView()
                .tabItem {
                    Label("About", systemImage: "info.circle")
                }
        }
        .frame(width: 450, height: 350)
    }
}

/// General settings tab
struct GeneralSettingsView: View {
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        Form {
            Section {
                Toggle("Launch at Login", isOn: Binding(
                    get: { settings.launchAtLogin },
                    set: { newValue in
                        settings.launchAtLogin = newValue
                        let _ = LaunchAtLoginManager.setEnabled(newValue)
                    }
                ))
                .help("Automatically start Dimmerly when you log in")
            } header: {
                Text("Startup")
                    .font(.headline)
            }

            Spacer()
        }
        .padding(20)
    }
}

/// Keyboard shortcuts settings tab
struct KeyboardShortcutsSettingsView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var shortcutManager: KeyboardShortcutManager

    var body: some View {
        Form {
            Section {
                HStack {
                    Text("Sleep Displays:")
                        .frame(width: 120, alignment: .leading)

                    KeyboardShortcutRecorder(
                        shortcut: Binding(
                            get: { settings.keyboardShortcut },
                            set: { newValue in
                                settings.keyboardShortcut = newValue
                                shortcutManager.updateShortcut(newValue)
                            }
                        )
                    )
                }
                .padding(.vertical, 8)

                if !shortcutManager.hasAccessibilityPermission {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                        Text("Accessibility permissions required")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Button("Grant Access") {
                            KeyboardShortcutManager.requestAccessibilityPermission()
                        }
                        .font(.caption)
                    }
                    .padding(.vertical, 4)
                }
            } header: {
                Text("Global Shortcuts")
                    .font(.headline)
            }

            Text("Global keyboard shortcuts allow you to trigger actions from any application.")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.top, 8)

            Spacer()
        }
        .padding(20)
    }
}

/// About tab
struct AboutSettingsView: View {
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "moon.fill")
                .font(.system(size: 48))
                .foregroundColor(.accentColor)

            Text("Dimmerly")
                .font(.title)
                .fontWeight(.bold)

            Text("Version 1.0.0")
                .font(.subheadline)
                .foregroundColor(.secondary)

            Text("A minimal macOS menu bar utility for quickly sleeping displays.")
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
                .padding(.horizontal, 40)

            Divider()
                .padding(.horizontal, 40)

            VStack(spacing: 8) {
                Text("Privacy-focused")
                    .font(.headline)
                Text("No data collection • No network access • No tracking")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Text("© 2026 Dimmerly")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(20)
    }
}

#Preview {
    SettingsView()
        .environmentObject(AppSettings())
        .environmentObject(KeyboardShortcutManager())
}

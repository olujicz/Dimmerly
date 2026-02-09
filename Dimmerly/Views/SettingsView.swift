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
        .frame(minWidth: 450, minHeight: 350)
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
                            .foregroundStyle(.yellow)
                            .accessibilityHidden(true)
                        Text("Warning: Accessibility permissions required for global shortcuts.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Open Accessibility Settings") {
                            KeyboardShortcutManager.requestAccessibilityPermission()
                        }
                        .font(.caption)
                    }
                    .accessibilityElement(children: .combine)
                    .padding(.vertical, 4)
                }
            } header: {
                Text("Global Shortcuts")
            }

            Text("Global keyboard shortcuts allow you to trigger actions from any application.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 8)

            Spacer()
        }
        .padding(20)
    }
}

/// About tab
struct AboutSettingsView: View {
    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "Version \(version) (\(build))"
    }

    var body: some View {
        VStack(spacing: 20) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)

            Text("Dimmerly")
                .font(.title)
                .fontWeight(.bold)

            Text(appVersion)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Text("A minimal macOS menu bar utility for quickly sleeping displays.")
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 40)

            Divider()
                .padding(.horizontal, 40)

            VStack(spacing: 8) {
                Text("Privacy-focused")
                    .font(.headline)
                Text("No data collection \u{2022} No network access \u{2022} No tracking")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text("\u{00A9} 2026 Dimmerly")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
    }
}

#Preview {
    SettingsView()
        .environmentObject(AppSettings())
        .environmentObject(KeyboardShortcutManager())
}

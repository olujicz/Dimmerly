//
//  SettingsView.swift
//  Dimmerly
//
//  Settings window for configuring app preferences.
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

            AboutSettingsView()
                .tabItem {
                    Label("About", systemImage: "info.circle")
                }
        }
        .frame(width: 400, height: 300)
    }
}

/// General settings tab — all preferences in one place
struct GeneralSettingsView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var shortcutManager: KeyboardShortcutManager

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Toggle("Launch at Login", isOn: Binding(
                get: { settings.launchAtLogin },
                set: { newValue in
                    settings.launchAtLogin = newValue
                    let _ = LaunchAtLoginManager.setEnabled(newValue)
                }
            ))
            .help("Automatically start Dimmerly when you log in")

            Toggle("Prevent Screen Lock", isOn: $settings.preventScreenLock)
                .help("Blank screens instead of sleeping displays, so your session stays unlocked")

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Sleep Displays:")
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

                Text("Global keyboard shortcuts work from any application.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if !shortcutManager.hasAccessibilityPermission {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Accessibility permission is required for global shortcuts.", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .symbolRenderingMode(.multicolor)

                        Button("Open Accessibility Settings") {
                            KeyboardShortcutManager.requestAccessibilityPermission()
                        }
                        .font(.caption)
                    }
                    .accessibilityElement(children: .combine)
                    .padding(.top, 4)
                }
            }

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
            Image("AboutIcon")
                .resizable()
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

            Text("Dimmerly")
                .font(.title)
                .fontWeight(.bold)

            Text(appVersion)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Text("A minimal macOS menu bar utility for quickly putting your displays to sleep.")
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 40)

            Spacer()

            Link("GitHub", destination: URL(string: "https://github.com/olujicz/Dimmerly")!)
                .font(.caption)

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

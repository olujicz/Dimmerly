//
//  SettingsGeneralTab.swift
//  Dimmerly
//

import AppKit
import SwiftUI

// MARK: - General Tab

/// General settings: launch at login, menu bar icon
struct GeneralSettingsTab: View {
    @Environment(AppSettings.self) var settings
    @Environment(KeyboardShortcutManager.self) var shortcutManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Alert content, kept separate from whether the alert is presented (below) so dismissing
    /// doesn't clear the title/message text while the dismiss animation is still fading out —
    /// only a fresh alert trigger replaces this, never the dismissal itself.
    @State private var launchAtLoginAlert: LaunchAtLoginAlertContent?
    @State private var isLaunchAtLoginAlertPresented = false

    var body: some View {
        Form {
            Section {
                Toggle("Launch at Login", isOn: Binding(
                    get: { settings.launchAtLogin },
                    set: { newValue in
                        launchAtLoginAlert = applyLaunchAtLoginChange(
                            requestedValue: newValue,
                            settings: settings,
                            result: LaunchAtLoginManager.setEnabled(newValue)
                        )
                        isLaunchAtLoginAlertPresented = launchAtLoginAlert != nil
                    }
                ))
                .help(Text("Automatically start Dimmerly when you log in"))

                menuBarIconPicker
            } header: {
                Label("General", systemImage: "gear")
            }
        }
        .formStyle(.grouped)
        .alert(
            launchAtLoginAlert?.title ?? "",
            isPresented: $isLaunchAtLoginAlertPresented
        ) {
            // A single dismissive button doesn't need a `.cancel` role.
            Button("OK") {
                isLaunchAtLoginAlertPresented = false
            }
        } message: {
            Text(launchAtLoginAlert?.message ?? "")
        }
        .onAppear {
            // Sync launch-at-login state with system
            settings.launchAtLogin = LaunchAtLoginManager.isEnabled
            // Re-check accessibility permission
            shortcutManager.hasAccessibilityPermission = KeyboardShortcutManager.checkAccessibilityPermission()
        }
    }

    // MARK: - Menu Bar Icon Picker

    private var menuBarIconPicker: some View {
        LabeledContent("Menu Bar Icon:") {
            HStack(spacing: 8) {
                ForEach(MenuBarIconStyle.allCases) { style in
                    let isSelected = settings.menuBarIconRaw == style.rawValue
                    Button {
                        settings.menuBarIcon = style
                    } label: {
                        Group {
                            if let systemImage = style.systemImageName {
                                Image(systemName: systemImage)
                            } else {
                                Image(style.assetName ?? "MenuBarIcon")
                            }
                        }
                        .frame(width: 32, height: 32)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary))
                        )
                        .foregroundStyle(isSelected ? .white : .primary)
                    }
                    .buttonStyle(.plain)
                    .help(style.displayName)
                    .accessibilityLabel(style.displayName)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
            .animation(
                reduceMotion ? nil : .spring(response: 0.2, dampingFraction: 0.8),
                value: settings.menuBarIconRaw
            )
        }
    }
}

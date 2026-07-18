//
//  SettingsShortcutsTab.swift
//  Dimmerly
//

import AppKit
import SwiftUI

// MARK: - Shortcuts Tab

/// Keyboard shortcut and preset management
struct ShortcutsSettingsTab: View {
    @Environment(AppSettings.self) var settings
    @Environment(KeyboardShortcutManager.self) var shortcutManager
    @Environment(PresetManager.self) var presetManager
    @Environment(PresetShortcutManager.self) var presetShortcutManager
    @Environment(\.undoManager) var undoManager

    @State private var mainShortcutConflictMessage: String?
    @State private var showRestoreDefaults = false

    var body: some View {
        Form {
            keyboardShortcutSection

            presetsManagementSection
        }
        .formStyle(.grouped)
        .onAppear {
            refreshAccessibilityState()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshAccessibilityState()
        }
    }

    // MARK: - Keyboard Shortcut

    private var keyboardShortcutSection: some View {
        Section {
            HStack {
                #if APPSTORE
                    Text("Dim Displays:")
                #else
                    Text(settings.preventScreenLock ? "Dim Displays:" : "Sleep Displays:")
                #endif
                KeyboardShortcutRecorder(
                    shortcut: Binding(
                        get: { settings.keyboardShortcut },
                        set: { newValue in
                            updateMainShortcut(newValue)
                        }
                    ),
                    onRecordingChanged: { _ in
                        mainShortcutConflictMessage = nil
                    }
                )
            }

            Text("Global keyboard shortcuts work from any application.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let mainShortcutConflictMessage {
                Label(mainShortcutConflictMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .symbolRenderingMode(.multicolor)
            }

            if !shortcutManager.hasAccessibilityPermission {
                VStack(alignment: .leading, spacing: 8) {
                    Label(
                        "Accessibility permission is required for global shortcuts.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .symbolRenderingMode(.multicolor)

                    Button {
                        KeyboardShortcutManager.requestAccessibilityPermission()
                    } label: {
                        HStack(spacing: 2) {
                            Text("Open Accessibility Settings")
                            Image(systemName: "arrow.up.forward")
                                .imageScale(.small)
                        }
                    }
                    .font(.caption)
                    .help("Open macOS Accessibility settings")
                }
                .accessibilityElement(children: .combine)
                .padding(.top, 4)
            }
        } header: {
            Label("Keyboard Shortcut", systemImage: "keyboard")
        }
    }

    private func updateMainShortcut(_ shortcut: GlobalShortcut) {
        if let conflictingPreset = presetManager.presets.first(where: { $0.shortcut == shortcut }) {
            mainShortcutConflictMessage = String(
                format: NSLocalizedString("This shortcut conflicts with %@", comment: "Shortcut conflict message"),
                conflictingPreset.name
            )
            return
        }

        mainShortcutConflictMessage = nil
        settings.keyboardShortcut = shortcut
        shortcutManager.updateShortcut(shortcut)
    }

    private func refreshAccessibilityState() {
        shortcutManager.refreshAccessibilityPermissionAndRestartIfNeeded()
        presetShortcutManager.refreshAccessibilityPermissionAndRestartIfNeeded()
    }

    // MARK: - Presets Management

    private var presetsManagementSection: some View {
        Section {
            ForEach(presetManager.presets) { preset in
                PresetManagementRow(
                    preset: preset,
                    mainShortcut: settings.keyboardShortcut,
                    mainShortcutName: StatusItemQuickActions.turnOffTitle(settings: settings),
                    allPresets: presetManager.presets,
                    onRename: { newName in
                        presetManager.renamePreset(id: preset.id, to: newName)
                    },
                    onDelete: {
                        presetManager.deletePreset(id: preset.id, undoManager: undoManager)
                    },
                    onShortcutChanged: { shortcut in
                        try presetManager.updateShortcut(for: preset.id, shortcut: shortcut)
                    }
                )
            }

            Button("Restore Defaults") {
                showRestoreDefaults = true
            }
            .help("Replace all presets with the defaults")
            .alert("Restore Default Presets?", isPresented: $showRestoreDefaults) {
                Button("Cancel", role: .cancel) {}
                Button("Restore", role: .destructive) { presetManager.restoreDefaultPresets(undoManager: undoManager) }
            } message: {
                Text("This will replace all your presets with the defaults. Custom presets and shortcuts will be lost.")
            }
        } header: {
            Label("Presets", systemImage: "slider.horizontal.3")
        }
    }
}

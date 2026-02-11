//
//  SettingsView.swift
//  Dimmerly
//
//  Settings window for configuring app preferences.
//

import SwiftUI

/// Main settings view for the application
struct SettingsView: View {
    var body: some View {
        GeneralSettingsView()
            .frame(minWidth: 400, maxWidth: 500, minHeight: 500)
            .onAppear {
                if #available(macOS 14.0, *) {
                    NSApp.activate()
                } else {
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
    }
}

/// General settings tab — all preferences in one place
struct GeneralSettingsView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var shortcutManager: KeyboardShortcutManager
    @EnvironmentObject var presetManager: PresetManager
    @EnvironmentObject var brightnessManager: BrightnessManager

    var body: some View {
        Form {
            Section {
                Toggle("Launch at Login", isOn: Binding(
                    get: { settings.launchAtLogin },
                    set: { newValue in
                        settings.launchAtLogin = newValue
                        let result = LaunchAtLoginManager.setEnabled(newValue)
                        if case .failure = result {
                            // Revert toggle on failure
                            settings.launchAtLogin = !newValue
                        }
                    }
                ))
                .help(Text("Automatically start Dimmerly when you log in"))

                #if APPSTORE
                Text("Dims screens without putting displays to sleep. Your session stays unlocked.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Ignore mouse movement", isOn: $settings.ignoreMouseMovement)
                    .font(.caption)
                    .help(Text("Only wake the screen on keyboard input or mouse click, not mouse movement"))

                Toggle("Fade transition", isOn: $settings.fadeTransition)
                    .font(.caption)
                    .help(Text("Gradually dims displays instead of turning them off instantly"))

                Text("Gradually dims displays instead of turning them off instantly.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                #else
                Picker("Turn Displays Off:", selection: Binding(
                    get: { settings.preventScreenLock ? 1 : 0 },
                    set: { settings.preventScreenLock = $0 == 1 }
                )) {
                    Text("Sleep & Lock").tag(0)
                    Text("Dim Only").tag(1)
                }
                .pickerStyle(.radioGroup)

                if !settings.preventScreenLock {
                    Text("Turns off all displays and locks your Mac, just like closing the lid. To control how quickly your password is required, adjust your Lock Screen settings.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Button("Open Lock Screen Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.Lock-Screen-Settings.extension") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .font(.caption)
                } else {
                    Text("Dims screens without putting displays to sleep. Your session stays unlocked.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Toggle("Ignore mouse movement", isOn: $settings.ignoreMouseMovement)
                        .font(.caption)
                        .help(Text("Only wake the screen on keyboard input or mouse click, not mouse movement"))

                    Toggle("Fade transition", isOn: $settings.fadeTransition)
                        .font(.caption)
                        .help(Text("Gradually dims displays instead of turning them off instantly"))

                    Text("Gradually dims displays instead of turning them off instantly.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                #endif
            }

            menuBarIconSection

            idleTimerSection

            keyboardShortcutSection

            if !presetManager.presets.isEmpty {
                presetsManagementSection
            }
        }
        .formStyle(.grouped)
        .onAppear {
            // Sync launch-at-login state with system (Issue 4)
            settings.launchAtLogin = LaunchAtLoginManager.isEnabled
            // Re-check accessibility permission (Issue 4)
            shortcutManager.hasAccessibilityPermission = KeyboardShortcutManager.checkAccessibilityPermission()
        }
    }

    // MARK: - Menu Bar Icon

    private var menuBarIconSection: some View {
        Section("Menu Bar Icon") {
            Picker("Style:", selection: $settings.menuBarIconRaw) {
                ForEach(MenuBarIconStyle.allCases) { style in
                    HStack(spacing: 6) {
                        if let systemImage = style.systemImageName {
                            Image(systemName: systemImage)
                                .frame(width: 16)
                        } else {
                            Image("MenuBarIcon")
                                .frame(width: 16)
                        }
                        Text(style.displayName)
                    }
                    .tag(style.rawValue)
                }
            }
            .pickerStyle(.radioGroup)
        }
    }

    // MARK: - Idle Timer

    private var idleTimerSection: some View {
        Section("Idle Timer") {
            Toggle("Auto-dim after inactivity", isOn: $settings.idleTimerEnabled)

            if settings.idleTimerEnabled {
                Stepper(value: $settings.idleTimerMinutes, in: 1...60) {
                    Text(
                        String(
                            format: NSLocalizedString(
                                "%d minutes",
                                comment: "Idle timer stepper label: number of minutes"
                            ),
                            settings.idleTimerMinutes
                        )
                    )
                }
                .font(.callout)

                Text(
                    String(
                        format: NSLocalizedString(
                            "Displays will dim automatically after %d minutes of inactivity.",
                            comment: "Idle timer description"
                        ),
                        settings.idleTimerMinutes
                    )
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Keyboard Shortcut

    private var keyboardShortcutSection: some View {
        Section("Keyboard Shortcut") {
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
    }

    // MARK: - Presets Management

    private var presetsManagementSection: some View {
        Section("Presets") {
            ForEach(presetManager.presets) { preset in
                PresetManagementRow(
                    preset: preset,
                    mainShortcut: settings.keyboardShortcut,
                    allPresets: presetManager.presets,
                    onRename: { newName in
                        presetManager.renamePreset(id: preset.id, to: newName)
                    },
                    onDelete: {
                        presetManager.deletePreset(id: preset.id)
                    },
                    onShortcutChanged: { shortcut in
                        presetManager.updateShortcut(for: preset.id, shortcut: shortcut)
                    }
                )
            }
        }
    }
}

// MARK: - Preset Management Row

private struct PresetManagementRow: View {
    let preset: BrightnessPreset
    let mainShortcut: GlobalShortcut
    let allPresets: [BrightnessPreset]
    let onRename: (String) -> Void
    let onDelete: () -> Void
    let onShortcutChanged: (GlobalShortcut?) -> Void

    @State private var isEditing = false
    @State private var editedName: String = ""
    @State private var isRecordingShortcut = false
    @State private var conflictMessage: String?
    @State private var showDeleteConfirmation = false

    var body: some View {
        HStack {
            if isEditing {
                TextField("Name", text: $editedName, onCommit: {
                    let trimmed = editedName.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty {
                        onRename(trimmed)
                    }
                    isEditing = false
                })
                .textFieldStyle(.roundedBorder)
                .font(.callout)
            } else {
                Text(preset.name)
                    .font(.callout)
                    .onTapGesture(count: 2) {
                        editedName = preset.name
                        isEditing = true
                    }
                    .contextMenu {
                        Button("Rename") {
                            editedName = preset.name
                            isEditing = true
                        }
                    }
            }

            Spacer()

            // Shortcut recorder
            PresetShortcutRecorderButton(
                shortcut: preset.shortcut,
                onRecord: { newShortcut in
                    // Check for conflicts
                    if let sc = newShortcut {
                        if sc == mainShortcut {
                            conflictMessage = String(
                                format: NSLocalizedString("This shortcut conflicts with %@", comment: "Shortcut conflict message"),
                                NSLocalizedString("Sleep Displays", comment: "Main shortcut name")
                            )
                            return
                        }
                        for other in allPresets where other.id != preset.id {
                            if other.shortcut == sc {
                                conflictMessage = String(
                                    format: NSLocalizedString("This shortcut conflicts with %@", comment: "Shortcut conflict message"),
                                    other.name
                                )
                                return
                            }
                        }
                    }
                    conflictMessage = nil
                    onShortcutChanged(newShortcut)
                }
            )

            Button {
                showDeleteConfirmation = true
            } label: {
                Image(systemName: "trash")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(Text("Delete \(preset.name)"))
            .help(Text("Delete Preset"))
            .alert("Delete Preset?", isPresented: $showDeleteConfirmation) {
                Button("Cancel", role: .cancel) {}
                Button("Delete", role: .destructive) { onDelete() }
            } message: {
                Text("\"\(preset.name)\" will be permanently deleted.")
            }
        }

        if let conflictMessage {
            Text(conflictMessage)
                .font(.caption)
                .foregroundStyle(.red)
        }
    }
}

// MARK: - Preset Shortcut Recorder Button

private struct PresetShortcutRecorderButton: View {
    let shortcut: GlobalShortcut?
    let onRecord: (GlobalShortcut?) -> Void

    @State private var isRecording = false

    var body: some View {
        Button {
            isRecording.toggle()
        } label: {
            if isRecording {
                Text("Press shortcut\u{2026}")
                    .font(.caption)
                    .frame(minWidth: 60)
            } else {
                Text(shortcut?.displayString ?? NSLocalizedString("Set\u{2026}", comment: "Preset shortcut button placeholder"))
                    .font(.caption)
                    .foregroundStyle(shortcut != nil ? .primary : .secondary)
                    .frame(minWidth: 60)
            }
        }
        .buttonStyle(.bordered)
        .tint(isRecording ? .accentColor : nil)
        .overlay(
            PresetShortcutCaptureView(
                isActive: isRecording,
                onCapture: { captured in
                    isRecording = false
                    onRecord(captured)
                },
                onCancel: {
                    isRecording = false
                }
            )
            .allowsHitTesting(isRecording)
            .opacity(0)
        )
        .contextMenu {
            if shortcut != nil {
                Button("Clear Shortcut") {
                    onRecord(nil)
                }
            }
        }
    }
}

// MARK: - Preset Shortcut Capture View

private struct PresetShortcutCaptureView: NSViewRepresentable {
    let isActive: Bool
    let onCapture: (GlobalShortcut) -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> PresetShortcutNSView {
        let view = PresetShortcutNSView()
        view.onCapture = onCapture
        view.onCancel = onCancel
        return view
    }

    func updateNSView(_ nsView: PresetShortcutNSView, context: Context) {
        nsView.isActive = isActive
        if isActive {
            nsView.window?.makeFirstResponder(nsView)
        }
    }
}

private class PresetShortcutNSView: NSView {
    var onCapture: ((GlobalShortcut) -> Void)?
    var onCancel: (() -> Void)?
    var isActive = false

    override var acceptsFirstResponder: Bool { isActive }

    override func keyDown(with event: NSEvent) {
        guard isActive else {
            super.keyDown(with: event)
            return
        }

        if event.keyCode == 53 { // Escape
            onCancel?()
            return
        }

        if let shortcut = GlobalShortcut.from(keyCode: event.keyCode, modifierFlags: event.modifierFlags),
           shortcut.isValid {
            onCapture?(shortcut)
        }
    }

    override func mouseDown(with event: NSEvent) {
        if isActive {
            onCancel?()
        }
        super.mouseDown(with: event)
    }
}

#Preview {
    SettingsView()
        .environmentObject(AppSettings())
        .environmentObject(KeyboardShortcutManager())
        .environmentObject(PresetManager())
        .environmentObject(BrightnessManager())
}

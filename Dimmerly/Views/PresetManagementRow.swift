//
//  PresetManagementRow.swift
//  Dimmerly
//
//  Preset row with rename, shortcut recorder, and delete controls
//  for use in the Settings presets section.
//

import SwiftUI

// MARK: - Preset Management Row

struct PresetManagementRow: View {
    let preset: BrightnessPreset
    /// Display name for the main shortcut's action, matching
    /// `StatusItemQuickActions.turnOffTitle(settings:)` — the same label shown in the menu
    /// bar panel and quick-actions menu, so this conflict message never disagrees with what
    /// the user actually sees (e.g. never says "Sleep Displays" in the App Store build, which
    /// only ever offers "Dim Displays").
    let mainShortcutName: String
    let onRename: (String) -> Void
    let onDelete: () -> Void
    let onShortcutChanged: (GlobalShortcut?) throws -> Void

    @State private var isEditing = false
    @State private var editedName: String = ""
    @State private var conflictMessage: String?
    @State private var showDeleteConfirmation = false
    @FocusState private var isNameFieldFocused: Bool

    var body: some View {
        HStack {
            if isEditing {
                TextField("Name", text: $editedName)
                    .textFieldStyle(.roundedBorder)
                    .focused($isNameFieldFocused)
                    .onAppear { isNameFieldFocused = true }
                    .onSubmit(commitRename)
                    .onExitCommand(perform: cancelRename)
                    // Clicking or tabbing away keeps the typed name, as renaming in Finder
                    // does, rather than silently dropping it and leaving the row in edit mode.
                    .onChange(of: isNameFieldFocused) { _, isFocused in
                        if !isFocused {
                            commitRename()
                        }
                    }
            } else {
                Text(preset.name)
                    .contextMenu {
                        Button("Rename", action: startRename)
                    }

                Button(action: startRename) {
                    Image(systemName: "pencil")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(Text("Rename \(preset.name)"))
                .help(Text("Rename Preset"))
            }

            Spacer()

            // Shortcut recorder
            PresetShortcutRecorderButton(
                presetName: preset.name,
                shortcut: preset.shortcut,
                onRecord: { newShortcut in
                    // PresetManager enforces uniqueness; only the main-shortcut message is
                    // reworded here to name the action the user sees in this tab.
                    do {
                        try onShortcutChanged(newShortcut)
                        conflictMessage = nil
                    } catch PresetShortcutError.conflictsWithMainShortcut {
                        conflictMessage = String(
                            format: String(localized: "This shortcut conflicts with %@."),
                            mainShortcutName
                        )
                    } catch {
                        conflictMessage = error.localizedDescription
                    }
                },
                onConflictDetected: { message in
                    conflictMessage = message
                },
                onRecordingChanged: { isRecording in
                    if isRecording {
                        conflictMessage = nil
                    }
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
            Label(conflictMessage, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .symbolRenderingMode(.multicolor)
        }
    }

    /// Name of the main shortcut or another preset already bound to `shortcut`.
    private func startRename() {
        editedName = preset.name
        isEditing = true
    }

    /// Ends editing and saves the name. Runs once: Return, then the field losing focus as
    /// it goes away, both land here.
    private func commitRename() {
        guard isEditing else { return }
        isEditing = false
        if let newName = Self.renamedName(from: editedName, current: preset.name) {
            onRename(newName)
        }
    }

    private func cancelRename() {
        isEditing = false
    }

    /// The trimmed name to save, or nil when it is blank or unchanged.
    nonisolated static func renamedName(from editedName: String, current: String) -> String? {
        let trimmed = editedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != current else { return nil }
        return trimmed
    }
}

// MARK: - Preset Shortcut Recorder Button

struct PresetShortcutRecorderButton: View {
    let presetName: String
    let shortcut: GlobalShortcut?
    let onRecord: (GlobalShortcut?) -> Void
    var onConflictDetected: ((String) -> Void)?
    var onRecordingChanged: ((Bool) -> Void)?

    @State private var isRecording = false
    @State private var recorderID = UUID()

    var body: some View {
        HStack(spacing: 4) {
            recorderButton

            // Mirrors the main recorder's trailing reset button. Hidden rather than removed
            // when there is nothing to clear, so the recorder doesn't shift sideways.
            Button {
                onRecord(nil)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help(Text("Clear Shortcut"))
            .accessibilityLabel(Text("Clear Shortcut for \(presetName)"))
            .opacity(shortcut == nil ? 0 : 1)
            .disabled(shortcut == nil || isRecording)
            .accessibilityHidden(shortcut == nil)
        }
    }

    private var recorderButton: some View {
        Button {
            isRecording.toggle()
        } label: {
            if isRecording {
                Text("Press shortcut\u{2026}")
                    .font(.caption)
                    .frame(minWidth: 60)
            } else {
                Text(
                    shortcut?.displayString
                        ?? NSLocalizedString("Set\u{2026}", comment: "Preset shortcut button placeholder")
                )
                .font(.caption)
                .foregroundStyle(shortcut != nil ? .primary : .secondary)
                .frame(minWidth: 60)
            }
        }
        .buttonStyle(.bordered)
        .tint(isRecording ? .accentColor : nil)
        .overlay(
            ShortcutCaptureView(
                isActive: isRecording,
                onCapture: { captured in
                    isRecording = false
                    onRecord(captured)
                },
                onCancel: {
                    isRecording = false
                },
                onConflictDetected: { message in
                    isRecording = false
                    onConflictDetected?(message)
                }
            )
            .allowsHitTesting(isRecording)
            .opacity(0)
        )
        .accessibilityLabel(Text("Shortcut for \(presetName)"))
        .accessibilityValue(
            isRecording
                ? Text("Press shortcut\u{2026}")
                : shortcut.map { Text(verbatim: $0.displayString) } ?? Text("None")
        )
        .accessibilityHint(
            Text(isRecording ? "Press a key combination to record" : "Click to record a new shortcut")
        )
        .help(Text("Click to record a new shortcut"))
        .onChange(of: isRecording) { _, newValue in
            ShortcutRecordingCoordinator.shared.setRecording(newValue, for: recorderID)
            onRecordingChanged?(newValue)
        }
        .onDisappear {
            ShortcutRecordingCoordinator.shared.setRecording(false, for: recorderID)
        }
        .contextMenu {
            if shortcut != nil {
                Button("Clear Shortcut") {
                    onRecord(nil)
                }
            }
        }
    }
}

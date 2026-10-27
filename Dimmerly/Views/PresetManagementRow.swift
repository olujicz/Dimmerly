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
    let mainShortcut: GlobalShortcut
    /// Display name for the main shortcut's action, matching
    /// `StatusItemQuickActions.turnOffTitle(settings:)` — the same label shown in the menu
    /// bar panel and quick-actions menu, so this conflict message never disagrees with what
    /// the user actually sees (e.g. never says "Sleep Displays" in the App Store build, which
    /// only ever offers "Dim Displays").
    let mainShortcutName: String
    let allPresets: [BrightnessPreset]
    let onRename: (String) -> Void
    let onDelete: () -> Void
    let onShortcutChanged: (GlobalShortcut?) throws -> Void

    @State private var isEditing = false
    @State private var editedName: String = ""
    @State private var conflictMessage: String?
    @State private var showDeleteConfirmation = false
    @State private var isHovered = false
    @FocusState private var renameButtonFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
            } else {
                Text(preset.name)
                    .contextMenu {
                        Button("Rename") {
                            editedName = preset.name
                            isEditing = true
                        }
                    }

                Button {
                    editedName = preset.name
                    isEditing = true
                } label: {
                    Image(systemName: "pencil")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .opacity(isHovered || renameButtonFocused ? 1 : 0.3)
                .focused($renameButtonFocused)
                .accessibilityLabel(Text("Rename \(preset.name)"))
                .help(Text("Rename Preset"))
            }

            Spacer()

            // Shortcut recorder
            PresetShortcutRecorderButton(
                shortcut: preset.shortcut,
                onRecord: { newShortcut in
                    // Check for conflicts
                    if let sc = newShortcut, let conflictName = conflictingName(for: sc) {
                        conflictMessage = String(
                            format: NSLocalizedString(
                                "This shortcut conflicts with %@",
                                comment: "Shortcut conflict message"
                            ),
                            conflictName
                        )
                        return
                    }
                    do {
                        try onShortcutChanged(newShortcut)
                        conflictMessage = nil
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
        .onHover { isHovered = $0 }
        .animation(reduceMotion ? nil : .spring(response: 0.2, dampingFraction: 0.8), value: isHovered)

        if let conflictMessage {
            Label(conflictMessage, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .symbolRenderingMode(.multicolor)
        }
    }

    /// Name of the main shortcut or another preset already bound to `shortcut`.
    private func conflictingName(for shortcut: GlobalShortcut) -> String? {
        if shortcut == mainShortcut {
            return mainShortcutName
        }
        return allPresets.first { $0.id != preset.id && $0.shortcut == shortcut }?.name
    }
}

// MARK: - Preset Shortcut Recorder Button

struct PresetShortcutRecorderButton: View {
    let shortcut: GlobalShortcut?
    let onRecord: (GlobalShortcut?) -> Void
    var onConflictDetected: ((String) -> Void)?
    var onRecordingChanged: ((Bool) -> Void)?

    @State private var isRecording = false
    @State private var recorderID = UUID()

    var body: some View {
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

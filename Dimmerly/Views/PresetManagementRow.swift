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
    let allPresets: [BrightnessPreset]
    let onRename: (String) -> Void
    let onDelete: () -> Void
    let onShortcutChanged: (GlobalShortcut?) -> Void

    @State private var isEditing = false
    @State private var editedName: String = ""
    @State private var isRecordingShortcut = false
    @State private var conflictMessage: String?
    @State private var showDeleteConfirmation = false
    @State private var isHovered = false

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

                if isHovered {
                    Button {
                        editedName = preset.name
                        isEditing = true
                    } label: {
                        Image(systemName: "pencil")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(Text("Rename \(preset.name)"))
                    .help(Text("Rename Preset"))
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
                                format: NSLocalizedString(
                                    "This shortcut conflicts with %@",
                                    comment: "Shortcut conflict message"
                                ),
                                NSLocalizedString(
                                    "Sleep Displays",
                                    comment: "Main shortcut name"
                                )
                            )
                            return
                        }
                        for other in allPresets where other.id != preset.id {
                            if other.shortcut == sc {
                                conflictMessage = String(
                                    format: NSLocalizedString(
                                        "This shortcut conflicts with %@",
                                        comment: "Shortcut conflict message"
                                    ),
                                    other.name
                                )
                                return
                            }
                        }
                    }
                    conflictMessage = nil
                    onShortcutChanged(newShortcut)
                },
                onRecordingChanged: { _ in
                    conflictMessage = nil
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
        .animation(.spring(response: 0.2, dampingFraction: 0.8), value: isHovered)

        if let conflictMessage {
            Label(conflictMessage, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .symbolRenderingMode(.multicolor)
        }
    }
}

// MARK: - Preset Shortcut Recorder Button

struct PresetShortcutRecorderButton: View {
    let shortcut: GlobalShortcut?
    let onRecord: (GlobalShortcut?) -> Void
    var onRecordingChanged: ((Bool) -> Void)?

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
        .onChange(of: isRecording) { _, newValue in
            onRecordingChanged?(newValue)
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

// MARK: - Preset Shortcut Capture View

private struct PresetShortcutCaptureView: NSViewRepresentable {
    let isActive: Bool
    let onCapture: (GlobalShortcut) -> Void
    let onCancel: () -> Void

    func makeNSView(context _: Context) -> PresetShortcutNSView {
        let view = PresetShortcutNSView()
        view.onCapture = onCapture
        view.onCancel = onCancel
        return view
    }

    func updateNSView(_ nsView: PresetShortcutNSView, context _: Context) {
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

    override var acceptsFirstResponder: Bool {
        isActive
    }

    override func keyDown(with event: NSEvent) {
        guard isActive else {
            super.keyDown(with: event)
            return
        }

        if event.keyCode == 53 { // Escape
            onCancel?()
            return
        }

        if let shortcut = GlobalShortcut.from(
            keyCode: event.keyCode,
            modifierFlags: event.modifierFlags
        ), shortcut.isValid {
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

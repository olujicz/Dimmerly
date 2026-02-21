//
//  KeyboardShortcutRecorder.swift
//  Dimmerly
//
//  SwiftUI component for recording keyboard shortcuts.
//  Allows users to press a key combination to set a new shortcut.
//

import AppKit
import SwiftUI

/// A view that allows users to record a keyboard shortcut
struct KeyboardShortcutRecorder: View {
    /// The currently configured shortcut
    @Binding var shortcut: GlobalShortcut

    /// Called when the recorder begins listening or is cancelled without recording
    var onRecordingChanged: ((Bool) -> Void)?

    /// Whether the recorder is actively listening for input
    @State private var isRecording = false

    /// Warning message shown when a reserved shortcut is attempted
    @State private var conflictMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                // The shortcut display/recorder button
                Button(action: {
                    conflictMessage = nil
                    isRecording.toggle()
                }, label: {
                    if isRecording {
                        Text("Press shortcut\u{2026}")
                            .frame(minWidth: 120)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                    } else {
                        Text(shortcut.displayString)
                            .frame(minWidth: 120)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                    }
                })
                .buttonStyle(.bordered)
                .tint(isRecording ? .accentColor : nil)
                .overlay(
                    ShortcutRecorderView(
                        isRecording: $isRecording,
                        onShortcutRecorded: { newShortcut in
                            conflictMessage = nil
                            shortcut = newShortcut
                        },
                        onConflictDetected: { message in
                            conflictMessage = message
                        }
                    )
                    .opacity(0) // Invisible overlay to capture key events
                )
                .accessibilityLabel(
                    String(
                        format: NSLocalizedString(
                            "Keyboard shortcut: %@",
                            comment: "Accessibility label: current keyboard shortcut"
                        ),
                        shortcut.displayString
                    )
                )
                .accessibilityHint(
                    Text(isRecording ? "Press a key combination to record" : "Click to record a new shortcut")
                )

                // Clear button
                Button(action: {
                    conflictMessage = nil
                    shortcut = .default
                }, label: {
                    Image(systemName: "arrow.counterclockwise")
                })
                .buttonStyle(.borderless)
                .help(Text("Reset to default shortcut"))
                .accessibilityLabel(Text("Reset shortcut to default"))
            }

            if let message = conflictMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .symbolRenderingMode(.multicolor)
            }
        }
        .onChange(of: isRecording) { _, newValue in
            onRecordingChanged?(newValue)
        }
    }
}

/// Helper view that captures keyboard events for shortcut recording
private struct ShortcutRecorderView: NSViewRepresentable {
    @Binding var isRecording: Bool
    let onShortcutRecorded: (GlobalShortcut) -> Void
    let onConflictDetected: (String) -> Void

    func makeNSView(context _: Context) -> NSView {
        let view = ShortcutCaptureView()
        view.onShortcutCaptured = { shortcut in
            onShortcutRecorded(shortcut)
            isRecording = false
        }
        view.onRecordingCancelled = {
            isRecording = false
        }
        view.onConflictDetected = { message in
            onConflictDetected(message)
            isRecording = false
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context _: Context) {
        if let captureView = nsView as? ShortcutCaptureView {
            captureView.isActive = isRecording
        }
    }
}

/// NSView subclass that captures keyboard events
private class ShortcutCaptureView: NSView {
    var isActive = false
    var onShortcutCaptured: ((GlobalShortcut) -> Void)?
    var onRecordingCancelled: (() -> Void)?
    var onConflictDetected: ((String) -> Void)?

    override var acceptsFirstResponder: Bool {
        isActive
    }

    override func keyDown(with event: NSEvent) {
        guard isActive else {
            super.keyDown(with: event)
            return
        }

        // Escape cancels recording (HIG Rule 5.3)
        if event.keyCode == 53 { // kVK_Escape
            isActive = false
            onRecordingCancelled?()
            return
        }

        // Try to create a shortcut from the event
        if let shortcut = GlobalShortcut.from(keyCode: event.keyCode, modifierFlags: event.modifierFlags) {
            if shortcut.isValid {
                if shortcut.isReservedSystemShortcut {
                    onConflictDetected?(
                        String(
                            format: NSLocalizedString(
                                "%@ is a standard system shortcut."
                                    + " Try a different combination.",
                                comment: "Shortcut conflict message"
                            ),
                            shortcut.displayString
                        )
                    )
                } else {
                    onShortcutCaptured?(shortcut)
                }
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        if isActive {
            isActive = false
            onRecordingCancelled?()
        }
        super.mouseDown(with: event)
    }
}

//
//  KeyboardShortcutRecorder.swift
//  Dimmerly
//
//  SwiftUI component for recording keyboard shortcuts.
//  Allows users to press a key combination to set a new shortcut.
//

import SwiftUI
import AppKit

/// A view that allows users to record a keyboard shortcut
struct KeyboardShortcutRecorder: View {
    /// The currently configured shortcut
    @Binding var shortcut: KeyboardShortcut

    /// Whether the recorder is actively listening for input
    @State private var isRecording = false

    /// The visual display text
    private var displayText: String {
        if isRecording {
            return "Press shortcut\u{2026}"
        } else {
            return shortcut.displayString
        }
    }

    var body: some View {
        HStack {
            // The shortcut display/recorder button
            Button(action: {
                isRecording.toggle()
            }) {
                Text(displayText)
                    .frame(minWidth: 120)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.bordered)
            .tint(isRecording ? .accentColor : nil)
            .overlay(
                ShortcutRecorderView(
                    isRecording: $isRecording,
                    onShortcutRecorded: { newShortcut in
                        shortcut = newShortcut
                    }
                )
                .opacity(0) // Invisible overlay to capture key events
            )
            .accessibilityLabel("Keyboard shortcut: \(shortcut.displayString)")
            .accessibilityHint(isRecording ? "Press a key combination to record" : "Click to record a new shortcut")

            // Clear button
            Button(action: {
                shortcut = .default
            }) {
                Image(systemName: "arrow.counterclockwise")
            }
            .buttonStyle(.borderless)
            .help("Reset to default shortcut")
            .accessibilityLabel("Reset shortcut to default")
        }
    }
}

/// Helper view that captures keyboard events for shortcut recording
private struct ShortcutRecorderView: NSViewRepresentable {
    @Binding var isRecording: Bool
    let onShortcutRecorded: (KeyboardShortcut) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = ShortcutCaptureView()
        view.onShortcutCaptured = { shortcut in
            onShortcutRecorded(shortcut)
            isRecording = false
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let captureView = nsView as? ShortcutCaptureView {
            captureView.isActive = isRecording
        }
    }
}

/// NSView subclass that captures keyboard events
private class ShortcutCaptureView: NSView {
    var isActive = false
    var onShortcutCaptured: ((KeyboardShortcut) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        guard isActive else {
            super.keyDown(with: event)
            return
        }

        // Try to create a shortcut from the event
        if let shortcut = KeyboardShortcut.from(keyCode: event.keyCode, modifierFlags: event.modifierFlags) {
            // Validate that it has modifiers (global shortcuts should have modifiers)
            if shortcut.isValid {
                onShortcutCaptured?(shortcut)
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        // Deactivate on mouse click outside
        if isActive {
            isActive = false
        }
        super.mouseDown(with: event)
    }
}

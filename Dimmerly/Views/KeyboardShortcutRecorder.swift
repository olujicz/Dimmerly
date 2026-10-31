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
    @State private var recorderID = UUID()

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
                    ShortcutCaptureView(
                        isActive: isRecording,
                        onCapture: { newShortcut in
                            conflictMessage = nil
                            shortcut = newShortcut
                            isRecording = false
                        },
                        onCancel: {
                            isRecording = false
                        },
                        onConflictDetected: { message in
                            conflictMessage = message
                            isRecording = false
                        }
                    )
                    // Matches PresetShortcutRecorderButton's overlay: only eligible for
                    // AppKit hit-testing while actually recording, so the invisible capture
                    // view can't swallow clicks meant for the button underneath at other times.
                    .allowsHitTesting(isRecording)
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
            ShortcutRecordingCoordinator.shared.setRecording(newValue, for: recorderID)
            onRecordingChanged?(newValue)
        }
        .onDisappear {
            ShortcutRecordingCoordinator.shared.setRecording(false, for: recorderID)
        }
    }
}

// MARK: - Shortcut Capture View

/// Invisible overlay that captures a key combination while its recorder is active.
/// Shared by the main shortcut recorder and the per-preset recorder buttons.
struct ShortcutCaptureView: NSViewRepresentable {
    let isActive: Bool
    let onCapture: (GlobalShortcut) -> Void
    let onCancel: () -> Void
    let onConflictDetected: (String) -> Void

    func makeNSView(context _: Context) -> ShortcutCaptureNSView {
        let view = ShortcutCaptureNSView()
        configure(view)
        return view
    }

    func updateNSView(_ nsView: ShortcutCaptureNSView, context _: Context) {
        configure(nsView)
    }

    /// Hands the view this render's callbacks. They capture the caller's current state (for a
    /// preset row, its presets and main shortcut), so assigning them only in `makeNSView` left
    /// conflict checks running against whatever the caller looked like when it first appeared.
    func configure(_ view: ShortcutCaptureNSView) {
        view.onCapture = onCapture
        view.onCancel = onCancel
        view.onConflictDetected = onConflictDetected
        view.isActive = isActive
    }
}

final class ShortcutCaptureNSView: NSView {
    var onCapture: ((GlobalShortcut) -> Void)?
    var onCancel: (() -> Void)?
    var onConflictDetected: ((String) -> Void)?

    /// Requests first responder only on the false→true transition, deferred to the next
    /// run loop turn — not synchronously inside `updateNSView`'s SwiftUI update transaction,
    /// and not on every subsequent SwiftUI re-render while already recording.
    var isActive = false {
        didSet {
            guard isActive, !oldValue else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, isActive else { return }
                window?.makeFirstResponder(self)
            }
        }
    }

    override var acceptsFirstResponder: Bool {
        isActive
    }

    /// Observer for the hosting window resigning key, so switching apps or windows ends recording.
    private var windowResignKeyObserver: NSObjectProtocol?

    /// Ends an in-progress recording without capturing. Clearing `isActive` first makes every
    /// later exit path (resign, Escape, click) a no-op, so `onCancel` fires at most once.
    private func cancelRecording() {
        guard isActive else { return }
        isActive = false
        onCancel?()
    }

    /// Focus moving to another recorder, field, or window must end recording; otherwise the
    /// label stays on "Press shortcut…" and the recording coordinator keeps suppressing every
    /// global shortcut.
    override func resignFirstResponder() -> Bool {
        let didResign = super.resignFirstResponder()
        if didResign {
            cancelRecording()
        }
        return didResign
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if let windowResignKeyObserver {
            NotificationCenter.default.removeObserver(windowResignKeyObserver)
            self.windowResignKeyObserver = nil
        }
        if newWindow == nil, isActive {
            // Leaving the window can happen inside a SwiftUI update; defer the state change.
            isActive = false
            let onCancel = onCancel
            DispatchQueue.main.async { onCancel?() }
        }
        guard let newWindow else { return }
        windowResignKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: newWindow,
            queue: nil // Posted on the main thread; deliver synchronously.
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.cancelRecording()
            }
        }
    }

    /// AppKit offers ⌘ combinations to the whole window as key equivalents before sending
    /// `keyDown`. Another view in the window can claim one (⌥⇧⌘D in Settings), which left the
    /// recorder stuck on "Press shortcut…", so the focused recorder takes them first.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isActive, window?.firstResponder === self else {
            return super.performKeyEquivalent(with: event)
        }
        keyDown(with: event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard isActive else {
            super.keyDown(with: event)
            return
        }

        // Escape cancels recording (HIG Rule 5.3)
        if event.keyCode == 53 { // kVK_Escape
            cancelRecording()
            return
        }

        if let shortcut = GlobalShortcut.from(
            keyCode: event.keyCode,
            modifierFlags: event.modifierFlags,
            charactersIgnoringModifiers: event.charactersIgnoringModifiers
        ) {
            #if APPSTORE
                guard shortcut.isValid else {
                    isActive = false
                    onConflictDetected?(GlobalShortcut.carbonShortcutRequirementMessage)
                    return
                }
            #endif
            guard shortcut.isValid else { return }
            // Recording ends here; clear `isActive` before the callbacks so the focus change
            // that follows isn't also reported as a cancel.
            isActive = false
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
                onCapture?(shortcut)
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        cancelRecording()
        super.mouseDown(with: event)
    }
}

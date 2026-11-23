//
//  BlankingSystemControllers.swift
//  Dimmerly
//
//  System-facing dependencies for ScreenBlanker.
//

import AppKit

enum BlankingOverlayWakeHint: Equatable {
    case click
    case escape

    var text: String {
        switch self {
        case .click:
            NSLocalizedString("Click to wake", comment: "Hint on a dimmed display while another display is visible")
        case .escape: NSLocalizedString("Press Esc to wake", comment: "Hint shown on blanked display")
        }
    }
}

@MainActor
protocol BlankingWindowControlling: AnyObject {
    func beginBlankingSession()

    @discardableResult
    func showWindow(for displayID: CGDirectDisplayID, showsEscapeHint: Bool) -> Bool
    func setWakeHint(_ hint: BlankingOverlayWakeHint?, for displayID: CGDirectDisplayID)

    func removeWindow(for displayID: CGDirectDisplayID)
    func removeAllWindows()
    func endBlankingSession()

    /// Shows the wake hint again after input that didn't wake the displays.
    func revealWakeHint()

    /// Whether wake input can reach the overlays: Dimmerly is the active app and one of its
    /// overlays is the key window. Always true where input is captured another way.
    var hasInputCapture: Bool { get }

    /// Makes a surviving overlay the key window when none is. Does nothing without overlays or
    /// when one already is key.
    func promoteKeyOverlayIfNeeded()

    /// Called when the mouse is pressed on a display's overlay. A partial session uses the
    /// overlay directly because its wake input monitor has not started.
    var onOverlayMouseDown: ((CGDirectDisplayID) -> Void)? { get set }
}

extension BlankingWindowControlling {
    var hasInputCapture: Bool {
        true
    }

    func promoteKeyOverlayIfNeeded() {}
}

@MainActor
protocol DisplayGammaControlling: AnyObject {
    func blank(_ displayID: CGDirectDisplayID)

    func apply(
        brightness: Double,
        warmth: Double,
        contrast: Double,
        to displayID: CGDirectDisplayID
    )

    func restore(_ displayID: CGDirectDisplayID)
}

@MainActor
protocol CursorVisibilityControlling: AnyObject {
    func hide()
    func unhide()
}

@MainActor
protocol BlankingClock: AnyObject {
    var now: TimeInterval { get }
    func sleep(for duration: Duration) async throws
}

@MainActor
protocol ActiveDisplayProviding: AnyObject {
    var activeDisplayIDs: [CGDirectDisplayID] { get }
    func hasScreen(for displayID: CGDirectDisplayID) -> Bool
}

@MainActor
enum BlankingWindowPresentation {
    static func prepareForLocalInputCapture(_ window: NSWindow) {
        window.hidesOnDeactivate = false
        window.orderFrontRegardless()
    }

    static func activateForLocalInputCapture(
        _ window: NSWindow,
        activation: @MainActor () -> Void
    ) {
        activation()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }
}

/// The overlay's content view. It takes the click that activates Dimmerly instead of only
/// activating the app, so one press on a dimmed display wakes it even when another app was
/// frontmost.
final class BlankingOverlayContentView: NSView {
    var onMouseDown: (() -> Void)?

    override func hitTest(_ point: NSPoint) -> NSView? {
        // The wake label is decorative. A click on it should wake just like a click beside it.
        super.hitTest(point) == nil ? nil : self
    }

    override func acceptsFirstMouse(for _: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with _: NSEvent) {
        onMouseDown?()
    }

    override func rightMouseDown(with _: NSEvent) {
        onMouseDown?()
    }

    override func otherMouseDown(with _: NSEvent) {
        onMouseDown?()
    }
}

@MainActor
final class SystemBlankingWindowController: BlankingWindowControlling {
    var onOverlayMouseDown: ((CGDirectDisplayID) -> Void)?
    private var windows: [CGDirectDisplayID: NSWindow] = [:]
    private var wakeHints: [CGDirectDisplayID: NSTextField] = [:]
    private var wakeHintFadeTask: Task<Void, Never>?
    #if APPSTORE
        private var previouslyFrontmostApplication: NSRunningApplication?
    #endif

    func beginBlankingSession() {
        #if APPSTORE
            let frontmostApplication = NSWorkspace.shared.frontmostApplication
            if frontmostApplication?.bundleIdentifier != Bundle.main.bundleIdentifier {
                previouslyFrontmostApplication = frontmostApplication
            }
            if let window = windows.values.first {
                BlankingWindowPresentation.activateForLocalInputCapture(window) {
                    // The idle timer and schedules blank without a click, so the frontmost
                    // app has no reason to yield. A cooperative activate() could leave it
                    // active, sending keystrokes to a hidden app and missing the wake key.
                    // Take focus instead of requesting it.
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
        #endif
    }

    func showWindow(for displayID: CGDirectDisplayID, showsEscapeHint: Bool) -> Bool {
        let hint: BlankingOverlayWakeHint? = showsEscapeHint ? .escape : nil
        if windows[displayID] != nil {
            setWakeHint(hint, for: displayID)
            return true
        }
        guard let screen = NSScreen.screen(for: displayID) else { return false }

        #if APPSTORE
            let window: NSWindow = BlankingPanel(
                contentRect: .zero,
                styleMask: .borderless,
                backing: .buffered,
                defer: false
            )
        #else
            let window = NSWindow(
                contentRect: .zero,
                styleMask: .borderless,
                backing: .buffered,
                defer: false
            )
        #endif
        window.level = .screenSaver
        window.backgroundColor = .black
        window.isOpaque = true
        window.ignoresMouseEvents = false
        window.acceptsMouseMovedEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.setFrame(screen.frame, display: true)

        let contentView = BlankingOverlayContentView()
        contentView.onMouseDown = { [weak self] in
            self?.onOverlayMouseDown?(displayID)
        }
        window.contentView = contentView

        windows[displayID] = window
        setWakeHint(hint, for: displayID)
        #if APPSTORE
            BlankingWindowPresentation.prepareForLocalInputCapture(window)
        #else
            window.orderFrontRegardless()
        #endif
        return true
    }

    func removeWindow(for displayID: CGDirectDisplayID) {
        // Removal never promotes another overlay: it also runs while a session is torn down, and
        // AppKit may already have cleared the key status. `promoteKeyOverlayIfNeeded()` runs once
        // the topology has been reconciled.
        windows.removeValue(forKey: displayID)?.orderOut(nil)
        wakeHints.removeValue(forKey: displayID)
    }

    var hasInputCapture: Bool {
        #if APPSTORE
            NSApp.isActive && windows.values.contains { $0.isKeyWindow }
        #else
            true
        #endif
    }

    func promoteKeyOverlayIfNeeded() {
        #if APPSTORE
            // Wake input is read through the key window. When the display holding it goes away,
            // another overlay takes over so keys keep reaching the monitor.
            guard !windows.values.contains(where: \.isKeyWindow),
                  let next = windows.sorted(by: { $0.key < $1.key }).first?.value
            else { return }
            next.makeKeyAndOrderFront(nil)
        #endif
    }

    func removeAllWindows() {
        for window in windows.values {
            window.orderOut(nil)
        }
        windows.removeAll()
        wakeHints.removeAll()
        wakeHintFadeTask?.cancel()
        wakeHintFadeTask = nil
    }

    func revealWakeHint() {
        guard !wakeHints.isEmpty else { return }
        let needsAnnouncement = wakeHints.values.allSatisfy { $0.alphaValue < 1 }
        for label in wakeHints.values {
            label.animator().alphaValue = 1
        }
        if needsAnnouncement, let label = wakeHints.values.first {
            announceWakeHint(label.stringValue)
        }
        scheduleWakeHintFade()
    }

    func endBlankingSession() {
        #if APPSTORE
            // Give focus back only if Dimmerly still has it. When the session ended because the
            // user switched to another app, that app is the one they want.
            if NSApp.isActive {
                previouslyFrontmostApplication?.activate(options: [])
            }
            previouslyFrontmostApplication = nil
        #endif
    }

    /// The hint fades so the displays go fully dark, and comes back whenever input is
    /// swallowed without waking. White at 60% on black keeps it above a 7:1 contrast ratio.
    func setWakeHint(_ hint: BlankingOverlayWakeHint?, for displayID: CGDirectDisplayID) {
        let text = hint?.text
        guard wakeHints[displayID]?.stringValue != text else { return }
        wakeHints.removeValue(forKey: displayID)?.removeFromSuperview()
        guard let text, let contentView = windows[displayID]?.contentView else { return }
        let shouldAnnounce = !wakeHints.values.contains { $0.stringValue == text }
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .white.withAlphaComponent(0.6)
        label.alignment = .center
        label.sizeToFit()
        label.frame.origin = CGPoint(
            x: (contentView.bounds.width - label.frame.width) / 2,
            y: 40
        )
        contentView.addSubview(label)
        wakeHints[displayID] = label

        if shouldAnnounce {
            announceWakeHint(text)
        }
        scheduleWakeHintFade()
    }

    private func scheduleWakeHintFade() {
        wakeHintFadeTask?.cancel()
        wakeHintFadeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, let self else { return }
            let labels = Array(wakeHints.values)
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 1
                for label in labels {
                    label.animator().alphaValue = 0
                }
            }, completionHandler: nil)
        }
    }

    private func announceWakeHint(_ text: String) {
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [
                .announcement: text,
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ]
        )
    }
}

#if APPSTORE
    private final class BlankingPanel: NSPanel {
        override var canBecomeKey: Bool {
            true
        }

        override var canBecomeMain: Bool {
            true
        }
    }
#endif

@MainActor
final class SystemDisplayGammaController: DisplayGammaControlling {
    func blank(_ displayID: CGDirectDisplayID) {
        CGSetDisplayTransferByFormula(
            displayID,
            0, 0, 1,
            0, 0, 1,
            0, 0, 1
        )
    }

    func apply(
        brightness: Double,
        warmth: Double,
        contrast: Double,
        to displayID: CGDirectDisplayID
    ) {
        GammaMath.setTransferTables(for: displayID, brightness: brightness, warmth: warmth, contrast: contrast)
    }

    func restore(_: CGDirectDisplayID) {
        CGDisplayRestoreColorSyncSettings()
    }
}

@MainActor
final class SystemCursorVisibilityController: CursorVisibilityControlling {
    func hide() {
        NSCursor.hide()
    }

    func unhide() {
        NSCursor.unhide()
    }
}

@MainActor
final class SystemBlankingClock: BlankingClock {
    var now: TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }

    func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}

@MainActor
final class SystemActiveDisplayProvider: ActiveDisplayProviding {
    var activeDisplayIDs: [CGDirectDisplayID] {
        BrightnessManager.activeDisplayIDs()
    }

    func hasScreen(for displayID: CGDirectDisplayID) -> Bool {
        NSScreen.screen(for: displayID) != nil
    }
}

extension NSScreen {
    /// The screen backed by `displayID`, if it is currently attached.
    static func screen(for displayID: CGDirectDisplayID) -> NSScreen? {
        screens.first { screen in
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID)
                == displayID
        }
    }
}

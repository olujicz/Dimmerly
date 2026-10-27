//
//  BlankingSystemControllers.swift
//  Dimmerly
//
//  System-facing dependencies for ScreenBlanker.
//

import AppKit

@MainActor
protocol BlankingWindowControlling: AnyObject {
    func beginBlankingSession()

    @discardableResult
    func showWindow(for displayID: CGDirectDisplayID, showsEscapeHint: Bool) -> Bool

    func removeWindow(for displayID: CGDirectDisplayID)
    func removeAllWindows()
    func endBlankingSession()

    /// Shows the wake hint again after input that didn't wake the displays.
    func revealWakeHint()
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

@MainActor
final class SystemBlankingWindowController: BlankingWindowControlling {
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
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
        #endif
    }

    func showWindow(for displayID: CGDirectDisplayID, showsEscapeHint: Bool) -> Bool {
        guard windows[displayID] == nil,
              let screen = Self.screen(for: displayID)
        else {
            return windows[displayID] != nil
        }

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

        if showsEscapeHint {
            wakeHints[displayID] = addWakeHint(to: window, screen: screen)
        }

        windows[displayID] = window
        #if APPSTORE
            BlankingWindowPresentation.prepareForLocalInputCapture(window)
        #else
            window.orderFrontRegardless()
        #endif
        return true
    }

    func removeWindow(for displayID: CGDirectDisplayID) {
        windows.removeValue(forKey: displayID)?.orderOut(nil)
        wakeHints.removeValue(forKey: displayID)
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
        if needsAnnouncement {
            announceWakeHint()
        }
        scheduleWakeHintFade()
    }

    func endBlankingSession() {
        #if APPSTORE
            previouslyFrontmostApplication?.activate(options: [])
            previouslyFrontmostApplication = nil
        #endif
    }

    private static func screen(for displayID: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { screen in
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID)
                == displayID
        }
    }

    private static var wakeHintText: String {
        NSLocalizedString("Press Esc to wake", comment: "Hint shown on blanked display")
    }

    /// The hint fades so the displays go fully dark, and comes back whenever input is
    /// swallowed without waking. White at 60% on black keeps it above a 7:1 contrast ratio.
    private func addWakeHint(to window: NSWindow, screen: NSScreen) -> NSTextField {
        let label = NSTextField(labelWithString: Self.wakeHintText)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .white.withAlphaComponent(0.6)
        label.alignment = .center
        label.sizeToFit()
        label.frame.origin = CGPoint(
            x: (screen.frame.width - label.frame.width) / 2,
            y: 40
        )
        window.contentView?.addSubview(label)

        if wakeHints.isEmpty {
            announceWakeHint()
        }
        scheduleWakeHintFade()
        return label
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

    private func announceWakeHint() {
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [
                .announcement: Self.wakeHintText,
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
        let multipliers = GammaMath.channelMultipliers(for: warmth)
        var red = GammaMath.buildTable(
            brightness: brightness,
            channelMultiplier: multipliers.r,
            contrast: contrast
        )
        var green = GammaMath.buildTable(
            brightness: brightness,
            channelMultiplier: multipliers.g,
            contrast: contrast
        )
        var blue = GammaMath.buildTable(
            brightness: brightness,
            channelMultiplier: multipliers.b,
            contrast: contrast
        )
        CGSetDisplayTransferByTable(displayID, 256, &red, &green, &blue)
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
        NSScreen.screens.contains { screen in
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID)
                == displayID
        }
    }
}

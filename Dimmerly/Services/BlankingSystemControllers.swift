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
            addWakeHint(to: window, screen: screen)
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
    }

    func removeAllWindows() {
        for window in windows.values {
            window.orderOut(nil)
        }
        windows.removeAll()
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

    private func addWakeHint(to window: NSWindow, screen: NSScreen) {
        let label = NSTextField(
            labelWithString: NSLocalizedString(
                "Press Esc to wake",
                comment: "Hint shown on blanked display"
            )
        )
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .white.withAlphaComponent(0.25)
        label.alignment = .center
        label.sizeToFit()
        label.frame.origin = CGPoint(
            x: (screen.frame.width - label.frame.width) / 2,
            y: 40
        )
        window.contentView?.addSubview(label)

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            guard label.window != nil else { return }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 1
                label.animator().alphaValue = 0
            }, completionHandler: nil)
        }
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

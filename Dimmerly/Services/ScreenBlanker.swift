//
//  ScreenBlanker.swift
//  Dimmerly
//
//  Blanks all screens as an alternative to display sleep.
//  Uses gamma table dimming (works over fullscreen apps and dims cursor)
//  with black overlay windows as a complementary layer.
//  Unlike pmset displaysleepnow, this does not trigger session lock.
//

import AppKit

/// Manages screen blanking using gamma dimming and overlay windows
@MainActor
class ScreenBlanker {
    static let shared = ScreenBlanker()

    private var windows: [NSWindow] = []
    private var eventMonitors: [Any] = []
    private(set) var isBlanking = false
    var onDismiss: (() -> Void)?
    /// Timestamp when blanking activated; events before the grace period are ignored
    private var activationTime: TimeInterval = 0
    /// Grace period in seconds to ignore input after blanking
    private let gracePeriod: TimeInterval = 0.5

    /// When true, mouse movement alone won't dismiss blanking
    var ignoreMouseMovement = false

    /// When true, displays fade to black gradually; when false, they go black instantly
    var useFadeTransition = false

    /// Closure to read per-display brightness (set by BrightnessManager)
    var brightnessForDisplay: ((CGDirectDisplayID) -> Double)?

    /// Active fade animation task
    private var fadeTask: Task<Void, Never>?

    // MARK: - Per-Display Blanking

    /// Set of individually blanked display IDs
    private(set) var blankedDisplayIDs: Set<CGDirectDisplayID> = []

    /// Per-display overlay windows for individual blanking
    private var perDisplayWindows: [CGDirectDisplayID: NSWindow] = [:]

    private init() {}

    /// Blanks all connected screens using gamma dimming and overlay windows
    func blank() {
        guard !isBlanking else { return }
        isBlanking = true
        activationTime = ProcessInfo.processInfo.systemUptime

        NSCursor.hide()
        startDismissMonitoring()

        if useFadeTransition {
            // Fade first, overlay windows appear after fade completes
            fadeToBlack()
        } else {
            // Instant: show overlays and zero gamma immediately
            showOverlayWindows()
            dimAllDisplays()
        }
    }

    /// Dismisses blanking and restores normal display state
    func dismiss() {
        guard isBlanking else { return }
        // Ignore dismiss attempts during the grace period
        guard ProcessInfo.processInfo.systemUptime - activationTime >= gracePeriod else { return }

        // Cancel any in-progress fade animation
        fadeTask?.cancel()
        fadeTask = nil

        stopDismissMonitoring()

        // Restore gamma to ColorSync profile defaults
        CGDisplayRestoreColorSyncSettings()

        for window in windows {
            window.orderOut(nil)
        }
        windows.removeAll()

        // Also clear any individually blanked displays
        for (displayID, window) in perDisplayWindows {
            window.orderOut(nil)
            blankedDisplayIDs.remove(displayID)
        }
        perDisplayWindows.removeAll()

        NSCursor.unhide()
        isBlanking = false
        onDismiss?()
    }

    // MARK: - Per-Display Blank/Unblank

    /// Blanks a single display (zeros gamma + overlay window)
    func blankDisplay(_ displayID: CGDirectDisplayID) {
        guard !blankedDisplayIDs.contains(displayID) else { return }

        // Zero gamma for this display
        CGSetDisplayTransferByFormula(
            displayID,
            0, 0, 1,
            0, 0, 1,
            0, 0, 1
        )

        // Create overlay window on the matching screen
        if let screen = screenForDisplay(displayID) {
            let window = createBlankWindow(for: screen)
            perDisplayWindows[displayID] = window
            window.orderFrontRegardless()
        }

        blankedDisplayIDs.insert(displayID)
    }

    /// Unblanks a single display (restores gamma + removes overlay)
    func unblankDisplay(_ displayID: CGDirectDisplayID) {
        guard blankedDisplayIDs.contains(displayID) else { return }

        // Restore gamma via brightness callback
        let brightness = brightnessForDisplay?(displayID) ?? 1.0
        let gammaMax = Float(brightness)
        CGSetDisplayTransferByFormula(
            displayID,
            0, gammaMax, 1,
            0, gammaMax, 1,
            0, gammaMax, 1
        )

        // Remove overlay window
        if let window = perDisplayWindows.removeValue(forKey: displayID) {
            window.orderOut(nil)
        }

        blankedDisplayIDs.remove(displayID)
    }

    /// Returns whether a specific display is currently blanked
    func isDisplayBlanked(_ displayID: CGDirectDisplayID) -> Bool {
        blankedDisplayIDs.contains(displayID)
    }

    // MARK: - Fade Animation

    /// Animates gamma from current brightness to black over ~0.5s
    private func fadeToBlack() {
        fadeTask?.cancel()

        fadeTask = Task { @MainActor in
            let displayIDs = BrightnessManager.activeDisplayIDs()
            let steps = 30
            let totalDuration: UInt64 = 500_000_000 // 0.5 seconds in nanoseconds
            let stepDelay = totalDuration / UInt64(steps)

            // Read starting brightness per display
            var startBrightness: [CGDirectDisplayID: Double] = [:]
            for displayID in displayIDs {
                if CGDisplayIsBuiltin(displayID) != 0 {
                    startBrightness[displayID] = 1.0
                } else {
                    startBrightness[displayID] = brightnessForDisplay?(displayID) ?? 1.0
                }
            }

            for step in 1...steps {
                guard !Task.isCancelled else { return }

                let progress = Double(step) / Double(steps)

                for displayID in displayIDs {
                    let start = startBrightness[displayID] ?? 1.0
                    let current = start * (1.0 - progress)
                    let gammaMax = Float(max(current, 0))

                    CGSetDisplayTransferByFormula(
                        displayID,
                        0, gammaMax, 1,
                        0, gammaMax, 1,
                        0, gammaMax, 1
                    )
                }

                try? await Task.sleep(nanoseconds: stepDelay)
            }

            // Ensure final zero state and show overlay windows after fade
            guard !Task.isCancelled else { return }
            dimAllDisplays()
            showOverlayWindows()
        }
    }

    /// Sets gamma output to zero on all active displays
    private func dimAllDisplays() {
        for displayID in BrightnessManager.activeDisplayIDs() {
            // Setting min=0 and max=0 makes output always 0 (black) regardless of input
            CGSetDisplayTransferByFormula(
                displayID,
                0, 0, 1,  // red:   min, max, gamma
                0, 0, 1,  // green: min, max, gamma
                0, 0, 1   // blue:  min, max, gamma
            )
        }
    }

    // MARK: - Helpers

    /// Shows opaque black overlay windows on all screens
    private func showOverlayWindows() {
        for screen in NSScreen.screens {
            let window = createBlankWindow(for: screen)
            windows.append(window)
            window.orderFrontRegardless()
        }
    }

    private func screenForDisplay(_ displayID: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { screen in
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == displayID
        }
    }

    private func createBlankWindow(for screen: NSScreen) -> NSWindow {
        let window = NSWindow(
            contentRect: .zero,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.level = .screenSaver
        window.backgroundColor = .black
        window.isOpaque = true
        window.ignoresMouseEvents = false
        window.acceptsMouseMovedEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // Explicitly position the window to cover this screen's full frame
        window.setFrame(screen.frame, display: true)
        return window
    }

    private func startDismissMonitoring() {
        // Dismiss on any keyboard or mouse event
        let keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] _ in
            Task { @MainActor in
                self?.dismiss()
            }
        }
        if let keyMonitor { eventMonitors.append(keyMonitor) }

        let localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            Task { @MainActor in
                self?.dismiss()
            }
            return nil
        }
        if let localKeyMonitor { eventMonitors.append(localKeyMonitor) }

        let mouseClickEvents: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .scrollWheel]
        let mouseEvents: NSEvent.EventTypeMask = ignoreMouseMovement ? mouseClickEvents : mouseClickEvents.union(.mouseMoved)

        let mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: mouseEvents) { [weak self] _ in
            Task { @MainActor in
                self?.dismiss()
            }
        }
        if let mouseMonitor { eventMonitors.append(mouseMonitor) }

        let localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: mouseEvents) { [weak self] event in
            Task { @MainActor in
                self?.dismiss()
            }
            return event
        }
        if let localMouseMonitor { eventMonitors.append(localMouseMonitor) }
    }

    private func stopDismissMonitoring() {
        for monitor in eventMonitors {
            NSEvent.removeMonitor(monitor)
        }
        eventMonitors.removeAll()
    }
}

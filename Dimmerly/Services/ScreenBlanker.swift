//
//  ScreenBlanker.swift
//  Dimmerly
//
//  Blanks displays using a dual-layer approach: gamma table manipulation + overlay windows.
//  This provides an alternative to pmset displaysleepnow that doesn't trigger session lock.
//
//  Key advantages over pmset displaysleepnow:
//  - Works in App Store sandbox (no command-line tools needed)
//  - Doesn't trigger screen lock on macOS Sonoma+
//  - Works over fullscreen apps and system UI (gamma affects everything)
//  - Can dim the cursor (gamma affects hardware output)
//
//  Design: Dual-layer approach
//  1. Gamma tables: Set display output to zero via CGSetDisplayTransferByFormula
//  2. Overlay windows: Black fullscreen windows at .screenSaver level
//
//  Why both layers?
//  - Gamma alone: Works over everything, but leaves ghost cursor on some systems
//  - Overlay alone: Can be occluded by other .screenSaver level windows
//  - Combined: Bulletproof blanking that works in all scenarios
//

import AppKit

/// Manages screen blanking using gamma manipulation and overlay windows.
///
/// This class provides two blanking modes:
/// 1. **Full blanking**: All displays blank simultaneously (menu bar action, global shortcut)
/// 2. **Per-display blanking**: Individual displays can be blanked via moon button toggles
///
/// Dismissal behavior:
/// - **Default mode**: Any keyboard press or mouse click unblanks
/// - **Ignore mouse movement**: Only clicks and keys unblank (movement ignored)
/// - **Escape-only mode**: Only Escape key unblanks (all other input swallowed)
///
/// Fade transition:
/// - Optional smooth fade from current brightness to black over ~0.5 seconds
/// - Respects per-display brightness and warmth for natural fade-out
/// - Can be disabled for instant blanking (accessibility/reduced motion)
///
/// Thread safety: All methods must be called from the main actor.
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

    /// Closure to read per-display warmth (set by BrightnessManager)
    var warmthForDisplay: ((CGDirectDisplayID) -> Double)?

    /// Closure to read per-display contrast (set by BrightnessManager)
    var contrastForDisplay: ((CGDirectDisplayID) -> Double)?

    /// Closure to restore a display's full gamma table (set by BrightnessManager)
    var restoreDisplay: ((CGDirectDisplayID) -> Void)?

    /// Active fade animation task
    private var fadeTask: Task<Void, Never>?

    /// When true, only Escape dismisses blanking (all other input is ignored)
    var requireEscapeToDismiss = false

    /// True when per-display blanking has covered every screen and monitoring is active
    private var isPerDisplayFullBlanked = false

    // MARK: - Per-Display Blanking

    /// Set of individually blanked display IDs
    private(set) var blankedDisplayIDs: Set<CGDirectDisplayID> = []

    /// Per-display overlay windows for individual blanking
    private var perDisplayWindows: [CGDirectDisplayID: NSWindow] = [:]

    private init() {}

    /// Blanks all connected screens using gamma dimming and overlay windows
    func blank() {
        guard !isBlanking, !isPerDisplayFullBlanked else { return }
        isBlanking = true
        activationTime = ProcessInfo.processInfo.systemUptime

        NSCursor.hide()
        startDismissMonitoring(action: { [weak self] in self?.dismiss() })

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

        // Restore per-display gamma tables directly to avoid a brightness flash.
        // CGDisplayRestoreColorSyncSettings() resets all displays to native brightness,
        // causing a visible flash before BrightnessManager reapplies the user's gamma.
        // Instead, restore each display's gamma table individually via the callback.
        if let restoreDisplay {
            for displayID in BrightnessManager.activeDisplayIDs() {
                restoreDisplay(displayID)
            }
        } else {
            // Fallback if callback not set (shouldn't happen in normal operation)
            CGDisplayRestoreColorSyncSettings()
        }

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
        isPerDisplayFullBlanked = false
        onDismiss?()
    }

    // MARK: - Per-Display Blank/Unblank

    /// Blanks a single display (zeros gamma + overlay window).
    /// When all screens end up blanked, starts Escape-key monitoring for recovery.
    func blankDisplay(_ displayID: CGDirectDisplayID) {
        guard !blankedDisplayIDs.contains(displayID) else { return }

        // Zero gamma for this display
        CGSetDisplayTransferByFormula(
            displayID,
            0, 0, 1,
            0, 0, 1,
            0, 0, 1
        )

        blankedDisplayIDs.insert(displayID)

        // Create overlay window on the matching screen
        if let screen = screenForDisplay(displayID) {
            let window = createBlankWindow(for: screen)
            perDisplayWindows[displayID] = window
            window.orderFrontRegardless()

            // If every screen is now blanked, start dismiss monitoring
            if allExternalScreensBlanked {
                isPerDisplayFullBlanked = true
                activationTime = ProcessInfo.processInfo.systemUptime
                NSCursor.hide()
                if requireEscapeToDismiss {
                    addWakeHint(to: window, screen: screen)
                }
                startDismissMonitoring(action: { [weak self] in self?.unblankAllDisplays() })
            }
        }
    }

    /// Unblanks a single display (restores gamma + removes overlay)
    func unblankDisplay(_ displayID: CGDirectDisplayID) {
        guard blankedDisplayIDs.contains(displayID) else { return }

        // Clean up per-display full-blank monitoring if active
        if isPerDisplayFullBlanked {
            stopDismissMonitoring()
            NSCursor.unhide()
            isPerDisplayFullBlanked = false
        }

        // Restore full gamma table (brightness + warmth) via callback
        if let restoreDisplay {
            restoreDisplay(displayID)
        } else {
            // Fallback: restore brightness only via formula
            let brightness = brightnessForDisplay?(displayID) ?? 1.0
            let gammaMax = Float(brightness)
            CGSetDisplayTransferByFormula(
                displayID,
                0, gammaMax, 1,
                0, gammaMax, 1,
                0, gammaMax, 1
            )
        }

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
            let stepDelay = Duration.milliseconds(500 / steps)

            // Read starting brightness, warmth, and contrast per display
            var startBrightness: [CGDirectDisplayID: Double] = [:]
            var displayWarmth: [CGDirectDisplayID: Double] = [:]
            var displayContrast: [CGDirectDisplayID: Double] = [:]
            for displayID in displayIDs {
                if CGDisplayIsBuiltin(displayID) != 0 {
                    startBrightness[displayID] = 1.0
                    displayWarmth[displayID] = 0.0
                    displayContrast[displayID] = 0.5
                } else {
                    startBrightness[displayID] = brightnessForDisplay?(displayID) ?? 1.0
                    displayWarmth[displayID] = warmthForDisplay?(displayID) ?? 0.0
                    displayContrast[displayID] = contrastForDisplay?(displayID) ?? 0.5
                }
            }

            for step in 1 ... steps {
                guard !Task.isCancelled else { return }

                let progress = Double(step) / Double(steps)

                for displayID in displayIDs {
                    let start = startBrightness[displayID] ?? 1.0
                    let warmth = displayWarmth[displayID] ?? 0.0
                    let contrast = displayContrast[displayID] ?? 0.5
                    let current = start * (1.0 - progress)
                    let m = BrightnessManager.channelMultipliers(for: warmth)

                    var rTable = BrightnessManager.buildTable(
                        brightness: current, channelMultiplier: m.r, contrast: contrast
                    )
                    var gTable = BrightnessManager.buildTable(
                        brightness: current, channelMultiplier: m.g, contrast: contrast
                    )
                    var bTable = BrightnessManager.buildTable(
                        brightness: current, channelMultiplier: m.b, contrast: contrast
                    )

                    CGSetDisplayTransferByTable(displayID, 256, &rTable, &gTable, &bTable)
                }

                try? await Task.sleep(for: stepDelay)
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
                0, 0, 1, // red:   min, max, gamma
                0, 0, 1, // green: min, max, gamma
                0, 0, 1 // blue:  min, max, gamma
            )
        }
    }

    // MARK: - Helpers

    /// Shows opaque black overlay windows on all screens
    private func showOverlayWindows() {
        for screen in NSScreen.screens {
            let window = createBlankWindow(for: screen)
            if requireEscapeToDismiss {
                addWakeHint(to: window, screen: screen)
            }
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

    /// Adds a subtle "Press Esc to wake" hint near the bottom of the overlay window
    private func addWakeHint(to window: NSWindow, screen: NSScreen) {
        let hintText = NSLocalizedString(
            "Press Esc to wake",
            comment: "Hint shown on blanked single-display"
        )
        let label = NSTextField(labelWithString: hintText)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .white.withAlphaComponent(0.25)
        label.alignment = .center
        label.sizeToFit()

        let x = (screen.frame.width - label.frame.width) / 2
        let y: CGFloat = 40 // offset from bottom
        label.frame.origin = CGPoint(x: x, y: y)

        window.contentView?.addSubview(label)

        // Fade the hint out after 4 seconds
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            await NSAnimationContext.runAnimationGroup { context in
                context.duration = 1.0
                label.animator().alphaValue = 0
            }
        }
    }

    /// Whether every external display is currently per-display blanked
    private var allExternalScreensBlanked: Bool {
        let externalIDs = BrightnessManager.activeDisplayIDs().filter { CGDisplayIsBuiltin($0) == 0 }
        return !externalIDs.isEmpty && externalIDs.allSatisfy { blankedDisplayIDs.contains($0) }
    }

    /// Unblanks all per-display blanked screens (called when all screens were blanked via moon buttons)
    private func unblankAllDisplays() {
        guard isPerDisplayFullBlanked else { return }
        guard ProcessInfo.processInfo.systemUptime - activationTime >= gracePeriod else { return }

        let idsToUnblank = blankedDisplayIDs
        for displayID in idsToUnblank {
            unblankDisplay(displayID)
        }
        onDismiss?()
    }

    // MARK: - Dismiss Monitoring

    /// Starts dismiss monitoring, dispatching to Escape-only or any-input based on settings.
    /// The action closure is called when the user triggers a dismiss.
    private func startDismissMonitoring(action: @escaping @MainActor @Sendable () -> Void) {
        if requireEscapeToDismiss {
            startEscapeOnlyDismissMonitoring(action: action)
        } else {
            startAnyInputDismissMonitoring(action: action)
        }
    }

    /// Escape-only mode: only Escape key triggers the action.
    /// All other keyboard and mouse input is swallowed so the screen stays dark.
    private func startEscapeOnlyDismissMonitoring(action: @escaping @MainActor @Sendable () -> Void) {
        let escapeKeyCode: UInt16 = 53

        let keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { event in
            let keyCode = event.keyCode
            guard keyCode == escapeKeyCode else { return }
            Task { @MainActor in action() }
        }
        if let keyMonitor { eventMonitors.append(keyMonitor) }

        let localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            if event.keyCode == escapeKeyCode {
                Task { @MainActor in action() }
            }
            return nil
        }
        if let localKeyMonitor { eventMonitors.append(localKeyMonitor) }

        let swallowedEvents: NSEvent.EventTypeMask = [
            .leftMouseDown, .rightMouseDown, .scrollWheel, .mouseMoved,
        ]
        let localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: swallowedEvents) { _ in
            nil
        }
        if let localMouseMonitor { eventMonitors.append(localMouseMonitor) }
    }

    /// Default mode: any keyboard or mouse event triggers the action.
    private func startAnyInputDismissMonitoring(action: @escaping @MainActor @Sendable () -> Void) {
        let keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { _ in
            Task { @MainActor in action() }
        }
        if let keyMonitor { eventMonitors.append(keyMonitor) }

        let localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { _ in
            Task { @MainActor in action() }
            return nil
        }
        if let localKeyMonitor { eventMonitors.append(localKeyMonitor) }

        let mouseClickEvents: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown]
        let allMouseEvents: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .scrollWheel, .mouseMoved]
        let mouseEvents: NSEvent.EventTypeMask = ignoreMouseMovement ? mouseClickEvents : allMouseEvents

        let mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: mouseEvents) { _ in
            Task { @MainActor in action() }
        }
        if let mouseMonitor { eventMonitors.append(mouseMonitor) }

        let localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: mouseEvents) { event in
            Task { @MainActor in action() }
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

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
    private var isActive = false
    /// Timestamp when blanking activated; events before the grace period are ignored
    private var activationTime: TimeInterval = 0
    /// Grace period in seconds to ignore input after blanking
    private let gracePeriod: TimeInterval = 0.5

    private init() {}

    /// Blanks all connected screens using gamma dimming and overlay windows
    func blank() {
        guard !isActive else { return }
        isActive = true
        activationTime = ProcessInfo.processInfo.systemUptime

        // Zero out gamma on all displays — this dims everything including cursor
        // and works over fullscreen apps
        dimAllDisplays()

        // Overlay windows as a complementary layer
        for screen in NSScreen.screens {
            let window = createBlankWindow(for: screen)
            windows.append(window)
            window.orderFrontRegardless()
        }

        NSCursor.hide()
        startDismissMonitoring()
    }

    /// Dismisses blanking and restores normal display state
    func dismiss() {
        guard isActive else { return }
        // Ignore dismiss attempts during the grace period
        guard ProcessInfo.processInfo.systemUptime - activationTime >= gracePeriod else { return }

        stopDismissMonitoring()

        // Restore gamma to ColorSync profile defaults
        CGDisplayRestoreColorSyncSettings()

        for window in windows {
            window.orderOut(nil)
        }
        windows.removeAll()
        NSCursor.unhide()
        isActive = false
    }

    /// Sets gamma output to zero on all active displays
    private func dimAllDisplays() {
        var displayIDs = [CGDirectDisplayID](repeating: 0, count: 16)
        var displayCount: UInt32 = 0

        guard CGGetActiveDisplayList(UInt32(displayIDs.count), &displayIDs, &displayCount) == .success else {
            return
        }

        for i in 0..<Int(displayCount) {
            // Setting min=0 and max=0 makes output always 0 (black) regardless of input
            CGSetDisplayTransferByFormula(
                displayIDs[i],
                0, 0, 1,  // red:   min, max, gamma
                0, 0, 1,  // green: min, max, gamma
                0, 0, 1   // blue:  min, max, gamma
            )
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

        let mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .rightMouseDown, .scrollWheel]) { [weak self] _ in
            Task { @MainActor in
                self?.dismiss()
            }
        }
        if let mouseMonitor { eventMonitors.append(mouseMonitor) }

        let localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .rightMouseDown, .scrollWheel]) { [weak self] event in
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

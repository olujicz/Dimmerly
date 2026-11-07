//
//  MenuBarPanelHost.swift
//  Dimmerly
//

import AppKit
import OSLog
import SwiftUI

// MARK: - Public popover presentation

/// Presents the menu bar panel through public AppKit APIs when a system
/// `MenuBarExtra` cannot be opened programmatically.
@MainActor
final class MenuBarPanelPresenter: NSObject, NSPopoverDelegate {
    static let shared = MenuBarPanelPresenter()

    typealias ContentBuilder = @MainActor (UUID?) -> NSViewController

    /// Hosts the panel so the popover follows its height. The popover is sized when it opens;
    /// without this, content that grows while it's open, such as Auto Warmth's status line, pushes
    /// the footer out of the window.
    static func hostingController(for panel: some View) -> NSViewController {
        let controller = NSHostingController(rootView: panel)
        controller.sizingOptions = .preferredContentSize
        return controller
    }

    typealias AnchorProvider = @MainActor () -> (rect: NSRect, view: NSView)?
    typealias PopoverFactory = @MainActor () -> NSPopover

    private let anchorProvider: AnchorProvider?
    private let popoverFactory: PopoverFactory
    private let anchorWindow = StatusItemAnchorWindow()
    private weak var statusItem: NSStatusItem?
    private var contentBuilder: ContentBuilder?
    private var didDismiss: (@MainActor () -> Void)?
    private var popover: NSPopover?
    private var dismissalWasNotified = false

    var isPresented: Bool {
        popover?.isShown == true
    }

    init(
        anchorProvider: AnchorProvider? = nil,
        popoverFactory: @escaping PopoverFactory = { NSPopover() }
    ) {
        self.anchorProvider = anchorProvider
        self.popoverFactory = popoverFactory
        super.init()
    }

    func configure(
        statusItem: NSStatusItem?,
        contentBuilder: @escaping ContentBuilder,
        didDismiss: @escaping @MainActor () -> Void
    ) {
        self.statusItem = statusItem
        self.contentBuilder = contentBuilder
        self.didDismiss = didDismiss
    }

    func present(selectedPresetID: UUID?) {
        guard let anchor = presentationAnchor(), let contentBuilder else { return }

        if let popover, popover.isShown {
            popover.contentViewController = contentBuilder(selectedPresetID)
            return
        }

        let popover = popoverFactory()
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        // The popover takes its size from the controller's `preferredContentSize`, which
        // `hostingController(for:)` keeps current. The panel caps its own scroll height.
        popover.contentViewController = contentBuilder(selectedPresetID)
        self.popover = popover
        dismissalWasNotified = false

        // `show(relativeTo:of:preferredEdge:)` is public AppKit presentation and
        // does not depend on MenuBarExtra's private target/action implementation.
        // The panel opens below the anchor whichever way its view's y-axis runs.
        popover.show(relativeTo: anchor.rect, of: anchor.view, preferredEdge: anchor.view.isFlipped ? .maxY : .minY)
        // No expanded interface session runs for this popover, so the system doesn't
        // highlight the status item the way it does when the item is clicked.
        statusItem?.button?.highlight(true)
    }

    func dismiss() {
        guard let popover else {
            notifyDismissalIfNeeded()
            return
        }

        if popover.isShown {
            popover.performClose(nil)
        } else {
            finishDismissal(for: popover)
        }
    }

    func popoverDidClose(_ notification: Notification) {
        guard let closedPopover = notification.object as? NSPopover else { return }
        finishDismissal(for: closedPopover)
    }

    private func presentationAnchor() -> (rect: NSRect, view: NSView)? {
        if let anchorProvider {
            return anchorProvider()
        }

        guard let button = statusItem?.button else { return nil }
        return anchorWindow.anchor(over: button)
    }

    private func finishDismissal(for popover: NSPopover) {
        guard self.popover === popover else { return }
        self.popover = nil
        anchorWindow.hide()
        statusItem?.button?.highlight(false)
        notifyDismissalIfNeeded()
    }

    private func notifyDismissalIfNeeded() {
        guard !dismissalWasNotified else { return }
        dismissalWasNotified = true
        didDismiss?()
    }
}

/// A transparent, click-through window laid over the status item for the panel's popover
/// to point at. On macOS 27, a popover anchored to the status item's own button also makes
/// SwiftUI open the `MenuBarExtra` window, so the panel appeared twice.
@MainActor
final class StatusItemAnchorWindow {
    private var window: NSPanel?

    /// Moves the window over `button` and shows it. Nil when the button isn't in a window.
    func anchor(over button: NSView) -> (rect: NSRect, view: NSView)? {
        guard let buttonWindow = button.window else { return nil }
        let window = window ?? makeWindow()
        self.window = window
        window.setFrame(buttonWindow.convertToScreen(button.convert(button.bounds, to: nil)), display: false)
        window.orderFrontRegardless()
        guard let view = window.contentView else { return nil }
        return (view.bounds, view)
    }

    func hide() {
        window?.orderOut(nil)
    }

    private func makeWindow() -> NSPanel {
        let window = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .statusBar
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        return window
    }
}

// MARK: - Status Item Reachability

/// Whether people can see the status item, so a panel opened from it would show up.
///
/// The item can be hidden: on macOS 26 and later people can turn off "Allow in the Menu Bar"
/// in System Settings > Menu Bar, and on a Mac with a camera housing items that don't fit
/// beside the app's menus sit behind it. A panel anchored to a hidden item opens off screen
/// or not at all, so callers open Settings instead.
@MainActor
enum StatusItemReachability {
    /// A screen's frame and the part of its top edge the camera housing covers, if any.
    struct Screen: Equatable {
        var frame: NSRect
        var cameraHousing: NSRect?

        init(frame: NSRect, cameraHousing: NSRect? = nil) {
            self.frame = frame
            self.cameraHousing = cameraHousing
        }

        init(_ screen: NSScreen) {
            frame = screen.frame
            // The unobscured areas either side of the housing; their widths are the same
            // whichever coordinate space AppKit reports them in.
            if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
                let minX = screen.frame.minX + left.width
                let maxX = screen.frame.maxX - right.width
                let height = max(left.height, right.height)
                cameraHousing = maxX > minX
                    ? NSRect(x: minX, y: screen.frame.maxY - height, width: maxX - minX, height: height)
                    : nil
            } else {
                cameraHousing = nil
            }
        }
    }

    static func isReachable(_ statusItem: NSStatusItem?) -> Bool {
        guard let statusItem, let button = statusItem.button, let window = button.window else {
            return false
        }
        let buttonFrame = window.convertToScreen(button.convert(button.bounds, to: nil))
        let reachable = isReachable(
            isVisible: statusItem.isVisible && window.isVisible,
            buttonFrame: buttonFrame,
            screens: NSScreen.screens.map(Screen.init)
        )
        statusItemReachabilityLogger.debug(
            """
            Status item reachable: \(reachable), visible: \(statusItem.isVisible), \
            window visible: \(window.isVisible), frame: \(String(describing: buttonFrame), privacy: .public)
            """
        )
        return reachable
    }

    /// The item is reachable when it's shown, its centre is on a screen, and it isn't behind
    /// that screen's camera housing.
    static func isReachable(isVisible: Bool, buttonFrame: NSRect, screens: [Screen]) -> Bool {
        guard isVisible, !buttonFrame.isEmpty else { return false }
        let center = NSPoint(x: buttonFrame.midX, y: buttonFrame.midY)
        guard let screen = screens.first(where: { $0.frame.contains(center) }) else { return false }
        if let cameraHousing = screen.cameraHousing, cameraHousing.contains(center) {
            return false
        }
        return true
    }
}

private let statusItemReachabilityLogger = Logger(
    subsystem: "rs.in.olujic.dimmerly",
    category: "StatusItemReachability"
)

// MARK: - Scroll Style

final class MenuBarPanelScrollStyleConfiguratorView: NSView {
    /// Set once the SwiftUI-created `NSScrollView` has been found and styled. Guards
    /// `scheduleApply` against restarting its retry chain on every subsequent SwiftUI
    /// update — `updateNSView` calls `scheduleApply()` with its default `attemptsRemaining`
    /// on every body re-evaluation (dozens per second while dragging a slider), and without
    /// this flag each of those would kick off a fresh 8-step `DispatchQueue.main.async` chain.
    private var hasAppliedStyle = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        scheduleApply()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        scheduleApply()
    }

    func scheduleApply(attemptsRemaining: Int = 8) {
        guard !hasAppliedStyle else { return }

        applyStyleWhenReady()

        guard !hasAppliedStyle, attemptsRemaining > 0 else { return }

        DispatchQueue.main.async { [weak self] in
            self?.scheduleApply(attemptsRemaining: attemptsRemaining - 1)
        }
    }

    private func applyStyleWhenReady() {
        guard let scrollView = nearestScrollView() else {
            return
        }

        MenuBarPanelScrollStyle.apply(to: scrollView)
        hasAppliedStyle = true
    }

    private func nearestScrollView() -> NSScrollView? {
        if let enclosingScrollView {
            return enclosingScrollView
        }

        var view = superview
        while let currentView = view {
            if let scrollView = currentView as? NSScrollView {
                return scrollView
            }
            view = currentView.superview
        }

        return nil
    }
}

/// Configures the panel's host window using the public `NSView.window` path.
/// This works for both SwiftUI's MenuBarExtra window and the fallback popover.
final class MenuBarPanelWindowConfiguratorView: NSView {
    private var hasConfiguredWindow = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        scheduleConfigure()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        scheduleConfigure()
    }

    func scheduleConfigure(attemptsRemaining: Int = 8) {
        guard !hasConfiguredWindow else { return }

        guard let window else {
            guard attemptsRemaining > 0 else { return }
            DispatchQueue.main.async { [weak self] in
                self?.scheduleConfigure(attemptsRemaining: attemptsRemaining - 1)
            }
            return
        }

        MenuBarPanelHostGlass.configureWindow(window)
        hasConfiguredWindow = true
    }
}

private struct MenuBarPanelWindowConfigurator: NSViewRepresentable {
    func makeNSView(context _: Context) -> NSView {
        MenuBarPanelWindowConfiguratorView()
    }

    func updateNSView(_ nsView: NSView, context _: Context) {
        (nsView as? MenuBarPanelWindowConfiguratorView)?.scheduleConfigure()
    }
}

private struct MenuBarPanelScrollStyleConfigurator: NSViewRepresentable {
    func makeNSView(context _: Context) -> NSView {
        MenuBarPanelScrollStyleConfiguratorView()
    }

    func updateNSView(_ nsView: NSView, context _: Context) {
        (nsView as? MenuBarPanelScrollStyleConfiguratorView)?.scheduleApply()
    }
}

extension View {
    func menuBarPanelScrollStyle() -> some View {
        background(MenuBarPanelScrollStyleConfigurator())
    }

    /// Applies the panel background for the running OS. See `MenuBarPanelBackground`.
    ///
    /// With `.systemGlass` the content is returned untouched: the `MenuBarExtra`
    /// window's default container background and `NSPopover`'s own background are
    /// already Liquid Glass, so drawing a material here would stack glass on glass.
    @ViewBuilder
    func menuBarPanelBackground(_ background: MenuBarPanelBackground = .current) -> some View {
        switch background {
        case .systemGlass:
            self
        case .visualEffectMaterial:
            menuBarPanelHostGlass()
                .menuBarPanelChrome()
        }
    }
}

private extension View {
    /// Let `MenuBarExtra` draw the only rounded window chrome.
    func menuBarPanelChrome() -> some View {
        containerBackground(.clear, for: .window)
    }
}

// MARK: - Host Glass Configuration

/// Fallback glass window styling shared by the system MenuBarExtra and the public
/// AppKit popover. Only used for `MenuBarPanelBackground.visualEffectMaterial`.
@MainActor
enum MenuBarPanelHostGlass {
    static let glassIdentifier = NSUserInterfaceItemIdentifier("DimmerlyMenuBarPanelGlass")

    /// One-time window setup: transparency and the rounded glass effect view.
    static func configureWindow(_ window: NSWindow) {
        guard let contentView = window.contentView else { return }

        if MenuBarPanelGlassStyle.clearsHostWindowBackground {
            window.isOpaque = false
            window.backgroundColor = .clear
        }

        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = NSColor.clear.cgColor

        clearContentBackgrounds(in: contentView)
    }

    /// Re-clears layer backgrounds that SwiftUI adds as the content view hierarchy changes
    /// (hover highlights, expanding adjustments, etc.), so the glass effect stays visible.
    static func refreshContentBackgrounds(in window: NSWindow) {
        guard let contentView = window.contentView else { return }
        clearContentBackgrounds(in: contentView)
    }

    private static func clearContentBackgrounds(in view: NSView) {
        if MenuBarPanelGlassBackgroundPolicy.shouldClearLayerBackground(
            for: view,
            glassIdentifier: glassIdentifier
        ) {
            view.wantsLayer = true
            view.layer?.backgroundColor = NSColor.clear.cgColor
        }

        guard MenuBarPanelGlassBackgroundPolicy.shouldVisitSubviews(
            of: view,
            glassIdentifier: glassIdentifier
        ) else {
            return
        }

        for subview in view.subviews {
            clearContentBackgrounds(in: subview)
        }
    }
}

/// Backing view for `MenuBarPanelHostRefreshConfigurator`. Coalesces repeated
/// `updateNSView` calls (SwiftUI fires one on every body re-evaluation — dozens per
/// second while dragging a brightness slider) into at most one actual hierarchy walk
/// per run-loop turn, instead of re-walking the full content view tree on every single call.
///
/// Internal (not `private`) so tests can exercise the coalescing behavior directly,
/// matching `MenuBarPanelScrollStyleConfiguratorView`'s testing approach.
final class MenuBarPanelHostRefreshConfiguratorView: NSView {
    private var isRefreshScheduled = false

    /// Number of times the hierarchy walk has actually run. Test-only observability into
    /// the coalescing behavior; unused in production beyond incrementing.
    private(set) var refreshCount = 0

    func scheduleRefresh() {
        guard !isRefreshScheduled else { return }
        isRefreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            isRefreshScheduled = false
            refreshCount += 1
            guard let window else { return }
            MenuBarPanelHostGlass.refreshContentBackgrounds(in: window)
        }
    }
}

/// Re-applies glass background clearing as SwiftUI's content view hierarchy changes.
private struct MenuBarPanelHostRefreshConfigurator: NSViewRepresentable {
    func makeNSView(context _: Context) -> NSView {
        MenuBarPanelHostRefreshConfiguratorView()
    }

    func updateNSView(_ nsView: NSView, context _: Context) {
        (nsView as? MenuBarPanelHostRefreshConfiguratorView)?.scheduleRefresh()
    }
}

/// Vends the glass material as part of the SwiftUI content. AppKit does not support
/// adding an `NSVisualEffectView` as a subview of `NSHostingController.view`, so the
/// material is inserted through an `NSViewRepresentable` instead of being injected
/// into the host window's content view.
@MainActor
enum MenuBarPanelGlassBackgroundView {
    static func makeEffectView() -> NSVisualEffectView {
        let effectView = NSVisualEffectView()
        effectView.identifier = MenuBarPanelHostGlass.glassIdentifier
        effectView.material = MenuBarPanelGlassStyle.windowMaterial
        effectView.blendingMode = MenuBarPanelGlassStyle.blendingMode
        effectView.state = MenuBarPanelGlassStyle.state
        effectView.isEmphasized = true
        effectView.wantsLayer = true
        effectView.layer?.cornerRadius = MenuBarPanelGlassStyle.cornerRadius
        effectView.layer?.cornerCurve = .continuous
        effectView.layer?.masksToBounds = true
        return effectView
    }
}

private struct MenuBarPanelGlassBackground: NSViewRepresentable {
    func makeNSView(context _: Context) -> NSVisualEffectView {
        MenuBarPanelGlassBackgroundView.makeEffectView()
    }

    func updateNSView(_ nsView: NSVisualEffectView, context _: Context) {
        nsView.material = MenuBarPanelGlassStyle.windowMaterial
        nsView.blendingMode = MenuBarPanelGlassStyle.blendingMode
        nsView.state = MenuBarPanelGlassStyle.state
    }
}

private extension View {
    /// Fallback material for macOS 15 through 25 (`.visualEffectMaterial`).
    func menuBarPanelHostGlass() -> some View {
        background(MenuBarPanelGlassBackground())
            .background(MenuBarPanelWindowConfigurator())
            .background(MenuBarPanelHostRefreshConfigurator())
    }
}

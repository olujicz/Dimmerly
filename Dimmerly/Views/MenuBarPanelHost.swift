//
//  MenuBarPanelHost.swift
//  Dimmerly
//

import AppKit
import SwiftUI

// MARK: - Public popover presentation

/// Presents the menu bar panel through public AppKit APIs when a system
/// `MenuBarExtra` cannot be opened programmatically.
@MainActor
final class MenuBarPanelPresenter: NSObject, NSPopoverDelegate {
    static let shared = MenuBarPanelPresenter()

    typealias ContentBuilder = @MainActor (UUID?) -> NSViewController
    typealias AnchorProvider = @MainActor () -> (rect: NSRect, view: NSView)?
    typealias PopoverFactory = @MainActor () -> NSPopover

    private let anchorProvider: AnchorProvider?
    private let popoverFactory: PopoverFactory
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
            popover.contentSize = contentSize(for: popover.contentViewController)
            return
        }

        let popover = popoverFactory()
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentViewController = contentBuilder(selectedPresetID)
        popover.contentSize = contentSize(for: popover.contentViewController)
        self.popover = popover
        dismissalWasNotified = false

        // `show(relativeTo:of:preferredEdge:)` is public AppKit presentation and
        // does not depend on MenuBarExtra's private target/action implementation.
        popover.show(relativeTo: anchor.rect, of: anchor.view, preferredEdge: .maxY)
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

    private func contentSize(for viewController: NSViewController?) -> NSSize {
        guard let viewController else { return NSSize(width: 300, height: 480) }

        viewController.view.layoutSubtreeIfNeeded()
        let fittingSize = viewController.view.fittingSize
        let height = fittingSize.height.isFinite && fittingSize.height > 0
            ? min(max(fittingSize.height, 200), 640)
            : 480
        return NSSize(width: 300, height: height)
    }

    private func presentationAnchor() -> (rect: NSRect, view: NSView)? {
        if let anchorProvider {
            return anchorProvider()
        }

        guard let button = statusItem?.button else { return nil }
        return (button.bounds, button)
    }

    private func finishDismissal(for popover: NSPopover) {
        guard self.popover === popover else { return }
        self.popover = nil
        notifyDismissalIfNeeded()
    }

    private func notifyDismissalIfNeeded() {
        guard !dismissalWasNotified else { return }
        dismissalWasNotified = true
        didDismiss?()
    }
}

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

    /// Let `MenuBarExtra` draw the only rounded window chrome.
    func menuBarPanelChrome() -> some View {
        containerBackground(.clear, for: .window)
    }
}

// MARK: - Host Glass Configuration

/// Glass window styling shared by the system MenuBarExtra and the public AppKit popover.
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

extension View {
    func menuBarPanelHostGlass() -> some View {
        background(MenuBarPanelGlassBackground())
            .background(MenuBarPanelWindowConfigurator())
            .background(MenuBarPanelHostRefreshConfigurator())
    }
}

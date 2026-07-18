//
//  MenuBarPanelHost.swift
//  Dimmerly
//

import AppKit
import SwiftUI

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

/// Glass window styling, driven by `MenuBarExtraAccess`'s `introspectMenuBarExtraWindow`
/// instead of a hand-rolled `viewDidMoveToWindow`/`viewDidMoveToSuperview` polling `NSView`.
@MainActor
enum MenuBarPanelHostGlass {
    private static let glassIdentifier = NSUserInterfaceItemIdentifier("DimmerlyMenuBarPanelGlass")

    /// One-time window setup: transparency and the rounded glass effect view.
    static func configureWindow(_ window: NSWindow) {
        guard let contentView = window.contentView else { return }

        if MenuBarPanelGlassStyle.clearsHostWindowBackground {
            window.isOpaque = false
            window.backgroundColor = .clear
        }

        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = NSColor.clear.cgColor

        let effectView = existingGlassEffectView(in: contentView) ?? makeGlassEffectView(in: contentView)
        effectView.material = MenuBarPanelGlassStyle.windowMaterial
        effectView.blendingMode = MenuBarPanelGlassStyle.blendingMode
        effectView.state = MenuBarPanelGlassStyle.state
        effectView.isEmphasized = true

        clearContentBackgrounds(in: contentView)
    }

    /// Re-clears layer backgrounds that SwiftUI adds as the content view hierarchy changes
    /// (hover highlights, expanding adjustments, etc.), so the glass effect stays visible.
    static func refreshContentBackgrounds(in window: NSWindow) {
        guard let contentView = window.contentView else { return }
        clearContentBackgrounds(in: contentView)
    }

    private static func existingGlassEffectView(in contentView: NSView) -> NSVisualEffectView? {
        contentView.subviews
            .compactMap { $0 as? NSVisualEffectView }
            .first { $0.identifier == glassIdentifier }
    }

    private static func makeGlassEffectView(in contentView: NSView) -> NSVisualEffectView {
        let effectView = NSVisualEffectView()
        effectView.identifier = glassIdentifier
        effectView.translatesAutoresizingMaskIntoConstraints = false
        effectView.wantsLayer = true
        effectView.layer?.cornerRadius = MenuBarPanelGlassStyle.cornerRadius
        effectView.layer?.cornerCurve = .continuous
        effectView.layer?.masksToBounds = true

        contentView.addSubview(effectView, positioned: .below, relativeTo: contentView.subviews.first)

        NSLayoutConstraint.activate([
            effectView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            effectView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            effectView.topAnchor.constraint(equalTo: contentView.topAnchor),
            effectView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])

        return effectView
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
/// Window-level setup (transparency, effect view) happens once via `introspectMenuBarExtraWindow`.
private struct MenuBarPanelHostRefreshConfigurator: NSViewRepresentable {
    func makeNSView(context _: Context) -> NSView {
        MenuBarPanelHostRefreshConfiguratorView()
    }

    func updateNSView(_ nsView: NSView, context _: Context) {
        (nsView as? MenuBarPanelHostRefreshConfiguratorView)?.scheduleRefresh()
    }
}

extension View {
    func menuBarPanelHostGlass() -> some View {
        background(MenuBarPanelHostRefreshConfigurator())
            .introspectMenuBarExtraWindow { window in
                MenuBarPanelHostGlass.configureWindow(window)
            }
    }
}

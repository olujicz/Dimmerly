//
//  MenuBarPanelTests.swift
//  DimmerlyTests
//
//  Unit tests for menu bar panel interaction helpers.
//

import AppKit
@testable import Dimmerly
import SwiftUI
import XCTest

final class MenuBarPanelTests: XCTestCase {
    func testMenuBarPanelChromeClearsWindowContainerWithoutManualPerimeterStroke() throws {
        let viewsURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Dimmerly/Views")
        let source = try ["MenuBarPanel.swift", "MenuBarPanelHost.swift"]
            .map { try String(contentsOf: viewsURL.appendingPathComponent($0), encoding: .utf8) }
            .joined(separator: "\n")

        XCTAssertTrue(source.contains(".menuBarPanelChrome()"))
        XCTAssertTrue(source.contains("containerBackground(.clear, for: .window)"))
        XCTAssertFalse(source.contains(".stroke(.separator.opacity(0.45), lineWidth: 0.75)"))
    }

    func testMenuBarPanelGlassStyleUsesSingleMenuMaterialLayer() {
        XCTAssertEqual(MenuBarPanelGlassStyle.windowMaterial, .menu)
        XCTAssertEqual(MenuBarPanelGlassStyle.blendingMode, .behindWindow)
        XCTAssertEqual(MenuBarPanelGlassStyle.state, .active)
        XCTAssertTrue(MenuBarPanelGlassStyle.clearsHostWindowBackground)
    }

    @MainActor
    func testGlassBackgroundPolicyClearsContainerViews() {
        let glassIdentifier = NSUserInterfaceItemIdentifier("DimmerlyMenuBarPanelGlass")
        let container = NSView()
        let clipView = NSClipView()

        XCTAssertTrue(
            MenuBarPanelGlassBackgroundPolicy.shouldClearLayerBackground(
                for: container,
                glassIdentifier: glassIdentifier
            )
        )
        XCTAssertTrue(
            MenuBarPanelGlassBackgroundPolicy.shouldClearLayerBackground(
                for: clipView,
                glassIdentifier: glassIdentifier
            )
        )
    }

    @MainActor
    func testGlassBackgroundPolicyPreservesScrollViewsControlsAndGlassEffectView() {
        let glassIdentifier = NSUserInterfaceItemIdentifier("DimmerlyMenuBarPanelGlass")
        let scrollView = NSScrollView()
        let button = NSButton(title: "Turn Displays Off", target: nil, action: nil)
        let slider = NSSlider(value: 0.5, minValue: 0, maxValue: 1, target: nil, action: nil)
        let effectView = NSVisualEffectView()
        effectView.identifier = glassIdentifier

        for view in [scrollView, button, slider, effectView] {
            XCTAssertFalse(
                MenuBarPanelGlassBackgroundPolicy.shouldClearLayerBackground(
                    for: view,
                    glassIdentifier: glassIdentifier
                )
            )
            XCTAssertFalse(
                MenuBarPanelGlassBackgroundPolicy.shouldVisitSubviews(
                    of: view,
                    glassIdentifier: glassIdentifier
                )
            )
        }
    }

    @MainActor
    func testScrollStyleUsesSubtleAutohidingOverlayScroller() {
        let scrollView = NSScrollView()
        scrollView.scrollerStyle = .legacy
        scrollView.autohidesScrollers = false
        scrollView.verticalScroller = NSScroller()
        scrollView.verticalScroller?.controlSize = .regular

        MenuBarPanelScrollStyle.apply(to: scrollView)

        XCTAssertEqual(scrollView.scrollerStyle, .overlay)
        XCTAssertTrue(scrollView.autohidesScrollers)
        XCTAssertEqual(scrollView.verticalScroller?.controlSize, .small)
    }

    @MainActor
    func testScrollStyleConfiguratorScheduleAppliesWhenAttachedInsideScrollView() {
        let scrollView = NSScrollView()
        scrollView.scrollerStyle = .legacy
        scrollView.autohidesScrollers = false
        scrollView.verticalScroller = NSScroller()
        scrollView.verticalScroller?.controlSize = .regular

        let configuratorView = MenuBarPanelScrollStyleConfiguratorView()
        scrollView.addSubview(configuratorView)

        configuratorView.scheduleApply()
        drainMainRunLoop()

        XCTAssertTrue(scrollView.autohidesScrollers)
        XCTAssertEqual(scrollView.verticalScroller?.controlSize, .small)
    }

    @MainActor
    func testScrollStyleConfiguratorDoesNotReapplyAfterFirstSuccess() {
        // Regression test: `updateNSView` calls `scheduleApply()` with its default
        // `attemptsRemaining` on every SwiftUI body re-evaluation (dozens per second while
        // dragging a slider). Once the scroll view has been found and styled, further calls
        // must be no-ops instead of each restarting an 8-step async retry chain.
        let scrollView = NSScrollView()
        scrollView.scrollerStyle = .legacy
        scrollView.autohidesScrollers = false
        scrollView.verticalScroller = NSScroller()
        scrollView.verticalScroller?.controlSize = .regular

        let configuratorView = MenuBarPanelScrollStyleConfiguratorView()
        scrollView.addSubview(configuratorView)

        configuratorView.scheduleApply()
        drainMainRunLoop()
        XCTAssertTrue(scrollView.autohidesScrollers)

        // Revert the scroll view's style externally, then call scheduleApply() again —
        // simulating another SwiftUI re-render after the style was already applied once.
        scrollView.autohidesScrollers = false
        scrollView.verticalScroller?.controlSize = .regular
        configuratorView.scheduleApply()
        drainMainRunLoop()

        XCTAssertFalse(
            scrollView.autohidesScrollers,
            "Once already styled, scheduleApply() must not re-walk and reapply"
        )
        XCTAssertEqual(scrollView.verticalScroller?.controlSize, .regular)
    }

    func testSliderSyncGateSuppressesProgrammaticChangeOnce() {
        var gate = SliderSyncGate()

        gate.markProgrammaticSync()

        XCTAssertFalse(gate.shouldPropagateChange())
        XCTAssertTrue(gate.shouldPropagateChange())
    }

    func testSliderSyncGateAllowsUserChangeWithoutProgrammaticSync() {
        var gate = SliderSyncGate()

        XCTAssertTrue(gate.shouldPropagateChange())
    }

    #if !APPSTORE
        @MainActor
        func testDDCControlsAreHiddenWhenHardwareManagerIsDisabled() {
            let displayID: CGDirectDisplayID = 42
            let manager = HardwareBrightnessManager(forTesting: true)
            manager.capabilities[displayID] = HardwareDisplayCapability(
                displayID: displayID,
                supportsDDC: true,
                supportedCodes: [.brightness, .volume, .audioMute, .inputSource],
                maxBrightness: 100,
                maxContrast: 100,
                maxVolume: 100
            )

            let row = DisplayBrightnessRow(
                display: ExternalDisplay(id: displayID, name: "External", brightness: 0.6),
                isBlanked: false,
                onChange: { _ in },
                onWarmthChange: { _ in },
                onContrastChange: { _ in },
                onToggleBlank: {}
            )
            let wired = row.ddcControls(hardwareManager: manager, displayID: displayID)

            XCTAssertFalse(wired.hasDDC)
            XCTAssertNil(wired.onVolumeChange)
            XCTAssertNil(wired.onMuteToggle)
            XCTAssertNil(wired.onInputSourceChange)
        }
    #endif

    func testMainShortcutRecorderRequestsFirstResponderWhenRecording() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Dimmerly/Views/KeyboardShortcutRecorder.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(
            source.contains("window?.makeFirstResponder(self)"),
            "Main shortcut recording should make its capture view first responder when recording starts"
        )
    }

    @MainActor
    private func drainMainRunLoop(iterations: Int = 12) {
        for _ in 0 ..< iterations {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
    }

    // MARK: - Host Glass Configuration

    @MainActor
    func testConfigureWindowInsertsSingleGlassEffectView() {
        let window = Self.makeTestWindow()

        MenuBarPanelHostGlass.configureWindow(window)

        XCTAssertFalse(window.isOpaque)
        XCTAssertEqual(window.backgroundColor, .clear)

        let effectViews = window.contentView?.subviews.compactMap { $0 as? NSVisualEffectView } ?? []
        XCTAssertEqual(effectViews.count, 1)
        XCTAssertEqual(effectViews.first?.material, MenuBarPanelGlassStyle.windowMaterial)
        XCTAssertEqual(effectViews.first?.blendingMode, MenuBarPanelGlassStyle.blendingMode)
        XCTAssertEqual(effectViews.first?.state, MenuBarPanelGlassStyle.state)
    }

    @MainActor
    func testConfigureWindowIsIdempotent() {
        let window = Self.makeTestWindow()

        MenuBarPanelHostGlass.configureWindow(window)
        MenuBarPanelHostGlass.configureWindow(window)

        let effectViews = window.contentView?.subviews.compactMap { $0 as? NSVisualEffectView } ?? []
        XCTAssertEqual(effectViews.count, 1)
    }

    @MainActor
    func testRefreshContentBackgroundsClearsNewlyAddedContainerViews() {
        let window = Self.makeTestWindow()
        MenuBarPanelHostGlass.configureWindow(window)

        let newContainer = NSView()
        newContainer.wantsLayer = true
        newContainer.layer?.backgroundColor = NSColor.white.cgColor
        window.contentView?.addSubview(newContainer)

        MenuBarPanelHostGlass.refreshContentBackgrounds(in: window)

        XCTAssertEqual(newContainer.layer?.backgroundColor, NSColor.clear.cgColor)
    }

    @MainActor
    func testHostRefreshConfiguratorCoalescesRapidScheduleRefreshCalls() {
        // Regression test: `updateNSView` calls `scheduleRefresh()` on every SwiftUI body
        // re-evaluation (dozens per second while dragging a slider). These must coalesce
        // into a single actual hierarchy walk per run-loop turn, not one walk per call.
        let window = Self.makeTestWindow()
        let configuratorView = MenuBarPanelHostRefreshConfiguratorView()
        window.contentView?.addSubview(configuratorView)

        for _ in 0 ..< 20 {
            configuratorView.scheduleRefresh()
        }

        drainMainRunLoop()

        XCTAssertEqual(configuratorView.refreshCount, 1)
    }

    @MainActor
    private static func makeTestWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        return window
    }

    // MARK: - Close Panel Environment Action

    @MainActor
    func testCloseMenuBarPanelEnvironmentDefaultIsNoOp() {
        // Should not crash when no environment override has been set.
        EnvironmentValues().closeMenuBarPanel()
    }
}

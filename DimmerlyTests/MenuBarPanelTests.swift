//
//  MenuBarPanelTests.swift
//  DimmerlyTests
//
//  Unit tests for menu bar panel interaction helpers.
//

import AppKit
@testable import Dimmerly
import XCTest

final class MenuBarPanelTests: XCTestCase {
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

        XCTAssertEqual(scrollView.scrollerStyle, .overlay)
        XCTAssertTrue(scrollView.autohidesScrollers)
        XCTAssertEqual(scrollView.verticalScroller?.controlSize, .small)
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

    @MainActor
    private func drainMainRunLoop(iterations: Int = 12) {
        for _ in 0 ..< iterations {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
    }
}

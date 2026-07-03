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
    func testMenuBarPanelChromeClearsWindowContainerWithoutManualPerimeterStroke() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Dimmerly/Views/MenuBarPanel.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

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
            manager.isEnabled = false
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
            source.contains("nsView.window?.makeFirstResponder(nsView)"),
            "Main shortcut recording should make its capture view first responder when recording starts"
        )
    }

    @MainActor
    private func drainMainRunLoop(iterations: Int = 12) {
        for _ in 0 ..< iterations {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
    }
}

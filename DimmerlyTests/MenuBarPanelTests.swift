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

@MainActor
private final class MenuPresentationWindowSpy: NSWindow {
    private(set) var didClose = false

    override func close() {
        didClose = true
    }
}

@MainActor
private final class ClosePanelSpy {
    private(set) var callCount = 0

    func close() {
        callCount += 1
    }
}

@MainActor
private final class PopoverSpy: NSPopover {
    private(set) var didShow = false
    private(set) var presentedRect: NSRect?
    private weak var presentedView: NSView?

    override func show(relativeTo positioningRect: NSRect, of positioningView: NSView, preferredEdge _: NSRectEdge) {
        didShow = true
        presentedRect = positioningRect
        presentedView = positioningView
    }

    func isPresented(relativeTo rect: NSRect, of view: NSView) -> Bool {
        didShow && presentedRect == rect && presentedView === view
    }
}

final class MenuBarPanelTests: XCTestCase {
    func testAutoTemperatureBadgeUsesAdaptiveHighContrastTreatment() throws {
        let repositoryURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = repositoryURL.appendingPathComponent("Dimmerly/Views/MenuBarDisplayControls.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("Text(\"Auto\")"))
        XCTAssertTrue(source.contains(".fontWeight(.semibold)"))
        XCTAssertTrue(source.contains(".foregroundStyle(.primary)"))
        XCTAssertTrue(source.contains("Capsule().fill(.orange.opacity(0.16))"))
        XCTAssertTrue(source.contains("Capsule().stroke(.orange, lineWidth: 0.75)"))
    }

    #if !APPSTORE
        func testInputSourceMenuMarksOnlyTheActiveSource() {
            let active = InputSourceMenuItemPresentation.forSource(.hdmi1, active: .hdmi1)
            let inactive = InputSourceMenuItemPresentation.forSource(.displayPort1, active: .hdmi1)

            XCTAssertEqual(active.title, "HDMI 1")
            XCTAssertEqual(active.systemImageName, "checkmark")
            XCTAssertEqual(inactive.title, "DisplayPort 1")
            XCTAssertNil(inactive.systemImageName)
        }
    #endif

    @MainActor
    func testCloseMenuBarPanelEnvironmentRoundTripsItsAction() {
        let spy = ClosePanelSpy()
        var values = EnvironmentValues()
        values.closeMenuBarPanel = { spy.close() }

        values.closeMenuBarPanel()

        XCTAssertEqual(spy.callCount, 1)
    }

    @MainActor
    func testMenuBarPanelCoordinatorPresentsAndSelectsPreset() {
        let coordinator = MenuBarPanelCoordinator()
        let presetID = UUID()
        var didActivateApp = false

        coordinator.openPreset(
            id: presetID,
            presentationPath: .menuBarExtra,
            activateApp: { didActivateApp = true }
        )

        XCTAssertTrue(coordinator.isPresented)
        XCTAssertEqual(coordinator.requestedPresetID, presetID)
        XCTAssertTrue(didActivateApp)

        coordinator.dismiss()

        XCTAssertFalse(coordinator.isPresented)
        XCTAssertNil(coordinator.requestedPresetID)
    }

    @MainActor
    func testPublicPopoverPresentationDoesNotUseMenuBarExtraBinding() {
        let coordinator = MenuBarPanelCoordinator()
        let presetID = UUID()
        var presentedPresetID: UUID?
        var dismissed = false

        coordinator.configureExternalPresentation(
            present: { presentedPresetID = $0 },
            dismiss: { dismissed = true }
        )
        coordinator.openPreset(
            id: presetID,
            presentationPath: .publicPopover,
            activateApp: {}
        )

        XCTAssertFalse(coordinator.isPresented)
        XCTAssertTrue(coordinator.isExternalPresentationActive)
        XCTAssertEqual(presentedPresetID, presetID)

        coordinator.dismiss()

        XCTAssertTrue(dismissed)
        XCTAssertFalse(coordinator.isExternalPresentationActive)
        XCTAssertNil(coordinator.requestedPresetID)
    }

    @MainActor
    func testMenuBarPanelPresenterUsesPublicPopoverWithAppKitAnchor() {
        let button = NSButton(frame: NSRect(x: 100, y: 20, width: 40, height: 24))
        let popover = PopoverSpy()
        let presenter = MenuBarPanelPresenter(
            anchorProvider: {
                (button.bounds, button)
            },
            popoverFactory: { popover }
        )
        defer {
            presenter.dismiss()
        }

        var contentBuildCount = 0
        presenter.configure(
            statusItem: nil,
            contentBuilder: { _ in
                contentBuildCount += 1
                return NSViewController()
            },
            didDismiss: {}
        )

        presenter.present(selectedPresetID: UUID())

        XCTAssertEqual(contentBuildCount, 1)
        XCTAssertTrue(popover.isPresented(relativeTo: button.bounds, of: button))
    }

    @MainActor
    func testGlassBackgroundPolicyPreservesSwiftUISliderBackingViews() {
        let glassIdentifier = NSUserInterfaceItemIdentifier("DimmerlyMenuBarPanelGlass")
        let sliderBackingView = NSView()
        sliderBackingView.setAccessibilityRole(.slider)

        XCTAssertFalse(
            MenuBarPanelGlassBackgroundPolicy.shouldClearLayerBackground(
                for: sliderBackingView,
                glassIdentifier: glassIdentifier
            )
        )
        XCTAssertFalse(
            MenuBarPanelGlassBackgroundPolicy.shouldVisitSubviews(
                of: sliderBackingView,
                glassIdentifier: glassIdentifier
            )
        )
    }

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
    func testConfigureWindowDoesNotInjectEffectViewIntoHostingContentView() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 400),
            styleMask: [.borderless],
            backing: .buffered,
            defer: true
        )
        let hostingContentView = NSView()
        window.contentView = hostingContentView

        MenuBarPanelHostGlass.configureWindow(window)

        let injectedEffectViews = hostingContentView.subviews.compactMap { $0 as? NSVisualEffectView }
        XCTAssertTrue(
            injectedEffectViews.isEmpty,
            "Adding NSVisualEffectView to NSHostingController.view is unsupported by AppKit"
        )
    }

    @MainActor
    func testGlassBackgroundViewUsesConfiguredMenuMaterial() {
        let effectView = MenuBarPanelGlassBackgroundView.makeEffectView()

        XCTAssertEqual(effectView.material, MenuBarPanelGlassStyle.windowMaterial)
        XCTAssertEqual(effectView.blendingMode, MenuBarPanelGlassStyle.blendingMode)
        XCTAssertEqual(effectView.state, MenuBarPanelGlassStyle.state)
        XCTAssertEqual(effectView.layer?.cornerRadius, MenuBarPanelGlassStyle.cornerRadius)
    }

    func testFooterButtonsOwnHoverStateRatherThanTheirLabel() throws {
        let viewsURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Dimmerly/Views")
        let panel = try String(
            contentsOf: viewsURL.appendingPathComponent("MenuBarPanel.swift"),
            encoding: .utf8
        )
        let presetControls = try String(
            contentsOf: viewsURL.appendingPathComponent("MenuBarPresetControls.swift"),
            encoding: .utf8
        )

        // A SwiftUI Button consumes pointer events before its label, so `.onHover`
        // inside `FooterLabel` never fires. The Button must own the hover state.
        // Scoped to FooterLabel: preset rows in this same file use .onHover correctly.
        let footerLabelStart = try XCTUnwrap(presetControls.range(of: "struct FooterLabel"))
        let footerLabelSource = String(presetControls[footerLabelStart.lowerBound...])
        XCTAssertFalse(
            footerLabelSource.contains(".onHover"),
            "FooterLabel must not attach .onHover inside a Button label"
        )
        XCTAssertTrue(
            panel.contains("isSettingsHovered"),
            "Footer Settings button must own its hover state"
        )
        XCTAssertTrue(
            panel.contains("isQuitHovered"),
            "Footer Quit button must own its hover state"
        )
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

    func testBrightnessSnapUsesCommonAnchorsWithinTolerance() {
        XCTAssertEqual(DisplaySliderSnap.brightness(0.73), 0.75, accuracy: 0.0001)
        XCTAssertEqual(DisplaySliderSnap.brightness(0.98), 1.0, accuracy: 0.0001)
    }

    func testBrightnessSnapPreservesValuesAwayFromAnchors() {
        XCTAssertEqual(DisplaySliderSnap.brightness(0.70), 0.70, accuracy: 0.0001)
    }

    func testWarmthSnapUsesKelvinAnchors() {
        let nearWarmAnchor = GammaMath.warmthForKelvin(4_520)

        XCTAssertEqual(
            DisplaySliderSnap.warmth(nearWarmAnchor),
            GammaMath.warmthForKelvin(4_500),
            accuracy: 0.0001
        )
    }

    func testContrastSnapCentersOnNeutralValue() {
        XCTAssertEqual(DisplaySliderSnap.contrast(0.52), 0.5, accuracy: 0.0001)
        XCTAssertEqual(DisplaySliderSnap.contrast(0.56), 0.56, accuracy: 0.0001)
    }

    func testVolumeSnapUsesQuarterSteps() {
        XCTAssertEqual(DisplaySliderSnap.volume(0.74), 0.75, accuracy: 0.0001)
        XCTAssertEqual(DisplaySliderSnap.volume(0.69), 0.69, accuracy: 0.0001)
    }

    func testSnapMarkerPositionsMatchSliderRanges() {
        XCTAssertEqual(DisplaySliderSnap.brightnessMarkerPositions.count, 3)
        XCTAssertEqual(DisplaySliderSnap.brightnessMarkerPositions[0], 1.0 / 6.0, accuracy: 0.0001)
        XCTAssertEqual(DisplaySliderSnap.brightnessMarkerPositions[1], 4.0 / 9.0, accuracy: 0.0001)
        XCTAssertEqual(DisplaySliderSnap.brightnessMarkerPositions[2], 13.0 / 18.0, accuracy: 0.0001)

        XCTAssertEqual(
            DisplaySliderSnap.warmthMarkerPositions,
            [
                GammaMath.warmthForKelvin(4500),
                GammaMath.warmthForKelvin(3500),
                GammaMath.warmthForKelvin(2700),
            ]
        )
        XCTAssertEqual(DisplaySliderSnap.contrastMarkerPositions, [0.5])
        XCTAssertEqual(DisplaySliderSnap.volumeMarkerPositions, [0.25, 0.5, 0.75])
    }

    private func menuBarDisplayControlsSource() throws -> String {
        let repositoryURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = repositoryURL.appendingPathComponent("Dimmerly/Views/MenuBarDisplayControls.swift")
        return try String(contentsOf: sourceURL, encoding: .utf8)
    }

    func testDisplaySlidersUseDecorativeSnapMarkerLayers() throws {
        let source = try menuBarDisplayControlsSource()

        XCTAssertTrue(source.contains("markerPositions: DisplaySliderSnap.brightnessMarkerPositions"))
        XCTAssertTrue(source.contains("markerPositions: DisplaySliderSnap.warmthMarkerPositions"))
        XCTAssertTrue(source.contains("markerPositions: DisplaySliderSnap.contrastMarkerPositions"))
        XCTAssertTrue(source.contains("markerPositions: DisplaySliderSnap.volumeMarkerPositions"))
        XCTAssertTrue(source.contains(".accessibilityHidden(true)"))
    }

    /// The native track is opaque, so the shared marker layer must overlay its slider.
    func testSnapMarkerLayersOverlayTheSliderRatherThanSitBehindIt() throws {
        let lines = try menuBarDisplayControlsSource().components(separatedBy: .newlines)
        let markerLines = lines.indices.filter { lines[$0].contains("SliderSnapMarkerLayer(") }

        XCTAssertEqual(markerLines.count, 1)

        for index in markerLines {
            XCTAssertEqual(
                lines[index - 1].trimmingCharacters(in: .whitespaces),
                ".overlay {",
                "marker layer on line \(index + 1) must overlay its slider, not sit behind it"
            )
        }
    }

    /// A `step:` argument makes AppKit draw its own tick marks under the track, which both
    /// changes the native slider appearance and swamps the decorative markers.
    func testDisplaySlidersStayContinuousSoAppKitDrawsNoTickMarks() throws {
        XCTAssertFalse(try menuBarDisplayControlsSource().contains("step:"))
    }

    @MainActor
    func testSnapMinimumBrightnessMatchesBrightnessManager() {
        XCTAssertEqual(
            DisplaySliderSnap.minimumBrightness,
            BrightnessManager.minimumBrightness,
            accuracy: 0.0001
        )
    }

    func testBrightnessPositionNormalisesAgainstTheMinimumBackedTrack() {
        XCTAssertEqual(DisplaySliderSnap.brightnessPosition(for: 0.10), 0.0, accuracy: 0.0001)
        XCTAssertEqual(DisplaySliderSnap.brightnessPosition(for: 0.55), 0.5, accuracy: 0.0001)
        XCTAssertEqual(DisplaySliderSnap.brightnessPosition(for: 1.0), 1.0, accuracy: 0.0001)
    }

    func testMarkerIsHiddenOnlyWhileTheKnobCoversIt() {
        // 200pt of travel, 10pt knob radius: markers within 5% of the knob are covered.
        XCTAssertFalse(
            DisplaySliderSnap.markerIsClearOfKnob(
                marker: 0.5,
                knob: 0.52,
                trackWidth: 200,
                knobRadius: 10
            )
        )
        XCTAssertTrue(
            DisplaySliderSnap.markerIsClearOfKnob(
                marker: 0.5,
                knob: 0.75,
                trackWidth: 200,
                knobRadius: 10
            )
        )
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
    func testConfigureWindowMakesHostWindowTransparent() {
        let window = Self.makeTestWindow()

        MenuBarPanelHostGlass.configureWindow(window)

        XCTAssertFalse(window.isOpaque)
        XCTAssertEqual(window.backgroundColor, .clear)
    }

    @MainActor
    func testConfigureWindowIsIdempotent() {
        let window = Self.makeTestWindow()

        MenuBarPanelHostGlass.configureWindow(window)
        MenuBarPanelHostGlass.configureWindow(window)

        XCTAssertFalse(window.isOpaque)
        XCTAssertEqual(window.backgroundColor, .clear)

        let effectViews = window.contentView?.subviews.compactMap { $0 as? NSVisualEffectView } ?? []
        XCTAssertTrue(effectViews.isEmpty)
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
    func testDisplayActionClosesMenuBeforeRunningOnNextMainActorTurn() async {
        var events: [String] = []
        let actionPerformed = expectation(description: "Display action performed")
        let presentationWindow = MenuPresentationWindowSpy(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        MenuBarDisplayAction.performAfterDismissal(
            presentationWindow: presentationWindow,
            closePresentation: { events.append("close") },
            action: {
                events.append("action")
                actionPerformed.fulfill()
            }
        )

        XCTAssertEqual(events, ["close"])
        XCTAssertTrue(presentationWindow.didClose)
        await fulfillment(of: [actionPerformed], timeout: 1)
        XCTAssertEqual(events, ["close", "action"])
    }

    @MainActor
    func testCloseMenuBarPanelEnvironmentDefaultIsNoOp() {
        // Should not crash when no environment override has been set.
        EnvironmentValues().closeMenuBarPanel()
    }
}

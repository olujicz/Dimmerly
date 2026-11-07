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
    @MainActor
    func testExternalModelUpdateCancelsPendingSliderSnap() async throws {
        let settleTask = DisplaySliderSettleTask()
        defer { settleTask.cancel() }
        var value = 0.26
        var propagatedValues: [Double] = []
        var syncGate = SliderSyncGate()
        settleTask.schedule(isDragging: false) {
            value = DisplaySliderSnap.brightness(value)
            if syncGate.shouldPropagateChange() {
                propagatedValues.append(value)
            }
        }

        settleTask.synchronize(value: value, modelValue: 0.48) { modelValue in
            syncGate.markProgrammaticSync()
            value = modelValue
        }
        XCTAssertFalse(syncGate.shouldPropagateChange())

        try await Task.sleep(for: DisplaySliderSnap.settleDelay + .milliseconds(150))

        XCTAssertEqual(value, 0.48, accuracy: 0.00001)
        XCTAssertTrue(propagatedValues.isEmpty)
    }

    @MainActor
    func testModelChangeDuringDragDoesNotMoveTheSlider() {
        let settleTask = DisplaySliderSettleTask()
        var value = 0.30
        var applied: [Double] = []

        settleTask.synchronize(value: value, modelValue: 0.80, isDragging: true) { modelValue in
            applied.append(modelValue)
            value = modelValue
        }

        XCTAssertEqual(value, 0.30)
        XCTAssertTrue(applied.isEmpty)

        settleTask.synchronize(value: value, modelValue: 0.80, isDragging: false) { modelValue in
            applied.append(modelValue)
            value = modelValue
        }

        XCTAssertEqual(applied, [0.80])
    }

    @MainActor
    func testReleaseWritesBackOnlyWhenTheModelDriftedDuringTheDrag() {
        XCTAssertTrue(DisplaySliderSettleTask.needsWriteBackAfterDrag(value: 0.30, modelValue: 0.80))
        XCTAssertFalse(DisplaySliderSettleTask.needsWriteBackAfterDrag(value: 0.30, modelValue: 0.3001))
        XCTAssertFalse(DisplaySliderSettleTask.needsWriteBackAfterDrag(value: 0.30, modelValue: nil))
    }

    @MainActor
    func testOwnModelEchoPreservesPendingSliderSnap() async {
        let settleTask = DisplaySliderSettleTask()
        defer { settleTask.cancel() }
        var value = 0.26
        let settled = expectation(description: "Keyboard edit settles after its model echo")
        settleTask.schedule(isDragging: false) {
            value = DisplaySliderSnap.brightness(value)
            settled.fulfill()
        }

        settleTask.synchronize(value: value, modelValue: value) { _ in
            XCTFail("An unchanged model echo should not synchronize the slider")
        }

        await fulfillment(of: [settled], timeout: 2)
        XCTAssertEqual(value, 0.25, accuracy: 0.00001)
    }

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

    /// On macOS 27 the open `MenuBarExtra` window closes through its expanded interface
    /// session, so the binding is left for MenuBarExtraAccess to clear and it sends no click.
    @MainActor
    func testDismissEndsTheSystemPanelSessionInsteadOfClearingTheBinding() {
        let coordinator = MenuBarPanelCoordinator()
        var endedSessions = 0
        coordinator.configureSystemPanelSession {
            endedSessions += 1
            return true
        }
        coordinator.openPreset(id: UUID(), presentationPath: .menuBarExtra, activateApp: {})

        coordinator.dismiss()

        XCTAssertEqual(endedSessions, 1)
        XCTAssertTrue(coordinator.isPresented)
        XCTAssertNil(coordinator.requestedPresetID)
    }

    @MainActor
    func testDismissClearsTheBindingWithoutASystemPanelSession() {
        let coordinator = MenuBarPanelCoordinator()
        coordinator.configureSystemPanelSession { false }
        coordinator.openPreset(id: UUID(), presentationPath: .menuBarExtra, activateApp: {})

        coordinator.dismiss()

        XCTAssertFalse(coordinator.isPresented)
    }

    @MainActor
    func testDismissLeavesTheSystemPanelSessionAloneWhileTheWindowIsClosed() {
        let coordinator = MenuBarPanelCoordinator()
        var endedSessions = 0
        coordinator.configureSystemPanelSession {
            endedSessions += 1
            return true
        }

        coordinator.dismiss()

        XCTAssertEqual(endedSessions, 0)
        XCTAssertFalse(coordinator.isPresented)
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
    func testOpenPanelPresentsWithoutSelectingAPreset() {
        let coordinator = MenuBarPanelCoordinator()
        coordinator.requestedPresetID = UUID()
        var didActivateApp = false

        coordinator.openPanel(presentationPath: .menuBarExtra, activateApp: { didActivateApp = true })

        XCTAssertTrue(coordinator.isPresented)
        XCTAssertNil(coordinator.requestedPresetID)
        XCTAssertTrue(didActivateApp)
    }

    @MainActor
    func testPopoverRequestedBeforeHostIsConfiguredPresentsOnceConfigured() {
        let coordinator = MenuBarPanelCoordinator()
        var presentations: [UUID?] = []

        coordinator.openPanel(presentationPath: .publicPopover, activateApp: {})
        XCTAssertTrue(presentations.isEmpty)

        coordinator.configureExternalPresentation(
            present: { presentations.append($0) },
            dismiss: {}
        )

        XCTAssertEqual(presentations, [nil])
        XCTAssertTrue(coordinator.isExternalPresentationActive)
    }

    @MainActor
    func testWidgetOpenURLIsRecognized() throws {
        XCTAssertTrue(try DimmerlyURL.opensPanel(XCTUnwrap(URL(string: "dimmerly://open"))))
        XCTAssertTrue(try DimmerlyURL.opensPanel(XCTUnwrap(URL(string: "Dimmerly://OPEN"))))
        XCTAssertFalse(try DimmerlyURL.opensPanel(XCTUnwrap(URL(string: "dimmerly://preset"))))
        XCTAssertFalse(try DimmerlyURL.opensPanel(XCTUnwrap(URL(string: "https://open"))))
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

    /// On macOS 27 a popover anchored to the status item's own button also opens the
    /// `MenuBarExtra` window, so the panel points at a window laid over the button instead.
    @MainActor
    func testStatusItemAnchorWindowCoversButtonWithoutUsingIt() throws {
        let buttonWindow = NSWindow(
            contentRect: NSRect(x: 200, y: 300, width: 120, height: 40),
            styleMask: [.borderless], backing: .buffered, defer: true
        )
        buttonWindow.isReleasedWhenClosed = false
        let button = NSButton(frame: NSRect(x: 10, y: 5, width: 35, height: 24))
        buttonWindow.contentView?.addSubview(button)
        let anchorWindow = StatusItemAnchorWindow()
        defer { anchorWindow.hide() }

        let anchor = try XCTUnwrap(anchorWindow.anchor(over: button))

        let overlay = try XCTUnwrap(anchor.view.window)
        XCTAssertFalse(overlay === buttonWindow)
        XCTAssertEqual(overlay.frame, buttonWindow.convertToScreen(button.convert(button.bounds, to: nil)))
        XCTAssertEqual(anchor.rect, anchor.view.bounds)
        XCTAssertTrue(overlay.ignoresMouseEvents)
        XCTAssertTrue(overlay.isVisible)

        anchorWindow.hide()
        XCTAssertFalse(overlay.isVisible)
    }

    @MainActor
    func testStatusItemAnchorWindowNeedsAButtonOnScreen() {
        XCTAssertNil(StatusItemAnchorWindow().anchor(over: NSButton()))
    }

    /// The `MenuBarExtra` window and the popover supply the system material on every macOS
    /// version, so the panel draws no background, clears no window, and walks no view tree.
    func testPanelLeavesItsBackgroundToTheSystem() throws {
        let source = try ["MenuBarPanel.swift", "MenuBarPanelHost.swift"]
            .map { try Self.repositorySource("Dimmerly/Views/\($0)") }
            .joined(separator: "\n")

        XCTAssertFalse(source.contains("NSVisualEffectView"))
        XCTAssertFalse(source.contains("containerBackground("))
        XCTAssertFalse(source.contains("layer?.backgroundColor"))
        XCTAssertFalse(source.contains(".stroke(.separator.opacity(0.45), lineWidth: 0.75)"))
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

        @MainActor
        func testNativeBrightnessIndicatorRequiresExperimentalOptIn() {
            let displayID: CGDirectDisplayID = 42
            let manager = HardwareBrightnessManager(forTesting: true)
            manager.enable()
            let row = DisplayBrightnessRow(
                display: ExternalDisplay(id: displayID, name: "External", brightness: 0.6),
                isBlanked: false,
                onChange: { _ in },
                onWarmthChange: { _ in },
                onContrastChange: { _ in },
                onToggleBlank: {}
            )

            let optedOut = row.ddcControls(
                hardwareManager: manager,
                displayID: displayID,
                supportsNativeBacklight: true
            )
            manager.applyRuntimeSettings(
                controlMode: .hardware,
                pollingInterval: 5,
                writeDelayMilliseconds: 50,
                experimentalNativeBrightnessEnabled: true
            )
            let optedIn = row.ddcControls(
                hardwareManager: manager,
                displayID: displayID,
                supportsNativeBacklight: true
            )

            XCTAssertFalse(optedOut.hasNativeBacklight)
            XCTAssertTrue(optedIn.hasNativeBacklight)
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

// MARK: - Control Availability

@MainActor
extension MenuBarPanelTests {
    /// AppKit offers key equivalents to the window before the focused text field sees the
    /// keystroke, so bare Return must not turn displays off while a preset is being named.
    func testTurnOffReturnShortcutIsDroppedWhileNamingAPreset() {
        XCTAssertEqual(
            MenuBarPanel.turnOffShortcut(isAddingPreset: false),
            KeyboardShortcut(.return, modifiers: [])
        )
        XCTAssertNil(MenuBarPanel.turnOffShortcut(isAddingPreset: true))
    }

    #if !APPSTORE
        /// A monitor can report VCP volume without VCP mute. The row then has a volume
        /// slider but no mute action, so the speaker must not be a button that does nothing.
        func testVolumeWithoutMuteSupportShowsSpeakerIconInsteadOfMuteButton() throws {
            let displayID: CGDirectDisplayID = 42
            let manager = HardwareBrightnessManager(forTesting: true)
            manager.enable()
            manager.capabilities[displayID] = HardwareDisplayCapability(
                displayID: displayID,
                supportsDDC: true,
                supportedCodes: [.brightness, .volume],
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

            XCTAssertTrue(wired.hasDDC)
            XCTAssertNotNil(wired.onVolumeChange)
            XCTAssertNil(wired.onMuteToggle)

            let source = try menuBarDisplayControlsSource()
            XCTAssertTrue(
                source.contains("if let onMuteToggle {"),
                "The mute Button must only be built when a mute action exists"
            )
            XCTAssertFalse(
                source.contains("onMuteToggle?()"),
                "An optional-chained mute call means the Button can be shown without an action"
            )
        }
    #endif
}

// MARK: - Panel and Preset Row Interactions

extension MenuBarPanelTests {
    func testPanelPresetDeleteUsesTheSettingsConfirmationWording() {
        let confirmation = ConfirmationAlert.deletePreset(named: "Evening")

        XCTAssertEqual(confirmation.title, "Delete Preset?")
        XCTAssertEqual(confirmation.message, "\"Evening\" will be permanently deleted.")
        XCTAssertEqual(confirmation.confirmButtonTitle, "Delete")
        XCTAssertTrue(confirmation.isDestructive)
    }

    func testPanelPresetOverwriteAsksBeforeReplacingSavedSettings() {
        let confirmation = ConfirmationAlert.updatePreset(named: "Evening")

        XCTAssertEqual(confirmation.title, "Update \"Evening\"?")
        XCTAssertEqual(confirmation.confirmButtonTitle, "Update")
        XCTAssertFalse(confirmation.isDestructive)
    }

    func testPanelPresetContextMenuConfirmsBeforeChangingAPreset() throws {
        let source = try Self.repositorySource("Dimmerly/Views/MenuBarPresetControls.swift")

        XCTAssertTrue(source.contains("confirm(.updatePreset(named: preset.name))"))
        XCTAssertTrue(source.contains("confirm(.deletePreset(named: preset.name))"))
        XCTAssertTrue(source.contains("AlertPresenter.confirm(confirmation)"))
    }

    /// The preset recorder in Settings offers a visible clear button, not only a context menu.
    func testPresetShortcutRecorderHasVisibleClearButton() throws {
        let source = try Self.repositorySource("Dimmerly/Views/PresetManagementRow.swift")

        XCTAssertTrue(source.contains("Image(systemName: \"xmark.circle.fill\")"))
        XCTAssertTrue(source.contains(".accessibilityLabel(Text(\"Clear Shortcut for \\(presetName)\"))"))
        XCTAssertTrue(source.contains(".accessibilityHidden(shortcut == nil)"))
    }

    #if !APPSTORE
        func testInputSourceSwitchConfirmationNamesDisplayAndInput() {
            let confirmation = ConfirmationAlert.switchInputSource(displayName: "Studio", sourceName: "HDMI 2")

            XCTAssertEqual(confirmation.title, "Switch Studio to HDMI 2?")
            XCTAssertTrue(confirmation.message.contains("\"No Signal\""))
            XCTAssertEqual(confirmation.confirmButtonTitle, "Switch")
        }

        /// The menu is a Picker so VoiceOver hears which input is selected, and it shows the
        /// active input until a switch is confirmed. Reselecting it asks nothing.
        @MainActor
        func testInputSourceMenuSelectsTheActiveInput() throws {
            var switched: [InputSource] = []
            var row = DisplayBrightnessRow(
                display: ExternalDisplay(id: 42, name: "External", brightness: 0.6),
                isBlanked: false,
                onChange: { _ in },
                onWarmthChange: { _ in },
                onContrastChange: { _ in },
                onToggleBlank: {}
            )
            row.activeInputSource = .hdmi1
            row.availableInputSources = [.hdmi1, .displayPort1]
            row.onInputSourceChange = { switched.append($0) }

            let selection = row.inputSourceSelection
            XCTAssertEqual(selection.wrappedValue, .hdmi1)
            selection.wrappedValue = .hdmi1
            selection.wrappedValue = nil
            XCTAssertEqual(switched, [])

            let source = try Self.repositorySource("Dimmerly/Views/MenuBarDisplayControls.swift")
            XCTAssertTrue(source.contains("Picker(selection: inputSourceSelection)"))
            XCTAssertTrue(source.contains(".tag(Optional(source))"))
            XCTAssertTrue(source.contains("AlertPresenter.confirm(confirmation)"))
        }
    #endif

    /// Disabled controls draw their own dimmed state; only the decoration beside them fades.
    func testBlankedDisplayControlsAreDimmedOnce() throws {
        let source = try Self.repositorySource("Dimmerly/Views/MenuBarDisplayControls.swift")

        XCTAssertFalse(source.contains(".opacity(isBlanked ?"))
        XCTAssertTrue(source.contains(".disabled(isBlanked)"))
        XCTAssertTrue(source.contains(".dimmedWhenDisabled()"))
    }

    func testHintsAndRowButtonsKeepReadableContrast() throws {
        let presetControls = try Self.repositorySource("Dimmerly/Views/MenuBarPresetControls.swift")
        XCTAssertFalse(presetControls.contains(".foregroundStyle(.quaternary)"))

        for path in ["Dimmerly/Views/PresetManagementRow.swift", "Dimmerly/Views/ScheduleViews.swift"] {
            let source = try Self.repositorySource(path)
            XCTAssertFalse(source.contains("? 1 : 0.3)"), "\(path) fades a row button until hover")
        }
    }

    func testPresetRenameSavesOnlyANewNonBlankName() {
        XCTAssertEqual(PresetManagementRow.renamedName(from: "  Night  ", current: "Evening"), "Night")
        XCTAssertNil(PresetManagementRow.renamedName(from: "   ", current: "Evening"))
        XCTAssertNil(PresetManagementRow.renamedName(from: "Evening ", current: "Evening"))
    }

    func testPresetRenameFieldFocusesSubmitsAndCancels() throws {
        let source = try Self.repositorySource("Dimmerly/Views/PresetManagementRow.swift")

        XCTAssertFalse(source.contains("onCommit:"))
        XCTAssertTrue(source.contains(".focused($isNameFieldFocused)"))
        XCTAssertTrue(source.contains(".onSubmit(commitRename)"))
        XCTAssertTrue(source.contains(".onExitCommand(perform: cancelRename)"))
    }

    static func repositorySource(_ relativePath: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }
}

// MARK: - Wording and order

extension MenuBarPanelTests {
    func testFooterUsesTheQuickActionsMenuWording() throws {
        let viewsURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Dimmerly/Views")
        let panel = try String(contentsOf: viewsURL.appendingPathComponent("MenuBarPanel.swift"), encoding: .utf8)
        let shortcutsTab = try String(
            contentsOf: viewsURL.appendingPathComponent("SettingsShortcutsTab.swift"),
            encoding: .utf8
        )

        // Same titles as `StatusItemQuickActions.makeQuickActionsMenu`.
        XCTAssertTrue(panel.contains("FooterLabel(\"Settings…\""))
        XCTAssertTrue(panel.contains("FooterLabel(\"Quit Dimmerly\""))
        // The main shortcut row names the action exactly as the panel and menu do.
        XCTAssertTrue(shortcutsTab.contains("Text(StatusItemQuickActions.turnOffTitle(settings: settings))"))
        XCTAssertFalse(shortcutsTab.contains("Sleep Displays"))
    }

    func testDisplayContextMenuListsBrightnessFromBrightestToMinimum() throws {
        let source = try menuBarDisplayControlsSource()
        let titles = ["Set to 100%", "Set to 75%", "Set to 50%", "Set to 25%", "Set to Minimum"]
        let offsets = try titles.map { title in
            try XCTUnwrap(source.range(of: "Button(\"\(title)\")"), "missing \(title)").lowerBound
        }

        XCTAssertEqual(offsets, offsets.sorted())
    }

    func testBrightnessPercentUsesLocaleAwareFormatting() throws {
        XCTAssertTrue(try menuBarDisplayControlsSource().contains("Text(Int(sliderValue * 100), format: .percent)"))
    }
}

/// The hosting controller behind the menu-bar panel's popover.
final class MenuBarPanelHostingTests: XCTestCase {
    /// The popover is sized once, when it opens, so the panel's controller has to report later
    /// height changes or growing content (Auto Warmth's status line) clips the footer.
    @MainActor
    func testPanelHostingControllerReportsItsHeightAsItChanges() throws {
        final class Content: ObservableObject {
            @Published var isTall = false
        }
        struct Panel: View {
            @ObservedObject var content: Content
            var body: some View {
                Color.clear.frame(width: 300, height: content.isTall ? 260 : 200)
            }
        }
        let content = Content()
        let controller = MenuBarPanelPresenter.hostingController(for: Panel(content: content))
        let hosting = try XCTUnwrap(controller as? NSHostingController<Panel>)
        XCTAssertTrue(hosting.sizingOptions.contains(.preferredContentSize))

        controller.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(controller.preferredContentSize.height, 200, accuracy: 0.5)
        content.isTall = true
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        controller.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(controller.preferredContentSize.height, 260, accuracy: 0.5)
    }
}

/// Popover presentation of the panel on macOS 27.
final class MenuBarPanelPresenterTests: XCTestCase {
    /// The popover follows the hosting controller's `preferredContentSize`; nothing sizes it by hand.
    @MainActor
    func testPresenterSizesThePopoverFromThePanelsPreferredContentSize() {
        let window = NSWindow(
            contentRect: NSRect(x: 200, y: 200, width: 200, height: 100),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        let button = NSButton(frame: NSRect(x: 80, y: 40, width: 40, height: 24))
        window.contentView?.addSubview(button)
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        let popover = NSPopover()
        popover.animates = false
        let presenter = MenuBarPanelPresenter(anchorProvider: { (button.bounds, button) }, popoverFactory: { popover })
        defer { presenter.dismiss() }
        presenter.configure(
            statusItem: nil,
            contentBuilder: { _ in
                MenuBarPanelPresenter.hostingController(for: Color.clear.frame(width: 300, height: 260))
            },
            didDismiss: {}
        )

        presenter.present(selectedPresetID: nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        XCTAssertTrue(popover.isShown)
        XCTAssertEqual(popover.contentSize.width, 300, accuracy: 0.5)
        XCTAssertEqual(popover.contentSize.height, 260, accuracy: 0.5)
    }

    /// On macOS 27 no expanded interface session runs for the popover, so the presenter
    /// highlights the status item itself while the panel is open.
    @MainActor
    func testPresenterHighlightsTheStatusItemWhileThePanelIsOpen() throws {
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        defer { NSStatusBar.system.removeStatusItem(statusItem) }
        let button = try XCTUnwrap(statusItem.button)
        let anchor = NSButton(frame: NSRect(x: 0, y: 0, width: 40, height: 24))
        let popover = PopoverSpy()
        let presenter = MenuBarPanelPresenter(anchorProvider: { (anchor.bounds, anchor) }, popoverFactory: { popover })
        presenter.configure(statusItem: statusItem, contentBuilder: { _ in NSViewController() }, didDismiss: {})

        presenter.present(selectedPresetID: nil)
        XCTAssertTrue(button.isHighlighted)

        presenter.popoverDidClose(Notification(name: NSPopover.didCloseNotification, object: popover))
        XCTAssertFalse(button.isHighlighted)
    }
}

/// Opening the panel while the status item is hidden.
final class HiddenStatusItemTests: XCTestCase {
    @MainActor
    func testStatusItemOnScreenIsReachable() {
        let screen = StatusItemReachability.Screen(frame: NSRect(x: 0, y: 0, width: 1920, height: 1080))
        XCTAssertTrue(StatusItemReachability.isReachable(
            isVisible: true,
            buttonFrame: NSRect(x: 1500, y: 1056, width: 30, height: 24),
            screens: [screen]
        ))
    }

    @MainActor
    func testHiddenOrOffScreenStatusItemIsNotReachable() {
        let screen = StatusItemReachability.Screen(frame: NSRect(x: 0, y: 0, width: 1920, height: 1080))
        let onScreen = NSRect(x: 1500, y: 1056, width: 30, height: 24)

        XCTAssertFalse(StatusItemReachability.isReachable(isVisible: false, buttonFrame: onScreen, screens: [screen]))
        XCTAssertFalse(StatusItemReachability.isReachable(isVisible: true, buttonFrame: .zero, screens: [screen]))
        XCTAssertFalse(StatusItemReachability.isReachable(
            isVisible: true,
            buttonFrame: NSRect(x: -40, y: 1056, width: 30, height: 24),
            screens: [screen]
        ))
        XCTAssertFalse(StatusItemReachability.isReachable(isVisible: true, buttonFrame: onScreen, screens: []))
    }

    @MainActor
    func testStatusItemBehindTheCameraHousingIsNotReachable() {
        let screen = StatusItemReachability.Screen(
            frame: NSRect(x: 0, y: 0, width: 1512, height: 982),
            cameraHousing: NSRect(x: 660, y: 950, width: 192, height: 32)
        )

        XCTAssertFalse(StatusItemReachability.isReachable(
            isVisible: true,
            buttonFrame: NSRect(x: 740, y: 952, width: 30, height: 24),
            screens: [screen]
        ))
        XCTAssertTrue(StatusItemReachability.isReachable(
            isVisible: true,
            buttonFrame: NSRect(x: 900, y: 952, width: 30, height: 24),
            screens: [screen]
        ))
    }

    @MainActor
    func testStatusItemWithoutAWindowIsNotReachable() {
        XCTAssertFalse(StatusItemReachability.isReachable(nil))
    }

    @MainActor
    func testOpeningWhileTheStatusItemIsHiddenOpensSettingsInstead() {
        for path in [MenuBarPanelPresentationPath.menuBarExtra, .publicPopover] {
            let coordinator = MenuBarPanelCoordinator()
            var presentations = 0
            var settingsOpened = 0
            var activations = 0
            coordinator.configureExternalPresentation(present: { _ in presentations += 1 }, dismiss: {})
            coordinator.configureHiddenStatusItemFallback(
                isStatusItemReachable: { false },
                openSettings: { settingsOpened += 1 }
            )

            coordinator.openPanel(presentationPath: path, activateApp: { activations += 1 })
            coordinator.openPreset(id: UUID(), presentationPath: path, activateApp: { activations += 1 })

            XCTAssertEqual(settingsOpened, 2, "\(path)")
            XCTAssertEqual(presentations, 0, "\(path)")
            XCTAssertEqual(activations, 0, "\(path)")
            XCTAssertFalse(coordinator.isPresented, "\(path)")
            XCTAssertFalse(coordinator.isExternalPresentationActive, "\(path)")
            XCTAssertNil(coordinator.requestedPresetID, "\(path)")
        }
    }

    @MainActor
    func testOpeningWhileTheStatusItemIsVisibleOpensThePanel() {
        let coordinator = MenuBarPanelCoordinator()
        var presentations: [UUID?] = []
        var settingsOpened = 0
        coordinator.configureExternalPresentation(present: { presentations.append($0) }, dismiss: {})
        coordinator.configureHiddenStatusItemFallback(
            isStatusItemReachable: { true },
            openSettings: { settingsOpened += 1 }
        )

        coordinator.openPanel(presentationPath: .publicPopover, activateApp: {})

        XCTAssertEqual(presentations, [nil])
        XCTAssertEqual(settingsOpened, 0)
    }
}

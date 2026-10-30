//
//  DimmerlyAppTests.swift
//  DimmerlyTests
//
//  Unit tests for the status bar icon's right-click quick actions menu.
//

import AppIntents
import AppKit
@testable import Dimmerly
import XCTest

@MainActor
final class DimmerlyAppTests: XCTestCase {
    func testSettingsPromotesWindowAfterSwiftUIAttachesIt() throws {
        let repositoryURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = repositoryURL.appendingPathComponent("Dimmerly/Views/SettingsView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains(".settingsWindowPresentation()"))
        XCTAssertTrue(source.contains("override func viewDidMoveToWindow()"))
        XCTAssertTrue(source.contains("window.orderFrontRegardless()"))
        XCTAssertFalse(source.contains(".onAppear {\n            NSApp.activate()\n        }"))
    }

    func testMenuBarExtraAccessUsesThePublicReleaseBeforeMacOS27SPI() throws {
        let repositoryURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let packageURL = repositoryURL.appendingPathComponent(
            "Dimmerly.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
        )
        let resolvedPackage = try String(contentsOf: packageURL, encoding: .utf8)

        XCTAssertTrue(resolvedPackage.contains("\"version\" : \"1.3.0\""))
        XCTAssertFalse(resolvedPackage.contains("\"version\" : \"1.3.1\""))
    }

    func testTurnOffTitleReflectsPreventScreenLockSetting() throws {
        // Isolated suite so this test doesn't read or overwrite the developer's real
        // preventScreenLock setting in UserDefaults.standard.
        let suiteName = "DimmerlyAppTests-\(UUID().uuidString)"
        let testDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { testDefaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(defaults: testDefaults)

        #if APPSTORE
            settings.preventScreenLock = false
            XCTAssertEqual(StatusItemQuickActions.turnOffTitle(settings: settings), "Dim Displays")
        #else
            settings.preventScreenLock = false
            XCTAssertEqual(StatusItemQuickActions.turnOffTitle(settings: settings), "Turn Displays Off")

            settings.preventScreenLock = true
            XCTAssertEqual(StatusItemQuickActions.turnOffTitle(settings: settings), "Dim Displays")
        #endif
    }

    func testQuickActionsMenuOrderMatchesHIGConventions() {
        let quickActions = StatusItemQuickActions()

        let menu = quickActions.makeQuickActionsMenu(turnOffTitle: "Turn Displays Off")

        // Action items first (most-used first), a separator, then Quit last —
        // matches Apple HIG guidance for grouping and destructive/exit actions.
        XCTAssertEqual(menu.items.map(\.title), [
            "Turn Displays Off",
            "Settings…",
            "",
            "Quit Dimmerly",
        ])
        XCTAssertTrue(menu.items[2].isSeparatorItem)
        XCTAssertEqual(menu.items[3].keyEquivalent, "q")
    }

    func testQuickActionsMenuItemsTargetTheirHandlers() {
        let quickActions = StatusItemQuickActions()

        let menu = quickActions.makeQuickActionsMenu(turnOffTitle: "Turn Displays Off")

        XCTAssertTrue(menu.items[0].target === quickActions)
        XCTAssertTrue(menu.items[1].target === quickActions)
        XCTAssertTrue(menu.items[3].target === NSApp)
    }

    func testQuickActionsSelectTheContextMenuPresentationOnMacOS27() {
        if #available(macOS 27.0, *) {
            XCTAssertEqual(StatusItemQuickActionsPresentation.current, .contextMenu)
        } else {
            XCTAssertEqual(StatusItemQuickActionsPresentation.current, .statusItemMenu)
        }
    }

    func testStatusItemAccessibilityValueFollowsDisplayState() {
        let button = NSButton()
        let accessibility = StatusItemAccessibility()
        let idle = StatusItemAccessibility.value(isAffectingDisplays: false)
        let active = StatusItemAccessibility.value(isAffectingDisplays: true)
        XCTAssertNotEqual(idle, active)

        accessibility.attach(button: { button })
        XCTAssertEqual(button.accessibilityValue() as? String, idle)

        accessibility.update(isAffectingDisplays: true)
        XCTAssertEqual(button.accessibilityValue() as? String, active)

        accessibility.update(isAffectingDisplays: false)
        XCTAssertEqual(button.accessibilityValue() as? String, idle)
    }

    func testStatusItemAccessibilityAppliesStateReportedBeforeTheButtonAttaches() {
        let button = NSButton()
        let accessibility = StatusItemAccessibility()

        accessibility.update(isAffectingDisplays: true)
        accessibility.attach(button: { button })

        XCTAssertEqual(
            button.accessibilityValue() as? String,
            StatusItemAccessibility.value(isAffectingDisplays: true)
        )
    }

    func testDiscardingLegacyWidgetCommandsPreservesPublishedStateAndPresets() throws {
        let suiteName = "WidgetLaunchTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        // The values older extensions wrote: a flag, a preset ID, and two requested toggle states.
        defaults.set(true, forKey: "widgetDimCommand")
        defaults.set(UUID().uuidString, forKey: "widgetPresetCommand")
        defaults.set(true, forKey: "widgetDimStateCommand")
        defaults.set(false, forKey: "widgetAutoWarmthCommand")
        SharedConstants.publishControlState(true, forKey: SharedConstants.controlAutoWarmthStateKey, in: defaults)
        defaults.set(Data([1, 2, 3]), forKey: SharedConstants.widgetPresetsKey)

        SharedConstants.discardLegacyWidgetCommands(in: defaults)

        for key in ["widgetDimCommand", "widgetPresetCommand", "widgetDimStateCommand", "widgetAutoWarmthCommand"] {
            XCTAssertNil(defaults.object(forKey: key), key)
        }
        XCTAssertTrue(SharedConstants.publishedAutoWarmthState(in: defaults))
        XCTAssertEqual(defaults.data(forKey: SharedConstants.widgetPresetsKey), Data([1, 2, 3]))
    }

    func testWidgetRequestLaunchesAppAndRetriesUntilItsObserverIsReady() async throws {
        let suiteName = "WidgetRequestTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var didLaunch = false
        var signals = 0
        var appliedCommands: [WidgetActionCommand] = []
        var requestID: UUID?

        try await WidgetActionExecution.perform(
            .setAutoWarmth(true),
            defaults: defaults,
            launchApp: { didLaunch = true },
            signalApp: { id in
                XCTAssertTrue(didLaunch)
                requestID = id
                signals += 1
                guard signals == 3 else { return }
                handleWidgetActionRequest(id, defaults: defaults) { command in
                    appliedCommands.append(command)
                    return true
                }
            },
            wait: {}
        )

        XCTAssertEqual(signals, 3)
        XCTAssertEqual(appliedCommands, [.setAutoWarmth(true)])
        let id = try XCTUnwrap(requestID)
        XCTAssertNil(SharedConstants.consumeWidgetActionRequest(id, from: defaults))
        XCTAssertNil(SharedConstants.widgetActionOutcome(id, in: defaults))
    }

    func testWidgetRequestAcceptsAcknowledgementArrivingDuringItsFinalWait() async throws {
        let suiteName = "WidgetBoundaryTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var now = Date()
        var requestID: UUID?

        try await WidgetActionExecution.perform(
            .dimDisplays,
            defaults: defaults,
            launchApp: {},
            signalApp: { requestID = $0 },
            now: { now },
            wait: {
                try SharedConstants.acknowledgeWidgetAction(XCTUnwrap(requestID), succeeded: true, in: defaults)
                now = now.addingTimeInterval(6)
            }
        )

        let id = try XCTUnwrap(requestID)
        XCTAssertNil(SharedConstants.consumeWidgetActionRequest(id, from: defaults))
        XCTAssertNil(SharedConstants.widgetActionOutcome(id, in: defaults))
    }

    func testWidgetRequestTimesOutAndCleansOnlyItsOwnCommand() async throws {
        let suiteName = "WidgetTimeoutTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var now = Date()
        let otherRequest = WidgetActionRequest(command: .setDimming(false), expiresAt: now.addingTimeInterval(30))
        try SharedConstants.storeWidgetActionRequest(otherRequest, in: defaults)
        var requestID: UUID?

        do {
            try await WidgetActionExecution.perform(
                .setDimming(true),
                defaults: defaults,
                launchApp: {},
                signalApp: { requestID = $0 },
                now: { now },
                wait: { now = now.addingTimeInterval(6) }
            )
            XCTFail("An action without an acknowledgement must not return success")
        } catch WidgetActionExecution.Failure.didNotComplete {
            // Expected: the app never handled this request.
        }

        let id = try XCTUnwrap(requestID)
        XCTAssertNil(SharedConstants.consumeWidgetActionRequest(id, from: defaults))
        XCTAssertNil(SharedConstants.widgetActionOutcome(id, in: defaults))
        XCTAssertEqual(
            SharedConstants.consumeWidgetActionRequest(otherRequest.id, from: defaults)?.command,
            .setDimming(false)
        )
    }

    func testCancelledWidgetRequestCleansItsCommandAndAcknowledgement() async throws {
        let suiteName = "WidgetCancellationTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var requestID: UUID?

        do {
            try await WidgetActionExecution.perform(
                .dimDisplays,
                defaults: defaults,
                launchApp: {},
                signalApp: { requestID = $0 },
                wait: { throw CancellationError() }
            )
            XCTFail("Cancellation must not return success")
        } catch is CancellationError {
            // Expected.
        }

        let id = try XCTUnwrap(requestID)
        XCTAssertNil(SharedConstants.consumeWidgetActionRequest(id, from: defaults))
        XCTAssertNil(SharedConstants.widgetActionOutcome(id, in: defaults))
    }

    func testFailedAppLaunchDoesNotLeaveAWidgetRequest() async throws {
        let suiteName = "WidgetLaunchFailureTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var didSignal = false

        do {
            try await WidgetActionExecution.perform(
                .dimDisplays,
                defaults: defaults,
                launchApp: { throw WidgetActionExecution.Failure.unavailable },
                signalApp: { _ in didSignal = true },
                wait: {}
            )
            XCTFail("Failed launch must not return success")
        } catch WidgetActionExecution.Failure.unavailable {
            // Expected.
        }

        XCTAssertFalse(didSignal)
        XCTAssertTrue((defaults.persistentDomain(forName: suiteName) ?? [:]).isEmpty)
    }

    func testWidgetRequestAcknowledgesAfterStatePublicationAndAppliesOnlyOnce() throws {
        let suiteName = "WidgetAcknowledgementTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let request = WidgetActionRequest(command: .setDimming(true), expiresAt: Date().addingTimeInterval(5))
        try SharedConstants.storeWidgetActionRequest(request, in: defaults)
        var actions = 0
        let apply: (WidgetActionCommand) -> Bool = { command in
            XCTAssertEqual(command, .setDimming(true))
            XCTAssertNil(SharedConstants.widgetActionOutcome(request.id, in: defaults))
            actions += 1
            SharedConstants.publishControlState(true, forKey: SharedConstants.controlDimStateKey, in: defaults)
            return true
        }

        handleWidgetActionRequest(request.id, defaults: defaults, performCommand: apply)
        handleWidgetActionRequest(request.id, defaults: defaults, performCommand: apply)

        XCTAssertEqual(actions, 1)
        XCTAssertTrue(SharedConstants.publishedDimState(in: defaults))
        XCTAssertEqual(SharedConstants.widgetActionOutcome(request.id, in: defaults), .succeeded)
    }

    func testWidgetRequestAcknowledgesAnActionTheAppCouldNotPerformAsFailed() throws {
        let suiteName = "WidgetFailureAcknowledgementTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let request = WidgetActionRequest(
            command: .applyPreset(UUID().uuidString),
            expiresAt: Date().addingTimeInterval(5)
        )
        try SharedConstants.storeWidgetActionRequest(request, in: defaults)

        handleWidgetActionRequest(request.id, defaults: defaults) { _ in false }

        XCTAssertEqual(SharedConstants.widgetActionOutcome(request.id, in: defaults), .failed)
    }

    /// A widget preset button or Control Center preset control can still name a preset that was
    /// deleted in the app. The extension must report that instead of claiming success.
    func testWidgetRequestThrowsWhenTheAppReportsFailure() async throws {
        let suiteName = "WidgetFailureTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var requestID: UUID?

        do {
            try await WidgetActionExecution.perform(
                .applyPreset(UUID().uuidString),
                defaults: defaults,
                launchApp: {},
                signalApp: { id in
                    requestID = id
                    handleWidgetActionRequest(id, defaults: defaults) { _ in false }
                },
                wait: {}
            )
            XCTFail("An action the app could not perform must not return success")
        } catch WidgetActionExecution.Failure.presetUnavailable {
            // Expected.
        }

        let id = try XCTUnwrap(requestID)
        XCTAssertNil(SharedConstants.widgetActionOutcome(id, in: defaults))
        XCTAssertTrue((defaults.persistentDomain(forName: suiteName) ?? [:]).isEmpty)
    }

    func testFailedWidgetActionsMapToTheirUserFacingError() {
        XCTAssertEqual(WidgetActionExecution.failure(for: .applyPreset("x")), .presetUnavailable)
        XCTAssertEqual(WidgetActionExecution.failure(for: .dimDisplays), .didNotComplete)
        XCTAssertEqual(WidgetActionExecution.failure(for: .setDimming(true)), .didNotComplete)
        XCTAssertEqual(WidgetActionExecution.failure(for: .setAutoWarmth(false)), .didNotComplete)
        XCTAssertNotNil(WidgetActionExecution.Failure.presetUnavailable.errorDescription)
    }

    func testApplyingAMissingOrMalformedPresetReportsThatNothingHappened() {
        let fixture = IsolatedPresetManagerFixture()
        defer { fixture.cleanup() }
        let settings = AppSettings(defaults: fixture.defaults)

        XCTAssertFalse(
            WidgetActionCommand.applyPreset(UUID().uuidString)
                .performInApp(settings: settings, presetManager: fixture.manager)
        )
        XCTAssertFalse(
            WidgetActionCommand.applyPreset("not-a-uuid")
                .performInApp(settings: settings, presetManager: fixture.manager)
        )
    }

    func testExpiredWidgetRequestNeverAppliesOrAcknowledges() throws {
        let suiteName = "ExpiredWidgetRequestTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let now = Date()
        let request = WidgetActionRequest(command: .dimDisplays, expiresAt: now)
        try SharedConstants.storeWidgetActionRequest(request, in: defaults)
        var didApply = false

        handleWidgetActionRequest(request.id, defaults: defaults, now: now) { _ in
            didApply = true
            return true
        }

        XCTAssertFalse(didApply)
        XCTAssertNil(SharedConstants.widgetActionOutcome(request.id, in: defaults))
        XCTAssertNil(SharedConstants.consumeWidgetActionRequest(request.id, from: defaults, now: now))
    }

    @available(macOS, deprecated: 26.0)
    func testWidgetIntentsKeepTheLegacyForegroundFallback() {
        XCTAssertTrue(DimDisplaysWidgetIntent.openAppWhenRun)
        XCTAssertTrue(ApplyPresetWidgetIntent.openAppWhenRun)
    }

    #if compiler(>=6.4)
        @available(macOS 27.0, *)
        func testWidgetIntentsTargetTheMainAppOnMacOS27() {
            XCTAssertEqual(DimDisplaysWidgetIntent.allowedExecutionTargets, .main)
            XCTAssertEqual(ApplyPresetWidgetIntent.allowedExecutionTargets, .main)
            XCTAssertEqual(SetDimmingWidgetIntent.allowedExecutionTargets, .main)
            XCTAssertEqual(SetAutoWarmthWidgetIntent.allowedExecutionTargets, .main)
        }

        @available(macOS 27.0, *)
        func testPresetEntityQueryConformsToSpotlightRecoveryProtocolOnMacOS27() {
            let query: any IndexedEntityQuery = PresetEntityQuery()
            XCTAssertNotNil(query)
        }

        @available(macOS 27.0, *)
        func testMainIntentsAndQueriesTargetTheMainAppOnMacOS27() {
            XCTAssertEqual(DisplayEntityQuery.allowedExecutionTargets, .main)
            XCTAssertEqual(PresetEntityQuery.allowedExecutionTargets, .main)
            XCTAssertEqual(SleepDisplaysIntent.allowedExecutionTargets, .main)
            XCTAssertEqual(SetDisplayBrightnessIntent.allowedExecutionTargets, .main)
            XCTAssertEqual(SetDisplayWarmthIntent.allowedExecutionTargets, .main)
            XCTAssertEqual(SetDisplayContrastIntent.allowedExecutionTargets, .main)
            XCTAssertEqual(ToggleDimIntent.allowedExecutionTargets, .main)
            XCTAssertEqual(ApplyPresetIntent.allowedExecutionTargets, .main)
        }
    #endif

    func testParameterizedIntentsExposeConstructibleConversationalSummaries() {
        _ = SetDisplayBrightnessIntent.parameterSummary
        _ = SetDisplayWarmthIntent.parameterSummary
        _ = SetDisplayContrastIntent.parameterSummary
        _ = ToggleDimIntent.parameterSummary
        _ = ApplyPresetIntent.parameterSummary
    }

    func testConversationalIntentsArePublishedAsAppShortcuts() {
        XCTAssertEqual(DimmerlyShortcuts.appShortcuts.count, 6)
    }
}

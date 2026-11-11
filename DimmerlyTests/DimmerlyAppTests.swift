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

    /// Sparkle is vendored, not a Swift package, so Dependabot never proposes a version.
    /// Moving the pin, or its checksum, should be a reviewed change that fails this test.
    func testSparkleIsPinnedToTheReviewedRelease() throws {
        let repositoryURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let pinURL = repositoryURL.appendingPathComponent("packaging/sparkle/sparkle-version.env")
        let pin = try String(contentsOf: pinURL, encoding: .utf8)

        XCTAssertTrue(pin.contains("SPARKLE_VERSION=2.10.1\n"))
        XCTAssertTrue(pin.contains(
            "SPARKLE_SHA256=1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27\n"
        ))
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

    #if !APPSTORE
        /// Launch setup, which starts Sparkle, is skipped while the app hosts the tests, so
        /// a test run never checks for updates or shows Sparkle's permission prompt.
        func testUpdaterIsNotStartedWhileHostingTests() {
            XCTAssertFalse(UpdaterController.shared.isStarted)
        }
    #endif

    func testQuickActionsMenuOrderMatchesHIGConventions() {
        let quickActions = StatusItemQuickActions()

        let menu = quickActions.makeQuickActionsMenu(turnOffTitle: "Turn Displays Off")

        // Action items first (most-used first), a separator, then Quit last —
        // matches Apple HIG guidance for grouping and destructive/exit actions.
        // The App Store edition is updated by the App Store, so it has no update item.
        var expectedTitles = ["Turn Displays Off", "Settings…"]
        #if !APPSTORE
            expectedTitles.append("Check for Updates…")
        #endif
        expectedTitles += ["", "Quit Dimmerly"]
        XCTAssertEqual(menu.items.map(\.title), expectedTitles)
        XCTAssertTrue(menu.items[menu.items.count - 2].isSeparatorItem)
        XCTAssertEqual(menu.items.last?.keyEquivalent, "q")
    }

    func testQuickActionsMenuItemsTargetTheirHandlers() {
        let quickActions = StatusItemQuickActions()

        let menu = quickActions.makeQuickActionsMenu(turnOffTitle: "Turn Displays Off")

        // Every item but the separator and Quit is handled by the quick actions object.
        for item in menu.items.dropLast(2) {
            XCTAssertTrue(item.target === quickActions, item.title)
        }
        XCTAssertTrue(menu.items.last?.target === NSApp)
    }

    #if !APPSTORE
        func testCheckForUpdatesItemFollowsCanCheckForUpdates() throws {
            @MainActor final class UpdatesStub {
                var canCheck = false
                var checks = 0
            }
            let stub = UpdatesStub()
            let quickActions = StatusItemQuickActions()
            quickActions.configureUpdates(
                checkForUpdates: { stub.checks += 1 },
                canCheckForUpdates: { stub.canCheck }
            )
            let menu = quickActions.makeQuickActionsMenu(turnOffTitle: "Turn Displays Off")
            let item = try XCTUnwrap(menu.items.first { $0.title == "Check for Updates…" })

            XCTAssertFalse(quickActions.validateMenuItem(item))

            stub.canCheck = true
            XCTAssertTrue(quickActions.validateMenuItem(item))

            let action = try XCTUnwrap(item.action)
            XCTAssertTrue(NSApp.sendAction(action, to: item.target, from: item))
            XCTAssertEqual(stub.checks, 1)
        }
    #endif

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

    func testLaunchSetupRunsOnceWhenLaunchingFinishesWithoutAnyView() {
        var setupRuns = 0
        let services = AppServices(launchSetupOverride: { setupRuns += 1 })
        let delegate = DimmerlyAppDelegate(services: services, isHostingUnitTests: false)
        XCTAssertFalse(services.isConfigured)

        let didFinishLaunching = Notification(name: NSApplication.didFinishLaunchingNotification)
        delegate.applicationDidFinishLaunching(didFinishLaunching)
        delegate.applicationDidFinishLaunching(didFinishLaunching)
        services.configure()

        XCTAssertEqual(setupRuns, 1)
        XCTAssertTrue(services.isConfigured)
    }

    func testLaunchSetupIsSkippedWhileHostingUnitTests() {
        var setupRuns = 0
        let services = AppServices(launchSetupOverride: { setupRuns += 1 })
        let delegate = DimmerlyAppDelegate(services: services, isHostingUnitTests: true)

        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))

        XCTAssertEqual(setupRuns, 0, "A test run must not configure the app against real displays")
        XCTAssertFalse(services.isConfigured)
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

    func testAppRemovesItsAcknowledgementOnceTheExtensionStoppedReadingIt() throws {
        let suiteName = "WidgetAcknowledgementRemovalTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let now = Date()
        let request = WidgetActionRequest(command: .dimDisplays, expiresAt: now.addingTimeInterval(5))
        let other = UUID()
        try SharedConstants.storeWidgetActionRequest(request, in: defaults)
        SharedConstants.acknowledgeWidgetAction(other, succeeded: true, in: defaults)
        var scheduled: [(date: Date, work: @MainActor () -> Void)] = []

        handleWidgetActionRequest(
            request.id,
            defaults: defaults,
            now: now,
            scheduleRemoval: { scheduled.append(($0, $1)) },
            performCommand: { _ in true }
        )

        XCTAssertEqual(SharedConstants.widgetActionOutcome(request.id, in: defaults), .succeeded)
        XCTAssertEqual(scheduled.map(\.date), [request.expiresAt.addingTimeInterval(widgetActionAcknowledgementGrace)])

        // By then the extension has stopped reading, and nothing else would remove the answer.
        for removal in scheduled {
            removal.work()
        }

        XCTAssertNil(SharedConstants.widgetActionOutcome(request.id, in: defaults))
        XCTAssertEqual(SharedConstants.widgetActionOutcome(other, in: defaults), .succeeded)
    }

    func testActionOutlastingTheDeadlineIsStillAcknowledgedDuringTheFinalWait() async throws {
        let suiteName = "WidgetLateActionTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var now = Date()
        var requestID: UUID?
        var removals: [@MainActor () -> Void] = []

        try await WidgetActionExecution.perform(
            .dimDisplays,
            defaults: defaults,
            launchApp: {},
            signalApp: { requestID = $0 },
            now: { now },
            wait: {
                // The app takes the request in time, but the action ends after the deadline.
                try handleWidgetActionRequest(
                    XCTUnwrap(requestID),
                    defaults: defaults,
                    now: now,
                    scheduleRemoval: { removals.append($1) },
                    performCommand: { _ in
                        now = now.addingTimeInterval(6)
                        return true
                    }
                )
            }
        )

        XCTAssertEqual(removals.count, 1)
        for removal in removals {
            removal()
        }
        XCTAssertTrue((defaults.persistentDomain(forName: suiteName) ?? [:]).isEmpty)
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

/// The debug-only screenshot stage behind `scripts/screenshots.sh refresh`.
@MainActor
final class ScreenshotStageTests: XCTestCase {
    func testLaunchScenesExpandControlsAndApplyEveningOnlyToStagedDisplays() throws {
        XCTAssertTrue(ScreenshotStage.Scene.launchMenu.isLaunch)
        XCTAssertTrue(ScreenshotStage.Scene.launchEvening.isLaunch)
        XCTAssertTrue(ScreenshotStage.Scene.launchSchedule.isLaunch)
        XCTAssertFalse(ScreenshotStage.Scene.menu.isLaunch)
        XCTAssertTrue(ScreenshotStage.launchDisplays.allSatisfy { $0.expanded == true })
        let brightness = ScreenshotStage.makeBrightnessManager(displays: ScreenshotStage.launchDisplays)
        let presets = ScreenshotStage.makePresetManager(presets: ScreenshotStage.launchPresets)
        let standardBefore = UserDefaults.standard.data(forKey: PresetManager.persistenceKey)
        let id = try XCTUnwrap(ScreenshotStage.applyLaunchPreset(
            scene: .launchEvening, brightnessManager: brightness, presetManager: presets
        ))
        XCTAssertEqual(presets.preset(withID: id)?.name, "Evening")
        XCTAssertEqual(brightness.displays.first?.brightness, 0.65)
        XCTAssertEqual(brightness.displays.first?.warmth, 0.55)
        XCTAssertNotNil(brightness.applyGammaHook)
        brightness.refreshDisplays()
        XCTAssertEqual(brightness.displays.map(\.id), [ScreenshotStage.displayID])
        XCTAssertEqual(UserDefaults.standard.data(forKey: PresetManager.persistenceKey), standardBefore)
        XCTAssertNil(ScreenshotStage.applyLaunchPreset(
            scene: .launchMenu, brightnessManager: brightness, presetManager: presets
        ))
    }

    override func tearDown() {
        // The suite is throwaway; don't leave a test run's copy on the developer's Mac.
        UserDefaults().removePersistentDomain(forName: ScreenshotStage.defaultsSuiteName)
        super.tearDown()
    }

    func testTestRunsUseTheRealManagers() {
        XCTAssertFalse(ScreenshotStage.isActive)
        XCTAssertEqual(SettingsView.Tab.initial, .general)
    }

    /// A screenshot must show bindings the App Store build accepts.
    func testStagedPresetShortcutsSuitTheAppStoreBuild() throws {
        let manager = ScreenshotStage.makePresetManager()
        XCTAssertEqual(manager.presets.map(\.name), ScreenshotStage.presets.map(\.name))
        for preset in manager.presets {
            let shortcut = try XCTUnwrap(preset.shortcut, preset.name)
            XCTAssertTrue(shortcut.isValidCarbonShortcut, preset.name)
        }
    }

    /// Staged presets are saved in the screenshot suite and never in the user's settings.
    func testStagedPresetsPersistOnlyInTheScreenshotSuite() throws {
        let standardBefore = UserDefaults.standard.data(forKey: PresetManager.persistenceKey)
        _ = ScreenshotStage.makePresetManager()

        let data = try XCTUnwrap(ScreenshotStage.defaults.data(forKey: PresetManager.persistenceKey))
        let saved = try JSONDecoder().decode([BrightnessPreset].self, from: data)
        XCTAssertEqual(saved.map(\.name), ScreenshotStage.presets.map(\.name))
        XCTAssertEqual(UserDefaults.standard.data(forKey: PresetManager.persistenceKey), standardBefore)
    }

    /// The staged display survives a refresh, and nothing reaches a real display's gamma.
    func testStagedBrightnessManagerStaysOnTheStagedDisplay() {
        let brightness = ScreenshotStage.makeBrightnessManager()
        XCTAssertNotNil(brightness.applyGammaHook)
        XCTAssertFalse(BrightnessManager.activeDisplayIDs().contains(ScreenshotStage.displayID))

        brightness.refreshDisplays()
        XCTAssertEqual(brightness.displays.map(\.id), [ScreenshotStage.displayID])
        XCTAssertEqual(brightness.displays.map(\.name), ScreenshotStage.screenshotDisplays.map(\.name))
        XCTAssertEqual(brightness.displays.first?.brightness, ScreenshotStage.screenshotDisplays.first?.brightness)
    }

    #if !APPSTORE
        /// Hardware control in a screenshot run finds no monitors to talk to.
        func testStagedHardwareManagerFindsNoMonitors() async {
            let hardware = ScreenshotStage.makeHardwareBrightnessManager()
            hardware.enable()
            hardware.probeAllDisplays(force: true)
            XCTAssertTrue(hardware.capabilities.isEmpty)
            await hardware.disable()
        }

        /// A staged run's external display answers DDC/CI from memory, for staged IDs only.
        func testStagedDDCAnswersOnlyForStagedDisplays() {
            let staged = ScreenshotStage.displayID
            XCTAssertEqual(ScreenshotStage.stagedExternalDisplayIDs, [staged])
            let ddc = ScreenshotStage.StagedDDCInterface(answeringDisplayIDs: [staged])

            let capability = ddc.probeCapabilities(for: staged, skippingBrightness: false)
            XCTAssertTrue(capability.supportsDDC)
            XCTAssertEqual(
                ddcFeatureLabels(for: capability),
                ["Brightness", "Contrast", "Volume", "Input"].formatted(.list(type: .and))
            )

            for realID in BrightnessManager.activeDisplayIDs() {
                XCTAssertFalse(ddc.probeCapabilities(for: realID, skippingBrightness: false).supportsDDC)
                XCTAssertNil(ddc.read(vcp: .brightness, for: realID))
                XCTAssertFalse(ddc.write(vcp: .brightness, value: 10, for: realID))
            }
        }
    #endif

    /// Every app-wide manager that holds state or reaches hardware must be replaced in a
    /// screenshot run. A new `static let shared` fails here until it is staged or listed
    /// as stateless.
    func testEveryStatefulSingletonIsStaged() throws {
        let stateless: Set = [
            "ConnectedDisplayResolver.swift", // Resolves intents against BrightnessManager.shared
            "PresetEntity.swift", // App Intents indexing; launch setup that the stage skips
            "MenuBarPanel.swift", // Panel coordinator; presentation only
            "MenuBarPanelHost.swift", // Panel presenter; presentation only
            "KeyboardShortcutManager.swift", // Shortcut recording UI state
            "ScreenBlanker.swift", // Runs only on an explicit Turn Off
        ]
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Dimmerly")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var checked = 0
        for case let file as URL in files where file.pathExtension == "swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            guard text.contains("static let shared =") else { continue }
            checked += 1
            guard !stateless.contains(file.lastPathComponent) else { continue }
            XCTAssertTrue(
                text.contains("ScreenshotStage.isActive"),
                "\(file.lastPathComponent) has a singleton that screenshot runs don't replace"
            )
        }
        XCTAssertGreaterThan(checked, stateless.count)
    }
}

/// Settings › About links: the paid App Store edition must not lead to the free download.
@MainActor
final class AboutSettingsLinkTests: XCTestCase {
    func testPrivacyLinkMatchesTheDistribution() {
        #if APPSTORE
            XCTAssertEqual(
                AboutSettingsTab.privacyPolicyURL?.absoluteString,
                "https://dimmerly.olujic.in.rs/app-store-privacy.html"
            )
        #else
            XCTAssertEqual(
                AboutSettingsTab.privacyPolicyURL?.absoluteString,
                "https://dimmerly.olujic.in.rs/privacy-policy.html"
            )
        #endif
    }

    func testSparkleIsCreditedOnlyInTheDirectBuild() {
        let names = OpenSourceLicense.all.map(\.name)
        #if APPSTORE
            XCTAssertFalse(names.contains("Sparkle"))
        #else
            XCTAssertTrue(names.contains("Sparkle"))
            let sparkle = OpenSourceLicense.all.first { $0.name == "Sparkle" }
            XCTAssertEqual(sparkle?.type, "MIT")
            XCTAssertTrue(sparkle?.text.contains("bsdiff") == true, "bundled third-party notices are included")
        #endif
    }

    #if !APPSTORE
        func testLastCheckedTextSaysNeverWithoutADate() {
            XCTAssertEqual(SettingsUpdatesSection.lastCheckedText(nil, now: Date()), String(localized: "Never"))
        }

        func testLastCheckedTextDescribesADate() {
            let now = Date(timeIntervalSince1970: 1_800_000_000)

            let text = SettingsUpdatesSection.lastCheckedText(now.addingTimeInterval(-7200), now: now)

            XCTAssertFalse(text.isEmpty)
            XCTAssertNotEqual(text, SettingsUpdatesSection.lastCheckedText(nil, now: now))
            let threeDaysAgo = now.addingTimeInterval(-86400 * 3)
            XCTAssertNotEqual(text, SettingsUpdatesSection.lastCheckedText(threeDaysAgo, now: now))
        }
    #endif
}

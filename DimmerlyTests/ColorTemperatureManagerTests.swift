//
//  ColorTemperatureManagerTests.swift
//  DimmerlyTests
//
//  Unit tests for ColorTemperatureManager state determination, interpolation,
//  and manual override lifecycle.
//

import AppKit
@testable import Dimmerly
import XCTest

@MainActor
final class ColorTemperatureManagerTests: XCTestCase {
    private var testSuiteName: String!
    private var testDefaults: UserDefaults!
    private var testSettings: AppSettings!
    /// Weakly held so tearDown can wait for every fixture's debounced persistence, including
    /// the first session of the relaunch tests.
    private var fixtureBrightnessManagers = NSHashTable<BrightnessManager>.weakObjects()

    override func setUp() async throws {
        testSuiteName = "ColorTemperatureManagerTests-\(UUID().uuidString)"
        testDefaults = try XCTUnwrap(UserDefaults(suiteName: testSuiteName))
        testSettings = AppSettings(defaults: testDefaults)
    }

    override func tearDown() async throws {
        // Warmth setters retain their manager through debounced persistence. Wait
        // for that work before removing its suite so a late write cannot recreate it.
        let deadline = ContinuousClock.now + .seconds(2)
        while !fixtureBrightnessManagers.allObjects.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(
            fixtureBrightnessManagers.allObjects.isEmpty,
            "Brightness persistence should finish before removing its defaults"
        )
        testDefaults.removePersistentDomain(forName: testSuiteName)
        testSettings = nil
        testDefaults = nil
        testSuiteName = nil
    }

    // MARK: - Helpers

    private func makeDate(
        year: Int = 2026, month: Int = 6, day: Int = 15,
        hour: Int, minute: Int, second: Int = 0,
        timeZone: TimeZone = .current
    ) -> Date {
        var calendar = Calendar.current
        calendar.timeZone = timeZone
        return calendar.date(from: DateComponents(
            year: year, month: month, day: day,
            hour: hour, minute: minute, second: second
        ))!
    }

    // MARK: - determineState

    func testDayState() {
        let sunrise = makeDate(hour: 6, minute: 0)
        let sunset = makeDate(hour: 20, minute: 0)
        let halfTransition: Double = 20 * 60 // 20 minutes

        let state = ColorTemperatureManager.determineState(
            now: makeDate(hour: 12, minute: 0),
            sunrise: sunrise,
            sunset: sunset,
            halfTransition: halfTransition
        )
        XCTAssertEqual(state, .day)
    }

    func testNightStateBeforeSunrise() {
        let sunrise = makeDate(hour: 6, minute: 0)
        let sunset = makeDate(hour: 20, minute: 0)
        let halfTransition: Double = 20 * 60

        let state = ColorTemperatureManager.determineState(
            now: makeDate(hour: 3, minute: 0),
            sunrise: sunrise,
            sunset: sunset,
            halfTransition: halfTransition
        )
        XCTAssertEqual(state, .night)
    }

    func testNightStateAfterSunset() {
        let sunrise = makeDate(hour: 6, minute: 0)
        let sunset = makeDate(hour: 20, minute: 0)
        let halfTransition: Double = 20 * 60

        let state = ColorTemperatureManager.determineState(
            now: makeDate(hour: 23, minute: 0),
            sunrise: sunrise,
            sunset: sunset,
            halfTransition: halfTransition
        )
        XCTAssertEqual(state, .night)
    }

    func testSunriseTransitionStart() {
        let sunrise = makeDate(hour: 6, minute: 0)
        let sunset = makeDate(hour: 20, minute: 0)
        let halfTransition: Double = 20 * 60 // transition: 5:40 to 6:20

        let state = ColorTemperatureManager.determineState(
            now: makeDate(hour: 5, minute: 40),
            sunrise: sunrise,
            sunset: sunset,
            halfTransition: halfTransition
        )
        if case let .sunriseTransition(progress) = state {
            XCTAssertEqual(progress, 0.0, accuracy: 0.01)
        } else {
            XCTFail("Expected sunriseTransition, got \(state)")
        }
    }

    func testSunriseTransitionMidpoint() {
        let sunrise = makeDate(hour: 6, minute: 0)
        let sunset = makeDate(hour: 20, minute: 0)
        let halfTransition: Double = 20 * 60

        let state = ColorTemperatureManager.determineState(
            now: makeDate(hour: 6, minute: 0),
            sunrise: sunrise,
            sunset: sunset,
            halfTransition: halfTransition
        )
        if case let .sunriseTransition(progress) = state {
            XCTAssertEqual(progress, 0.5, accuracy: 0.01)
        } else {
            XCTFail("Expected sunriseTransition, got \(state)")
        }
    }

    func testSunriseTransitionEnd() {
        let sunrise = makeDate(hour: 6, minute: 0)
        let sunset = makeDate(hour: 20, minute: 0)
        let halfTransition: Double = 20 * 60 // transition ends at 6:20

        let state = ColorTemperatureManager.determineState(
            now: makeDate(hour: 6, minute: 20),
            sunrise: sunrise,
            sunset: sunset,
            halfTransition: halfTransition
        )
        if case let .sunriseTransition(progress) = state {
            XCTAssertEqual(progress, 1.0, accuracy: 0.01)
        } else {
            XCTFail("Expected sunriseTransition, got \(state)")
        }
    }

    func testSunsetTransitionStart() {
        let sunrise = makeDate(hour: 6, minute: 0)
        let sunset = makeDate(hour: 20, minute: 0)
        let halfTransition: Double = 20 * 60 // transition: 19:40 to 20:20

        let state = ColorTemperatureManager.determineState(
            now: makeDate(hour: 19, minute: 40),
            sunrise: sunrise,
            sunset: sunset,
            halfTransition: halfTransition
        )
        if case let .sunsetTransition(progress) = state {
            XCTAssertEqual(progress, 0.0, accuracy: 0.01)
        } else {
            XCTFail("Expected sunsetTransition, got \(state)")
        }
    }

    func testSunsetTransitionMidpoint() {
        let sunrise = makeDate(hour: 6, minute: 0)
        let sunset = makeDate(hour: 20, minute: 0)
        let halfTransition: Double = 20 * 60

        let state = ColorTemperatureManager.determineState(
            now: makeDate(hour: 20, minute: 0),
            sunrise: sunrise,
            sunset: sunset,
            halfTransition: halfTransition
        )
        if case let .sunsetTransition(progress) = state {
            XCTAssertEqual(progress, 0.5, accuracy: 0.01)
        } else {
            XCTFail("Expected sunsetTransition, got \(state)")
        }
    }

    func testSunsetTransitionEnd() {
        let sunrise = makeDate(hour: 6, minute: 0)
        let sunset = makeDate(hour: 20, minute: 0)
        let halfTransition: Double = 20 * 60

        let state = ColorTemperatureManager.determineState(
            now: makeDate(hour: 20, minute: 20),
            sunrise: sunrise,
            sunset: sunset,
            halfTransition: halfTransition
        )
        if case let .sunsetTransition(progress) = state {
            XCTAssertEqual(progress, 1.0, accuracy: 0.01)
        } else {
            XCTFail("Expected sunsetTransition, got \(state)")
        }
    }

    // MARK: - Kelvin Interpolation

    func testKelvinInterpolationDuringTransition() {
        // During a 50% sunrise transition between night(2700K) and day(6500K)
        let nightK = 2700.0
        let dayK = 6500.0
        let progress = 0.5

        let expected = nightK + (dayK - nightK) * progress // 4600K
        XCTAssertEqual(expected, 4600.0)
    }

    func testKelvinInterpolationAtTransitionBoundaries() {
        let nightK = 2700.0
        let dayK = 6500.0

        // At sunrise start (progress=0), should be night temp
        let atStart = nightK + (dayK - nightK) * 0.0
        XCTAssertEqual(atStart, nightK)

        // At sunrise end (progress=1), should be day temp
        let atEnd = nightK + (dayK - nightK) * 1.0
        XCTAssertEqual(atEnd, dayK)
    }

    // MARK: - Manual Override

    /// Drives an injected BrightnessManager rather than the shared one. Using the singleton meant
    /// `apply(enabled:)` ran `restoreSavedWarmth()` against real displays, so the suite rewrote
    /// the developer's live gamma and persisted warmth just by running.
    private func isolatedManager(
        warmth: Double = 0.3,
        settings: AppSettings? = nil
    ) -> (ColorTemperatureManager, BrightnessManager) {
        let brightnessManager = BrightnessManager(forTesting: true, defaults: testDefaults)
        fixtureBrightnessManagers.add(brightnessManager)
        brightnessManager.applyGammaHook = { _, _, _, _ in }
        // Enabling auto warmth animates its first update, which applies gamma from a detached
        // task. Forcing the non-animated path keeps these assertions synchronous.
        brightnessManager.canAnimateTransitionsHook = { false }
        // Pin identity so the key doesn't depend on whatever EDID the host reports for this ID.
        brightnessManager.displayIdentityHook = { "identity-\($0)" }
        brightnessManager.displays = [
            ExternalDisplay(id: 1, name: "Test", brightness: 1.0, warmth: warmth, contrast: 0.5),
        ]
        let manager = ColorTemperatureManager(
            brightnessManager: brightnessManager,
            settings: settings ?? testSettings
        )
        return (manager, brightnessManager)
    }

    func testManualOverrideDeactivatesAutoMode() {
        let (manager, _) = isolatedManager()
        manager.apply(enabled: true)
        manager.isActive = true

        manager.notifyManualWarmthChange()

        XCTAssertFalse(manager.isActive, "Manual change should deactivate auto mode")
        manager.apply(enabled: false)
    }

    func testManualOverrideRecoversWhenLocationReturns() {
        let (manager, _) = isolatedManager()
        var coordinates: (latitude: Double, longitude: Double)?
        manager.locationCoordinatesHook = { coordinates }

        manager.apply(enabled: true)
        manager.notifyManualWarmthChange()

        coordinates = localSolarCoordinates
        manager.updateColorTemperature(now: makeDate(hour: 12, minute: 0))
        XCTAssertFalse(manager.isActive, "The first valid update should preserve the manual override")

        manager.updateColorTemperature(now: makeDate(hour: 23, minute: 0))
        XCTAssertTrue(manager.isActive, "A later day/night boundary should clear the manual override")

        manager.apply(enabled: false)
    }

    func testPresetAppliedTriggersOverride() {
        let (manager, _) = isolatedManager()
        manager.apply(enabled: true)
        manager.isActive = true

        manager.notifyPresetApplied()

        XCTAssertFalse(manager.isActive, "Preset with warmth should trigger manual override")
        manager.apply(enabled: false)
    }

    /// Align equatorial solar noon with the host's local noon, including zones whose
    /// civil offset extends beyond the geographic longitude range.
    private var localSolarCoordinates: (latitude: Double, longitude: Double) {
        let noon = makeDate(hour: 12, minute: 0)
        let longitude = Double(TimeZone.current.secondsFromGMT(for: noon)) / 240
        return (0, min(max(longitude, -180), 180))
    }

    /// Start without location so the first injected update establishes the override's
    /// phase, without depending on the wall clock used by the notification entry point.
    private func managerWithManualOverride(at date: Date) -> ColorTemperatureManager {
        let (manager, _) = isolatedManager()
        manager.locationCoordinatesHook = { nil }
        manager.apply(enabled: true)
        manager.notifyManualWarmthChange()
        manager.locationCoordinatesHook = { self.localSolarCoordinates }
        manager.updateColorTemperature(now: date)
        XCTAssertFalse(manager.isActive, "The first valid update should retain the manual override")
        return manager
    }

    func testManualOverrideExpiresAfterSleepingUntilTheNextDaytime() {
        let manager = managerWithManualOverride(at: makeDate(hour: 12, minute: 0))
        defer { manager.apply(enabled: false) }

        // No polling observes either sunset or sunrise while the machine sleeps.
        manager.updateColorTemperature(now: makeDate(day: 16, hour: 12, minute: 0))

        XCTAssertTrue(manager.isActive, "A missed boundary must expire the override even in the same phase")
        XCTAssertEqual(manager.currentKelvin, Double(testSettings.dayTemperature))
    }

    func testManualOverrideExpiresAfterSleepingUntilTheNextNighttime() {
        let manager = managerWithManualOverride(at: makeDate(hour: 22, minute: 0))
        defer { manager.apply(enabled: false) }

        manager.updateColorTemperature(now: makeDate(day: 16, hour: 22, minute: 0))

        XCTAssertTrue(manager.isActive, "A missed sunrise must expire a nighttime override")
        XCTAssertEqual(manager.currentKelvin, Double(testSettings.nightTemperature))
    }

    func testManualOverrideRemainsPausedBeforeTheNextBoundary() {
        let manager = managerWithManualOverride(at: makeDate(hour: 12, minute: 0))
        defer { manager.apply(enabled: false) }

        manager.updateColorTemperature(now: makeDate(hour: 13, minute: 0))

        XCTAssertFalse(manager.isActive, "Time passing within the same solar phase must preserve the override")
    }

    func testManualOverrideResumesAtTheNextOppositePhase() {
        let manager = managerWithManualOverride(at: makeDate(hour: 12, minute: 0))
        defer { manager.apply(enabled: false) }

        manager.updateColorTemperature(now: makeDate(hour: 22, minute: 0))

        XCTAssertTrue(manager.isActive)
        XCTAssertEqual(manager.currentKelvin, Double(testSettings.nightTemperature))
    }

    func testManualOverrideExpiresExactlyAtSunsetTransitionStart() throws {
        testSettings.colorTempTransitionMinutes = 90
        let noon = makeDate(hour: 12, minute: 0)
        let manager = managerWithManualOverride(at: noon)
        defer { manager.apply(enabled: false) }
        let solar = SolarCalculator.sunriseSunset(latitude: 0, longitude: localSolarCoordinates.longitude, date: noon)
        let sunset = try XCTUnwrap(solar.sunset)
        let halfTransition = ColorTemperatureManager.halfTransitionSeconds(
            forTransitionMinutes: testSettings.colorTempTransitionMinutes
        )
        let boundary = sunset.addingTimeInterval(-halfTransition)

        manager.updateColorTemperature(now: boundary.addingTimeInterval(-1))
        XCTAssertFalse(manager.isActive, "The override must last until the transition starts")

        manager.updateColorTemperature(now: boundary)
        XCTAssertTrue(manager.isActive, "The override must expire at the start, rather than midpoint, of sunset")
    }

    func testManualOverrideExpiresAfterLocationIsUnavailableAcrossBoundaries() {
        let manager = managerWithManualOverride(at: makeDate(hour: 12, minute: 0))
        defer { manager.apply(enabled: false) }

        manager.locationCoordinatesHook = { nil }
        manager.updateColorTemperature(now: makeDate(hour: 22, minute: 0))
        XCTAssertFalse(manager.isActive, "Auto warmth must remain inactive without a location")

        manager.locationCoordinatesHook = { self.localSolarCoordinates }
        manager.updateColorTemperature(now: makeDate(day: 16, hour: 12, minute: 0))

        XCTAssertTrue(manager.isActive, "Returning location must not revive an override whose boundary passed")
        XCTAssertEqual(manager.currentKelvin, Double(testSettings.dayTemperature))
    }

    func testManualOverrideUsesTheCurrentTransitionDuration() throws {
        testSettings.colorTempTransitionMinutes = 120
        let noon = makeDate(hour: 12, minute: 0)
        let manager = managerWithManualOverride(at: noon)
        defer { manager.apply(enabled: false) }
        let solar = SolarCalculator.sunriseSunset(latitude: 0, longitude: localSolarCoordinates.longitude, date: noon)
        let sunset = try XCTUnwrap(solar.sunset)

        testSettings.colorTempTransitionMinutes = 20
        manager.updateColorTemperature(now: sunset.addingTimeInterval(-59 * 60))
        XCTAssertFalse(manager.isActive, "Shortening the transition must move the override's expiry to the new start")

        manager.updateColorTemperature(now: sunset.addingTimeInterval(-10 * 60))
        XCTAssertTrue(manager.isActive, "The override should clear when the revised transition starts")
    }

    func testNighttimeManualOverrideWaitsForTheNextCalendarDaysSunrise() throws {
        testSettings.colorTempTransitionMinutes = 90
        let manager = managerWithManualOverride(at: makeDate(hour: 22, minute: 0))
        defer { manager.apply(enabled: false) }
        let tomorrow = makeDate(day: 16, hour: 12, minute: 0)
        let solar = SolarCalculator.sunriseSunset(
            latitude: 0, longitude: localSolarCoordinates.longitude, date: tomorrow
        )
        let sunrise = try XCTUnwrap(solar.sunrise)
        let boundary = sunrise.addingTimeInterval(-45 * 60)

        manager.updateColorTemperature(now: boundary.addingTimeInterval(-1))
        XCTAssertFalse(manager.isActive)

        manager.updateColorTemperature(now: boundary)
        XCTAssertTrue(manager.isActive, "After sunset the next boundary must use tomorrow's solar schedule")
    }

    /// The isolation itself is the point: enabling auto warmth must apply through the injected
    /// manager. Deliberately never references `BrightnessManager.shared` — merely reading it from
    /// a test instantiates the singleton, which enumerates displays and persists, and that is the
    /// very pollution this change removes. Isolation from the shared instance is structural:
    /// ColorTemperatureManager holds no reference to it.
    func testAutoWarmthAppliesThroughTheInjectedManager() {
        let (manager, injected) = isolatedManager()
        var gammaApplications = 0
        injected.applyGammaHook = { _, _, _, _ in gammaApplications += 1 }

        // Enable snapshots the current warmth, disable restores it — both through the injected
        // manager, and neither needing a location. Asserting on the enable path alone would
        // depend on a saved location, since without one the recalculation returns early: that
        // passed on a developer machine and failed on CI.
        manager.apply(enabled: true)
        manager.apply(enabled: false)

        XCTAssertGreaterThan(gammaApplications, 0, "Warmth must be applied via the injected manager")
        XCTAssertEqual(injected.displays.count, 1, "Effects belong to the injected manager")
    }

    // MARK: - Pre-Auto Warmth Across Relaunch

    /// Auto ticks persist their warmth, so after a relaunch at night the displays come back at
    /// the night tint. Enabling auto at launch must not snapshot that: turning auto off the next
    /// day has to return the warmth the user had before they first enabled it.
    func testDisablingAfterRelaunchRestoresWarmthFromBeforeAutoWasEnabled() {
        let (firstSession, _) = isolatedManager(warmth: 0.3)
        firstSession.locationCoordinatesHook = { nil }
        firstSession.apply(enabled: true)
        // Quit with auto still on; the persisted display warmth is now the night value.

        let relaunchedSettings = AppSettings(defaults: testDefaults)
        let (relaunched, brightnessManager) = isolatedManager(warmth: 0.8, settings: relaunchedSettings)
        relaunched.locationCoordinatesHook = { nil }
        relaunched.apply(enabled: true)
        relaunched.apply(enabled: false)

        XCTAssertEqual(
            brightnessManager.displays.first?.warmth ?? -1, 0.3, accuracy: 0.0001,
            "Disabling auto warmth must restore the warmth from before auto was enabled, not the night tint"
        )
    }

    /// A snapshot left behind while auto was off at launch (it was switched off outside the app)
    /// is stale; enabling auto later must snapshot the warmth the user has then.
    func testStalePreAutoWarmthIsDiscardedWhenAutoLaunchesDisabled() {
        let (firstSession, _) = isolatedManager(warmth: 0.3)
        firstSession.locationCoordinatesHook = { nil }
        firstSession.apply(enabled: true)

        let relaunchedSettings = AppSettings(defaults: testDefaults)
        let (relaunched, brightnessManager) = isolatedManager(warmth: 0.6, settings: relaunchedSettings)
        relaunched.locationCoordinatesHook = { nil }
        relaunched.apply(enabled: false)
        relaunched.apply(enabled: true)
        relaunched.apply(enabled: false)

        XCTAssertEqual(
            brightnessManager.displays.first?.warmth ?? -1, 0.6, accuracy: 0.0001,
            "Enabling auto must snapshot the current warmth when no auto session carried over"
        )
    }

    /// Disabling ends the auto session, so the next launch must not restore its snapshot again.
    func testDisablingClearsThePersistedPreAutoWarmth() {
        let (firstSession, _) = isolatedManager(warmth: 0.3)
        firstSession.locationCoordinatesHook = { nil }
        firstSession.apply(enabled: true)
        firstSession.apply(enabled: false)

        let relaunchedSettings = AppSettings(defaults: testDefaults)
        let (relaunched, brightnessManager) = isolatedManager(warmth: 0.6, settings: relaunchedSettings)
        relaunched.locationCoordinatesHook = { nil }
        relaunched.apply(enabled: true)
        relaunched.apply(enabled: false)

        XCTAssertEqual(brightnessManager.displays.first?.warmth ?? -1, 0.6, accuracy: 0.0001)
    }

    // MARK: - Zero Transition Duration

    func testZeroTransitionDuration() {
        let sunrise = makeDate(hour: 6, minute: 0)
        let sunset = makeDate(hour: 20, minute: 0)
        let halfTransition: Double = 0 // instant transition

        // At sunrise exactly with zero duration, should return progress 1.0 (instant complete)
        let stateAtSunrise = ColorTemperatureManager.determineState(
            now: makeDate(hour: 6, minute: 0),
            sunrise: sunrise,
            sunset: sunset,
            halfTransition: halfTransition
        )
        if case let .sunriseTransition(progress) = stateAtSunrise {
            XCTAssertEqual(progress, 1.0, accuracy: 0.01)
        } else {
            XCTFail("Expected sunriseTransition, got \(stateAtSunrise)")
        }

        // At sunset exactly with zero duration, should return progress 1.0
        let stateAtSunset = ColorTemperatureManager.determineState(
            now: makeDate(hour: 20, minute: 0),
            sunrise: sunrise,
            sunset: sunset,
            halfTransition: halfTransition
        )
        if case let .sunsetTransition(progress) = stateAtSunset {
            XCTAssertEqual(progress, 1.0, accuracy: 0.01)
        } else {
            XCTFail("Expected sunsetTransition, got \(stateAtSunset)")
        }

        let beforeSunrise = ColorTemperatureManager.determineState(
            now: makeDate(hour: 5, minute: 59),
            sunrise: sunrise,
            sunset: sunset,
            halfTransition: halfTransition
        )
        XCTAssertEqual(beforeSunrise, .night)

        let afterSunrise = ColorTemperatureManager.determineState(
            now: makeDate(hour: 6, minute: 1),
            sunrise: sunrise,
            sunset: sunset,
            halfTransition: halfTransition
        )
        XCTAssertEqual(afterSunrise, .day)
    }

    // MARK: - Wake Monitoring

    func testWorkspaceWakeMonitorHandlesScreenWake() async {
        let notificationCenter = NotificationCenter()
        var updateCount = 0
        let monitor = WorkspaceWakeMonitor(
            notificationCenter: notificationCenter,
            delay: .milliseconds(10)
        ) {
            updateCount += 1
        }
        monitor.start()

        notificationCenter.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(updateCount, 1)
        monitor.stop()
    }

    /// A single re-apply one second after wake fires too early on real hardware: display
    /// re-enumeration can still be in progress, and macOS wiped the gamma table ~8 seconds after
    /// the display came back. A second settle pass closes that window.
    func testWorkspaceWakeMonitorFiresAgainAfterTheSettleDelay() async {
        let notificationCenter = NotificationCenter()
        var updateCount = 0
        let monitor = WorkspaceWakeMonitor(
            notificationCenter: notificationCenter,
            delay: .milliseconds(10),
            settleDelay: .milliseconds(30)
        ) {
            updateCount += 1
        }
        monitor.start()

        notificationCenter.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        try? await Task.sleep(for: .milliseconds(120))

        XCTAssertEqual(updateCount, 2, "Once after the initial delay, once after the settle delay")
        monitor.stop()
    }

    /// Without a settle delay the behaviour is unchanged — one callback per coalesced wake.
    func testWorkspaceWakeMonitorFiresOnceWithoutASettleDelay() async {
        let notificationCenter = NotificationCenter()
        var updateCount = 0
        let monitor = WorkspaceWakeMonitor(
            notificationCenter: notificationCenter,
            delay: .milliseconds(10)
        ) {
            updateCount += 1
        }
        monitor.start()

        notificationCenter.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        try? await Task.sleep(for: .milliseconds(120))

        XCTAssertEqual(updateCount, 1)
        monitor.stop()
    }

    func testWorkspaceWakeMonitorHandlesSystemWake() async {
        let notificationCenter = NotificationCenter()
        var updateCount = 0
        let monitor = WorkspaceWakeMonitor(
            notificationCenter: notificationCenter,
            delay: .milliseconds(10)
        ) {
            updateCount += 1
        }
        monitor.start()

        notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(updateCount, 1)
        monitor.stop()
    }

    func testWorkspaceWakeMonitorCoalescesDuplicateWakeEvents() async {
        let notificationCenter = NotificationCenter()
        var updateCount = 0
        let monitor = WorkspaceWakeMonitor(
            notificationCenter: notificationCenter,
            delay: .milliseconds(10)
        ) {
            updateCount += 1
        }
        monitor.start()

        notificationCenter.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(updateCount, 1)
        monitor.stop()
    }

    func testWorkspaceWakeMonitorStopCancelsPendingUpdate() async {
        let notificationCenter = NotificationCenter()
        var updateCount = 0
        let monitor = WorkspaceWakeMonitor(
            notificationCenter: notificationCenter,
            delay: .milliseconds(30)
        ) {
            updateCount += 1
        }
        monitor.start()

        notificationCenter.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        monitor.stop()
        try? await Task.sleep(for: .milliseconds(60))

        XCTAssertEqual(updateCount, 0)
    }
}

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
    // MARK: - Helpers

    private func makeDate(
        year: Int = 2026, month: Int = 6, day: Int = 15,
        hour: Int, minute: Int, second: Int = 0
    ) -> Date {
        Calendar.current.date(from: DateComponents(
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
    private func isolatedManager() -> (ColorTemperatureManager, BrightnessManager) {
        let brightnessManager = BrightnessManager(forTesting: true)
        brightnessManager.applyGammaHook = { _, _, _, _ in }
        // Enabling auto warmth animates its first update, which applies gamma from a detached
        // task. Forcing the non-animated path keeps these assertions synchronous.
        brightnessManager.canAnimateTransitionsHook = { false }
        // Pin identity so the key doesn't depend on whatever EDID the host reports for this ID.
        brightnessManager.displayIdentityHook = { "identity-\($0)" }
        brightnessManager.displays = [
            ExternalDisplay(id: 1, name: "Test", brightness: 1.0, warmth: 0.3, contrast: 0.5),
        ]
        return (ColorTemperatureManager(brightnessManager: brightnessManager), brightnessManager)
    }

    func testManualOverrideDeactivatesAutoMode() {
        let (manager, _) = isolatedManager()
        manager.apply(enabled: true)
        manager.isActive = true

        manager.notifyManualWarmthChange()

        XCTAssertFalse(manager.isActive, "Manual change should deactivate auto mode")
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

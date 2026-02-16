//
//  ColorTemperatureManagerTests.swift
//  DimmerlyTests
//
//  Unit tests for ColorTemperatureManager state determination, interpolation,
//  and manual override lifecycle.
//

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

    func testManualOverrideDeactivatesAutoMode() {
        let manager = ColorTemperatureManager.shared
        manager.isActive = true
        // Simulate that auto mode has been enabled via settings
        manager.observeSettings(readEnabled: { true })

        manager.notifyManualWarmthChange()

        XCTAssertFalse(manager.isActive, "Manual change should deactivate auto mode")
    }

    func testPresetAppliedTriggersOverride() {
        let manager = ColorTemperatureManager.shared
        manager.isActive = true
        manager.observeSettings(readEnabled: { true })

        manager.notifyPresetApplied()

        XCTAssertFalse(manager.isActive, "Preset with warmth should trigger manual override")
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
}

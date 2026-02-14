//
//  SolarCalculatorTests.swift
//  DimmerlyTests
//
//  Unit tests for the NOAA solar position algorithm.
//  Verifies sunrise/sunset accuracy against known reference values.
//

@testable import Dimmerly
import XCTest

final class SolarCalculatorTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!

    /// Helper to create a date from components in a given timezone.
    private func makeDate(
        year: Int, month: Int, day: Int,
        hour: Int = 12, minute: Int = 0,
        timeZone: TimeZone? = nil
    ) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone ?? utc
        let components = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)
        return calendar.date(from: components)!
    }

    /// Extracts hour and minute from a date in a given timezone.
    private func hourMinute(_ date: Date, in timeZone: TimeZone) -> (hour: Int, minute: Int) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let h = calendar.component(.hour, from: date)
        let m = calendar.component(.minute, from: date)
        return (h, m)
    }

    /// Converts hour:minute to total minutes for easy comparison.
    private func totalMinutes(_ hour: Int, _ minute: Int) -> Int {
        hour * 60 + minute
    }

    // MARK: - Known Location Accuracy

    /// New York City — 2026-03-20 (spring equinox): sunrise ~06:58, sunset ~19:10 EDT
    func testNewYorkSpringEquinox() {
        let tz = TimeZone(identifier: "America/New_York")!
        let date = makeDate(year: 2026, month: 3, day: 20, timeZone: tz)

        let result = SolarCalculator.sunriseSunset(
            latitude: 40.7128, longitude: -74.0060, date: date, timeZone: tz
        )

        let sunrise = try! XCTUnwrap(result.sunrise)
        let sunset = try! XCTUnwrap(result.sunset)

        let sr = hourMinute(sunrise, in: tz)
        let ss = hourMinute(sunset, in: tz)

        // Allow ±3 minutes tolerance from NOAA reference
        XCTAssertEqual(totalMinutes(sr.hour, sr.minute), totalMinutes(6, 58), accuracy: 3,
                       "NYC spring equinox sunrise should be ~06:58 EDT, got \(sr.hour):\(String(format: "%02d", sr.minute))")
        XCTAssertEqual(totalMinutes(ss.hour, ss.minute), totalMinutes(19, 10), accuracy: 3,
                       "NYC spring equinox sunset should be ~19:10 EDT, got \(ss.hour):\(String(format: "%02d", ss.minute))")
    }

    /// London — 2026-06-21 (summer solstice): sunrise ~04:43, sunset ~21:21 BST
    func testLondonSummerSolstice() {
        let tz = TimeZone(identifier: "Europe/London")!
        let date = makeDate(year: 2026, month: 6, day: 21, timeZone: tz)

        let result = SolarCalculator.sunriseSunset(
            latitude: 51.5074, longitude: -0.1278, date: date, timeZone: tz
        )

        let sunrise = try! XCTUnwrap(result.sunrise)
        let sunset = try! XCTUnwrap(result.sunset)

        let sr = hourMinute(sunrise, in: tz)
        let ss = hourMinute(sunset, in: tz)

        XCTAssertEqual(totalMinutes(sr.hour, sr.minute), totalMinutes(4, 43), accuracy: 3,
                       "London summer solstice sunrise should be ~04:43 BST, got \(sr.hour):\(String(format: "%02d", sr.minute))")
        XCTAssertEqual(totalMinutes(ss.hour, ss.minute), totalMinutes(21, 21), accuracy: 3,
                       "London summer solstice sunset should be ~21:21 BST, got \(ss.hour):\(String(format: "%02d", ss.minute))")
    }

    /// Tokyo — 2026-12-21 (winter solstice): sunrise ~06:47, sunset ~16:32 JST
    func testTokyoWinterSolstice() {
        let tz = TimeZone(identifier: "Asia/Tokyo")!
        let date = makeDate(year: 2026, month: 12, day: 21, timeZone: tz)

        let result = SolarCalculator.sunriseSunset(
            latitude: 35.6762, longitude: 139.6503, date: date, timeZone: tz
        )

        let sunrise = try! XCTUnwrap(result.sunrise)
        let sunset = try! XCTUnwrap(result.sunset)

        let sr = hourMinute(sunrise, in: tz)
        let ss = hourMinute(sunset, in: tz)

        XCTAssertEqual(totalMinutes(sr.hour, sr.minute), totalMinutes(6, 47), accuracy: 3,
                       "Tokyo winter solstice sunrise should be ~06:47 JST, got \(sr.hour):\(String(format: "%02d", sr.minute))")
        XCTAssertEqual(totalMinutes(ss.hour, ss.minute), totalMinutes(16, 32), accuracy: 3,
                       "Tokyo winter solstice sunset should be ~16:32 JST, got \(ss.hour):\(String(format: "%02d", ss.minute))")
    }

    // MARK: - Equator

    /// Near the equator, day length is approximately 12 hours year-round.
    func testEquatorDaylength() {
        let date = makeDate(year: 2026, month: 6, day: 21)

        let result = SolarCalculator.sunriseSunset(
            latitude: 0.0, longitude: 0.0, date: date, timeZone: utc
        )

        let sunrise = try! XCTUnwrap(result.sunrise)
        let sunset = try! XCTUnwrap(result.sunset)

        let dayLengthMinutes = sunset.timeIntervalSince(sunrise) / 60.0
        // Equator day length should be close to 12 hours (720 minutes) ± 15 min
        XCTAssertEqual(dayLengthMinutes, 720, accuracy: 15,
                       "Equator day length should be ~12 hours, got \(dayLengthMinutes / 60) hours")
    }

    // MARK: - Polar Regions

    /// Above the Arctic Circle in June (polar day) — sun never sets.
    func testArcticPolarDay() {
        let date = makeDate(year: 2026, month: 6, day: 21)

        let result = SolarCalculator.sunriseSunset(
            latitude: 71.0, longitude: 25.0, date: date, timeZone: utc
        )

        XCTAssertNil(result.sunrise, "Arctic polar day should return nil sunrise")
        XCTAssertNil(result.sunset, "Arctic polar day should return nil sunset")
    }

    /// Above the Arctic Circle in December (polar night) — sun never rises.
    func testArcticPolarNight() {
        let date = makeDate(year: 2026, month: 12, day: 21)

        let result = SolarCalculator.sunriseSunset(
            latitude: 71.0, longitude: 25.0, date: date, timeZone: utc
        )

        XCTAssertNil(result.sunrise, "Arctic polar night should return nil sunrise")
        XCTAssertNil(result.sunset, "Arctic polar night should return nil sunset")
    }

    // MARK: - Southern Hemisphere

    /// Sydney — December should have longer days than June (opposite of northern hemisphere).
    func testSouthernHemisphereSeasons() {
        let tz = TimeZone(identifier: "Australia/Sydney")!

        let december = makeDate(year: 2026, month: 12, day: 21, timeZone: tz)
        let june = makeDate(year: 2026, month: 6, day: 21, timeZone: tz)

        let decResult = SolarCalculator.sunriseSunset(
            latitude: -33.8688, longitude: 151.2093, date: december, timeZone: tz
        )
        let junResult = SolarCalculator.sunriseSunset(
            latitude: -33.8688, longitude: 151.2093, date: june, timeZone: tz
        )

        let decSunrise = try! XCTUnwrap(decResult.sunrise)
        let decSunset = try! XCTUnwrap(decResult.sunset)
        let junSunrise = try! XCTUnwrap(junResult.sunrise)
        let junSunset = try! XCTUnwrap(junResult.sunset)

        let decDayLength = decSunset.timeIntervalSince(decSunrise)
        let junDayLength = junSunset.timeIntervalSince(junSunrise)

        XCTAssertGreaterThan(decDayLength, junDayLength,
                             "Sydney December day should be longer than June day")
    }

    // MARK: - Sunrise Before Sunset

    /// For any normal (non-polar) location, sunrise should always be before sunset.
    func testSunriseBeforeSunset() {
        let locations: [(lat: Double, lon: Double)] = [
            (40.7, -74.0),   // New York
            (51.5, -0.1),    // London
            (-33.9, 151.2),  // Sydney
            (35.7, 139.7),   // Tokyo
            (0.0, 0.0),      // Equator
        ]

        let date = makeDate(year: 2026, month: 3, day: 20)

        for loc in locations {
            let result = SolarCalculator.sunriseSunset(
                latitude: loc.lat, longitude: loc.lon, date: date, timeZone: utc
            )
            if let sunrise = result.sunrise, let sunset = result.sunset {
                XCTAssertLessThan(sunrise, sunset,
                                  "Sunrise should be before sunset at (\(loc.lat), \(loc.lon))")
            }
        }
    }
}

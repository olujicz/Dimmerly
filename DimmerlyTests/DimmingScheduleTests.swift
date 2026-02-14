//
//  DimmingScheduleTests.swift
//  DimmerlyTests
//
//  Unit tests for DimmingSchedule and ScheduleTrigger models.
//  Tests Codable conformance, display descriptions, and computed properties.
//

@testable import Dimmerly
import XCTest

final class DimmingScheduleTests: XCTestCase {

    // MARK: - ScheduleTrigger Codable

    func testFixedTimeCodableRoundTrip() throws {
        let trigger = ScheduleTrigger.fixedTime(hour: 22, minute: 30)
        let data = try JSONEncoder().encode(trigger)
        let decoded = try JSONDecoder().decode(ScheduleTrigger.self, from: data)
        XCTAssertEqual(decoded, trigger)
    }

    func testSunriseCodableRoundTrip() throws {
        let trigger = ScheduleTrigger.sunrise(offsetMinutes: -15)
        let data = try JSONEncoder().encode(trigger)
        let decoded = try JSONDecoder().decode(ScheduleTrigger.self, from: data)
        XCTAssertEqual(decoded, trigger)
    }

    func testSunsetCodableRoundTrip() throws {
        let trigger = ScheduleTrigger.sunset(offsetMinutes: 30)
        let data = try JSONEncoder().encode(trigger)
        let decoded = try JSONDecoder().decode(ScheduleTrigger.self, from: data)
        XCTAssertEqual(decoded, trigger)
    }

    // MARK: - ScheduleTrigger requiresLocation

    func testFixedTimeDoesNotRequireLocation() {
        let trigger = ScheduleTrigger.fixedTime(hour: 10, minute: 0)
        XCTAssertFalse(trigger.requiresLocation)
    }

    func testSunriseRequiresLocation() {
        let trigger = ScheduleTrigger.sunrise(offsetMinutes: 0)
        XCTAssertTrue(trigger.requiresLocation)
    }

    func testSunsetRequiresLocation() {
        let trigger = ScheduleTrigger.sunset(offsetMinutes: 0)
        XCTAssertTrue(trigger.requiresLocation)
    }

    // MARK: - ScheduleTrigger displayDescription

    func testFixedTimeDisplayDescription() {
        let trigger = ScheduleTrigger.fixedTime(hour: 14, minute: 30)
        let desc = trigger.displayDescription
        // Should produce a locale-formatted time containing "14" or "2" (for 2:30 PM)
        XCTAssertFalse(desc.isEmpty, "Fixed time should produce a non-empty description")
        // Verify it contains the minute component
        XCTAssertTrue(desc.contains("30"), "Should contain minute value, got: \(desc)")
    }

    func testSunriseNoOffsetDescription() {
        let trigger = ScheduleTrigger.sunrise(offsetMinutes: 0)
        XCTAssertTrue(trigger.displayDescription.lowercased().contains("sunrise"),
                       "Should contain 'sunrise', got: \(trigger.displayDescription)")
    }

    func testSunrisePositiveOffsetDescription() {
        let trigger = ScheduleTrigger.sunrise(offsetMinutes: 30)
        let desc = trigger.displayDescription
        XCTAssertTrue(desc.contains("30"), "Should contain offset value, got: \(desc)")
        XCTAssertTrue(desc.lowercased().contains("after") || desc.lowercased().contains("sunrise"),
                       "Should indicate after sunrise, got: \(desc)")
    }

    func testSunriseNegativeOffsetDescription() {
        let trigger = ScheduleTrigger.sunrise(offsetMinutes: -15)
        let desc = trigger.displayDescription
        XCTAssertTrue(desc.contains("15"), "Should contain absolute offset value, got: \(desc)")
        XCTAssertTrue(desc.lowercased().contains("before") || desc.lowercased().contains("sunrise"),
                       "Should indicate before sunrise, got: \(desc)")
    }

    func testSunsetNoOffsetDescription() {
        let trigger = ScheduleTrigger.sunset(offsetMinutes: 0)
        XCTAssertTrue(trigger.displayDescription.lowercased().contains("sunset"),
                       "Should contain 'sunset', got: \(trigger.displayDescription)")
    }

    func testSunsetPositiveOffsetDescription() {
        let trigger = ScheduleTrigger.sunset(offsetMinutes: 45)
        let desc = trigger.displayDescription
        XCTAssertTrue(desc.contains("45"), "Should contain offset value, got: \(desc)")
    }

    func testSunsetNegativeOffsetDescription() {
        let trigger = ScheduleTrigger.sunset(offsetMinutes: -20)
        let desc = trigger.displayDescription
        XCTAssertTrue(desc.contains("20"), "Should contain absolute offset value, got: \(desc)")
    }

    // MARK: - DimmingSchedule Codable

    func testDimmingScheduleCodableRoundTrip() throws {
        let presetID = UUID()
        let schedule = DimmingSchedule(
            name: "Evening",
            trigger: .fixedTime(hour: 20, minute: 0),
            presetID: presetID,
            isEnabled: true
        )

        let data = try JSONEncoder().encode(schedule)
        let decoded = try JSONDecoder().decode(DimmingSchedule.self, from: data)

        XCTAssertEqual(decoded.id, schedule.id)
        XCTAssertEqual(decoded.name, "Evening")
        XCTAssertEqual(decoded.trigger, .fixedTime(hour: 20, minute: 0))
        XCTAssertEqual(decoded.presetID, presetID)
        XCTAssertTrue(decoded.isEnabled)
    }

    func testDimmingScheduleCodableWithSunsetTrigger() throws {
        let schedule = DimmingSchedule(
            name: "Night",
            trigger: .sunset(offsetMinutes: -30),
            presetID: UUID(),
            isEnabled: false
        )

        let data = try JSONEncoder().encode(schedule)
        let decoded = try JSONDecoder().decode(DimmingSchedule.self, from: data)

        XCTAssertEqual(decoded.name, "Night")
        XCTAssertEqual(decoded.trigger, .sunset(offsetMinutes: -30))
        XCTAssertFalse(decoded.isEnabled)
    }

    // MARK: - DimmingSchedule Equatable

    func testDimmingScheduleEquatable() {
        let id = UUID()
        let presetID = UUID()
        let date = Date()

        let a = DimmingSchedule(id: id, name: "Test", trigger: .fixedTime(hour: 8, minute: 0),
                                presetID: presetID, isEnabled: true, createdAt: date)
        let b = DimmingSchedule(id: id, name: "Test", trigger: .fixedTime(hour: 8, minute: 0),
                                presetID: presetID, isEnabled: true, createdAt: date)

        XCTAssertEqual(a, b)
    }

    func testDimmingScheduleNotEqualDifferentTrigger() {
        let id = UUID()
        let presetID = UUID()
        let date = Date()

        let a = DimmingSchedule(id: id, name: "Test", trigger: .fixedTime(hour: 8, minute: 0),
                                presetID: presetID, isEnabled: true, createdAt: date)
        let b = DimmingSchedule(id: id, name: "Test", trigger: .fixedTime(hour: 9, minute: 0),
                                presetID: presetID, isEnabled: true, createdAt: date)

        XCTAssertNotEqual(a, b)
    }

    // MARK: - ScheduleTrigger Equatable

    func testScheduleTriggerEquatable() {
        XCTAssertEqual(ScheduleTrigger.fixedTime(hour: 10, minute: 30),
                       ScheduleTrigger.fixedTime(hour: 10, minute: 30))
        XCTAssertNotEqual(ScheduleTrigger.fixedTime(hour: 10, minute: 30),
                          ScheduleTrigger.fixedTime(hour: 10, minute: 31))
        XCTAssertNotEqual(ScheduleTrigger.sunrise(offsetMinutes: 0),
                          ScheduleTrigger.sunset(offsetMinutes: 0))
        XCTAssertEqual(ScheduleTrigger.sunrise(offsetMinutes: -15),
                       ScheduleTrigger.sunrise(offsetMinutes: -15))
    }
}

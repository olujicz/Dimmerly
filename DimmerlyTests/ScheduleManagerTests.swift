//
//  ScheduleManagerTests.swift
//  DimmerlyTests
//
//  Unit tests for ScheduleManager CRUD, firing logic, and state management.
//

@testable import Dimmerly
import XCTest

@MainActor
final class ScheduleManagerTests: XCTestCase {
    private var manager: ScheduleManager!

    override func setUp() async throws {
        UserDefaults.standard.removeObject(forKey: "dimmerlyDimmingSchedules")
        manager = ScheduleManager()
        manager.schedules = []
    }

    override func tearDown() async throws {
        manager = nil
        UserDefaults.standard.removeObject(forKey: "dimmerlyDimmingSchedules")
    }

    // MARK: - Helpers

    private func makeDate(
        year: Int = 2026, month: Int = 1, day: Int = 1,
        hour: Int, minute: Int, second: Int = 0
    ) -> Date {
        Calendar.current.date(from: DateComponents(
            year: year, month: month, day: day,
            hour: hour, minute: minute, second: second
        ))!
    }

    private func makeSchedule(
        id: UUID = UUID(),
        name: String = "Test",
        hour: Int = 10,
        minute: Int = 0,
        presetID: UUID = UUID(),
        isEnabled: Bool = true
    ) -> DimmingSchedule {
        DimmingSchedule(
            id: id, name: name,
            trigger: .fixedTime(hour: hour, minute: minute),
            presetID: presetID, isEnabled: isEnabled
        )
    }

    // MARK: - CRUD

    func testAddSchedule() {
        let schedule = makeSchedule(name: "Morning")
        manager.addSchedule(schedule)
        XCTAssertEqual(manager.schedules.count, 1)
        XCTAssertEqual(manager.schedules.first?.name, "Morning")
    }

    func testDeleteSchedule() {
        let schedule = makeSchedule()
        manager.addSchedule(schedule)
        XCTAssertEqual(manager.schedules.count, 1)

        manager.deleteSchedule(id: schedule.id)
        XCTAssertTrue(manager.schedules.isEmpty)
    }

    func testDeleteNonexistentScheduleIsNoOp() {
        let schedule = makeSchedule()
        manager.addSchedule(schedule)
        manager.deleteSchedule(id: UUID())
        XCTAssertEqual(manager.schedules.count, 1, "Should not remove unrelated schedule")
    }

    func testToggleSchedule() {
        let schedule = makeSchedule(isEnabled: true)
        manager.addSchedule(schedule)
        XCTAssertTrue(manager.schedules[0].isEnabled)

        manager.toggleSchedule(id: schedule.id)
        XCTAssertFalse(manager.schedules[0].isEnabled)

        manager.toggleSchedule(id: schedule.id)
        XCTAssertTrue(manager.schedules[0].isEnabled)
    }

    func testUpdateSchedule() {
        let id = UUID()
        let original = makeSchedule(id: id, name: "Original", hour: 10)
        manager.addSchedule(original)

        let updated = DimmingSchedule(
            id: id, name: "Updated",
            trigger: .fixedTime(hour: 22, minute: 30),
            presetID: original.presetID, isEnabled: true
        )
        manager.updateSchedule(updated)

        XCTAssertEqual(manager.schedules.count, 1)
        XCTAssertEqual(manager.schedules[0].name, "Updated")
        XCTAssertEqual(manager.schedules[0].trigger, .fixedTime(hour: 22, minute: 30))
    }

    func testUpdateNonexistentScheduleIsNoOp() {
        let schedule = makeSchedule(name: "Existing")
        manager.addSchedule(schedule)

        let orphan = makeSchedule(id: UUID(), name: "Orphan")
        manager.updateSchedule(orphan)

        XCTAssertEqual(manager.schedules.count, 1)
        XCTAssertEqual(manager.schedules[0].name, "Existing")
    }

    // MARK: - Firing Logic

    func testCheckSchedulesCatchesUpAfterLongGap() {
        var triggerCount = 0
        manager.onScheduleTriggered = { _ in triggerCount += 1 }

        let schedule = makeSchedule(hour: 10, minute: 0)
        manager.addSchedule(schedule)

        let before = makeDate(hour: 9, minute: 58, second: 30)
        manager.checkSchedules(now: before)
        XCTAssertEqual(triggerCount, 0)

        let after = makeDate(hour: 10, minute: 5)
        manager.checkSchedules(now: after)
        XCTAssertEqual(triggerCount, 1, "Should fire once after gap crossing trigger time")
    }

    func testDisabledScheduleDoesNotFire() {
        var triggerCount = 0
        manager.onScheduleTriggered = { _ in triggerCount += 1 }

        let schedule = makeSchedule(hour: 10, minute: 0, isEnabled: false)
        manager.addSchedule(schedule)

        let before = makeDate(hour: 9, minute: 59)
        manager.checkSchedules(now: before)

        let after = makeDate(hour: 10, minute: 1)
        manager.checkSchedules(now: after)

        XCTAssertEqual(triggerCount, 0, "Disabled schedule should not fire")
    }

    func testSameDayDuplicatePrevention() {
        var triggerCount = 0
        manager.onScheduleTriggered = { _ in triggerCount += 1 }

        let schedule = makeSchedule(hour: 10, minute: 0)
        manager.addSchedule(schedule)

        // First check crosses trigger
        let before = makeDate(hour: 9, minute: 59)
        manager.checkSchedules(now: before)
        let after = makeDate(hour: 10, minute: 1)
        manager.checkSchedules(now: after)
        XCTAssertEqual(triggerCount, 1)

        // Second check same day, later time — should NOT fire again
        let later = makeDate(hour: 10, minute: 30)
        manager.checkSchedules(now: later)
        XCTAssertEqual(triggerCount, 1, "Should not fire twice on the same day")
    }

    func testNewDayResetsFireState() {
        var triggerCount = 0
        manager.onScheduleTriggered = { _ in triggerCount += 1 }

        let schedule = makeSchedule(hour: 10, minute: 0)
        manager.addSchedule(schedule)

        // Day 1: fire
        let day1Before = makeDate(day: 1, hour: 9, minute: 59)
        manager.checkSchedules(now: day1Before)
        let day1After = makeDate(day: 1, hour: 10, minute: 1)
        manager.checkSchedules(now: day1After)
        XCTAssertEqual(triggerCount, 1)

        // Day 2: should fire again
        let day2Before = makeDate(day: 2, hour: 9, minute: 59)
        manager.checkSchedules(now: day2Before)
        let day2After = makeDate(day: 2, hour: 10, minute: 1)
        manager.checkSchedules(now: day2After)
        XCTAssertEqual(triggerCount, 2, "Should fire again on a new day")
    }

    func testUpdateScheduleClearsSameDayFiredState() {
        var triggerCount = 0
        manager.onScheduleTriggered = { _ in triggerCount += 1 }

        let id = UUID()
        let original = makeSchedule(id: id, hour: 10, minute: 0)
        manager.addSchedule(original)

        // Fire at 10:00
        let firstBefore = makeDate(hour: 9, minute: 59)
        manager.checkSchedules(now: firstBefore)
        let firstAfter = makeDate(hour: 10, minute: 0, second: 30)
        manager.checkSchedules(now: firstAfter)
        XCTAssertEqual(triggerCount, 1)

        // Update to 10:01
        let updated = DimmingSchedule(
            id: id, name: "Edited",
            trigger: .fixedTime(hour: 10, minute: 1),
            presetID: original.presetID, isEnabled: true
        )
        manager.updateSchedule(updated)

        // Should fire again after edit
        let secondAfter = makeDate(hour: 10, minute: 1, second: 30)
        manager.checkSchedules(now: secondAfter)
        XCTAssertEqual(triggerCount, 2, "Edited schedule should fire again same day")
    }

    func testToggleDisableClearsFiredState() {
        var triggerCount = 0
        manager.onScheduleTriggered = { _ in triggerCount += 1 }

        let schedule = makeSchedule(hour: 10, minute: 0)
        manager.addSchedule(schedule)

        // Fire at 10:00
        let before = makeDate(hour: 9, minute: 59)
        manager.checkSchedules(now: before)
        let after = makeDate(hour: 10, minute: 1)
        manager.checkSchedules(now: after)
        XCTAssertEqual(triggerCount, 1)

        // Disable — this clears the firedToday state
        manager.toggleSchedule(id: schedule.id)
        XCTAssertFalse(manager.schedules[0].isEnabled)

        // Re-enable
        manager.toggleSchedule(id: schedule.id)
        XCTAssertTrue(manager.schedules[0].isEnabled)

        // Set lastCheckDate back before trigger so the window includes 10:00 again
        let beforeAgain = makeDate(hour: 9, minute: 58)
        manager.checkSchedules(now: beforeAgain)
        let afterAgain = makeDate(hour: 10, minute: 1)
        manager.checkSchedules(now: afterAgain)
        XCTAssertEqual(triggerCount, 2, "Re-enabled schedule should fire again after toggle cleared state")
    }

    func testMultipleSchedulesFire() {
        var firedPresets: [UUID] = []
        manager.onScheduleTriggered = { firedPresets.append($0) }

        let preset1 = UUID()
        let preset2 = UUID()
        manager.addSchedule(makeSchedule(name: "A", hour: 10, minute: 0, presetID: preset1))
        manager.addSchedule(makeSchedule(name: "B", hour: 10, minute: 0, presetID: preset2))

        let before = makeDate(hour: 9, minute: 59)
        manager.checkSchedules(now: before)
        let after = makeDate(hour: 10, minute: 1)
        manager.checkSchedules(now: after)

        XCTAssertEqual(firedPresets.count, 2, "Both schedules should fire")
        XCTAssertTrue(firedPresets.contains(preset1))
        XCTAssertTrue(firedPresets.contains(preset2))
    }

    // MARK: - resolveTriggerDate

    func testResolveTriggerDateFixedTime() throws {
        let date = makeDate(hour: 12, minute: 0)
        let resolved = manager.resolveTriggerDate(.fixedTime(hour: 22, minute: 30), on: date)

        let unwrapped = try XCTUnwrap(resolved)
        let components = Calendar.current.dateComponents([.hour, .minute], from: unwrapped)
        XCTAssertEqual(components.hour, 22)
        XCTAssertEqual(components.minute, 30)
    }

    func testResolveTriggerDateSunriseReturnsDateOrNil() {
        // Result depends on whether LocationProvider.shared has coordinates.
        // In CI with no location, this returns nil. On a developer machine, it returns a Date.
        // Either way, if non-nil, it should be a valid time on the same day.
        let date = makeDate(hour: 12, minute: 0)
        let resolved = manager.resolveTriggerDate(.sunrise(offsetMinutes: 0), on: date)
        if let resolved {
            let sameDay = Calendar.current.isDate(resolved, inSameDayAs: date)
            XCTAssertTrue(sameDay, "Resolved sunrise should be on the same day")
        }
    }

    func testResolveTriggerDateSunsetReturnsDateOrNil() {
        let date = makeDate(hour: 12, minute: 0)
        let resolved = manager.resolveTriggerDate(.sunset(offsetMinutes: 0), on: date)
        if let resolved {
            let sameDay = Calendar.current.isDate(resolved, inSameDayAs: date)
            XCTAssertTrue(sameDay, "Resolved sunset should be on the same day")
        }
    }

    // MARK: - Persistence

    func testSchedulesPersistAcrossInstances() {
        let schedule = makeSchedule(name: "Persistent")
        manager.addSchedule(schedule)

        // Create a new manager instance — should load from UserDefaults
        let newManager = ScheduleManager()
        XCTAssertEqual(newManager.schedules.count, 1)
        XCTAssertEqual(newManager.schedules.first?.name, "Persistent")
        XCTAssertEqual(newManager.schedules.first?.id, schedule.id)
    }
}

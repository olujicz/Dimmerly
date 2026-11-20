@testable import Dimmerly
import XCTest

@MainActor
final class RatingPromptTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private lazy var defaults: UserDefaults = {
        let suiteName = "RatingPromptTests-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suiteName) }
        return UserDefaults(suiteName: suiteName)!
    }()

    private func day(_ offset: Int) -> Date {
        calendar.date(byAdding: .day, value: offset, to: Date(timeIntervalSince1970: 1_800_000_000))!
    }

    private func makeTracker() -> RatingPromptTracker {
        RatingPromptTracker(defaults: defaults, calendar: calendar)
    }

    /// First use on day 0 and one preset on each of days 1 through 3.
    private func useForSeveralDays(_ tracker: RatingPromptTracker) {
        tracker.recordLaunch(now: day(0))
        for offset in 1 ... 3 {
            tracker.recordPresetApplied(now: day(offset))
        }
    }

    func testNoPromptOnFirstLaunch() {
        let tracker = makeTracker()
        tracker.recordLaunch(now: day(0))
        XCTAssertFalse(tracker.claimPrompt(now: day(0), version: "1.5.1"))
    }

    func testNoPromptWithoutPresetUse() {
        let tracker = makeTracker()
        tracker.recordLaunch(now: day(0))
        XCTAssertFalse(tracker.claimPrompt(now: day(30), version: "1.5.1"))
    }

    func testNoPromptBeforeAWeekOfUse() {
        let tracker = makeTracker()
        useForSeveralDays(tracker)
        XCTAssertFalse(tracker.claimPrompt(now: day(6), version: "1.5.1"))
        XCTAssertTrue(tracker.claimPrompt(now: day(7), version: "1.5.1"))
    }

    func testManyPresetsOnOneDayCountAsOneActiveDay() {
        let tracker = makeTracker()
        tracker.recordLaunch(now: day(0))
        for _ in 1 ... 10 {
            tracker.recordPresetApplied(now: day(1))
        }
        XCTAssertEqual(tracker.stats.activeDays, 1)
        XCTAssertEqual(tracker.stats.presetApplications, 10)
        XCTAssertFalse(tracker.claimPrompt(now: day(30), version: "1.5.1"))
    }

    func testPromptOnlyOncePerVersion() {
        let tracker = makeTracker()
        useForSeveralDays(tracker)
        XCTAssertTrue(tracker.claimPrompt(now: day(10), version: "1.5.1"))
        XCTAssertFalse(tracker.claimPrompt(now: day(400), version: "1.5.1"))
    }

    func testNextVersionWaitsForTheMinimumGap() {
        let tracker = makeTracker()
        useForSeveralDays(tracker)
        XCTAssertTrue(tracker.claimPrompt(now: day(10), version: "1.5.1"))
        let gap = RatingPromptPolicy.minDaysBetweenPrompts
        XCTAssertFalse(tracker.claimPrompt(now: day(10 + gap - 1), version: "1.6.0"))
        XCTAssertTrue(tracker.claimPrompt(now: day(10 + gap), version: "1.6.0"))
    }

    func testFirstLaunchDateIsNotOverwritten() {
        let tracker = makeTracker()
        tracker.recordLaunch(now: day(0))
        tracker.recordLaunch(now: day(5))
        XCTAssertEqual(tracker.stats.firstUse, day(0))
    }

    func testCountsSurviveANewTracker() {
        useForSeveralDays(makeTracker())
        XCTAssertTrue(makeTracker().claimPrompt(now: day(8), version: "1.5.1"))
    }
}

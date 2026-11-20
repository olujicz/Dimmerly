//
//  RatingPrompt.swift
//  Dimmerly
//
//  Decides when the App Store edition may ask for a rating. The ask follows clear repeat
//  value, never a first impression: several days of use, a few presets applied by the user,
//  and a quiet moment (the menu bar panel has just closed, no display is blanked).
//  The system also limits how often the prompt can appear; this adds its own, stricter limit.
//
//  The decision logic builds in both editions so it is tested everywhere. Only the App Store
//  edition records anything or asks (see `RatingPrompt`).
//

import Foundation

/// Counts of use that the prompt decision reads.
struct RatingPromptStats: Equatable {
    var firstUse: Date?
    var activeDays = 0
    var lastActiveDay: Date?
    var presetApplications = 0
    var lastPromptDate: Date?
    var lastPromptVersion: String?
}

enum RatingPromptPolicy {
    /// Days between the first launch and the first ask.
    static let minDaysSinceFirstUse = 7
    /// Distinct days on which the user applied a preset.
    static let minActiveDays = 3
    static let minPresetApplications = 3
    /// Days between two asks, on top of the system's own limit.
    static let minDaysBetweenPrompts = 120

    static func isEligible(
        _ stats: RatingPromptStats,
        now: Date,
        version: String,
        calendar: Calendar = .current
    ) -> Bool {
        guard let firstUse = stats.firstUse,
              daysBetween(firstUse, now, calendar) >= minDaysSinceFirstUse,
              stats.activeDays >= minActiveDays,
              stats.presetApplications >= minPresetApplications
        else { return false }
        if stats.lastPromptVersion == version {
            return false
        }
        if let last = stats.lastPromptDate, daysBetween(last, now, calendar) < minDaysBetweenPrompts {
            return false
        }
        return true
    }

    private static func daysBetween(_ start: Date, _ end: Date, _ calendar: Calendar) -> Int {
        calendar.dateComponents(
            [.day], from: calendar.startOfDay(for: start), to: calendar.startOfDay(for: end)
        ).day ?? 0
    }
}

/// Keeps the counts in `UserDefaults`. Nothing leaves the Mac; the counts only gate the ask.
@MainActor
final class RatingPromptTracker {
    private enum Key {
        static let firstUse = "ratingPrompt.firstUse"
        static let activeDays = "ratingPrompt.activeDays"
        static let lastActiveDay = "ratingPrompt.lastActiveDay"
        static let presetApplications = "ratingPrompt.presetApplications"
        static let lastPromptDate = "ratingPrompt.lastPromptDate"
        static let lastPromptVersion = "ratingPrompt.lastPromptVersion"
    }

    private let defaults: UserDefaults
    private let calendar: Calendar

    init(defaults: UserDefaults = .standard, calendar: Calendar = .current) {
        self.defaults = defaults
        self.calendar = calendar
    }

    var stats: RatingPromptStats {
        RatingPromptStats(
            firstUse: defaults.object(forKey: Key.firstUse) as? Date,
            activeDays: defaults.integer(forKey: Key.activeDays),
            lastActiveDay: defaults.object(forKey: Key.lastActiveDay) as? Date,
            presetApplications: defaults.integer(forKey: Key.presetApplications),
            lastPromptDate: defaults.object(forKey: Key.lastPromptDate) as? Date,
            lastPromptVersion: defaults.string(forKey: Key.lastPromptVersion)
        )
    }

    /// Starts the clock on the first launch.
    func recordLaunch(now: Date = Date()) {
        if defaults.object(forKey: Key.firstUse) == nil {
            defaults.set(now, forKey: Key.firstUse)
        }
    }

    /// Counts a preset the user chose, not one a schedule or the idle timer applied.
    func recordPresetApplied(now: Date = Date()) {
        recordLaunch(now: now)
        defaults.set(defaults.integer(forKey: Key.presetApplications) + 1, forKey: Key.presetApplications)
        let today = calendar.startOfDay(for: now)
        if let last = defaults.object(forKey: Key.lastActiveDay) as? Date, calendar.isDate(last, inSameDayAs: today) {
            return
        }
        defaults.set(defaults.integer(forKey: Key.activeDays) + 1, forKey: Key.activeDays)
        defaults.set(today, forKey: Key.lastActiveDay)
    }

    /// Records an ask and returns true when the policy allows one now. The caller asks only on true.
    func claimPrompt(now: Date = Date(), version: String) -> Bool {
        guard RatingPromptPolicy.isEligible(stats, now: now, version: version, calendar: calendar) else {
            return false
        }
        defaults.set(now, forKey: Key.lastPromptDate)
        defaults.set(version, forKey: Key.lastPromptVersion)
        return true
    }
}

#if APPSTORE
    /// Wires the tracker to the system rating request, in the App Store edition only.
    @MainActor
    enum RatingPrompt {
        static let tracker = RatingPromptTracker()

        /// How long after the panel closes before asking, so the ask never lands on a click.
        private static let delay: Duration = .seconds(2)

        static func appLaunched() {
            tracker.recordLaunch()
        }

        static func presetApplied() {
            tracker.recordPresetApplied()
        }

        /// Asks if the policy allows it and nothing else is going on.
        static func panelDidClose(
            isBusy: @escaping @MainActor () -> Bool,
            request: @escaping @MainActor () -> Void
        ) {
            Task { @MainActor in
                try? await Task.sleep(for: delay)
                guard !isBusy() else { return }
                let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
                if tracker.claimPrompt(version: version) {
                    request()
                }
            }
        }
    }
#else
    @MainActor
    enum RatingPrompt {
        static func appLaunched() {}
        static func presetApplied() {}
    }
#endif

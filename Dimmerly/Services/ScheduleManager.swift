//
//  ScheduleManager.swift
//  Dimmerly
//
//  Manages time-based dimming schedules with support for fixed times, sunrise, and sunset triggers.
//  Polls every 30 seconds to detect when schedule trigger times are crossed, handling:
//  - Sleep/wake catch-up (fires missed schedules after system resume)
//  - Once-per-day execution (prevents duplicate firing on same calendar day)
//  - Dynamic solar time resolution (sunrise/sunset vary by date and location)
//
//  Follows the IdleTimerManager pattern for settings observation and lifecycle management.
//

import Foundation
import Observation

/// Manages automatic preset application based on time-of-day schedules.
///
/// Schedules support three trigger types:
/// - **Fixed time**: Specific hour and minute (e.g., 10:00 PM)
/// - **Sunrise**: Solar sunrise ± offset in minutes (requires location permissions)
/// - **Sunset**: Solar sunset ± offset in minutes (requires location permissions)
///
/// Design details:
/// - **Polling interval**: 30 seconds (sufficient for minute-resolution schedules)
/// - **Firing logic**: Triggers fire once per day when their time is crossed
/// - **Sleep catch-up**: After system wake, checks for missed triggers since last poll
/// - **State tracking**: Maintains "fired today" dictionary to prevent duplicate execution
///
/// Thread safety: All methods must be called from the main actor.
@MainActor
@Observable
class ScheduleManager {
    /// The list of configured schedules, persisted to UserDefaults as JSON.
    /// Changes to this array automatically trigger SwiftUI view updates.
    var schedules: [DimmingSchedule] = []

    /// Callback invoked when a schedule's trigger time is reached.
    /// Called with the preset ID that should be applied.
    var onScheduleTriggered: ((UUID) -> Void)?

    /// Timer for periodic schedule checking (fires every 30 seconds).
    private var timer: Timer?

    /// Tracks which schedules have fired today to prevent duplicate execution.
    /// Key: schedule ID, Value: date string in "yyyy-MM-dd" format.
    /// Cleaned automatically at the end of each day.
    private var firedToday: [UUID: String] = [:]

    /// Timestamp of the most recent schedule check.
    /// Used to detect the time range that needs checking on next poll.
    /// Enables catch-up after sleep/wake (system time jumps forward).
    private var lastCheckDate: Date?

    /// Notification observer for UserDefaults changes (to react to settings toggles).
    private var settingsObserver: NSObjectProtocol?

    /// Cached enabled state to detect changes and start/stop polling.
    private var lastEnabled: Bool?

    /// UserDefaults key for persisting schedules as JSON.
    private static let schedulesKey = "dimmerlyDimmingSchedules"

    init() {
        loadSchedules()
    }

    // MARK: - Settings Observation

    /// Begins observing the schedule-enabled setting and auto-starts/stops polling accordingly.
    ///
    /// This method:
    /// 1. Reads the current enabled state and starts polling if enabled
    /// 2. Registers a UserDefaults observer to react to setting changes
    /// 3. Automatically starts/stops the polling timer when the setting toggles
    ///
    /// Design pattern: This follows the same pattern as IdleTimerManager, where the manager
    /// doesn't directly access AppSettings to avoid tight coupling. Instead, the caller
    /// provides a closure that reads the current value.
    ///
    /// - Parameter readEnabled: Closure that returns the current schedule-enabled setting from UserDefaults
    func observeSettings(readEnabled: @Sendable @escaping () -> Bool) {
        let enabled = readEnabled()
        lastEnabled = enabled

        if enabled {
            startPolling()
        }

        settingsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleSettingsChange(readEnabled: readEnabled)
            }
        }
    }

    /// Handles changes to the schedule-enabled setting by starting/stopping polling.
    ///
    /// Called automatically when UserDefaults changes. Only takes action if the enabled
    /// state actually changed (prevents unnecessary timer restarts).
    private func handleSettingsChange(readEnabled: @Sendable () -> Bool) {
        let enabled = readEnabled()
        guard enabled != lastEnabled else { return }
        lastEnabled = enabled
        if enabled {
            startPolling()
        } else {
            stopPolling()
        }
    }

    // MARK: - Polling

    /// Starts the polling timer and performs an immediate schedule check.
    ///
    /// Timer configuration:
    /// - Interval: 30 seconds (adequate for minute-resolution schedules)
    /// - Repeating: Yes (runs until stopPolling() is called)
    /// - Thread: Main thread (all callbacks execute on main actor)
    ///
    /// Always calls stopPolling() first to prevent duplicate timers if called multiple times.
    private func startPolling() {
        stopPolling()
        // 30-second interval is sufficient for minute-resolution schedules
        // (worst-case delay: 30 seconds after trigger time)
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkSchedules()
            }
        }
        // Also check immediately to handle schedules that should fire right now
        checkSchedules()
    }

    /// Stops the polling timer and resets the last check date.
    ///
    /// Called when:
    /// - Schedules are disabled in settings
    /// - Before starting polling (to prevent duplicate timers)
    private func stopPolling() {
        timer?.invalidate()
        timer = nil
        lastCheckDate = nil
    }

    /// Checks all enabled schedules and fires any whose trigger time has been crossed.
    ///
    /// This method implements the core scheduling logic:
    /// 1. Determine the time range to check: (previousCheck, now]
    /// 2. For each enabled schedule:
    ///    - Skip if already fired today (prevents duplicates)
    ///    - Resolve trigger to concrete date/time (handles sunrise/sunset)
    ///    - Fire if trigger falls within the check range
    /// 3. Update tracking state (firedToday, lastCheckDate)
    ///
    /// Sleep/wake catch-up:
    /// If the system was asleep and wakes up, `now` may be hours ahead of `previousCheck`.
    /// This method will fire all schedules whose triggers were missed during sleep.
    ///
    /// - Parameter now: Current date/time (defaults to Date(), injectable for testing)
    func checkSchedules(now: Date = Date()) {
        let todayString = Self.dateString(for: now)
        let previousCheck = effectivePreviousCheckDate(for: now)

        for schedule in schedules where schedule.isEnabled {
            // Skip if already fired today (prevents firing same schedule multiple times per day)
            if firedToday[schedule.id] == todayString {
                continue
            }

            // Resolve the trigger to a concrete date/time for today
            // (sunrise/sunset times vary by date, so we must resolve each check)
            guard let triggerDate = resolveTriggerDate(schedule.trigger, on: now) else {
                continue
            }

            // Fire once if the trigger time falls within the check window (previousCheck, now]
            // This half-open interval ensures we fire exactly once when crossing the trigger time
            if triggerDate > previousCheck, triggerDate <= now {
                firedToday[schedule.id] = todayString
                onScheduleTriggered?(schedule.presetID)
            }
        }

        // Clean up stale entries from firedToday (schedules fired on previous days)
        firedToday = firedToday.filter { $0.value == todayString }
        lastCheckDate = now
    }

    /// Returns the previous check date for determining the time range to check.
    ///
    /// Fallback behavior:
    /// - If lastCheckDate exists and is valid, use it (normal case)
    /// - Otherwise, use a 2-minute lookback window from now (first run or after stopPolling)
    ///
    /// The 2-minute lookback on startup allows firing schedules that should have triggered
    /// in the last couple minutes (e.g., if the app was just launched at 10:01 but a
    /// schedule was set for 10:00).
    ///
    /// - Parameter now: Current date/time
    /// - Returns: Date representing the start of the check window
    private func effectivePreviousCheckDate(for now: Date) -> Date {
        guard let lastCheckDate, lastCheckDate <= now else {
            // First check or time went backwards: use 2-minute lookback
            return now.addingTimeInterval(-120)
        }
        return lastCheckDate
    }

    /// Converts a ScheduleTrigger to a concrete Date for a given day.
    ///
    /// Trigger types:
    /// - **Fixed time**: Simple hour and minute (e.g., 22:00 = 10:00 PM)
    /// - **Sunrise**: Calculates solar sunrise for the user's location, then applies offset
    /// - **Sunset**: Calculates solar sunset for the user's location, then applies offset
    ///
    /// Failure cases:
    /// - Sunrise/sunset: Returns `nil` if location permissions denied or solar calculation fails
    ///   (e.g., polar regions during summer/winter where sun doesn't rise/set)
    ///
    /// - Parameters:
    ///   - trigger: The schedule trigger to resolve
    ///   - date: The calendar day to resolve for (time component ignored)
    /// - Returns: Concrete date/time when the trigger should fire, or `nil` if unresolvable
    func resolveTriggerDate(_ trigger: ScheduleTrigger, on date: Date) -> Date? {
        let calendar = Calendar.current

        switch trigger {
        case let .fixedTime(hour, minute):
            // Simple case: set hour and minute on the given day
            return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: date)

        case let .sunrise(offsetMinutes):
            // Solar sunrise requires location permissions
            guard let location = locationCoordinates() else { return nil }
            let solar = SolarCalculator.sunriseSunset(
                latitude: location.latitude,
                longitude: location.longitude,
                date: date
            )
            guard let sunrise = solar.sunrise else { return nil }
            // Apply offset (negative = before sunrise, positive = after sunrise)
            return calendar.date(byAdding: .minute, value: offsetMinutes, to: sunrise)

        case let .sunset(offsetMinutes):
            // Solar sunset requires location permissions
            guard let location = locationCoordinates() else { return nil }
            let solar = SolarCalculator.sunriseSunset(
                latitude: location.latitude,
                longitude: location.longitude,
                date: date
            )
            guard let sunset = solar.sunset else { return nil }
            // Apply offset (negative = before sunset, positive = after sunset)
            return calendar.date(byAdding: .minute, value: offsetMinutes, to: sunset)
        }
    }

    /// Returns the user's current location coordinates from LocationProvider.
    ///
    /// - Returns: Latitude and longitude tuple, or `nil` if location unavailable
    ///   (permissions denied or not yet determined)
    private func locationCoordinates() -> (latitude: Double, longitude: Double)? {
        guard let lat = LocationProvider.shared.latitude,
              let lon = LocationProvider.shared.longitude
        else {
            return nil
        }
        return (lat, lon)
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static func dateString(for date: Date) -> String {
        dayFormatter.string(from: date)
    }

    // MARK: - CRUD

    /// Adds a new schedule to the list and persists to UserDefaults.
    ///
    /// - Parameter schedule: The schedule to add
    func addSchedule(_ schedule: DimmingSchedule) {
        schedules.append(schedule)
        saveSchedules()
    }

    /// Updates an existing schedule and resets its "fired today" status.
    ///
    /// Resetting the fired status allows the updated schedule to fire again today if its
    /// trigger time hasn't passed yet. This is intentional behavior: if you edit a schedule's
    /// trigger time, you probably want it to fire at the new time.
    ///
    /// - Parameter schedule: The updated schedule (matched by ID)
    func updateSchedule(_ schedule: DimmingSchedule) {
        guard let index = schedules.firstIndex(where: { $0.id == schedule.id }) else { return }
        schedules[index] = schedule
        // Reset fired status so the modified schedule can fire again today
        firedToday.removeValue(forKey: schedule.id)
        saveSchedules()
    }

    /// Deletes a schedule by ID and clears its tracking state.
    ///
    /// - Parameter id: The schedule ID to delete
    func deleteSchedule(id: UUID) {
        schedules.removeAll { $0.id == id }
        firedToday.removeValue(forKey: id)
        saveSchedules()
    }

    /// Toggles a schedule's enabled state.
    ///
    /// When disabling a schedule, clears its "fired today" status so it can fire immediately
    /// if re-enabled later the same day.
    ///
    /// - Parameter id: The schedule ID to toggle
    func toggleSchedule(id: UUID) {
        guard let index = schedules.firstIndex(where: { $0.id == id }) else { return }
        schedules[index].isEnabled.toggle()
        // Clear fired status when disabling (allows re-firing if re-enabled today)
        if !schedules[index].isEnabled {
            firedToday.removeValue(forKey: id)
        }
        saveSchedules()
    }

    // MARK: - Persistence

    private func loadSchedules() {
        guard let data = UserDefaults.standard.data(forKey: Self.schedulesKey),
              let decoded = try? JSONDecoder().decode([DimmingSchedule].self, from: data)
        else {
            return
        }
        schedules = decoded
    }

    private func saveSchedules() {
        guard let data = try? JSONEncoder().encode(schedules) else { return }
        UserDefaults.standard.set(data, forKey: Self.schedulesKey)
    }

    // MARK: - Lifecycle

    // Note: deinit intentionally omitted to avoid @MainActor data race warnings in Swift 6.
    // This manager is held by @StateObject in DimmerlyApp for the app's lifetime, so deinit
    // never executes. Cleanup (timer invalidation, observer removal) is handled explicitly
    // via stopPolling() when schedules are disabled.
}

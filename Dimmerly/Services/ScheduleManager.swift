//
//  ScheduleManager.swift
//  Dimmerly
//
//  Manages time-based dimming schedules. Polls every 30 seconds and
//  applies the referenced preset when a schedule's trigger time arrives.
//  Follows the IdleTimerManager pattern for settings observation.
//

import Foundation

@MainActor
class ScheduleManager: ObservableObject {
    /// The list of configured schedules, persisted to UserDefaults
    @Published var schedules: [DimmingSchedule] = []

    /// Called with the preset ID when a schedule triggers
    var onScheduleTriggered: ((UUID) -> Void)?

    private var timer: Timer?
    /// Tracks which schedules have already fired today (schedule ID → "yyyy-MM-dd")
    private var firedToday: [UUID: String] = [:]
    /// Timestamp of the previous schedule check, used for catch-up after sleep/resume.
    private var lastCheckDate: Date?
    private var settingsObserver: NSObjectProtocol?
    private var lastEnabled: Bool?

    private static let schedulesKey = "dimmerlyDimmingSchedules"

    init() {
        loadSchedules()
    }

    // MARK: - Settings Observation

    /// Begins observing settings changes and auto-starts/stops polling based on current values.
    ///
    /// - Parameter readEnabled: Closure that returns the current schedule-enabled setting
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

    private func startPolling() {
        stopPolling()
        // Poll every 30 seconds (schedules are minute-resolution)
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkSchedules()
            }
        }
        // Also check immediately
        checkSchedules()
    }

    private func stopPolling() {
        timer?.invalidate()
        timer = nil
        lastCheckDate = nil
    }

    /// Checks schedules and fires any trigger crossed since the previous check.
    /// Kept internal to allow deterministic unit tests with a fixed `now` date.
    func checkSchedules(now: Date = Date()) {
        let todayString = Self.dateString(for: now)
        let previousCheck = effectivePreviousCheckDate(for: now)

        for schedule in schedules where schedule.isEnabled {
            // Skip if already fired today
            if firedToday[schedule.id] == todayString {
                continue
            }

            guard let triggerDate = resolveTriggerDate(schedule.trigger, on: now) else {
                continue
            }

            // Fire once if the trigger time falls within (previousCheck, now].
            if triggerDate > previousCheck && triggerDate <= now {
                firedToday[schedule.id] = todayString
                onScheduleTriggered?(schedule.presetID)
            }
        }

        // Clean up old entries from firedToday (previous days)
        firedToday = firedToday.filter { $0.value == todayString }
        lastCheckDate = now
    }

    /// Returns the prior check date, falling back to a 2-minute lookback window.
    /// This preserves current behavior on startup while allowing catch-up after sleep.
    private func effectivePreviousCheckDate(for now: Date) -> Date {
        guard let lastCheckDate, lastCheckDate <= now else {
            return now.addingTimeInterval(-120)
        }
        return lastCheckDate
    }

    /// Converts a ScheduleTrigger to a concrete Date for today
    func resolveTriggerDate(_ trigger: ScheduleTrigger, on date: Date) -> Date? {
        let calendar = Calendar.current

        switch trigger {
        case .fixedTime(let hour, let minute):
            return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: date)

        case .sunrise(let offsetMinutes):
            guard let location = locationCoordinates() else { return nil }
            let solar = SolarCalculator.sunriseSunset(
                latitude: location.latitude,
                longitude: location.longitude,
                date: date
            )
            guard let sunrise = solar.sunrise else { return nil }
            return calendar.date(byAdding: .minute, value: offsetMinutes, to: sunrise)

        case .sunset(let offsetMinutes):
            guard let location = locationCoordinates() else { return nil }
            let solar = SolarCalculator.sunriseSunset(
                latitude: location.latitude,
                longitude: location.longitude,
                date: date
            )
            guard let sunset = solar.sunset else { return nil }
            return calendar.date(byAdding: .minute, value: offsetMinutes, to: sunset)
        }
    }

    private func locationCoordinates() -> (latitude: Double, longitude: Double)? {
        guard let lat = LocationProvider.shared.latitude,
              let lon = LocationProvider.shared.longitude else {
            return nil
        }
        return (lat, lon)
    }

    private static func dateString(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    // MARK: - CRUD

    func addSchedule(_ schedule: DimmingSchedule) {
        schedules.append(schedule)
        saveSchedules()
    }

    func updateSchedule(_ schedule: DimmingSchedule) {
        guard let index = schedules.firstIndex(where: { $0.id == schedule.id }) else { return }
        schedules[index] = schedule
        // A modified schedule should be eligible to fire again today.
        firedToday.removeValue(forKey: schedule.id)
        saveSchedules()
    }

    func deleteSchedule(id: UUID) {
        schedules.removeAll { $0.id == id }
        firedToday.removeValue(forKey: id)
        saveSchedules()
    }

    func toggleSchedule(id: UUID) {
        guard let index = schedules.firstIndex(where: { $0.id == id }) else { return }
        schedules[index].isEnabled.toggle()
        if !schedules[index].isEnabled {
            firedToday.removeValue(forKey: id)
        }
        saveSchedules()
    }

    // MARK: - Persistence

    private func loadSchedules() {
        guard let data = UserDefaults.standard.data(forKey: Self.schedulesKey),
              let decoded = try? JSONDecoder().decode([DimmingSchedule].self, from: data) else {
            return
        }
        schedules = decoded
    }

    private func saveSchedules() {
        guard let data = try? JSONEncoder().encode(schedules) else { return }
        UserDefaults.standard.set(data, forKey: Self.schedulesKey)
    }

    // deinit omitted to avoid @MainActor data race (Swift 6).
    // The manager is held by @StateObject for the app lifetime, so deinit is never reached.
}

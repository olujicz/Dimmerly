//
//  ColorTemperatureManager.swift
//  Dimmerly
//
//  Manages automatic color temperature adjustment based on time of day.
//  Transitions warmth between day and night temperatures at sunrise and sunset.
//
//  Follows the ScheduleManager/IdleTimerManager pattern:
//  - @MainActor ObservableObject with Timer-based polling
//  - Settings observation via UserDefaults notifications
//  - Injectable Date for testability
//

import AppKit
import Foundation

/// Time-of-day state for color temperature determination.
enum ColorTempState: Equatable {
    /// Full daytime — use day temperature
    case day
    /// Full nighttime — use night temperature
    case night
    /// Transitioning during sunrise (0.0 = night, 1.0 = day)
    case sunriseTransition(progress: Double)
    /// Transitioning during sunset (0.0 = day, 1.0 = night)
    case sunsetTransition(progress: Double)
}

/// Manages automatic color temperature adjustment based on sunrise/sunset times.
///
/// When enabled, polls every 60 seconds and adjusts all displays' warmth to match
/// the appropriate color temperature for the time of day:
/// - **Day**: Uses the configured day temperature (default 6500K)
/// - **Night**: Uses the configured night temperature (default 2700K)
/// - **Transitions**: Linearly interpolates over a configurable duration centered on sunrise/sunset
///
/// Manual override: When the user manually changes warmth (slider or preset), auto mode
/// pauses until the next sunrise/sunset boundary, then resumes automatically.
///
/// Thread safety: All methods must be called from the main actor.
@MainActor
class ColorTemperatureManager: ObservableObject {
    static let shared = ColorTemperatureManager()

    /// Whether auto color temperature is currently actively controlling warmth.
    /// False when disabled in settings or during manual override.
    @Published var isActive = false

    /// The current target Kelvin value being applied (for UI display).
    @Published var currentKelvin: Double = 6500

    /// Timer for periodic color temperature checks (fires every 60 seconds).
    private var timer: Timer?

    /// Notification observer for UserDefaults changes.
    private var settingsObserver: NSObjectProtocol?

    /// Notification observer for system wake events.
    private var wakeObserver: NSObjectProtocol?

    /// Cached enabled state to detect changes.
    private var lastEnabled: Bool?

    /// Whether the user has manually overridden warmth since the last boundary crossing.
    private var manualOverrideActive = false

    /// The state (day/night) at the time of the last manual override.
    /// When the state changes from this, the override is cleared.
    private var overrideState: ColorTempState?

    /// Warmth values saved before auto mode took over, keyed by display ID string.
    /// Restored when the user disables auto mode so their manual warmth isn't lost.
    private var savedWarmthSnapshot: [String: Double]?

    /// Whether the next update should animate the warmth transition.
    /// Set to true when auto mode is first enabled; cleared after the first update.
    private var animateNextUpdate = false

    // MARK: - Settings Observation

    /// Begins observing the auto color temperature setting and starts/stops polling accordingly.
    ///
    /// - Parameter readEnabled: Closure that returns the current auto-color-temp-enabled setting
    func observeSettings(readEnabled: @Sendable @escaping () -> Bool) {
        let enabled = readEnabled()
        lastEnabled = enabled

        if enabled {
            savedWarmthSnapshot = BrightnessManager.shared.currentWarmthSnapshot()
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
            // Save current warmth so we can restore it if auto mode is disabled
            savedWarmthSnapshot = BrightnessManager.shared.currentWarmthSnapshot()
            manualOverrideActive = false
            overrideState = nil
            animateNextUpdate = true
            startPolling()
        } else {
            stopPolling()
            isActive = false
            restoreSavedWarmth()
        }
    }

    /// Restores warmth values that were saved before auto mode took over,
    /// using a smooth animation matching the preset transition timing.
    private func restoreSavedWarmth() {
        guard let snapshot = savedWarmthSnapshot else { return }
        let bm = BrightnessManager.shared
        bm.isAutoColorTempUpdate = true
        if !bm.animateWarmthValues(snapshot) {
            bm.applyWarmthValues(snapshot)
        }
        bm.isAutoColorTempUpdate = false
        savedWarmthSnapshot = nil
    }

    // MARK: - Polling

    private func startPolling() {
        stopPolling()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateColorTemperature()
            }
        }

        // Re-evaluate immediately on system wake — the Mac may have slept for hours
        // and the time-of-day state could be completely different.
        // Uses a 1.5s delay so BrightnessManager's wake handler (1s) finishes first.
        wakeObserver = NotificationCenter.default.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.5))
                self?.updateColorTemperature()
            }
        }

        updateColorTemperature()
    }

    private func stopPolling() {
        timer?.invalidate()
        timer = nil
        if let wakeObserver {
            NotificationCenter.default.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
    }

    // MARK: - Core Logic

    /// Evaluates the current time-of-day state and applies the appropriate warmth.
    ///
    /// - Parameter now: Current date/time (injectable for testing)
    func updateColorTemperature(now: Date = Date()) {
        guard let location = locationCoordinates() else {
            isActive = false
            return
        }

        let solar = SolarCalculator.sunriseSunset(
            latitude: location.latitude,
            longitude: location.longitude,
            date: now
        )

        guard let sunrise = solar.sunrise, let sunset = solar.sunset else {
            isActive = false
            return
        }

        let settings = AppSettings.shared
        let transitionDuration = Double(settings.colorTempTransitionMinutes) * 60.0
        let halfTransition = transitionDuration / 2.0

        let state = Self.determineState(
            now: now,
            sunrise: sunrise,
            sunset: sunset,
            halfTransition: halfTransition
        )

        // Clear manual override when crossing a day/night boundary
        if manualOverrideActive, let overrideState {
            let currentBaseState = Self.baseState(state)
            let overrideBaseState = Self.baseState(overrideState)
            if currentBaseState != overrideBaseState {
                manualOverrideActive = false
                self.overrideState = nil
            }
        }

        if manualOverrideActive {
            isActive = false
            return
        }

        isActive = true

        let dayKelvin = Double(settings.dayTemperature)
        let nightKelvin = Double(settings.nightTemperature)

        let targetKelvin: Double
        switch state {
        case .day:
            targetKelvin = dayKelvin
        case .night:
            targetKelvin = nightKelvin
        case let .sunriseTransition(progress):
            targetKelvin = nightKelvin + (dayKelvin - nightKelvin) * progress
        case let .sunsetTransition(progress):
            targetKelvin = dayKelvin + (nightKelvin - dayKelvin) * progress
        }

        currentKelvin = targetKelvin
        let warmth = BrightnessManager.warmthForKelvin(targetKelvin)
        let clamped = min(max(warmth, 0.0), 1.0)

        let bm = BrightnessManager.shared
        bm.isAutoColorTempUpdate = true
        if animateNextUpdate {
            animateNextUpdate = false
            if !bm.animateAllWarmth(to: clamped) {
                bm.setAllWarmth(to: clamped)
            }
        } else {
            bm.setAllWarmth(to: clamped)
        }
        bm.isAutoColorTempUpdate = false
    }

    /// Determines the color temperature state for a given time relative to sunrise/sunset.
    ///
    /// - Parameters:
    ///   - now: Current time
    ///   - sunrise: Today's sunrise time
    ///   - sunset: Today's sunset time
    ///   - halfTransition: Half the transition duration in seconds
    /// - Returns: The current color temperature state
    static func determineState(
        now: Date,
        sunrise: Date,
        sunset: Date,
        halfTransition: Double
    ) -> ColorTempState {
        let sunriseStart = sunrise.addingTimeInterval(-halfTransition)
        let sunriseEnd = sunrise.addingTimeInterval(halfTransition)
        let sunsetStart = sunset.addingTimeInterval(-halfTransition)
        let sunsetEnd = sunset.addingTimeInterval(halfTransition)

        if now >= sunriseStart, now <= sunriseEnd {
            let total = sunriseEnd.timeIntervalSince(sunriseStart)
            if total <= 0 {
                return .sunriseTransition(progress: 1.0)
            }
            let elapsed = now.timeIntervalSince(sunriseStart)
            return .sunriseTransition(progress: min(max(elapsed / total, 0), 1))
        }

        if now >= sunsetStart, now <= sunsetEnd {
            let total = sunsetEnd.timeIntervalSince(sunsetStart)
            if total <= 0 {
                return .sunsetTransition(progress: 1.0)
            }
            let elapsed = now.timeIntervalSince(sunsetStart)
            return .sunsetTransition(progress: min(max(elapsed / total, 0), 1))
        }

        if now > sunriseEnd, now < sunsetStart {
            return .day
        }

        return .night
    }

    /// Returns the base state (day or night) for override boundary detection.
    private static func baseState(_ state: ColorTempState) -> ColorTempState {
        switch state {
        case .day, .sunriseTransition:
            return .day
        case .night, .sunsetTransition:
            return .night
        }
    }

    // MARK: - Manual Override

    /// Called when the user manually changes warmth (via slider or other direct input).
    /// Pauses auto mode until the next day/night boundary crossing.
    func notifyManualWarmthChange() {
        guard lastEnabled == true else { return }
        guard !manualOverrideActive else { return }

        manualOverrideActive = true
        isActive = false

        // Capture current state for boundary detection
        if let location = locationCoordinates() {
            let now = Date()
            let solar = SolarCalculator.sunriseSunset(
                latitude: location.latitude,
                longitude: location.longitude,
                date: now
            )
            if let sunrise = solar.sunrise, let sunset = solar.sunset {
                let settings = AppSettings.shared
                let halfTransition = Double(settings.colorTempTransitionMinutes) * 30.0
                overrideState = Self.determineState(
                    now: now,
                    sunrise: sunrise,
                    sunset: sunset,
                    halfTransition: halfTransition
                )
            }
        }
    }

    /// Called when a preset that includes warmth is applied.
    /// Same behavior as manual warmth change — pauses auto mode.
    func notifyPresetApplied() {
        notifyManualWarmthChange()
    }

    // MARK: - Status

    /// Returns a short description of the next sunrise or sunset transition for UI display,
    /// e.g. "Sunset 8:12 PM · 2700K", or nil if unavailable.
    func nextTransitionDescription() -> String? {
        guard let location = locationCoordinates() else { return nil }

        let now = Date()
        let solar = SolarCalculator.sunriseSunset(
            latitude: location.latitude,
            longitude: location.longitude,
            date: now
        )
        guard let sunrise = solar.sunrise, let sunset = solar.sunset else { return nil }

        let settings = AppSettings.shared
        let dayK = settings.dayTemperature
        let nightK = settings.nightTemperature

        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"

        if now < sunrise {
            return "Sunrise \(formatter.string(from: sunrise)) · \(dayK)K"
        } else if now < sunset {
            return "Sunset \(formatter.string(from: sunset)) · \(nightK)K"
        } else {
            // After sunset — next transition is tomorrow's sunrise
            if let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: now) {
                let tomorrowSolar = SolarCalculator.sunriseSunset(
                    latitude: location.latitude,
                    longitude: location.longitude,
                    date: tomorrow
                )
                if let tomorrowSunrise = tomorrowSolar.sunrise {
                    return "Sunrise \(formatter.string(from: tomorrowSunrise)) · \(dayK)K"
                }
            }
            return nil
        }
    }

    // MARK: - Location

    private func locationCoordinates() -> (latitude: Double, longitude: Double)? {
        guard let lat = LocationProvider.shared.latitude,
              let lon = LocationProvider.shared.longitude
        else {
            return nil
        }
        return (lat, lon)
    }

    // MARK: - Lifecycle

    // Note: deinit intentionally omitted to avoid @MainActor data race warnings in Swift 6.
    // This manager is held by @StateObject in DimmerlyApp for the app's lifetime, so deinit
    // never executes.
}

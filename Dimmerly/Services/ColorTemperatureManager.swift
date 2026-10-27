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
import Observation
import OSLog

private let colorTemperatureLogger = Logger(
    subsystem: "rs.in.olujic.dimmerly",
    category: "ColorTemperatureManager"
)

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

    /// Compact description for log output, including transition progress.
    var logDescription: String {
        switch self {
        case .day: "day"
        case .night: "night"
        case let .sunriseTransition(progress): "sunrise \(Int(progress * 100))%"
        case let .sunsetTransition(progress): "sunset \(Int(progress * 100))%"
        }
    }
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
@Observable
class ColorTemperatureManager {
    static let shared = ColorTemperatureManager()

    /// Whether auto color temperature is currently actively controlling warmth.
    /// False when disabled in settings or during manual override.
    var isActive = false

    /// The current target Kelvin value being applied (for UI display).
    var currentKelvin: Double = 6500

    /// Recalculates warmth every 60 seconds.
    private let pollingTimer = PollingTimer()

    /// Coalesces system and screen wake events before recalculating warmth.
    private var wakeMonitor: WorkspaceWakeMonitor?

    /// Whether auto color temperature is currently enabled (mirrors AppSettings).
    /// Used by `notifyManualWarmthChange` to decide whether a manual override applies.
    private var isEnabled: Bool = false

    /// Whether the user has manually overridden warmth since the last boundary crossing.
    private var manualOverrideActive = false

    /// The state (day/night) at the time of the last manual override.
    /// When the state changes from this, the override is cleared.
    private var overrideState: ColorTempState?

    /// The solar event selected when the override was established. Its transition
    /// start uses the current duration, even if that setting changes while paused.
    private var overrideSolarBoundary: Date?

    /// Warmth values saved before auto mode took over, keyed by display ID string.
    /// Restored when the user disables auto mode so their manual warmth isn't lost.
    private var savedWarmthSnapshot: [String: Double]?

    /// Last warmth value written to the log, so routine 60-second ticks don't flood it.
    private var lastLoggedWarmth: Double?

    /// Whether the next update should animate the warmth transition.
    /// Set to true when auto mode is first enabled; cleared after the first update.
    private var animateNextUpdate = false

    /// The manager warmth is applied through. Defaults to the app-wide instance; tests inject an
    /// isolated one so enabling or disabling auto warmth doesn't rewrite real display state.
    private let brightnessManager: BrightnessManager
    private let settings: AppSettings

    /// Optional location lookup override for deterministic tests.
    var locationCoordinatesHook: (() -> (latitude: Double, longitude: Double)?)?

    /// - Parameter brightnessManager: Where warmth is applied. Pass an isolated instance in tests.
    init(brightnessManager: BrightnessManager = .shared, settings: AppSettings = .shared) {
        self.brightnessManager = brightnessManager
        self.settings = settings
    }

    // MARK: - Enable/Disable

    /// Applies the current auto-color-temperature setting. Called by the app on launch
    /// and whenever `AppSettings.autoColorTempEnabled` changes.
    ///
    /// Turning the feature ON snapshots the user's current warmth so it can be restored
    /// if they later turn it OFF, clears any prior manual override, and enables an
    /// animated first update. Turning it OFF stops polling and restores the snapshot.
    func apply(enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        colorTemperatureLogger.info("Auto color temperature \(enabled ? "enabled" : "disabled", privacy: .public)")
        if enabled {
            savedWarmthSnapshot = brightnessManager.currentWarmthSnapshot()
            manualOverrideActive = false
            overrideState = nil
            overrideSolarBoundary = nil
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
        let summary = "\(snapshot.count) displays, max warmth \(snapshot.values.max() ?? 0)"
        colorTemperatureLogger.info("Restoring pre-auto warmth snapshot: \(summary, privacy: .public)")
        let bm = brightnessManager
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
        pollingTimer.start(interval: 60) { [weak self] in
            self?.updateColorTemperature()
        }

        // Re-evaluate after either the Mac or only its screens wake. The delay lets
        // BrightnessManager finish display stabilization and gamma restoration first.
        let monitor = WorkspaceWakeMonitor(delay: .seconds(1.5)) { [weak self] in
            guard let self, isEnabled else { return }
            updateColorTemperature()
        }
        monitor.start()
        wakeMonitor = monitor

        updateColorTemperature()
    }

    private func stopPolling() {
        pollingTimer.stop()
        wakeMonitor?.stop()
        wakeMonitor = nil
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

        let halfTransition = Self.halfTransitionSeconds(forTransitionMinutes: settings.colorTempTransitionMinutes)

        let state = Self.determineState(
            now: now,
            sunrise: sunrise,
            sunset: sunset,
            halfTransition: halfTransition
        )

        if manualOverrideActive, overrideState == nil {
            overrideState = state
            overrideSolarBoundary = Self.nextBoundary(
                after: now,
                sunrise: sunrise,
                sunset: sunset,
                halfTransition: halfTransition,
                location: location
            )
        }

        // Clear manual override when crossing a day/night boundary
        if manualOverrideActive, let overrideState {
            let currentBaseState = Self.baseState(state)
            let overrideBaseState = Self.baseState(overrideState)
            let boundaryPassed = overrideSolarBoundary.map { now >= $0.addingTimeInterval(-halfTransition) } == true
            if boundaryPassed || currentBaseState != overrideBaseState {
                manualOverrideActive = false
                self.overrideState = nil
                overrideSolarBoundary = nil
                colorTemperatureLogger.info("Manual warmth override cleared at a day/night boundary")
            }
        }

        if manualOverrideActive {
            isActive = false
            return
        }

        isActive = true

        let dayKelvin = Double(settings.dayTemperature)
        let nightKelvin = Double(settings.nightTemperature)

        let targetKelvin: Double = switch state {
        case .day:
            dayKelvin
        case .night:
            nightKelvin
        case let .sunriseTransition(progress):
            nightKelvin + (dayKelvin - nightKelvin) * progress
        case let .sunsetTransition(progress):
            dayKelvin + (nightKelvin - dayKelvin) * progress
        }

        currentKelvin = targetKelvin
        let warmth = GammaMath.warmthForKelvin(targetKelvin)
        let clamped = min(max(warmth, 0.0), 1.0)

        // Logged only when the target moves materially: this runs every 60 seconds, and the
        // point is a usable trail for "warmth looked wrong at time X", not a per-tick firehose.
        let summary = "\(state.logDescription) kelvin=\(Int(targetKelvin)) warmth=\(clamped)"
        if lastLoggedWarmth == nil || abs((lastLoggedWarmth ?? 0) - clamped) > 0.01 {
            lastLoggedWarmth = clamped
            colorTemperatureLogger.info("Applying \(summary, privacy: .public)")
        } else {
            // Every tick, at debug level. The info-level filter above hides a steady target,
            // which meant a stretch where warmth was being re-requested unchanged looked
            // identical to auto warmth not running at all.
            colorTemperatureLogger.debug("Re-asserting \(summary, privacy: .public)")
        }

        let bm = brightnessManager
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
    /// Converts the user-facing transition duration (minutes) to the half-duration (seconds)
    /// `determineState` needs, so callers don't each re-derive `minutes * 30.0` independently.
    static func halfTransitionSeconds(forTransitionMinutes minutes: Int) -> Double {
        Double(minutes) * 60.0 / 2.0
    }

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
            .day
        case .night, .sunsetTransition:
            .night
        }
    }

    /// Base states change at the start of sunrise/sunset transitions, rather than
    /// at their solar midpoint. Use the next day's solar calculation after sunset
    /// so changing day length and daylight-saving changes don't become a fixed delay.
    /// Returns the raw solar event so its start can follow later duration edits.
    private static func nextBoundary(
        after now: Date,
        sunrise: Date,
        sunset: Date,
        halfTransition: Double,
        location: (latitude: Double, longitude: Double)
    ) -> Date? {
        let boundaries = [sunrise, sunset]
        if let next = boundaries.filter({ $0.addingTimeInterval(-halfTransition) > now }).min() {
            return next
        }

        guard let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: now) else { return nil }
        let solar = SolarCalculator.sunriseSunset(
            latitude: location.latitude,
            longitude: location.longitude,
            date: tomorrow
        )
        return [solar.sunrise, solar.sunset]
            .compactMap(\.self)
            .filter { $0.addingTimeInterval(-halfTransition) > now }
            .min()
    }

    // MARK: - Manual Override

    /// Called when the user manually changes warmth (via slider or other direct input).
    /// Pauses auto mode until the next day/night boundary crossing.
    func notifyManualWarmthChange() {
        guard isEnabled, !manualOverrideActive else { return }

        manualOverrideActive = true
        isActive = false
        colorTemperatureLogger.info("Manual warmth change: auto warmth paused until the next boundary")

        // Capture current state for boundary detection
        if let location = locationCoordinates() {
            let now = Date()
            let solar = SolarCalculator.sunriseSunset(
                latitude: location.latitude,
                longitude: location.longitude,
                date: now
            )
            if let sunrise = solar.sunrise, let sunset = solar.sunset {
                let halfTransition = Self.halfTransitionSeconds(
                    forTransitionMinutes: settings.colorTempTransitionMinutes
                )
                overrideState = Self.determineState(
                    now: now,
                    sunrise: sunrise,
                    sunset: sunset,
                    halfTransition: halfTransition
                )
                overrideSolarBoundary = Self.nextBoundary(
                    after: now,
                    sunrise: sunrise,
                    sunset: sunset,
                    halfTransition: halfTransition,
                    location: location
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

        let dayK = settings.dayTemperature
        let nightK = settings.nightTemperature

        if now < sunrise {
            let time = sunrise.formatted(date: .omitted, time: .shortened)
            return String(localized: "Sunrise \(time) · \(dayK)K",
                          comment: "Next color temperature transition — sunrise time and target Kelvin")
        } else if now < sunset {
            let time = sunset.formatted(date: .omitted, time: .shortened)
            return String(localized: "Sunset \(time) · \(nightK)K",
                          comment: "Next color temperature transition — sunset time and target Kelvin")
        } else {
            // After sunset — next transition is tomorrow's sunrise
            if let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: now) {
                let tomorrowSolar = SolarCalculator.sunriseSunset(
                    latitude: location.latitude,
                    longitude: location.longitude,
                    date: tomorrow
                )
                if let tomorrowSunrise = tomorrowSolar.sunrise {
                    let time = tomorrowSunrise.formatted(date: .omitted, time: .shortened)
                    return String(localized: "Sunrise \(time) · \(dayK)K",
                                  comment: "Next color temperature transition — sunrise time and target Kelvin")
                }
            }
            return nil
        }
    }

    // MARK: - Location

    private func locationCoordinates() -> (latitude: Double, longitude: Double)? {
        if let locationCoordinatesHook {
            return locationCoordinatesHook()
        }

        guard let lat = LocationProvider.shared.latitude,
              let lon = LocationProvider.shared.longitude
        else {
            return nil
        }
        return (lat, lon)
    }

    // MARK: - Lifecycle

    // Note: deinit intentionally omitted to avoid @MainActor data race warnings in Swift 6.
    // This manager is held by @State in DimmerlyApp for the app's lifetime, so deinit
    // never executes.
}

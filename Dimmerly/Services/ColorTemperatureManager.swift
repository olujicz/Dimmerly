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

    /// Timer for periodic color temperature checks (fires every 60 seconds).
    private var timer: Timer?

    /// Incremented by `stopPolling()`, so each timer's callbacks carry the generation they were
    /// scheduled under. `Timer` isn't `Sendable` and so can't be compared across the hop to the
    /// main actor; an `Int` can. Readable for tests, writable only here.
    private(set) var timerGeneration = 0

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

    /// - Parameter brightnessManager: Where warmth is applied. Pass an isolated instance in tests.
    init(brightnessManager: BrightnessManager = .shared) {
        self.brightnessManager = brightnessManager
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
        // Added to `.common` run loop modes so warmth transitions keep progressing during a
        // modal alert or menu tracking/slider dragging, not just the run loop's default mode.
        // The inner `[weak self]` matters: without it the hop would hold a strong reference
        // to this manager for the hop's duration. `generation` is captured immutably, so the
        // callback carries the identity of the timer that scheduled it.
        let generation = timerGeneration
        let newTimer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleTimerFired(generation: generation)
            }
        }
        RunLoop.main.add(newTimer, forMode: .common)
        timer = newTimer

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

    /// Recalculates warmth on behalf of the polling timer, after the hop to the main actor.
    ///
    /// Comparing generations discards callbacks from a timer that `stopPolling()` invalidated or
    /// that a restart has since replaced, matching the idiom in ScheduleManager/IdleTimerManager.
    /// This also covers the disabled case: `apply(enabled:)` routes every transition to `false`
    /// through `stopPolling()`, which retires the generation.
    ///
    /// - Parameter generation: The `timerGeneration` in effect when the firing timer was scheduled.
    func handleTimerFired(generation: Int) {
        guard generation == timerGeneration else { return }
        updateColorTemperature()
    }

    private func stopPolling() {
        timer?.invalidate()
        timer = nil
        // Retires the outgoing timer's generation so any callback still in flight is discarded.
        timerGeneration += 1
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

        let settings = AppSettings.shared
        let halfTransition = Self.halfTransitionSeconds(forTransitionMinutes: settings.colorTempTransitionMinutes)

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

    // MARK: - Manual Override

    /// Called when the user manually changes warmth (via slider or other direct input).
    /// Pauses auto mode until the next day/night boundary crossing.
    func notifyManualWarmthChange() {
        guard isEnabled else { return }
        guard !manualOverrideActive else { return }

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
                let settings = AppSettings.shared
                let halfTransition = Self.halfTransitionSeconds(
                    forTransitionMinutes: settings.colorTempTransitionMinutes
                )
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
        formatter.dateFormat = DateFormatter.dateFormat(fromTemplate: "j:mm", options: 0, locale: .current)

        if now < sunrise {
            let time = formatter.string(from: sunrise)
            return String(localized: "Sunrise \(time) · \(dayK)K",
                          comment: "Next color temperature transition — sunrise time and target Kelvin")
        } else if now < sunset {
            let time = formatter.string(from: sunset)
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
                    let time = formatter.string(from: tomorrowSunrise)
                    return String(localized: "Sunrise \(time) · \(dayK)K",
                                  comment: "Next color temperature transition — sunrise time and target Kelvin")
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

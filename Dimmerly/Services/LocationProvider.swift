//
//  LocationProvider.swift
//  Dimmerly
//
//  Provides location data for solar calculations.
//  Supports both CLLocationManager-based and manual coordinate entry.
//

import AppKit
import CoreLocation
import Foundation
import Observation
import Synchronization

/// Tracks which location request is live. CoreLocation's delegate callbacks are
/// nonisolated, so the state sits behind a mutex rather than on the main actor.
private final class LocationRequestGate: Sendable {
    private struct State {
        var generation: UInt64 = 0
        var activeRequest: UInt64?
    }

    private let state = Mutex(State())

    func begin() -> UInt64 {
        state.withLock { state in
            state.generation &+= 1
            state.activeRequest = state.generation
            return state.generation
        }
    }

    func invalidate() {
        state.withLock { state in
            state.generation &+= 1
            state.activeRequest = nil
        }
    }

    func current() -> UInt64 {
        state.withLock { $0.generation }
    }

    func isCurrent(_ token: UInt64) -> Bool {
        state.withLock { token == $0.generation }
    }

    /// A callback is only honoured while the request that asked for it is still the live one.
    /// Unsolicited deliveries, and deliveries that lost a race with a manual edit, clear, or a
    /// newer request, are all dropped.
    func acceptsCallback(_ token: UInt64) -> Bool {
        state.withLock { state in
            guard let activeRequest = state.activeRequest else { return false }
            return token == activeRequest && token == state.generation
        }
    }

    func complete(_ token: UInt64) {
        state.withLock { state in
            guard token == state.generation, state.activeRequest == token else { return }
            state.activeRequest = nil
            state.generation &+= 1
        }
    }
}

/// Why a "Use Current Location" request can't get a fix. Shown in Settings so a request
/// that the system turned down doesn't just fail silently.
enum LocationAccessProblem: Equatable {
    /// Location Services is switched off for the whole Mac.
    case servicesOff
    /// The person turned down Dimmerly's request, or turned it off later.
    case denied
    /// A policy such as a configuration profile blocks location access; the person can't change it.
    case restricted

    /// The problem a request would hit right now, or nil if one can go ahead.
    /// Location Services being off is checked first: macOS then reports every app as denied.
    static func current(servicesEnabled: Bool, status: CLAuthorizationStatus) -> LocationAccessProblem? {
        guard servicesEnabled else { return .servicesOff }
        switch status {
        case .denied: return .denied
        case .restricted: return .restricted
        default: return nil
        }
    }
}

@MainActor
@Observable
class LocationProvider: NSObject {
    #if DEBUG
        /// Screenshot runs (`DIMMERLY_SCREENSHOT`) get an isolated instance; see `ScreenshotStage`.
        static let shared = ScreenshotStage.isActive ? ScreenshotStage.makeLocationProvider() : LocationProvider()
    #else
        static let shared = LocationProvider()
    #endif

    var latitude: Double?
    var longitude: Double?
    var authorizationStatus: CLAuthorizationStatus = .notDetermined
    /// Set when a location request was turned down, and cleared once access comes back or a
    /// location is set. Only a request sets it, so Settings doesn't warn before anyone asked.
    var accessProblem: LocationAccessProblem?

    /// The pane that controls Dimmerly's location access. Settings names the path in text too,
    /// in case this URL stops resolving in a later macOS.
    static let locationPrivacySettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices"
    )

    private let locationManager = CLLocationManager()
    /// False for the `forTesting` instance, which must never read the live authorization status.
    private let readsSystemAuthorization: Bool
    private let requestGate = LocationRequestGate()
    private let locationServicesAvailable: LocationServicesAvailabilityCheck

    /// The `UserDefaults` suite to read from and persist to. Defaults to `.standard` for
    /// production use; tests should inject an isolated suite so they don't read or overwrite
    /// the developer's real saved location.
    private let defaults: UserDefaults

    private static let latitudeKey = "dimmerlyLatitude"
    private static let longitudeKey = "dimmerlyLongitude"
    /// Sentinel value indicating a saved coordinate (0.0 is valid, so we use key existence)
    private static let hasSavedKey = "dimmerlyLocationSaved"

    /// Whether the system has Location Services switched on. Injected so tests can drive
    /// `requestLocation()` without reaching CoreLocation or raising an authorization prompt.
    typealias LocationServicesAvailabilityCheck = @Sendable () async -> Bool

    init(
        defaults: UserDefaults = .standard,
        locationServicesAvailable: @escaping LocationServicesAvailabilityCheck = {
            await LocationProvider.systemLocationServicesEnabled()
        }
    ) {
        self.defaults = defaults
        self.locationServicesAvailable = locationServicesAvailable
        readsSystemAuthorization = true
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyKilometer
        loadSavedLocation()
        authorizationStatus = locationManager.authorizationStatus
    }

    /// Test-only initializer that skips CoreLocation wiring.
    ///
    /// The production initializer registers as `CLLocationManager`'s delegate and seeds
    /// `authorizationStatus` from it, after which the system keeps writing that property
    /// asynchronously. A test asserting on the property needs an instance the system never
    /// touches, or it races real authorization changes.
    ///
    /// - Parameters:
    ///   - forTesting: Pass `true` to skip delegate registration and status seeding.
    ///   - defaults: Isolated suite so the test doesn't touch the developer's saved location.
    ///   - locationServicesAvailable: Stubbed Location Services switch for `refreshAccessProblem()`.
    init(
        forTesting _: Bool,
        defaults: UserDefaults = .standard,
        locationServicesAvailable: @escaping LocationServicesAvailabilityCheck = { false }
    ) {
        self.defaults = defaults
        self.locationServicesAvailable = locationServicesAvailable
        readsSystemAuthorization = false
        super.init()
        loadSavedLocation()
    }

    /// Whether a location is available
    var hasLocation: Bool {
        latitude != nil && longitude != nil
    }

    /// Requests a one-shot location fix from the system.
    /// Uses `startUpdatingLocation()` which reliably triggers the macOS
    /// authorization prompt, even for agent (LSUIElement) apps.
    func requestLocation() {
        let requestToken = requestGate.begin()
        // `CLLocationManager.locationServicesEnabled()` can block briefly and is
        // flagged as non-main-thread-safe by Apple, so the check runs off the main
        // actor. This task inherits the main actor, so it resumes there to start updating.
        Task { [weak self, locationServicesAvailable] in
            let servicesEnabled = await locationServicesAvailable()
            guard let self else { return }
            guard servicesEnabled else {
                // Leave the request open: Location Services may come back while Settings
                // is showing, and a fix that then arrives is still the one asked for.
                if requestGate.acceptsCallback(requestToken) {
                    accessProblem = .servicesOff
                }
                return
            }
            beginLocationRequest(token: requestToken)
        }
    }

    /// Re-reads Location Services and Dimmerly's authorization, so a problem shown in Settings
    /// clears (or changes) once the person fixes it in System Settings and comes back.
    /// Nothing is cached: access can change at any time while the app runs.
    func refreshAccessProblem() async {
        guard accessProblem != nil else { return }
        let servicesEnabled = await locationServicesAvailable()
        if readsSystemAuthorization {
            authorizationStatus = locationManager.authorizationStatus
        }
        // A request made in the meantime may already have cleared or replaced the problem.
        guard accessProblem != nil else { return }
        accessProblem = LocationAccessProblem.current(servicesEnabled: servicesEnabled, status: authorizationStatus)
    }

    /// Opens Privacy & Security > Location Services in System Settings.
    func openLocationPrivacySettings() {
        guard let url = Self.locationPrivacySettingsURL else { return }
        NSWorkspace.shared.open(url)
    }

    /// Off-main helper that calls the CLLocationManager class method Apple
    /// recommends not be invoked from the main thread.
    private static func systemLocationServicesEnabled() async -> Bool {
        await Task.detached(priority: .userInitiated) {
            CLLocationManager.locationServicesEnabled()
        }.value
    }

    private func beginLocationRequest(token: UInt64) {
        guard requestGate.isCurrent(token) else { return }
        let status = locationManager.authorizationStatus
        authorizationStatus = status

        if let problem = LocationAccessProblem.current(servicesEnabled: true, status: status) {
            // Already turned down: the system won't ask again, so Settings explains where to
            // allow it instead of the request failing without a word.
            accessProblem = problem
            requestGate.complete(token)
            return
        }

        accessProblem = nil
        // Activate the app so the authorization dialog is visible for LSUIElement apps
        NSApp.activate()
        // For both .notDetermined and .authorizedAlways, startUpdatingLocation()
        // will either trigger the auth prompt or begin delivering locations.
        locationManager.startUpdatingLocation()
    }

    /// Sets a user-entered manual location
    func setManualLocation(latitude: Double, longitude: Double) {
        requestGate.invalidate()
        locationManager.stopUpdatingLocation()
        self.latitude = latitude
        self.longitude = longitude
        // A typed-in location works around the problem, so the warning has done its job.
        accessProblem = nil
        saveLocation()
    }

    /// Clears the saved location
    func clearLocation() {
        requestGate.invalidate()
        locationManager.stopUpdatingLocation()
        latitude = nil
        longitude = nil
        defaults.removeObject(forKey: Self.latitudeKey)
        defaults.removeObject(forKey: Self.longitudeKey)
        defaults.removeObject(forKey: Self.hasSavedKey)
    }

    private func loadSavedLocation() {
        guard defaults.bool(forKey: Self.hasSavedKey) else { return }
        latitude = defaults.double(forKey: Self.latitudeKey)
        longitude = defaults.double(forKey: Self.longitudeKey)
    }

    private func saveLocation() {
        if let lat = latitude, let lon = longitude {
            defaults.set(lat, forKey: Self.latitudeKey)
            defaults.set(lon, forKey: Self.longitudeKey)
            defaults.set(true, forKey: Self.hasSavedKey)
        }
    }
}

// MARK: - CLLocationManagerDelegate

extension LocationProvider: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        manager.stopUpdatingLocation()
        guard let location = locations.last else { return }
        let lat = location.coordinate.latitude
        let lon = location.coordinate.longitude
        let requestToken = requestGate.current()
        Task { @MainActor in
            guard self.requestGate.acceptsCallback(requestToken) else { return }
            self.latitude = lat
            self.longitude = lon
            self.accessProblem = nil
            self.saveLocation()
            self.requestGate.complete(requestToken)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Per Apple's CLLocationManagerDelegate documentation, `.locationUnknown` means the
        // location is temporarily unavailable but the manager will keep trying — stopping
        // here would kill the one-shot request and silently leave sunrise/sunset schedules
        // without a location, even though a location may have arrived moments later.
        if let clError = error as? CLError, clError.code == .locationUnknown {
            return
        }
        manager.stopUpdatingLocation()
        if let clError = error as? CLError, clError.code == .denied {
            reportDeniedRequest()
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        applyAuthorizationStatus(manager.authorizationStatus)
    }

    /// The person turned down the prompt for a request that is still waiting. Settings then
    /// says where to allow access, rather than the request just stopping.
    nonisolated func reportDeniedRequest() {
        let requestToken = requestGate.current()
        Task { @MainActor in
            guard self.requestGate.acceptsCallback(requestToken), self.accessProblem != .servicesOff else { return }
            self.accessProblem = .denied
            self.requestGate.complete(requestToken)
        }
    }

    /// Publishes an authorization status on the main actor.
    ///
    /// Separated from the delegate callback so tests can drive a known status. Asserting against
    /// `CLLocationManager.authorizationStatus` instead races the system: the delegate snapshots
    /// the value, and the live property can change again before the assertion re-reads it — a
    /// fresh CI runner resolves `notDetermined` to `denied` — which made the test flaky.
    nonisolated func applyAuthorizationStatus(_ status: CLAuthorizationStatus) {
        Task { @MainActor in
            self.authorizationStatus = status
            switch status {
            case .denied, .restricted:
                // Some macOS versions report a turned-down prompt only as an authorization
                // change, without a `.denied` failure. A pending request still needs to say so.
                let requestToken = self.requestGate.current()
                // With Location Services off every app reads as denied; keep the warning
                // that names the actual switch.
                if self.requestGate.acceptsCallback(requestToken), self.accessProblem != .servicesOff {
                    self.accessProblem = status == .restricted ? .restricted : .denied
                    self.requestGate.complete(requestToken)
                }
            case .notDetermined:
                break
            default:
                // Access came back: a denied or restricted warning no longer applies. A
                // Location Services warning stays until a refresh sees the switch turned on.
                if self.accessProblem == .denied || self.accessProblem == .restricted {
                    self.accessProblem = nil
                }
            }
        }
    }
}

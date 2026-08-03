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

@MainActor
@Observable
class LocationProvider: NSObject {
    static let shared = LocationProvider()

    var latitude: Double?
    var longitude: Double?
    var authorizationStatus: CLAuthorizationStatus = .notDetermined

    private let locationManager = CLLocationManager()

    /// The `UserDefaults` suite to read from and persist to. Defaults to `.standard` for
    /// production use; tests should inject an isolated suite so they don't read or overwrite
    /// the developer's real saved location.
    private let defaults: UserDefaults

    private static let latitudeKey = "dimmerlyLatitude"
    private static let longitudeKey = "dimmerlyLongitude"
    /// Sentinel value indicating a saved coordinate (0.0 is valid, so we use key existence)
    private static let hasSavedKey = "dimmerlyLocationSaved"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
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
    init(forTesting _: Bool, defaults: UserDefaults = .standard) {
        self.defaults = defaults
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
        // `CLLocationManager.locationServicesEnabled()` can block briefly and is
        // flagged as non-main-thread-safe by Apple. Run it on a background task,
        // then hop back to @MainActor to start updating.
        Task { [weak self] in
            let enabled = await Self.locationServicesAvailable()
            guard enabled else { return }
            await MainActor.run {
                self?.beginLocationRequest()
            }
        }
    }

    /// Off-main helper that calls the CLLocationManager class method Apple
    /// recommends not be invoked from the main thread.
    private static func locationServicesAvailable() async -> Bool {
        await Task.detached(priority: .userInitiated) {
            CLLocationManager.locationServicesEnabled()
        }.value
    }

    private func beginLocationRequest() {
        // Activate the app so the authorization dialog is visible for LSUIElement apps
        NSApp.activate()

        switch locationManager.authorizationStatus {
        case .denied, .restricted:
            // Already denied — open System Settings so the user can grant access
            let prefURL = "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices"
            if let url = URL(string: prefURL) {
                NSWorkspace.shared.open(url)
            }
        default:
            // For both .notDetermined and .authorizedAlways, startUpdatingLocation()
            // will either trigger the auth prompt or begin delivering locations.
            locationManager.startUpdatingLocation()
        }
    }

    /// Sets a user-entered manual location
    func setManualLocation(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
        saveLocation()
    }

    /// Clears the saved location
    func clearLocation() {
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
        Task { @MainActor in
            self.latitude = lat
            self.longitude = lon
            self.saveLocation()
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
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        applyAuthorizationStatus(manager.authorizationStatus)
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
        }
    }
}

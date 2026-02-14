//
//  LocationProvider.swift
//  Dimmerly
//
//  Provides location data for solar calculations.
//  Supports both CLLocationManager-based and manual coordinate entry.
//

import Foundation
import CoreLocation
import AppKit

@MainActor
class LocationProvider: NSObject, ObservableObject {
    static let shared = LocationProvider()

    @Published var latitude: Double?
    @Published var longitude: Double?
    @Published var authorizationStatus: CLAuthorizationStatus = .notDetermined

    private let locationManager = CLLocationManager()

    private static let latitudeKey = "dimmerlyLatitude"
    private static let longitudeKey = "dimmerlyLongitude"
    /// Sentinel value indicating a saved coordinate (0.0 is valid, so we use key existence)
    private static let hasSavedKey = "dimmerlyLocationSaved"

    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyKilometer
        loadSavedLocation()
        authorizationStatus = locationManager.authorizationStatus
    }

    /// Whether a location is available
    var hasLocation: Bool {
        latitude != nil && longitude != nil
    }

    /// Requests a one-shot location fix from the system.
    /// Uses `startUpdatingLocation()` which reliably triggers the macOS
    /// authorization prompt, even for agent (LSUIElement) apps.
    func requestLocation() {
        guard CLLocationManager.locationServicesEnabled() else { return }

        // Activate the app so the authorization dialog is visible for LSUIElement apps
        NSApp.activate()

        switch locationManager.authorizationStatus {
        case .denied, .restricted:
            // Already denied — open System Settings so the user can grant access
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") {
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
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: Self.latitudeKey)
        defaults.removeObject(forKey: Self.longitudeKey)
        defaults.removeObject(forKey: Self.hasSavedKey)
    }

    private func loadSavedLocation() {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: Self.hasSavedKey) else { return }
        latitude = defaults.double(forKey: Self.latitudeKey)
        longitude = defaults.double(forKey: Self.longitudeKey)
    }

    private func saveLocation() {
        let defaults = UserDefaults.standard
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
        manager.stopUpdatingLocation()
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.authorizationStatus = status
        }
    }
}

//
//  LocationProviderTests.swift
//  DimmerlyTests
//
//  Unit tests for LocationProvider persistence and CLLocationManagerDelegate handling.
//

import CoreLocation
@testable import Dimmerly
import XCTest

@MainActor
final class LocationProviderTests: XCTestCase {
    private var testSuiteName: String!
    private var testDefaults: UserDefaults!

    override func setUp() async throws {
        testSuiteName = "LocationProviderTests-\(UUID().uuidString)"
        testDefaults = UserDefaults(suiteName: testSuiteName)
        testDefaults.removePersistentDomain(forName: testSuiteName)
    }

    override func tearDown() async throws {
        testDefaults.removePersistentDomain(forName: testSuiteName)
        testDefaults = nil
        testSuiteName = nil
    }

    func testInitialStateHasNoLocationWhenNothingSaved() {
        let provider = LocationProvider(defaults: testDefaults)
        XCTAssertFalse(provider.hasLocation)
        XCTAssertNil(provider.latitude)
        XCTAssertNil(provider.longitude)
    }

    func testSetManualLocationUpdatesStateAndPersists() {
        let provider = LocationProvider(defaults: testDefaults)
        provider.setManualLocation(latitude: 52.52, longitude: 13.405)

        XCTAssertTrue(provider.hasLocation)
        XCTAssertEqual(provider.latitude ?? 0, 52.52, accuracy: 0.0001)
        XCTAssertEqual(provider.longitude ?? 0, 13.405, accuracy: 0.0001)

        // A fresh instance backed by the same suite should load the persisted values.
        let reloaded = LocationProvider(defaults: testDefaults)
        XCTAssertEqual(reloaded.latitude ?? 0, 52.52, accuracy: 0.0001)
        XCTAssertEqual(reloaded.longitude ?? 0, 13.405, accuracy: 0.0001)
    }

    func testClearLocationRemovesStateAndPersistedValues() {
        let provider = LocationProvider(defaults: testDefaults)
        provider.setManualLocation(latitude: 40.7128, longitude: -74.0060)
        XCTAssertTrue(provider.hasLocation)

        provider.clearLocation()

        XCTAssertFalse(provider.hasLocation)
        XCTAssertNil(provider.latitude)
        XCTAssertNil(provider.longitude)

        let reloaded = LocationProvider(defaults: testDefaults)
        XCTAssertFalse(reloaded.hasLocation, "Clearing must persist — a fresh instance must not resurrect it")
    }

    // MARK: - CLLocationManagerDelegate

    func testDidFailWithLocationUnknownErrorDoesNotClearState() {
        let provider = LocationProvider(defaults: testDefaults)
        provider.setManualLocation(latitude: 1.0, longitude: 2.0)

        let error = CLError(.locationUnknown)
        provider.locationManager(CLLocationManager(), didFailWithError: error)

        // Regression test for the fix: `.locationUnknown` is documented by Apple as
        // transient — the manager keeps trying — so it must not be treated as fatal.
        XCTAssertTrue(provider.hasLocation, "A transient locationUnknown error must not clear existing state")
    }

    func testDidUpdateLocationsSetsLatitudeAndLongitude() {
        let provider = LocationProvider(defaults: testDefaults)
        let location = CLLocation(latitude: 48.8566, longitude: 2.3522)

        provider.locationManager(CLLocationManager(), didUpdateLocations: [location])

        // The delegate callback hops to @MainActor asynchronously to update state.
        let expectation = expectation(description: "location applied")
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(50))
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)

        XCTAssertEqual(provider.latitude ?? 0, 48.8566, accuracy: 0.0001)
        XCTAssertEqual(provider.longitude ?? 0, 2.3522, accuracy: 0.0001)
    }

    func testDidChangeAuthorizationUpdatesStatus() {
        let provider = LocationProvider(defaults: testDefaults)
        let manager = CLLocationManager()

        provider.locationManagerDidChangeAuthorization(manager)

        let expectation = expectation(description: "status applied")
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(50))
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)

        XCTAssertEqual(provider.authorizationStatus, manager.authorizationStatus)
    }
}

//
//  BrightnessManagerTests+Persistence.swift
//  DimmerlyTests
//
//  Saving pending display values when the app quits.
//

@testable import Dimmerly
import XCTest

@MainActor
extension BrightnessManagerTests {
    private func managerWithIsolatedDefaults(_ defaults: UserDefaults, identity: String) -> BrightnessManager {
        let manager = BrightnessManager(forTesting: true, defaults: defaults)
        manager.applyGammaHook = { _, _, _, _ in }
        manager.isBuiltInDisplayHook = { _ in false }
        manager.displayIdentityHook = { _ in identity }
        manager.displays = [
            ExternalDisplay(id: 2, name: "DELL S2723HC", brightness: 1.0, warmth: 0.0, contrast: 0.5),
        ]
        return manager
    }

    /// A change inside the 500 ms debounce window must not be lost when the app quits.
    func testFlushPendingPersistenceSavesADebouncedChangeImmediately() throws {
        let suiteName = "BrightnessManagerTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let identity = "v16652m49551s3212"
        let manager = managerWithIsolatedDefaults(defaults, identity: identity)

        manager.setContrast(for: 2, to: 0.7)
        XCTAssertNil(defaults.dictionary(forKey: "dimmerlyDisplayContrast"), "The write should still be debounced")

        manager.flushPendingPersistence()

        let contrast = try XCTUnwrap(defaults.dictionary(forKey: "dimmerlyDisplayContrast") as? [String: Double])
        XCTAssertEqual(try XCTUnwrap(contrast[identity]), 0.7, accuracy: 0.0001)
    }

    /// A preset transition cut short by quitting never reaches its own save, so the flush saves
    /// the values it was heading to.
    func testFlushPendingPersistenceSavesTheEndValuesOfARunningTransition() throws {
        let suiteName = "BrightnessManagerTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let identity = "v16652m49551s3212"
        let manager = managerWithIsolatedDefaults(defaults, identity: identity)
        manager.canAnimateTransitionsHook = { true }

        let preset = BrightnessPreset(
            name: "Evening",
            displayWarmth: [identity: 0.42],
            displayContrast: [identity: 0.6]
        )
        XCTAssertTrue(manager.animateToPreset(preset), "Animation should start")

        manager.flushPendingPersistence()

        XCTAssertEqual(manager.displays[0].warmth, 0.42, accuracy: 0.0001)
        let warmth = try XCTUnwrap(defaults.dictionary(forKey: "dimmerlyDisplayWarmth") as? [String: Double])
        let contrast = try XCTUnwrap(defaults.dictionary(forKey: "dimmerlyDisplayContrast") as? [String: Double])
        XCTAssertEqual(try XCTUnwrap(warmth[identity]), 0.42, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(contrast[identity]), 0.6, accuracy: 0.0001)
    }

    /// An edit made inside the debounce window, followed by the display being unplugged, must
    /// still be saved, and found again when the display returns under a new numeric ID.
    func testEditsMadeJustBeforeADisconnectSurviveAReconnectUnderANewID() throws {
        let suiteName = "BrightnessManagerTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let manager = BrightnessManager(forTesting: true, defaults: defaults)
        manager.applyGammaHook = { _, _, _, _ in }
        manager.isBuiltInDisplayHook = { _ in false }
        manager.displayIdentityHook = { id in id == 2 || id == 5 ? "unplugged" : "stays" }
        manager.displays = [
            ExternalDisplay(id: 2, name: "DELL S2723HC", brightness: 1.0, warmth: 0.0, contrast: 0.5),
            ExternalDisplay(id: 3, name: "LG", brightness: 1.0, warmth: 0.0, contrast: 0.5),
        ]

        manager.setBrightness(for: 2, to: 0.6)
        manager.setWarmth(for: 2, to: 0.3)
        manager.setContrast(for: 2, to: 0.8)
        XCTAssertNil(defaults.dictionary(forKey: "dimmerlyDisplayContrast"), "The write should still be debounced")

        manager.activeDisplayIDsHook = { [3] }
        manager.refreshDisplays()

        let brightness = try XCTUnwrap(defaults.dictionary(forKey: "dimmerlyDisplayBrightness") as? [String: Double])
        let warmth = try XCTUnwrap(defaults.dictionary(forKey: "dimmerlyDisplayWarmth") as? [String: Double])
        let contrast = try XCTUnwrap(defaults.dictionary(forKey: "dimmerlyDisplayContrast") as? [String: Double])
        XCTAssertEqual(try XCTUnwrap(brightness["unplugged"]), 0.6, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(warmth["unplugged"]), 0.3, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(contrast["unplugged"]), 0.8, accuracy: 0.0001)

        manager.activeDisplayIDsHook = { [3, 5] }
        manager.refreshDisplays()

        let reconnected = try XCTUnwrap(manager.displays.first { $0.id == 5 })
        XCTAssertEqual(reconnected.brightness, 0.6, accuracy: 0.0001)
        XCTAssertEqual(reconnected.warmth, 0.3, accuracy: 0.0001)
        XCTAssertEqual(reconnected.contrast, 0.8, accuracy: 0.0001)
    }
}

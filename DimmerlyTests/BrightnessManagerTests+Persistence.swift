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

    func testDuplicateSerialDisplaysKeepSeparateSettingsAndPresetsAcrossRefreshAndReload() throws {
        let suiteName = "BrightnessManagerTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let uniqueKey = "v111m222s67890"
        defaults.set([uniqueKey: 0.66], forKey: "dimmerlyDisplayBrightness")
        defaults.set([uniqueKey: 0.55], forKey: "dimmerlyDisplayWarmth")
        defaults.set([uniqueKey: 0.44], forKey: "dimmerlyDisplayContrast")

        let manager = duplicateSerialManager(defaults: defaults, displayIDs: [31, 32, 33])
        manager.refreshDisplays()
        manager.setBrightness(for: 31, to: 0.3)
        manager.setBrightness(for: 32, to: 0.8)
        manager.setWarmth(for: 31, to: 0.1)
        manager.setWarmth(for: 32, to: 0.7)
        manager.setContrast(for: 31, to: 0.2)
        manager.setContrast(for: 32, to: 0.9)
        manager.refreshDisplays()
        XCTAssertEqual(manager.displays.map(\.brightness), [0.3, 0.8, 0.66])
        XCTAssertEqual(manager.displays.map(\.warmth), [0.1, 0.7, 0.55])
        XCTAssertEqual(manager.displays.map(\.contrast), [0.2, 0.9, 0.44])
        let preset = BrightnessPreset(
            name: "Independent displays",
            displayBrightness: manager.currentBrightnessSnapshot(),
            displayWarmth: manager.currentWarmthSnapshot(),
            displayContrast: manager.currentContrastSnapshot()
        )
        XCTAssertEqual(preset.displayBrightness.count, 3)
        manager.flushPendingPersistence()

        // One duplicate is absent at launch, and macOS has changed the numeric IDs.
        let reloaded = duplicateSerialManager(defaults: defaults, displayIDs: [41, 43])
        reloaded.refreshDisplays()
        XCTAssertEqual(reloaded.displays.map(\.brightness), [0.3, 0.66])
        XCTAssertEqual(reloaded.displays.map(\.warmth), [0.1, 0.55])
        XCTAssertEqual(reloaded.displays.map(\.contrast), [0.2, 0.44])
        reloaded.activeDisplayIDsHook = { [41, 42, 43] }
        reloaded.refreshDisplays()
        XCTAssertEqual(reloaded.displays.map(\.brightness), [0.3, 0.8, 0.66])
        XCTAssertEqual(reloaded.displays.map(\.warmth), [0.1, 0.7, 0.55])
        XCTAssertEqual(reloaded.displays.map(\.contrast), [0.2, 0.9, 0.44])

        reloaded.setAllBrightness(to: 1)
        reloaded.setAllWarmth(to: 0)
        reloaded.setAllContrast(to: 0.5)
        reloaded.applyBrightnessValues(preset.displayBrightness)
        try reloaded.applyWarmthValues(XCTUnwrap(preset.displayWarmth))
        try reloaded.applyContrastValues(XCTUnwrap(preset.displayContrast))
        XCTAssertEqual(reloaded.displays.map(\.brightness), [0.3, 0.8, 0.66])
        XCTAssertEqual(reloaded.displays.map(\.warmth), [0.1, 0.7, 0.55])
        XCTAssertEqual(reloaded.displays.map(\.contrast), [0.2, 0.9, 0.44])
        reloaded.flushPendingPersistence()
    }

    private func duplicateSerialManager(defaults: UserDefaults, displayIDs: [UInt32]) -> BrightnessManager {
        let manager = BrightnessManager(forTesting: true, defaults: defaults)
        manager.activeDisplayIDsHook = { displayIDs }
        manager.displayNameHook = { "External \($0)" }
        manager.isBuiltInDisplayHook = { _ in false }
        manager.isBlankingHook = { false }
        manager.applyGammaHook = { _, _, _, _ in }
        manager.displayUnitNumberHook = { $0 % 10 }
        manager.displayIdentityHook = { id in
            BrightnessManager.persistenceIdentity(
                vendor: 111, model: 222, serial: id % 10 == 3 ? 67890 : 12345, unitNumber: id % 10, displayID: id
            )
        }
        return manager
    }

    /// Unplugging a display while a preset transition is running must save where the transition
    /// was heading, not whatever frame it had reached.
    func testUnplugDuringATransitionAppliesAndSavesTheTransitionEndValues() async throws {
        let suiteName = "BrightnessManagerTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let identity = "unplugged"
        let manager = managerWithIsolatedDefaults(defaults, identity: identity)
        manager.displayIdentityHook = { id in id == 3 ? "stays" : identity }
        manager.isBlankingHook = { false }
        manager.displays.append(ExternalDisplay(id: 3, name: "LG", brightness: 1.0, warmth: 0.0, contrast: 0.5))
        manager.canAnimateTransitionsHook = { true }

        let firstFrame = expectation(description: "surviving display receives an animation frame")
        var appliedBrightness: Double?
        manager.applyGammaHook = { id, brightness, _, _ in
            guard id == 3 else { return }
            if appliedBrightness == nil {
                firstFrame.fulfill()
            }
            appliedBrightness = brightness
        }
        let preset = BrightnessPreset(
            name: "Evening",
            universalBrightness: 0.4,
            universalWarmth: 0.42,
            universalContrast: 0.6
        )
        XCTAssertTrue(manager.animateToPreset(preset), "Animation should start")
        await fulfillment(of: [firstFrame], timeout: 1)
        XCTAssertGreaterThan(try XCTUnwrap(appliedBrightness), 0.4)

        manager.activeDisplayIDsHook = { [3] }
        manager.refreshDisplays()

        XCTAssertEqual(manager.displays[0].brightness, 0.4, accuracy: 0.0001)
        XCTAssertEqual(manager.displays[0].warmth, 0.42, accuracy: 0.0001)
        XCTAssertEqual(manager.displays[0].contrast, 0.6, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(appliedBrightness), 0.4, accuracy: 0.0001)
        manager.persistAll()
        let brightness = try XCTUnwrap(defaults.dictionary(forKey: "dimmerlyDisplayBrightness") as? [String: Double])
        let warmth = try XCTUnwrap(defaults.dictionary(forKey: "dimmerlyDisplayWarmth") as? [String: Double])
        let contrast = try XCTUnwrap(defaults.dictionary(forKey: "dimmerlyDisplayContrast") as? [String: Double])
        XCTAssertEqual(try XCTUnwrap(brightness[identity]), 0.4, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(brightness["stays"]), 0.4, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(warmth[identity]), 0.42, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(contrast[identity]), 0.6, accuracy: 0.0001)

        manager.activeDisplayIDsHook = { [3, 5] }
        manager.refreshDisplays()
        let reconnected = try XCTUnwrap(manager.displays.first { $0.id == 5 })
        XCTAssertEqual(reconnected.brightness, 0.4, accuracy: 0.0001)
        XCTAssertEqual(reconnected.warmth, 0.42, accuracy: 0.0001)
        XCTAssertEqual(reconnected.contrast, 0.6, accuracy: 0.0001)
    }
}

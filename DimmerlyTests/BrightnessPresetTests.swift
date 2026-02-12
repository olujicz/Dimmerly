//
//  BrightnessPresetTests.swift
//  DimmerlyTests
//
//  Unit tests for BrightnessPreset and PresetManager.
//

import XCTest
@testable import Dimmerly

@MainActor
final class BrightnessPresetTests: XCTestCase {

    /// Tests Codable round-trip for BrightnessPreset
    func testCodableRoundTrip() throws {
        let preset = BrightnessPreset(
            name: "Test Preset",
            displayBrightness: ["12345": 0.5, "67890": 0.8]
        )

        let data = try JSONEncoder().encode(preset)
        let decoded = try JSONDecoder().decode(BrightnessPreset.self, from: data)

        XCTAssertEqual(preset.id, decoded.id)
        XCTAssertEqual(preset.name, decoded.name)
        XCTAssertEqual(preset.displayBrightness, decoded.displayBrightness)
    }

    /// Tests that preset with optional shortcut encodes/decodes correctly
    func testCodableWithShortcut() throws {
        var preset = BrightnessPreset(
            name: "With Shortcut",
            displayBrightness: ["100": 0.75]
        )
        preset.shortcut = GlobalShortcut(key: "1", modifiers: [.command, .option])

        let data = try JSONEncoder().encode(preset)
        let decoded = try JSONDecoder().decode(BrightnessPreset.self, from: data)

        XCTAssertEqual(decoded.shortcut?.key, "1")
        XCTAssertEqual(decoded.shortcut?.modifiers, [.command, .option])
    }

    /// Tests that preset without shortcut decodes correctly
    func testCodableWithoutShortcut() throws {
        let preset = BrightnessPreset(
            name: "No Shortcut",
            displayBrightness: ["100": 0.5]
        )

        let data = try JSONEncoder().encode(preset)
        let decoded = try JSONDecoder().decode(BrightnessPreset.self, from: data)

        XCTAssertNil(decoded.shortcut)
    }

    /// Tests Equatable conformance
    func testEquatable() {
        let id = UUID()
        let date = Date()
        let preset1 = BrightnessPreset(id: id, name: "Test", displayBrightness: ["1": 0.5], createdAt: date)
        let preset2 = BrightnessPreset(id: id, name: "Test", displayBrightness: ["1": 0.5], createdAt: date)
        let preset3 = BrightnessPreset(name: "Different", displayBrightness: ["1": 0.5])

        XCTAssertEqual(preset1, preset2)
        XCTAssertNotEqual(preset1, preset3)
    }

    /// Tests PresetManager max preset limit
    func testMaxPresetLimit() {
        let manager = PresetManager()
        // Clear any existing presets
        while !manager.presets.isEmpty {
            manager.deletePreset(id: manager.presets[0].id)
        }

        let bm = BrightnessManager(forTesting: true)

        // Add up to the limit
        for i in 0..<PresetManager.maxPresets {
            manager.saveCurrentAsPreset(name: "Preset \(i)", brightnessManager: bm)
        }
        XCTAssertEqual(manager.presets.count, PresetManager.maxPresets)

        // Try to add one more — should not exceed limit
        manager.saveCurrentAsPreset(name: "Over Limit", brightnessManager: bm)
        XCTAssertEqual(manager.presets.count, PresetManager.maxPresets)

        // Clean up
        while !manager.presets.isEmpty {
            manager.deletePreset(id: manager.presets[0].id)
        }
    }

    /// Tests delete operation
    func testDeletePreset() {
        let manager = PresetManager()
        let bm = BrightnessManager(forTesting: true)

        manager.saveCurrentAsPreset(name: "To Delete", brightnessManager: bm)
        let count = manager.presets.count
        guard let id = manager.presets.last?.id else {
            XCTFail("Expected at least one preset")
            return
        }

        manager.deletePreset(id: id)
        XCTAssertEqual(manager.presets.count, count - 1)
    }

    /// Tests rename operation
    func testRenamePreset() {
        let manager = PresetManager()
        let bm = BrightnessManager(forTesting: true)

        manager.saveCurrentAsPreset(name: "Original", brightnessManager: bm)
        guard let id = manager.presets.last?.id else {
            XCTFail("Expected at least one preset")
            return
        }

        manager.renamePreset(id: id, to: "Renamed")
        XCTAssertEqual(manager.presets.last?.name, "Renamed")

        // Clean up
        manager.deletePreset(id: id)
    }

    // MARK: - Codable with warmth and contrast

    func testCodableRoundTripWithWarmthAndContrast() throws {
        let preset = BrightnessPreset(
            name: "Full Config",
            displayBrightness: ["1": 0.5],
            displayWarmth: ["1": 0.3],
            universalWarmth: 0.6,
            displayContrast: ["1": 0.8],
            universalContrast: 0.4
        )

        let data = try JSONEncoder().encode(preset)
        let decoded = try JSONDecoder().decode(BrightnessPreset.self, from: data)

        XCTAssertEqual(decoded.displayWarmth, ["1": 0.3])
        XCTAssertEqual(decoded.universalWarmth, 0.6)
        XCTAssertEqual(decoded.displayContrast, ["1": 0.8])
        XCTAssertEqual(decoded.universalContrast, 0.4)
    }

    // MARK: - Default init values

    func testDefaultInitValues() {
        let preset = BrightnessPreset(name: "Defaults")

        XCTAssertEqual(preset.name, "Defaults")
        XCTAssertTrue(preset.displayBrightness.isEmpty)
        XCTAssertNil(preset.shortcut)
        XCTAssertNil(preset.universalBrightness)
        XCTAssertNil(preset.displayWarmth)
        XCTAssertNil(preset.universalWarmth)
        XCTAssertNil(preset.displayContrast)
        XCTAssertNil(preset.universalContrast)
    }

    func testInitWithUniversalValues() {
        let preset = BrightnessPreset(
            name: "Universal",
            universalBrightness: 0.8,
            universalWarmth: 0.5,
            universalContrast: 0.7
        )

        XCTAssertEqual(preset.universalBrightness, 0.8)
        XCTAssertEqual(preset.universalWarmth, 0.5)
        XCTAssertEqual(preset.universalContrast, 0.7)
        XCTAssertTrue(preset.displayBrightness.isEmpty)
    }

    // MARK: - Equatable with warmth/contrast

    func testEquatableDifferingByWarmth() {
        let id = UUID()
        let date = Date()
        let preset1 = BrightnessPreset(id: id, name: "Test", displayBrightness: ["1": 0.5], createdAt: date, universalWarmth: 0.3)
        let preset2 = BrightnessPreset(id: id, name: "Test", displayBrightness: ["1": 0.5], createdAt: date, universalWarmth: 0.7)

        XCTAssertNotEqual(preset1, preset2, "Presets differing by warmth should not be equal")
    }

    func testEquatableDifferingByContrast() {
        let id = UUID()
        let date = Date()
        let preset1 = BrightnessPreset(id: id, name: "Test", displayBrightness: ["1": 0.5], createdAt: date, universalContrast: 0.2)
        let preset2 = BrightnessPreset(id: id, name: "Test", displayBrightness: ["1": 0.5], createdAt: date, universalContrast: 0.9)

        XCTAssertNotEqual(preset1, preset2, "Presets differing by contrast should not be equal")
    }
}

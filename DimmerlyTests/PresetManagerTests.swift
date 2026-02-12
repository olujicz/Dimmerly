//
//  PresetManagerTests.swift
//  DimmerlyTests
//
//  Unit tests for PresetManager operations.
//

import XCTest
@testable import Dimmerly

@MainActor
final class PresetManagerTests: XCTestCase {

    var manager: PresetManager!
    var bm: BrightnessManager!

    override func setUp() async throws {
        manager = PresetManager()
        bm = BrightnessManager(forTesting: true)
        // Clear presets for a clean slate
        while !manager.presets.isEmpty {
            manager.deletePreset(id: manager.presets[0].id)
        }
    }

    override func tearDown() async throws {
        // Clean up presets
        while !manager.presets.isEmpty {
            manager.deletePreset(id: manager.presets[0].id)
        }
        // Clean up UserDefaults keys used by PresetManager
        UserDefaults.standard.removeObject(forKey: "dimmerlyBrightnessPresets")
        UserDefaults.standard.removeObject(forKey: "dimmerlyDefaultPresetsSeeded")
        manager = nil
        bm = nil
    }

    // MARK: - applyPreset

    func testApplyPresetUniversalBrightness() {
        bm.displays = [
            ExternalDisplay(id: 1, name: "A", brightness: 1.0),
            ExternalDisplay(id: 2, name: "B", brightness: 1.0),
        ]
        let preset = BrightnessPreset(name: "Test", universalBrightness: 0.5)
        manager.applyPreset(preset, to: bm)
        XCTAssertEqual(bm.displays[0].brightness, 0.5)
        XCTAssertEqual(bm.displays[1].brightness, 0.5)
    }

    func testApplyPresetPerDisplayBrightness() {
        bm.displays = [
            ExternalDisplay(id: 1, name: "A", brightness: 1.0),
            ExternalDisplay(id: 2, name: "B", brightness: 1.0),
        ]
        let preset = BrightnessPreset(name: "Test", displayBrightness: ["1": 0.3, "2": 0.7])
        manager.applyPreset(preset, to: bm)
        XCTAssertEqual(bm.displays[0].brightness, 0.3)
        XCTAssertEqual(bm.displays[1].brightness, 0.7)
    }

    func testApplyPresetUniversalWarmth() {
        bm.displays = [
            ExternalDisplay(id: 1, name: "A", brightness: 1.0, warmth: 0.0),
            ExternalDisplay(id: 2, name: "B", brightness: 1.0, warmth: 0.0),
        ]
        let preset = BrightnessPreset(name: "Test", universalBrightness: 1.0, universalWarmth: 0.6)
        manager.applyPreset(preset, to: bm)
        XCTAssertEqual(bm.displays[0].warmth, 0.6)
        XCTAssertEqual(bm.displays[1].warmth, 0.6)
    }

    func testApplyPresetPerDisplayWarmth() {
        bm.displays = [
            ExternalDisplay(id: 1, name: "A", brightness: 1.0, warmth: 0.0),
            ExternalDisplay(id: 2, name: "B", brightness: 1.0, warmth: 0.0),
        ]
        let preset = BrightnessPreset(name: "Test", universalBrightness: 1.0, displayWarmth: ["1": 0.3, "2": 0.8])
        manager.applyPreset(preset, to: bm)
        XCTAssertEqual(bm.displays[0].warmth, 0.3)
        XCTAssertEqual(bm.displays[1].warmth, 0.8)
    }

    func testApplyPresetUniversalContrast() {
        bm.displays = [
            ExternalDisplay(id: 1, name: "A", brightness: 1.0, warmth: 0.0, contrast: 0.5),
            ExternalDisplay(id: 2, name: "B", brightness: 1.0, warmth: 0.0, contrast: 0.5),
        ]
        let preset = BrightnessPreset(name: "Test", universalBrightness: 1.0, universalContrast: 0.8)
        manager.applyPreset(preset, to: bm)
        XCTAssertEqual(bm.displays[0].contrast, 0.8)
        XCTAssertEqual(bm.displays[1].contrast, 0.8)
    }

    func testApplyPresetPerDisplayContrast() {
        bm.displays = [
            ExternalDisplay(id: 1, name: "A", brightness: 1.0, warmth: 0.0, contrast: 0.5),
            ExternalDisplay(id: 2, name: "B", brightness: 1.0, warmth: 0.0, contrast: 0.5),
        ]
        let preset = BrightnessPreset(name: "Test", universalBrightness: 1.0, displayContrast: ["1": 0.2, "2": 0.9])
        manager.applyPreset(preset, to: bm)
        XCTAssertEqual(bm.displays[0].contrast, 0.2)
        XCTAssertEqual(bm.displays[1].contrast, 0.9)
    }

    func testApplyPresetNilWarmthLeavesUnchanged() {
        bm.displays = [ExternalDisplay(id: 1, name: "A", brightness: 1.0, warmth: 0.4)]
        let preset = BrightnessPreset(name: "Legacy", universalBrightness: 0.5)
        // warmth fields are nil (legacy preset)
        manager.applyPreset(preset, to: bm)
        XCTAssertEqual(bm.displays[0].warmth, 0.4, "Nil warmth should leave existing value unchanged")
    }

    func testApplyPresetNilContrastLeavesUnchanged() {
        bm.displays = [ExternalDisplay(id: 1, name: "A", brightness: 1.0, warmth: 0.0, contrast: 0.3)]
        let preset = BrightnessPreset(name: "Legacy", universalBrightness: 0.5)
        // contrast fields are nil (legacy preset)
        manager.applyPreset(preset, to: bm)
        XCTAssertEqual(bm.displays[0].contrast, 0.3, "Nil contrast should leave existing value unchanged")
    }

    // MARK: - updatePreset

    func testUpdatePresetCapturesCurrentValues() {
        bm.displays = [
            ExternalDisplay(id: 1, name: "A", brightness: 0.6, warmth: 0.3, contrast: 0.7),
        ]
        manager.saveCurrentAsPreset(name: "Update Me", brightnessManager: bm)
        guard let preset = manager.presets.last else {
            XCTFail("Expected a preset"); return
        }

        // Change display values
        bm.displays[0].brightness = 0.4
        bm.displays[0].warmth = 0.8
        bm.displays[0].contrast = 0.2

        manager.updatePreset(id: preset.id, brightnessManager: bm)

        guard let updated = manager.presets.first(where: { $0.id == preset.id }) else {
            XCTFail("Updated preset not found"); return
        }
        XCTAssertEqual(updated.displayBrightness["1"], 0.4)
        XCTAssertEqual(updated.displayWarmth?["1"], 0.8)
        XCTAssertEqual(updated.displayContrast?["1"], 0.2)
    }

    func testUpdatePresetClearsUniversalValues() {
        // Start with a universal preset
        let preset = BrightnessPreset(name: "Universal", universalBrightness: 0.5, universalWarmth: 0.3, universalContrast: 0.7)
        manager.presets.append(preset)

        bm.displays = [ExternalDisplay(id: 1, name: "A", brightness: 0.8, warmth: 0.1, contrast: 0.5)]
        manager.updatePreset(id: preset.id, brightnessManager: bm)

        guard let updated = manager.presets.first(where: { $0.id == preset.id }) else {
            XCTFail("Updated preset not found"); return
        }
        XCTAssertNil(updated.universalBrightness, "Universal brightness should be cleared")
        XCTAssertNil(updated.universalWarmth, "Universal warmth should be cleared")
        XCTAssertNil(updated.universalContrast, "Universal contrast should be cleared")
    }

    func testUpdatePresetInvalidIDIsNoOp() {
        let countBefore = manager.presets.count
        manager.updatePreset(id: UUID(), brightnessManager: bm)
        XCTAssertEqual(manager.presets.count, countBefore)
    }

    // MARK: - movePresets

    func testMovePresetsReorder() {
        bm.displays = []
        manager.saveCurrentAsPreset(name: "First", brightnessManager: bm)
        manager.saveCurrentAsPreset(name: "Second", brightnessManager: bm)
        manager.saveCurrentAsPreset(name: "Third", brightnessManager: bm)

        // Move first item to end
        manager.movePresets(from: IndexSet(integer: 0), to: 3)

        XCTAssertEqual(manager.presets[0].name, "Second")
        XCTAssertEqual(manager.presets[1].name, "Third")
        XCTAssertEqual(manager.presets[2].name, "First")
    }

    // MARK: - updateShortcut

    func testUpdateShortcutSet() {
        bm.displays = []
        manager.saveCurrentAsPreset(name: "Shortcut Test", brightnessManager: bm)
        guard let id = manager.presets.last?.id else {
            XCTFail("Expected a preset"); return
        }

        let shortcut = GlobalShortcut(key: "1", modifiers: [.command, .option])
        manager.updateShortcut(for: id, shortcut: shortcut)

        XCTAssertEqual(manager.presets.last?.shortcut?.key, "1")
        XCTAssertEqual(manager.presets.last?.shortcut?.modifiers, [.command, .option])
    }

    func testUpdateShortcutClear() {
        bm.displays = []
        manager.saveCurrentAsPreset(name: "Shortcut Test", brightnessManager: bm)
        guard let id = manager.presets.last?.id else {
            XCTFail("Expected a preset"); return
        }

        // Set then clear
        manager.updateShortcut(for: id, shortcut: GlobalShortcut(key: "1", modifiers: [.command]))
        manager.updateShortcut(for: id, shortcut: nil)

        XCTAssertNil(manager.presets.last?.shortcut, "Shortcut should be cleared")
    }

    // MARK: - restoreDefaultPresets

    func testRestoreDefaultPresets() {
        // Add some custom presets
        bm.displays = []
        manager.saveCurrentAsPreset(name: "Custom 1", brightnessManager: bm)
        manager.saveCurrentAsPreset(name: "Custom 2", brightnessManager: bm)

        manager.restoreDefaultPresets()

        XCTAssertEqual(manager.presets.count, 3)
        XCTAssertEqual(manager.presets[0].name, "Full")
        XCTAssertEqual(manager.presets[1].name, "Evening")
        XCTAssertEqual(manager.presets[2].name, "Night")
    }

    // MARK: - defaultPresets static values

    func testDefaultPresetsValues() {
        let defaults = PresetManager.defaultPresets
        XCTAssertEqual(defaults.count, 3)

        // Full
        XCTAssertEqual(defaults[0].name, "Full")
        XCTAssertEqual(defaults[0].universalBrightness, 1.0)
        XCTAssertEqual(defaults[0].universalWarmth, 0.0)
        XCTAssertEqual(defaults[0].universalContrast, 0.5)

        // Evening
        XCTAssertEqual(defaults[1].name, "Evening")
        XCTAssertEqual(defaults[1].universalBrightness, 0.7)
        XCTAssertEqual(defaults[1].universalWarmth, 0.4)
        XCTAssertEqual(defaults[1].universalContrast, 0.5)

        // Night
        XCTAssertEqual(defaults[2].name, "Night")
        XCTAssertEqual(defaults[2].universalBrightness, 0.3)
        XCTAssertEqual(defaults[2].universalWarmth, 0.8)
        XCTAssertEqual(defaults[2].universalContrast, 0.5)
    }
}

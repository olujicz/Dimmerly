//
//  PresetManager.swift
//  Dimmerly
//
//  Manages CRUD operations for brightness presets.
//  Persists to UserDefaults as JSON.
//

import Foundation
import WidgetKit

@MainActor
class PresetManager: ObservableObject {
    static let shared = PresetManager()
    static let maxPresets = 10

    @Published var presets: [BrightnessPreset] = []

    private let persistenceKey = "dimmerlyBrightnessPresets"
    private let defaultsSeededKey = "dimmerlyDefaultPresetsSeeded"

    init() {
        loadPresets()
        seedDefaultPresetsIfNeeded()
        syncPresetsToWidget()
    }

    /// Saves the current display brightness, warmth, and contrast values as a new preset
    func saveCurrentAsPreset(name: String, brightnessManager: BrightnessManager) {
        guard presets.count < Self.maxPresets else { return }

        let brightnessSnapshot = brightnessManager.currentBrightnessSnapshot()
        let warmthSnapshot = brightnessManager.currentWarmthSnapshot()
        let contrastSnapshot = brightnessManager.currentContrastSnapshot()
        let preset = BrightnessPreset(name: name, displayBrightness: brightnessSnapshot, displayWarmth: warmthSnapshot, displayContrast: contrastSnapshot)
        presets.append(preset)
        persistPresets()
    }

    /// Applies a preset's brightness, warmth, and contrast values to currently connected displays
    func applyPreset(_ preset: BrightnessPreset, to brightnessManager: BrightnessManager) {
        if let universal = preset.universalBrightness {
            brightnessManager.setAllBrightness(to: universal)
        } else {
            brightnessManager.applyBrightnessValues(preset.displayBrightness)
        }

        // Apply warmth if present (nil = legacy preset, leave warmth unchanged)
        if let universalWarmth = preset.universalWarmth {
            brightnessManager.setAllWarmth(to: universalWarmth)
        } else if let displayWarmth = preset.displayWarmth {
            brightnessManager.applyWarmthValues(displayWarmth)
        }

        // Apply contrast if present (nil = legacy preset, leave contrast unchanged)
        if let universalContrast = preset.universalContrast {
            brightnessManager.setAllContrast(to: universalContrast)
        } else if let displayContrast = preset.displayContrast {
            brightnessManager.applyContrastValues(displayContrast)
        }
    }

    /// Updates an existing preset with the current display values
    func updatePreset(id: UUID, brightnessManager: BrightnessManager) {
        guard let index = presets.firstIndex(where: { $0.id == id }) else { return }
        presets[index].displayBrightness = brightnessManager.currentBrightnessSnapshot()
        presets[index].displayWarmth = brightnessManager.currentWarmthSnapshot()
        presets[index].displayContrast = brightnessManager.currentContrastSnapshot()
        presets[index].universalBrightness = nil
        presets[index].universalWarmth = nil
        presets[index].universalContrast = nil
        persistPresets()
    }

    /// Deletes a preset by ID
    func deletePreset(id: UUID) {
        presets.removeAll { $0.id == id }
        persistPresets()
    }

    /// Renames a preset by ID
    func renamePreset(id: UUID, to newName: String) {
        guard let index = presets.firstIndex(where: { $0.id == id }) else { return }
        presets[index].name = newName
        persistPresets()
    }

    /// Moves presets for reordering
    func movePresets(from source: IndexSet, to destination: Int) {
        presets.move(fromOffsets: source, toOffset: destination)
        persistPresets()
    }

    /// Updates the shortcut for a preset
    func updateShortcut(for presetID: UUID, shortcut: GlobalShortcut?) {
        guard let index = presets.firstIndex(where: { $0.id == presetID }) else { return }
        presets[index].shortcut = shortcut
        persistPresets()
    }

    // MARK: - Default Presets

    static let defaultPresets: [BrightnessPreset] = [
        BrightnessPreset(name: "Full", universalBrightness: 1.0, universalWarmth: 0.0, universalContrast: 0.5),
        BrightnessPreset(name: "Evening", universalBrightness: 0.7, universalWarmth: 0.4, universalContrast: 0.5),
        BrightnessPreset(name: "Night", universalBrightness: 0.3, universalWarmth: 0.8, universalContrast: 0.5),
    ]

    /// Replaces all presets with the default set
    func restoreDefaultPresets() {
        presets = Self.defaultPresets
        persistPresets()
    }

    private func seedDefaultPresetsIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: defaultsSeededKey) else { return }
        UserDefaults.standard.set(true, forKey: defaultsSeededKey)

        guard presets.isEmpty else { return }

        presets = Self.defaultPresets
        persistPresets()
    }

    // MARK: - Persistence

    private func loadPresets() {
        guard let data = UserDefaults.standard.data(forKey: persistenceKey),
              let decoded = try? JSONDecoder().decode([BrightnessPreset].self, from: data) else {
            return
        }
        presets = decoded
    }

    private func persistPresets() {
        guard let data = try? JSONEncoder().encode(presets) else { return }
        UserDefaults.standard.set(data, forKey: persistenceKey)
        syncPresetsToWidget()
    }

    // MARK: - Widget Sync

    private func syncPresetsToWidget() {
        if presets.isEmpty {
            SharedConstants.sharedDefaults?.removeObject(forKey: SharedConstants.widgetPresetsKey)
            WidgetCenter.shared.reloadAllTimelines()
            return
        }

        let widgetPresets = presets.map { WidgetPresetInfo(id: $0.id.uuidString, name: $0.name) }
        guard let data = try? JSONEncoder().encode(widgetPresets) else { return }
        SharedConstants.sharedDefaults?.set(data, forKey: SharedConstants.widgetPresetsKey)
        WidgetCenter.shared.reloadAllTimelines()
    }
}

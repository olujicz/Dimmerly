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

    /// Saves the current display brightness values as a new preset
    func saveCurrentAsPreset(name: String, brightnessManager: BrightnessManager) {
        guard presets.count < Self.maxPresets else { return }

        let snapshot = brightnessManager.currentBrightnessSnapshot()
        let preset = BrightnessPreset(name: name, displayBrightness: snapshot)
        presets.append(preset)
        persistPresets()
    }

    /// Applies a preset's brightness values to currently connected displays
    func applyPreset(_ preset: BrightnessPreset, to brightnessManager: BrightnessManager) {
        if let universal = preset.universalBrightness {
            brightnessManager.setAllBrightness(to: universal)
        } else {
            brightnessManager.applyBrightnessValues(preset.displayBrightness)
        }
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

    private func seedDefaultPresetsIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: defaultsSeededKey) else { return }
        UserDefaults.standard.set(true, forKey: defaultsSeededKey)

        guard presets.isEmpty else { return }

        presets = [
            BrightnessPreset(name: "Full", universalBrightness: 1.0),
            BrightnessPreset(name: "Half", universalBrightness: 0.5),
        ]
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
        // Avoid touching App Group UserDefaults when there are no presets to sync.
        // This prevents cfprefsd warnings on first launch before the container is populated.
        guard !presets.isEmpty else { return }
        let widgetPresets = presets.map { WidgetPresetInfo(id: $0.id.uuidString, name: $0.name) }
        guard let data = try? JSONEncoder().encode(widgetPresets) else { return }
        SharedConstants.sharedDefaults?.set(data, forKey: SharedConstants.widgetPresetsKey)
        WidgetCenter.shared.reloadAllTimelines()
    }
}

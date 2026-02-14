//
//  PresetManager.swift
//  Dimmerly
//
//  Manages brightness presets: saved display configurations that can be quickly applied.
//  Handles CRUD operations, persistence to UserDefaults, and widget synchronization.
//
//  Preset types:
//  - Per-display: Stores brightness/warmth/contrast for each display separately
//  - Universal: Single values applied to all displays (simpler, portable across setups)
//
//  Backward compatibility: Newer properties (warmth, contrast, universal values) are optional
//  to support presets created by older app versions.
//

import Foundation
import WidgetKit

/// Manages saved brightness presets and coordinates with widgets.
///
/// Design decisions:
/// - **Max 10 presets**: UI/UX limit to keep the interface manageable
/// - **Universal vs per-display**: Universal presets are simpler but less flexible
/// - **Widget sync**: Presets are copied to shared UserDefaults for widget access
/// - **Default presets**: Three presets (Full, Evening, Night) are auto-seeded on first launch
///
/// Thread safety: All methods must be called from the main actor.
@MainActor
class PresetManager: ObservableObject {
    static let shared = PresetManager()

    /// Maximum number of presets allowed. Enforced in UI and saveCurrentAsPreset().
    /// Prevents UI overflow and keeps the preset list manageable.
    static let maxPresets = 10

    /// Currently loaded presets, published for SwiftUI binding.
    /// Order is preserved for display and reordering operations.
    @Published var presets: [BrightnessPreset] = []

    /// UserDefaults key for preset persistence (JSON array)
    private let persistenceKey = "dimmerlyBrightnessPresets"

    /// UserDefaults flag to track whether default presets have been seeded
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

    /// Applies a preset's brightness, warmth, and contrast values to currently connected displays.
    ///
    /// This method handles backward compatibility:
    /// - Universal values (if present) are applied to all displays
    /// - Per-display values (if present) are applied only to matching display IDs
    /// - Nil values (legacy presets) leave that setting unchanged
    ///
    /// When `animated` is true, transitions smoothly over ~300ms using gamma table interpolation.
    /// Falls back to instant application when Reduce Motion is enabled or blanking is active.
    ///
    /// Example: A preset created on v1.0 (before warmth/contrast) will only change brightness,
    /// leaving the user's current warmth and contrast settings intact.
    ///
    /// - Parameters:
    ///   - preset: The preset to apply
    ///   - brightnessManager: The brightness manager to apply values to
    ///   - animated: Whether to animate the transition (default: false)
    func applyPreset(_ preset: BrightnessPreset, to brightnessManager: BrightnessManager, animated: Bool = false) {
        if animated && brightnessManager.animateToPreset(preset) {
            return
        }

        // Apply brightness (universal or per-display)
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

    /// Synchronizes presets to the widget extension via shared UserDefaults.
    ///
    /// Widgets run in a separate process and can't access the main app's UserDefaults.
    /// Instead, we use an App Group shared container to pass a lightweight representation
    /// of presets (ID + name only, not full brightness values).
    ///
    /// When the widget displays preset buttons:
    /// 1. Widget reads preset list from shared defaults (via SharedConstants)
    /// 2. User taps a preset button in the widget
    /// 3. Widget writes preset ID to shared defaults
    /// 4. Widget posts distributed notification to wake the main app
    /// 5. Main app reads preset ID and applies the full preset
    ///
    /// Timeline reload: Tells WidgetKit to refresh all widget displays immediately.
    private func syncPresetsToWidget() {
        if presets.isEmpty {
            // No presets: remove from shared defaults so widget hides preset buttons
            SharedConstants.sharedDefaults?.removeObject(forKey: SharedConstants.widgetPresetsKey)
            WidgetCenter.shared.reloadAllTimelines()
            return
        }

        // Convert to lightweight WidgetPresetInfo (ID + name only)
        let widgetPresets = presets.map { WidgetPresetInfo(id: $0.id.uuidString, name: $0.name) }
        guard let data = try? JSONEncoder().encode(widgetPresets) else { return }
        SharedConstants.sharedDefaults?.set(data, forKey: SharedConstants.widgetPresetsKey)
        WidgetCenter.shared.reloadAllTimelines()
    }
}

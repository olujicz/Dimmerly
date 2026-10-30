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
import Observation
import OSLog
import WidgetKit

private let presetManagerLogger = Logger(
    subsystem: "rs.in.olujic.dimmerly",
    category: "PresetManager"
)

/// Boundary between preset persistence and the widget's shared process state. Keeping this
/// dependency injectable prevents preset tests from mutating the real app-group suite or the
/// process-wide WidgetKit timeline service.
@MainActor
protocol WidgetPresetSynchronizing {
    func synchronize(_ presets: [BrightnessPreset])
}

@MainActor
struct AppGroupWidgetPresetSynchronizer: WidgetPresetSynchronizing {
    let defaults: UserDefaults?
    let reloadAllTimelines: () -> Void
    /// Control Center preset controls are not timelines, so `reloadAllTimelines` leaves them alone.
    let reloadPresetControls: () -> Void

    init(
        defaults: UserDefaults? = SharedConstants.sharedDefaults,
        reloadAllTimelines: @escaping () -> Void = { WidgetCenter.shared.reloadAllTimelines() },
        reloadPresetControls: @escaping () -> Void = { ControlCenterStatePublisher.live.refreshPresetControls() }
    ) {
        self.defaults = defaults
        self.reloadAllTimelines = reloadAllTimelines
        self.reloadPresetControls = reloadPresetControls
    }

    private func reloadWidgets() {
        reloadAllTimelines()
        reloadPresetControls()
    }

    func synchronize(_ presets: [BrightnessPreset]) {
        guard let defaults else {
            presetManagerLogger.error("Shared defaults unavailable; widget presets were not synchronized")
            reloadWidgets()
            return
        }

        if presets.isEmpty {
            defaults.removeObject(forKey: SharedConstants.widgetPresetsKey)
            reloadWidgets()
            return
        }

        let widgetPresets = presets.map { WidgetPresetInfo(id: $0.id.uuidString, name: $0.name) }
        do {
            let data = try JSONEncoder().encode(widgetPresets)
            defaults.set(data, forKey: SharedConstants.widgetPresetsKey)
            reloadWidgets()
        } catch {
            presetManagerLogger.error(
                "Failed to encode widget presets: \(error.localizedDescription, privacy: .public)"
            )
        }
    }
}

/// Loads a JSON array persisted in `UserDefaults` one element at a time, so a single element
/// this build cannot decode (corruption, or a newer build's enum case after a downgrade) does not
/// discard the rest. When anything is dropped, the original data is copied to `backupKey` before
/// the next save can replace it. An existing backup is kept: it was taken before any lossy save,
/// so it holds at least as much as the current data.
enum LossyDefaultsArray {
    private struct Element<Value: Decodable>: Decodable {
        let value: Value?

        init(from decoder: Decoder) throws {
            value = try? Value(from: decoder)
        }
    }

    static func load<Value: Decodable>(
        _: Value.Type,
        key: String,
        backupKey: String,
        defaults: UserDefaults,
        logger: Logger
    ) -> [Value] {
        guard let data = defaults.data(forKey: key) else { return [] }

        let elements: [Element<Value>]
        do {
            elements = try JSONDecoder().decode([Element<Value>].self, from: data)
        } catch {
            logger.error(
                "Stored \(key, privacy: .public) is unreadable: \(error.localizedDescription, privacy: .public)"
            )
            backUp(data, key: key, backupKey: backupKey, defaults: defaults, logger: logger)
            return []
        }

        let values = elements.compactMap(\.value)
        let failedCount = elements.count - values.count
        if failedCount > 0 {
            logger.error(
                """
                Dropped \(failedCount, privacy: .public) of \(elements.count, privacy: .public) \
                undecodable elements in \(key, privacy: .public)
                """
            )
            backUp(data, key: key, backupKey: backupKey, defaults: defaults, logger: logger)
        }
        return values
    }

    private static func backUp(
        _ data: Data,
        key: String,
        backupKey: String,
        defaults: UserDefaults,
        logger: Logger
    ) {
        guard defaults.data(forKey: backupKey) == nil else {
            logger.notice("Keeping the existing backup of \(key, privacy: .public) in \(backupKey, privacy: .public)")
            return
        }
        defaults.set(data, forKey: backupKey)
        logger.notice("Backed up the original \(key, privacy: .public) to \(backupKey, privacy: .public)")
    }
}

enum PresetShortcutError: LocalizedError, Equatable {
    case conflictsWithMainShortcut
    case conflictsWithPreset(name: String)

    var errorDescription: String? {
        switch self {
        case .conflictsWithMainShortcut:
            String(localized: "This shortcut conflicts with the main display shortcut.")
        case let .conflictsWithPreset(name):
            String(
                format: String(localized: "This shortcut conflicts with %@."),
                name
            )
        }
    }
}

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
@Observable
class PresetManager {
    static let shared = PresetManager()

    /// Maximum number of presets allowed. Enforced in UI and saveCurrentAsPreset().
    /// Prevents UI overflow and keeps the preset list manageable.
    static let maxPresets = 10

    /// Currently loaded presets, published for SwiftUI binding.
    /// Order is preserved for display and reordering operations.
    var presets: [BrightnessPreset] = []

    /// UserDefaults key for preset persistence (JSON array)
    static let persistenceKey = "dimmerlyBrightnessPresets"

    /// UserDefaults key holding the original preset data when some presets could not be decoded
    static let backupKey = "dimmerlyBrightnessPresetsBackup"

    /// UserDefaults flag to track whether default presets have been seeded
    private let defaultsSeededKey = "dimmerlyDefaultPresetsSeeded"

    /// The `UserDefaults` suite to read from and persist to. Defaults to `.standard` for
    /// production use; tests should inject an isolated suite so they don't read or overwrite
    /// the developer's real saved presets.
    private let defaults: UserDefaults

    /// Resolves the current main display shortcut at assignment time.
    private let mainShortcutProvider: () -> GlobalShortcut

    private let widgetSynchronizer: any WidgetPresetSynchronizing

    /// Reports an explicit warmth preset to the automatic warmth coordinator.
    private let notifyWarmthPresetApplied: () -> Void

    init(
        defaults: UserDefaults = .standard,
        mainShortcutProvider: @escaping () -> GlobalShortcut = { AppSettings.shared.keyboardShortcut },
        widgetSynchronizer: any WidgetPresetSynchronizing = AppGroupWidgetPresetSynchronizer(),
        notifyWarmthPresetApplied: @escaping () -> Void = { ColorTemperatureManager.shared.notifyPresetApplied() }
    ) {
        self.defaults = defaults
        self.mainShortcutProvider = mainShortcutProvider
        self.widgetSynchronizer = widgetSynchronizer
        self.notifyWarmthPresetApplied = notifyWarmthPresetApplied
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
        let preset = BrightnessPreset(
            name: name,
            displayBrightness: brightnessSnapshot,
            displayWarmth: warmthSnapshot,
            displayContrast: contrastSnapshot
        )
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
    func preset(withID id: UUID) -> BrightnessPreset? {
        presets.first { $0.id == id }
    }

    /// Applies the preset with `id`; does nothing if it has since been deleted.
    func applyPreset(id: UUID, to brightnessManager: BrightnessManager, animated: Bool = false) {
        guard let preset = preset(withID: id) else { return }
        applyPreset(preset, to: brightnessManager, animated: animated)
    }

    func applyPreset(_ preset: BrightnessPreset, to brightnessManager: BrightnessManager, animated: Bool = false) {
        // An explicit warmth target overrides auto warmth even if its value already matches.
        // Reuse the snapshot identities and legacy numeric IDs accepted by BrightnessManager.
        let hasWarmthTarget: Bool
        if preset.universalWarmth != nil {
            hasWarmthTarget = !brightnessManager.displays.isEmpty
        } else if let displayWarmth = preset.displayWarmth {
            let connectedKeys = Set(brightnessManager.currentWarmthSnapshot().keys)
                .union(brightnessManager.displays.map { String($0.id) })
            hasWarmthTarget = displayWarmth.keys.contains(where: connectedKeys.contains)
        } else {
            hasWarmthTarget = false
        }

        // Notify before animation starts because the animated path returns early.
        if hasWarmthTarget {
            notifyWarmthPresetApplied()
        }

        if animated, brightnessManager.animateToPreset(preset) {
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

    /// Deletes a preset by ID, optionally registering an undo action
    func deletePreset(id: UUID, undoManager: UndoManager? = nil) {
        guard let index = presets.firstIndex(where: { $0.id == id }) else { return }
        let deleted = presets[index]
        presets.remove(at: index)
        persistPresets()

        undoManager?.registerUndo(withTarget: self) { manager in
            MainActor.assumeIsolated {
                manager.presets.insert(deleted, at: min(index, manager.presets.count))
                manager.persistPresets()
            }
        }
        undoManager?.setActionName(
            String(
                format: NSLocalizedString("Delete %@", comment: "Undo action: delete preset"),
                deleted.name
            )
        )
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

    /// The conflict that assigning `shortcut` would cause, shared by the preset and main shortcut
    /// editors. For a preset (`presetID` set) that includes the main display shortcut; any other
    /// preset already using `shortcut` conflicts either way.
    func shortcutConflict(for shortcut: GlobalShortcut, assigningTo presetID: UUID?) -> PresetShortcutError? {
        if presetID != nil, shortcut == mainShortcutProvider() {
            return .conflictsWithMainShortcut
        }
        if let conflictingPreset = presets.first(where: { $0.id != presetID && $0.shortcut == shortcut }) {
            return .conflictsWithPreset(name: conflictingPreset.name)
        }
        return nil
    }

    /// Updates the shortcut for a preset after enforcing global uniqueness.
    func updateShortcut(for presetID: UUID, shortcut: GlobalShortcut?) throws {
        guard let index = presets.firstIndex(where: { $0.id == presetID }) else { return }
        if let shortcut, let conflict = shortcutConflict(for: shortcut, assigningTo: presetID) {
            throw conflict
        }
        presets[index].shortcut = shortcut
        persistPresets()
    }

    // MARK: - Default Presets

    static let defaultPresets: [BrightnessPreset] = [
        BrightnessPreset(
            name: String(localized: "Full", comment: "Default preset name — maximum brightness"),
            universalBrightness: 1.0, universalWarmth: 0.0, universalContrast: 0.5
        ),
        BrightnessPreset(
            name: String(localized: "Evening", comment: "Default preset name — moderate dimming"),
            universalBrightness: 0.7, universalWarmth: 0.4, universalContrast: 0.5
        ),
        BrightnessPreset(
            name: String(localized: "Night", comment: "Default preset name — strong dimming"),
            universalBrightness: 0.3, universalWarmth: 0.8, universalContrast: 0.5
        ),
    ]

    /// Replaces all presets with the default set, optionally registering an undo action
    func restoreDefaultPresets(undoManager: UndoManager? = nil) {
        let previousPresets = presets
        presets = Self.defaultPresets
        persistPresets()

        undoManager?.registerUndo(withTarget: self) { manager in
            MainActor.assumeIsolated {
                manager.presets = previousPresets
                manager.persistPresets()
            }
        }
        undoManager?.setActionName(
            NSLocalizedString("Restore Defaults", comment: "Undo action: restore default presets")
        )
    }

    private func seedDefaultPresetsIfNeeded() {
        guard !defaults.bool(forKey: defaultsSeededKey) else { return }
        defaults.set(true, forKey: defaultsSeededKey)

        guard presets.isEmpty else { return }

        presets = Self.defaultPresets
        persistPresets()
    }

    // MARK: - Persistence

    private func loadPresets() {
        presets = LossyDefaultsArray.load(
            BrightnessPreset.self,
            key: Self.persistenceKey,
            backupKey: Self.backupKey,
            defaults: defaults,
            logger: presetManagerLogger
        )
    }

    private func persistPresets() {
        do {
            let data = try JSONEncoder().encode(presets)
            defaults.set(data, forKey: Self.persistenceKey)
            syncPresetsToWidget()
        } catch {
            presetManagerLogger.error(
                "Failed to encode brightness presets: \(error.localizedDescription, privacy: .public)"
            )
        }
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
        widgetSynchronizer.synchronize(presets)
    }
}

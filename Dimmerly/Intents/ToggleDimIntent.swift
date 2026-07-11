//
//  ToggleDimIntent.swift
//  Dimmerly
//
//  App Intent to toggle display dimming (blank/unblank) for a specific display.
//

import AppIntents
import CoreGraphics

struct ToggleDimIntent: AppIntent {
    static let title: LocalizedStringResource = "Toggle Display Dimming"
    static let description: IntentDescription = .init("Blanks or unblanks a specific display.")

    @Parameter(title: "Display")
    var display: DisplayEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let displayID = CGDirectDisplayID(display.id) else {
            throw DisplayIntentError.invalidDisplay
        }
        BrightnessManager.shared.toggleBlank(for: displayID)
        return .result()
    }
}

struct ApplyPresetIntent: AppIntent {
    static let title: LocalizedStringResource = "Apply Brightness Preset"
    static let description: IntentDescription = .init("Applies a saved brightness preset to connected displays.")

    @Parameter(title: "Preset")
    var preset: PresetEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        let presetManager = PresetManager.shared
        let brightnessManager = BrightnessManager.shared

        guard let uuid = UUID(uuidString: preset.id),
              let resolvedPreset = presetManager.presets.first(where: { $0.id == uuid })
        else {
            throw IntentError.presetNotFound
        }

        presetManager.applyPreset(resolvedPreset, to: brightnessManager, animated: true)
        return .result()
    }

    enum IntentError: Swift.Error, CustomLocalizedStringResourceConvertible {
        case presetNotFound

        var localizedStringResource: LocalizedStringResource {
            switch self {
            case .presetNotFound: "That preset no longer exists."
            }
        }
    }
}

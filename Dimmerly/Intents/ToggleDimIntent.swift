//
//  ToggleDimIntent.swift
//  Dimmerly
//
//  App Intent to toggle display dimming (blank/unblank) for a specific display.
//

import AppIntents
import CoreGraphics

@available(macOS 14.0, *)
struct ToggleDimIntent: AppIntent {
    static let title: LocalizedStringResource = "Toggle Display Dimming"
    static let description: IntentDescription = IntentDescription("Blanks or unblanks a specific display.")

    @Parameter(title: "Display")
    var display: DisplayEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let displayID = CGDirectDisplayID(display.id) else {
            throw IntentError.invalidDisplay
        }
        BrightnessManager.shared.toggleBlank(for: displayID)
        return .result()
    }

    enum IntentError: Swift.Error, CustomLocalizedStringResourceConvertible {
        case invalidDisplay

        var localizedStringResource: LocalizedStringResource {
            switch self {
            case .invalidDisplay: return "The selected display is no longer connected."
            }
        }
    }
}

@available(macOS 14.0, *)
struct ApplyPresetIntent: AppIntent {
    static let title: LocalizedStringResource = "Apply Brightness Preset"
    static let description: IntentDescription = IntentDescription("Applies a saved brightness preset to connected displays.")

    @Parameter(title: "Preset Name")
    var presetName: String

    @MainActor
    func perform() async throws -> some IntentResult {
        let presetManager = PresetManager.shared
        let brightnessManager = BrightnessManager.shared

        guard let preset = presetManager.presets.first(where: { $0.name == presetName }) else {
            throw IntentError.presetNotFound
        }

        presetManager.applyPreset(preset, to: brightnessManager)
        return .result()
    }

    enum IntentError: Swift.Error, CustomLocalizedStringResourceConvertible {
        case presetNotFound

        var localizedStringResource: LocalizedStringResource {
            switch self {
            case .presetNotFound: return "No preset found with that name."
            }
        }
    }
}

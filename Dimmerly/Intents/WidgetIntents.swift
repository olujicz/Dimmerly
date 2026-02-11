//
//  WidgetIntents.swift
//  Dimmerly
//
//  AppIntents for widget buttons. Uses openAppWhenRun to execute
//  in the main app process (widget extensions cannot call gamma APIs).
//

import AppIntents

@available(macOS 14.0, *)
struct DimDisplaysWidgetIntent: AppIntent {
    static let title: LocalizedStringResource = "Dim Displays (Widget)"
    static let description: IntentDescription = "Dims all connected displays."
    static let openAppWhenRun: Bool = true
    static let isDiscoverable: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION
        DisplayAction.performSleep(settings: AppSettings.shared)
        #endif
        return .result()
    }
}

@available(macOS 14.0, *)
struct ApplyPresetWidgetIntent: AppIntent {
    static let title: LocalizedStringResource = "Apply Preset (Widget)"
    static let description: IntentDescription = "Applies a saved brightness preset."
    static let openAppWhenRun: Bool = true
    static let isDiscoverable: Bool = false

    @Parameter(title: "Preset ID")
    var presetID: String

    init() {}

    init(presetID: String) {
        self.presetID = presetID
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION
        guard let uuid = UUID(uuidString: presetID) else { return .result() }
        let presetManager = PresetManager.shared
        let brightnessManager = BrightnessManager.shared
        guard let preset = presetManager.presets.first(where: { $0.id == uuid }) else {
            return .result()
        }
        presetManager.applyPreset(preset, to: brightnessManager)
        #endif
        return .result()
    }
}

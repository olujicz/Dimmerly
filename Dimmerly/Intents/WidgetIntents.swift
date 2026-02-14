//
//  WidgetIntents.swift
//  Dimmerly
//
//  AppIntents for widget buttons. Uses DistributedNotificationCenter
//  for cross-process communication since widget extensions cannot
//  call gamma APIs directly.
//

import AppIntents

struct DimDisplaysWidgetIntent: AppIntent {
    static let title: LocalizedStringResource = "Dim Displays (Widget)"
    static let description: IntentDescription = "Dims all connected displays."
    static let openAppWhenRun: Bool = true
    static let isDiscoverable: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult {
        #if WIDGET_EXTENSION
            DistributedNotificationCenter.default().postNotificationName(
                SharedConstants.dimNotification, object: nil, userInfo: nil, deliverImmediately: true
            )
        #else
            DisplayAction.performSleep(settings: AppSettings.shared)
        #endif
        return .result()
    }
}

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
        #if WIDGET_EXTENSION
            SharedConstants.sharedDefaults?.set(presetID, forKey: SharedConstants.widgetPresetCommandKey)
            SharedConstants.sharedDefaults?.synchronize()
            DistributedNotificationCenter.default().postNotificationName(
                SharedConstants.presetNotification, object: nil, userInfo: nil, deliverImmediately: true
            )
        #else
            guard let uuid = UUID(uuidString: presetID) else { return .result() }
            let presetManager = PresetManager.shared
            let brightnessManager = BrightnessManager.shared
            guard let preset = presetManager.presets.first(where: { $0.id == uuid }) else {
                return .result()
            }
            presetManager.applyPreset(preset, to: brightnessManager, animated: true)
        #endif
        return .result()
    }
}

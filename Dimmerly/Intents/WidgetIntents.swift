//
//  WidgetIntents.swift
//  Dimmerly
//
//  AppIntents for widget buttons. Uses DistributedNotificationCenter
//  for cross-process communication since widget extensions cannot
//  call gamma APIs directly.
//

import AppIntents

#if compiler(>=6.4)
    enum WidgetIntentExecutionPolicy: Equatable {
        case mainApp
        case widgetKitExtension

        #if WIDGET_EXTENSION
            static let current: Self = .widgetKitExtension
        #else
            static let current: Self = .mainApp
        #endif

        @available(macOS 27.0, *)
        var intentExecutionTargets: IntentExecutionTargets {
            switch self {
            case .mainApp:
                .main
            case .widgetKitExtension:
                .widgetKitExtension
            }
        }
    }
#endif

struct DimDisplaysWidgetIntent: AppIntent {
    static let title: LocalizedStringResource = "Dim Displays (Widget)"
    static let description: IntentDescription = "Dims all connected displays."
    static let isDiscoverable: Bool = false

    /// Keep the legacy behavior for macOS 15–25. macOS 26 and later prefer
    /// supportedModes, while older systems continue to use openAppWhenRun.
    @available(macOS, deprecated: 26.0, message: "Use supportedModes on macOS 26 and later")
    static let openAppWhenRun: Bool = true

    @available(macOS 26.0, *)
    static let supportedModes: IntentModes = .foreground(.immediate)

    #if compiler(>=6.4)
        #if WIDGET_EXTENSION
            @available(macOS 27.0, *)
            static let allowedExecutionTargets: IntentExecutionTargets = .widgetKitExtension
        #else
            @available(macOS 27.0, *)
            static let allowedExecutionTargets: IntentExecutionTargets = .main
        #endif
    #endif

    @MainActor
    func perform() async throws -> some IntentResult {
        #if WIDGET_EXTENSION
            SharedConstants.storeWidgetDimCommand()
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
    static let isDiscoverable: Bool = false

    /// Keep the legacy behavior for macOS 15–25. macOS 26 and later prefer
    /// supportedModes, while older systems continue to use openAppWhenRun.
    @available(macOS, deprecated: 26.0, message: "Use supportedModes on macOS 26 and later")
    static let openAppWhenRun: Bool = true

    @available(macOS 26.0, *)
    static let supportedModes: IntentModes = .foreground(.immediate)

    #if compiler(>=6.4)
        #if WIDGET_EXTENSION
            @available(macOS 27.0, *)
            static let allowedExecutionTargets: IntentExecutionTargets = .widgetKitExtension
        #else
            @available(macOS 27.0, *)
            static let allowedExecutionTargets: IntentExecutionTargets = .main
        #endif
    #endif

    @Parameter(title: "Preset ID")
    var presetID: String

    init() {}

    init(presetID: String) {
        self.presetID = presetID
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        #if WIDGET_EXTENSION
            SharedConstants.storeWidgetPresetCommand(presetID)
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

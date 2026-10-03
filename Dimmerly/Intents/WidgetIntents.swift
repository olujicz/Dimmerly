//
//  WidgetIntents.swift
//  Dimmerly
//
//  Widget and Control Center actions execute in the main app, which owns
//  the display APIs and the observable settings.
//

import AppIntents
import AppKit

/// Extensions launch the containing app and wait for its acknowledgement. The app owns
/// the display APIs; foreground intent modes alone do not route Control Center actions there.
@MainActor
enum WidgetActionExecution {
    enum Failure: LocalizedError {
        case unavailable
        case didNotComplete

        var errorDescription: String? {
            switch self {
            case .unavailable:
                String(localized: "Dimmerly could not open to control your displays.")
            case .didNotComplete:
                String(localized: "Dimmerly did not complete the display action. Try again.")
            }
        }
    }

    static func perform(
        _ command: WidgetActionCommand,
        defaults: UserDefaults? = SharedConstants.sharedDefaults,
        launchApp: () async throws -> Void = launchContainingApp,
        signalApp: (UUID) -> Void = { id in
            DistributedNotificationCenter.default().postNotificationName(
                SharedConstants.widgetActionNotification,
                object: id.uuidString,
                userInfo: nil,
                deliverImmediately: true
            )
        },
        now: () -> Date = Date.init,
        wait: () async throws -> Void = { try await Task.sleep(for: .milliseconds(100)) }
    ) async throws {
        guard let defaults else { throw Failure.unavailable }
        // LaunchServices completion doesn't guarantee the app's observers are ready yet.
        try await launchApp()
        try Task.checkCancellation()
        let request = WidgetActionRequest(command: command, expiresAt: now().addingTimeInterval(5))
        try SharedConstants.storeWidgetActionRequest(request, in: defaults)
        defer { SharedConstants.removeWidgetActionRequest(request.id, from: defaults) }

        while now() < request.expiresAt {
            try Task.checkCancellation()
            signalApp(request.id)
            if SharedConstants.widgetActionWasAcknowledged(request.id, in: defaults) {
                return
            }
            try await wait()
        }
        // The action may have completed during the final wait as its deadline passed.
        try Task.checkCancellation()
        if SharedConstants.widgetActionWasAcknowledged(request.id, in: defaults) {
            return
        }
        throw Failure.didNotComplete
    }

    private static func launchContainingApp() async throws {
        var appURL = Bundle.main.bundleURL
        while appURL.pathExtension != "app", appURL.path != "/" {
            appURL.deleteLastPathComponent()
        }
        guard appURL.pathExtension == "app" else { throw Failure.unavailable }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        _ = try await NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
    }
}

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
        @available(macOS 27.0, *)
        static let allowedExecutionTargets: IntentExecutionTargets = .main
    #endif

    @MainActor
    func perform() async throws -> some IntentResult {
        #if WIDGET_EXTENSION
            try await WidgetActionExecution.perform(.dimDisplays)
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
        @available(macOS 27.0, *)
        static let allowedExecutionTargets: IntentExecutionTargets = .main
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
            try await WidgetActionExecution.perform(.applyPreset(presetID))
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

/// Backs the Control Center dim toggle. `value` is the state the user switched the toggle to.
///
/// "Dimmed" means Dimmerly is blanking at least one display (`ScreenBlanker.isBlankingAnyDisplay`).
/// See `DisplayAction.setDimmed(_:settings:)` for what each direction does.
struct SetDimmingWidgetIntent: SetValueIntent {
    static let title: LocalizedStringResource = "Dim Displays (Control)"
    static let description: IntentDescription = "Dims all connected displays, or wakes the displays Dimmerly dimmed."
    static let isDiscoverable: Bool = false

    /// Keep the legacy behavior for macOS 15–25. macOS 26 and later prefer
    /// supportedModes, while older systems continue to use openAppWhenRun.
    @available(macOS, deprecated: 26.0, message: "Use supportedModes on macOS 26 and later")
    static let openAppWhenRun: Bool = true

    @available(macOS 26.0, *)
    static let supportedModes: IntentModes = .foreground(.immediate)

    #if compiler(>=6.4)
        @available(macOS 27.0, *)
        static let allowedExecutionTargets: IntentExecutionTargets = .main
    #endif

    @Parameter(title: "Dimmed")
    var value: Bool

    init() {}

    init(value: Bool) {
        self.value = value
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        #if WIDGET_EXTENSION
            try await WidgetActionExecution.perform(.setDimming(value))
        #else
            handleWidgetDimStateCommand(settings: AppSettings.shared, consumeCommand: { value })
        #endif
        return .result()
    }
}

/// Backs the Control Center Auto Warmth toggle. `value` is the state the user switched it to.
struct SetAutoWarmthWidgetIntent: SetValueIntent {
    static let title: LocalizedStringResource = "Auto Warmth (Control)"
    static let description: IntentDescription = "Turns automatic display warmth on or off."
    static let isDiscoverable: Bool = false

    /// Keep the legacy behavior for macOS 15–25. macOS 26 and later prefer
    /// supportedModes, while older systems continue to use openAppWhenRun.
    @available(macOS, deprecated: 26.0, message: "Use supportedModes on macOS 26 and later")
    static let openAppWhenRun: Bool = true

    @available(macOS 26.0, *)
    static let supportedModes: IntentModes = .foreground(.immediate)

    #if compiler(>=6.4)
        @available(macOS 27.0, *)
        static let allowedExecutionTargets: IntentExecutionTargets = .main
    #endif

    @Parameter(title: "Enabled")
    var value: Bool

    init() {}

    init(value: Bool) {
        self.value = value
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        #if WIDGET_EXTENSION
            try await WidgetActionExecution.perform(.setAutoWarmth(value))
        #else
            handleWidgetAutoWarmthCommand(settings: AppSettings.shared, consumeCommand: { value })
        #endif
        return .result()
    }
}

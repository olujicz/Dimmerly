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
        /// The app no longer has the preset the widget or control asked for.
        case presetUnavailable

        var errorDescription: String? {
            switch self {
            case .unavailable:
                String(localized: "Dimmerly could not open to control your displays.")
            case .didNotComplete:
                String(localized: "Dimmerly did not complete the display action. Try again.")
            case .presetUnavailable:
                String(
                    localized: "Dimmerly could not find this preset. It may have been deleted.",
                    comment: "Error shown when a widget or control applies a preset that no longer exists"
                )
            }
        }
    }

    /// The error to report when the app answered that it could not perform `command`.
    /// Applying a preset is the one command that can find nothing to act on.
    static func failure(for command: WidgetActionCommand) -> Failure {
        switch command {
        case .applyPreset:
            .presetUnavailable
        case .dimDisplays, .setDimming, .setAutoWarmth:
            .didNotComplete
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
            if try appAnswered(request, in: defaults) {
                return
            }
            try await wait()
        }
        // The action may have completed during the final wait as its deadline passed.
        try Task.checkCancellation()
        if try appAnswered(request, in: defaults) {
            return
        }
        throw Failure.didNotComplete
    }

    /// True once the app reported success; throws when it reported that it could not do it.
    private static func appAnswered(_ request: WidgetActionRequest, in defaults: UserDefaults) throws -> Bool {
        switch SharedConstants.widgetActionOutcome(request.id, in: defaults) {
        case .succeeded:
            true
        case .failed:
            throw failure(for: request.command)
        case nil:
            false
        }
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
            try WidgetActionCommand.dimDisplays.performForIntent()
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
            try WidgetActionCommand.applyPreset(presetID).performForIntent()
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
            try WidgetActionCommand.setDimming(value).performForIntent()
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
            try WidgetActionCommand.setAutoWarmth(value).performForIntent()
        #endif
        return .result()
    }
}

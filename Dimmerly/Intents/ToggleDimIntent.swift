//
//  ToggleDimIntent.swift
//  Dimmerly
//
//  App Intent to toggle display dimming (blank/unblank) for a specific display.
//

import AppIntents
import AppKit
import CoreGraphics

@MainActor
private func resolvePresetEntity(
    _ entity: PresetEntity,
    in presetManager: PresetManager
) throws -> (id: UUID, preset: BrightnessPreset) {
    guard let uuid = UUID(uuidString: entity.id),
          let resolvedPreset = presetManager.presets.first(where: { $0.id == uuid })
    else {
        throw ApplyPresetIntent.IntentError.presetNotFound
    }

    return (uuid, resolvedPreset)
}

@MainActor
private func applyPresetEntity(_ entity: PresetEntity) throws {
    let presetManager = PresetManager.shared
    let brightnessManager = BrightnessManager.shared

    let resolved = try resolvePresetEntity(entity, in: presetManager)

    presetManager.applyPreset(resolved.preset, to: brightnessManager, animated: true)
}

struct ToggleDimIntent: AppIntent {
    static let title: LocalizedStringResource = "Toggle Display Dimming"
    static let description: IntentDescription = .init("Blanks or unblanks a specific display.")

    #if compiler(>=6.4)
        @available(macOS 27.0, *)
        static let allowedExecutionTargets: IntentExecutionTargets = .main
    #endif

    static var parameterSummary: some ParameterSummary {
        Summary("Toggle dimming for \(\.$display)")
    }

    @Parameter(
        title: "Display",
        requestValueDialog: "Which display should I control?",
        requestDisambiguationDialog: "Which display do you want to control?"
    )
    var display: DisplayEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        try perform(using: LiveDisplayIntentCommand.shared)
        return .result()
    }

    @MainActor
    func perform(using command: DisplayIntentCommanding) throws {
        let displayID = try ConnectedDisplayResolver.resolve(display) {
            command.connectedDisplayDescriptors
        }
        command.toggleDim(for: displayID)
    }
}

struct ApplyPresetIntent: AppIntent {
    static let title: LocalizedStringResource = "Apply Brightness Preset"
    static let description: IntentDescription = .init("Applies a saved brightness preset to connected displays.")

    #if compiler(>=6.4)
        @available(macOS 27.0, *)
        static let allowedExecutionTargets: IntentExecutionTargets = .main
    #endif

    static var parameterSummary: some ParameterSummary {
        Summary("Apply the \(\.$preset) brightness preset")
    }

    @Parameter(
        title: "Preset",
        requestValueDialog: "Which preset should I apply?",
        requestDisambiguationDialog: "Which preset do you want to apply?"
    )
    var preset: PresetEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        try applyPresetEntity(preset)
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

struct OpenPresetIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open Brightness Preset"
    static let description: IntentDescription = .init("Opens a saved brightness preset in Dimmerly.")

    #if compiler(>=6.4)
        @available(macOS 27.0, *)
        static let allowedExecutionTargets: IntentExecutionTargets = .main
    #endif

    static var parameterSummary: some ParameterSummary {
        Summary("Open the \(\.$target) brightness preset")
    }

    @Parameter(
        title: "Preset",
        requestValueDialog: "Which preset should I open?",
        requestDisambiguationDialog: "Which preset do you want to open?"
    )
    var target: PresetEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        try perform(
            using: PresetManager.shared,
            coordinator: MenuBarPanelCoordinator.shared,
            activateApp: { NSApp.activate(ignoringOtherApps: true) }
        )
        return .result()
    }

    @MainActor
    func perform(
        using presetManager: PresetManager,
        coordinator: MenuBarPanelCoordinator,
        activateApp: @escaping @MainActor () -> Void,
        presentationPath: MenuBarPanelPresentationPath = .current
    ) throws {
        let resolved = try resolvePresetEntity(target, in: presetManager)
        coordinator.openPreset(
            id: resolved.id,
            presentationPath: presentationPath,
            activateApp: activateApp
        )
    }
}

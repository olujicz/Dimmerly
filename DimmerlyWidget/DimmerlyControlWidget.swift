//
//  DimmerlyControlWidget.swift
//  DimmerlyWidget
//
//  Control Center and menu bar controls: a dim button, dim and Auto Warmth toggles,
//  and a configurable preset button.
//

import AppIntents
import SwiftUI
import WidgetKit

// Gate the controls behind the compiler version that introduced
// ControlWidgetConfiguration so older toolchains can still build the widget
// extension. The matching SDK availability check remains on the declarations.
#if compiler(>=6.2)
    @available(macOS 26.0, *)
    struct DimmerlyControlWidget: ControlWidget {
        var body: some ControlWidgetConfiguration {
            StaticControlConfiguration(kind: SharedConstants.dimControlKind) {
                ControlWidgetButton(action: DimDisplaysWidgetIntent()) {
                    Label("Dim Displays", systemImage: "moon.fill")
                }
            }
            .displayName("Dim Displays")
            .description("Quickly dim all connected displays.")
        }
    }

    // MARK: - Dim toggle

    /// Reads whether the running app is blanking any display, as it last published.
    @available(macOS 26.0, *)
    struct DimStateValueProvider: ControlValueProvider {
        var previewValue: Bool {
            false
        }

        func currentValue() async throws -> Bool {
            SharedConstants.publishedDimState()
        }
    }

    /// On while Dimmerly is blanking a display. Turning it on dims the displays the same way the
    /// Dim Displays button does, and turning it off wakes every display Dimmerly blanked.
    @available(macOS 26.0, *)
    struct DimmerlyDimToggleControl: ControlWidget {
        var body: some ControlWidgetConfiguration {
            StaticControlConfiguration(
                kind: SharedConstants.dimToggleControlKind,
                provider: DimStateValueProvider()
            ) { isDimmed in
                ControlWidgetToggle(isOn: isDimmed, action: SetDimmingWidgetIntent()) {
                    Label("Display Dimming", systemImage: isDimmed ? "moon.fill" : "moon")
                }
                .tint(.indigo)
            }
            .displayName("Display Dimming")
            .description("Shows whether Dimmerly is dimming a display, and dims or wakes your displays.")
        }
    }

    // MARK: - Auto Warmth toggle

    /// Reads whether Auto Warmth is on, as the app last published it.
    @available(macOS 26.0, *)
    struct AutoWarmthValueProvider: ControlValueProvider {
        var previewValue: Bool {
            false
        }

        func currentValue() async throws -> Bool {
            SharedConstants.publishedAutoWarmthState()
        }
    }

    @available(macOS 26.0, *)
    struct DimmerlyAutoWarmthControl: ControlWidget {
        var body: some ControlWidgetConfiguration {
            StaticControlConfiguration(
                kind: SharedConstants.autoWarmthControlKind,
                provider: AutoWarmthValueProvider()
            ) { isEnabled in
                ControlWidgetToggle(isOn: isEnabled, action: SetAutoWarmthWidgetIntent()) {
                    Label("Auto Warmth", systemImage: isEnabled ? "sun.horizon.fill" : "sun.horizon")
                }
                .tint(.orange)
            }
            .displayName("Auto Warmth")
            .description("Turns automatic display warmth on or off.")
        }
    }

    // MARK: - Preset button

    /// A saved preset as the widget extension sees it, read from the list the app shares through
    /// the app group. The app's `PresetEntity` cannot be used here: its query reads
    /// `PresetManager`, which only exists in the app process.
    @available(macOS 26.0, *)
    struct ControlPresetEntity: AppEntity {
        static var typeDisplayRepresentation: TypeDisplayRepresentation {
            TypeDisplayRepresentation(name: "Preset")
        }

        static let defaultQuery = ControlPresetQuery()

        var id: String
        var name: String

        init(_ preset: WidgetPresetInfo) {
            id = preset.id
            name = preset.name
        }

        var displayRepresentation: DisplayRepresentation {
            DisplayRepresentation(title: "\(name)")
        }
    }

    @available(macOS 26.0, *)
    struct ControlPresetQuery: EntityQuery {
        func entities(for identifiers: [String]) async throws -> [ControlPresetEntity] {
            let presets = SharedConstants.widgetPresets()
            return identifiers.compactMap { id in
                presets.first { $0.id == id }.map(ControlPresetEntity.init)
            }
        }

        func suggestedEntities() async throws -> [ControlPresetEntity] {
            SharedConstants.widgetPresets().map(ControlPresetEntity.init)
        }
    }

    @available(macOS 26.0, *)
    struct SelectPresetControlIntent: ControlConfigurationIntent {
        static let title: LocalizedStringResource = "Choose Preset"
        static let description: IntentDescription = "Choose the brightness preset this control applies."
        static let isDiscoverable: Bool = false

        @Parameter(title: "Preset")
        var preset: ControlPresetEntity?
    }

    /// Resolves the chosen preset against the current shared list, so a renamed preset shows its
    /// new name and a deleted one reads as unconfigured.
    @available(macOS 26.0, *)
    struct PresetControlValueProvider: AppIntentControlValueProvider {
        func previewValue(configuration: SelectPresetControlIntent) -> WidgetPresetInfo? {
            configuration.preset.map { WidgetPresetInfo(id: $0.id, name: $0.name) }
        }

        func currentValue(configuration: SelectPresetControlIntent) async throws -> WidgetPresetInfo? {
            SharedConstants.widgetPreset(withID: configuration.preset?.id)
        }
    }

    @available(macOS 26.0, *)
    struct DimmerlyPresetControl: ControlWidget {
        var body: some ControlWidgetConfiguration {
            AppIntentControlConfiguration(
                kind: SharedConstants.presetControlKind,
                provider: PresetControlValueProvider()
            ) { preset in
                // With no preset chosen, or the chosen one deleted, the button asks to be configured
                // and its empty preset ID makes the app ignore a tap.
                ControlWidgetButton(action: ApplyPresetWidgetIntent(presetID: preset?.id ?? "")) {
                    Label {
                        if let preset {
                            Text(preset.name)
                        } else {
                            Text("Choose Preset")
                        }
                    } icon: {
                        Image(systemName: "sun.max")
                    }
                }
            }
            .displayName("Apply Preset")
            .description("Applies a brightness preset you choose.")
            .promptsForUserConfiguration()
        }
    }
#endif

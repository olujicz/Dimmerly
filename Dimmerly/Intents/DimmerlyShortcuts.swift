//
//  DimmerlyShortcuts.swift
//  Dimmerly
//
//  AppShortcutsProvider for Shortcuts.app discoverability.
//

import AppIntents

@available(macOS 14.0, *)
struct DimmerlyShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SleepDisplaysIntent(),
            phrases: [
                "Sleep displays with \(.applicationName)",
                "Dim displays with \(.applicationName)",
                "Turn off displays with \(.applicationName)",
            ],
            shortTitle: "Sleep Displays",
            systemImageName: "moon.fill"
        )
        AppShortcut(
            intent: SetDisplayBrightnessIntent(),
            phrases: [
                "Set display brightness with \(.applicationName)",
                "Change brightness with \(.applicationName)",
            ],
            shortTitle: "Set Brightness",
            systemImageName: "sun.max"
        )
        AppShortcut(
            intent: ToggleDimIntent(),
            phrases: [
                "Toggle display dimming with \(.applicationName)",
            ],
            shortTitle: "Toggle Dimming",
            systemImageName: "moon.haze"
        )
        AppShortcut(
            intent: ApplyPresetIntent(),
            phrases: [
                "Apply brightness preset with \(.applicationName)",
            ],
            shortTitle: "Apply Preset",
            systemImageName: "slider.horizontal.3"
        )
    }
}

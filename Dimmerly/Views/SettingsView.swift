//
//  SettingsView.swift
//  Dimmerly
//
//  Settings window for configuring app preferences.
//

import AppKit
import SwiftUI

/// Promotes the Settings window only after SwiftUI has attached its content to an
/// `NSWindow`. Activating from the button action can run before the Settings scene
/// creates its window on first launch, leaving it ordered behind the current app.
final class SettingsWindowPresentationView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        guard let window else { return }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }
}

private struct SettingsWindowPresentationConfigurator: NSViewRepresentable {
    func makeNSView(context _: Context) -> NSView {
        SettingsWindowPresentationView()
    }

    func updateNSView(_: NSView, context _: Context) {}
}

private extension View {
    func settingsWindowPresentation() -> some View {
        background(SettingsWindowPresentationConfigurator())
    }
}

struct LaunchAtLoginAlertContent: Equatable {
    let title: String
    let message: String
}

@MainActor
func applyLaunchAtLoginChange(
    requestedValue: Bool,
    settings: AppSettings,
    result: Result<Void, LaunchAtLoginError>
) -> LaunchAtLoginAlertContent? {
    settings.launchAtLogin = requestedValue

    switch result {
    case .success:
        return nil
    case let .failure(error):
        settings.launchAtLogin = !requestedValue
        return LaunchAtLoginAlertContent(
            title: NSLocalizedString(
                "Launch at Login Unavailable",
                comment: "Settings alert title when launch at login registration fails"
            ),
            message: error.localizedDescription
        )
    }
}

#if !APPSTORE
    @MainActor
    func isDDCControlModeAvailable(
        _ mode: DDCControlMode,
        hardwareManager: HardwareBrightnessManager
    ) -> Bool {
        switch mode {
        case .softwareOnly:
            true
        case .hardware:
            hardwareManager.isEnabled
                && hardwareManager.capabilities.values.contains { $0.supportsDDC && $0.supportsBrightness }
        }
    }

    func ddcFeatureLabels(for cap: HardwareDisplayCapability) -> String {
        var labels: [String] = []
        if cap.supportsBrightness {
            labels.append("Brightness")
        }
        if cap.supportsContrast {
            labels.append("Contrast")
        }
        if cap.supportsVolume {
            labels.append("Volume")
        }
        if cap.supportsInputSource {
            labels.append("Input")
        }
        return labels.joined(separator: ", ")
    }

    func ddcDisplayStatusSymbolName(for cap: HardwareDisplayCapability) -> String {
        if cap.supportsDDC, cap.supportsBrightness {
            return "checkmark.circle.fill"
        }
        if cap.supportsDDC {
            return "exclamationmark.circle"
        }
        return "tv.and.mediabox"
    }

    func ddcDisplayStatusText(for cap: HardwareDisplayCapability) -> String {
        guard cap.supportsDDC else {
            return String(localized: "Uses software brightness", comment: "DDC display status: software fallback")
        }

        let features = ddcFeatureLabels(for: cap)
        guard cap.supportsBrightness else {
            return features.isEmpty
                ? String(localized: "Hardware brightness unavailable", comment: "DDC display status: no brightness")
                : String(
                    format: String(
                        localized: "Hardware brightness unavailable · %@",
                        comment: "DDC display status: no brightness but other features"
                    ),
                    features
                )
        }

        return features.isEmpty
            ? String(localized: "Hardware controls available", comment: "DDC display status: hardware available")
            : String(
                format: String(
                    localized: "Hardware controls: %@",
                    comment: "DDC display status: supported hardware features"
                ),
                features
            )
    }

    func ddcDisplayAccessibilityStatus(for cap: HardwareDisplayCapability) -> String {
        guard cap.supportsDDC else {
            return String(localized: "uses software brightness", comment: "DDC accessibility status: software fallback")
        }

        let features = ddcFeatureLabels(for: cap)
        guard cap.supportsBrightness else {
            return features.isEmpty
                ? String(
                    localized: "hardware brightness unavailable",
                    comment: "DDC accessibility status: no brightness"
                )
                : String(
                    format: String(
                        localized: "hardware brightness unavailable, %@",
                        comment: "DDC accessibility status: no brightness but other features"
                    ),
                    features
                )
        }

        return features.isEmpty
            ? String(localized: "hardware controls available", comment: "DDC accessibility status: available")
            : String(
                format: String(
                    localized: "hardware controls available, %@",
                    comment: "DDC accessibility status: available features"
                ),
                features
            )
    }

    @MainActor
    func applyDDCRuntimeSettings(
        settings: AppSettings,
        hardwareManager: HardwareBrightnessManager
    ) {
        hardwareManager.applyRuntimeSettings(
            controlMode: settings.ddcControlMode,
            pollingInterval: settings.ddcPollingInterval,
            writeDelayMilliseconds: settings.ddcWriteDelay
        )
    }

    @MainActor
    func applyDDCEnabledChange(
        _ newValue: Bool,
        settings: AppSettings,
        hardwareManager: HardwareBrightnessManager,
        brightnessManager: BrightnessManager = .shared
    ) async {
        settings.ddcEnabled = newValue

        if newValue {
            hardwareManager.enable()
            applyDDCRuntimeSettings(settings: settings, hardwareManager: hardwareManager)
            hardwareManager.probeAllDisplays()
            hardwareManager.startPolling()
        } else {
            await hardwareManager.disable()
            brightnessManager.reapplyAll()
        }
    }
#endif

/// Main settings view for the application.
/// Uses a TabView to organize settings into logical groups following macOS HIG.
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsTab()
                .tabItem { Label("General", systemImage: "gear") }

            DisplaySettingsTab()
                .tabItem { Label("Displays", systemImage: "display") }

            ScheduleSettingsTab()
                .tabItem { Label("Schedule", systemImage: "calendar.badge.clock") }

            ShortcutsSettingsTab()
                .tabItem { Label("Shortcuts", systemImage: "keyboard") }

            AboutSettingsTab()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(minWidth: 480, maxWidth: 580, minHeight: 480, idealHeight: 520)
        .settingsWindowPresentation()
    }
}

// MARK: - Preview

#Preview {
    SettingsView()
        .environment(AppSettings())
        .environment(KeyboardShortcutManager())
        .environment(PresetShortcutManager())
        .environment(PresetManager())
        .environment(BrightnessManager())
        .environment(ScheduleManager())
        .environment(LocationProvider.shared)
        .environment(ColorTemperatureManager.shared)
    #if !APPSTORE
        .environment(HardwareBrightnessManager(forTesting: true))
    #endif
}

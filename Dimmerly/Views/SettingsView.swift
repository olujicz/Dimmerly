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

    /// Gives every pane the same width and a height that follows its content, up to a cap
    /// past which the form scrolls. The window then changes height as you switch tabs, like
    /// other Mac settings windows, and can't be resized by dragging.
    func settingsPaneFrame() -> some View {
        frame(width: SettingsView.paneWidth)
            .frame(maxHeight: SettingsView.maxPaneHeight)
            .fixedSize(horizontal: false, vertical: true)
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
        hardwareManager: HardwareBrightnessManager,
        supportsNativeBacklight: Bool = false
    ) -> Bool {
        switch mode {
        case .softwareOnly:
            true
        case .hardware:
            hardwareManager.isEnabled
                && (supportsNativeBacklight
                    || hardwareManager.capabilities.values.contains { $0.supportsDDC && $0.supportsBrightness })
        }
    }

    func ddcFeatureLabels(for cap: HardwareDisplayCapability) -> String {
        var labels: [String] = []
        if cap.supportsBrightness {
            labels.append(String(localized: "Brightness", comment: "DDC feature name in a display status list"))
        }
        if cap.supportsContrast {
            labels.append(String(localized: "Contrast", comment: "DDC feature name in a display status list"))
        }
        if cap.supportsVolume {
            labels.append(String(localized: "Volume", comment: "DDC feature name in a display status list"))
        }
        if cap.supportsInputSource {
            labels.append(String(localized: "Input", comment: "DDC feature name in a display status list"))
        }
        return labels.formatted(.list(type: .and))
    }

    func ddcDisplayStatusSymbolName(for cap: HardwareDisplayCapability) -> String {
        if cap.supportsDDC, cap.supportsBrightness {
            return "checkmark.circle.fill"
        }
        if cap.supportsDDC {
            return "exclamationmark.circle"
        }
        return cap.transportReachable ? "powerplug" : "tv.and.mediabox"
    }

    func ddcDisplayStatusText(for cap: HardwareDisplayCapability) -> String {
        guard cap.supportsDDC else {
            if cap.transportReachable {
                return String(
                    localized: "No DDC/CI reply. Unplug the monitor from power for a minute.",
                    comment: "DDC display status: monitor reached but its DDC/CI controller never answered"
                )
            }
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
            if cap.transportReachable {
                return String(
                    localized: "no DDC/CI reply, unplug the monitor from power for a minute",
                    comment: "DDC accessibility status: monitor reached but its DDC/CI controller never answered"
                )
            }
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
            writeDelayMilliseconds: settings.ddcWriteDelay,
            experimentalNativeBrightnessEnabled: settings.experimentalNativeBrightnessEnabled
        )
    }

    @MainActor
    func applyExperimentalNativeBrightnessChange(
        _ newValue: Bool,
        settings: AppSettings,
        hardwareManager: HardwareBrightnessManager,
        brightnessManager: BrightnessManager = .shared
    ) {
        settings.experimentalNativeBrightnessEnabled = newValue
        applyDDCRuntimeSettings(settings: settings, hardwareManager: hardwareManager)
        brightnessManager.refreshDisplays()

        if settings.ddcEnabled {
            hardwareManager.probeAllDisplays(force: true)
            hardwareManager.startPolling()
        }
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
            brightnessManager.refreshDisplays()
            hardwareManager.probeAllDisplays()
            hardwareManager.startPolling()
        } else {
            await hardwareManager.disable()
            brightnessManager.refreshDisplays()
        }
    }
#endif

/// Main settings view for the application.
/// Uses a TabView to organize settings into logical groups following macOS HIG.
struct SettingsView: View {
    static let paneWidth: CGFloat = 520
    static let maxPaneHeight: CGFloat = 600

    var body: some View {
        TabView {
            GeneralSettingsTab()
                .settingsPaneFrame()
                .tabItem { Label("General", systemImage: "gearshape") }

            DisplaySettingsTab()
                .settingsPaneFrame()
                .tabItem { Label("Displays", systemImage: "display") }

            ScheduleSettingsTab()
                .settingsPaneFrame()
                .tabItem { Label("Schedule", systemImage: "calendar.badge.clock") }

            ShortcutsSettingsTab()
                .settingsPaneFrame()
                .tabItem { Label("Shortcuts", systemImage: "keyboard") }

            AboutSettingsTab()
                .settingsPaneFrame()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .settingsWindowPresentation()
    }
}

/// A button that leaves Dimmerly for a web page or System Settings, marked with an
/// arrow so it reads as a link out of the app.
struct ExternalLinkButton: View {
    let title: Text
    let help: Text
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 2) {
                title
                Image(systemName: "arrow.up.forward")
                    .imageScale(.small)
            }
        }
        .help(help)
    }
}

extension ExternalLinkButton {
    init(_ title: Text, url: URL?, help: Text) {
        self.init(title: title, help: help) {
            guard let url else { return }
            NSWorkspace.shared.open(url)
        }
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

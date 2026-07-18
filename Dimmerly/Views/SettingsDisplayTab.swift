//
//  SettingsDisplayTab.swift
//  Dimmerly
//

import AppKit
import SwiftUI

// MARK: - Displays Tab

/// Display-related settings: dimming mode, idle timer, color temperature, hardware control
struct DisplaySettingsTab: View {
    @Environment(AppSettings.self) var settings
    @Environment(BrightnessManager.self) var brightnessManager
    @Environment(ColorTemperatureManager.self) var colorTempManager
    #if !APPSTORE
        @Environment(HardwareBrightnessManager.self) var hardwareManager
    #endif
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Form {
            dimmingSection

            idleTimerSection

            colorTemperatureSection

            #if !APPSTORE
                hardwareControlSection
            #endif
        }
        .formStyle(.grouped)
    }

    // MARK: - Dimming

    private var dimmingSection: some View {
        @Bindable var settings = settings
        return Section {
            #if APPSTORE
                Text("Dims screens without putting displays to sleep. Your session stays unlocked.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            #else
                Picker("Turn Displays Off:", selection: Binding(
                    get: { settings.preventScreenLock ? 1 : 0 },
                    set: { settings.preventScreenLock = $0 == 1 }
                )) {
                    Text("Sleep & Lock").tag(0)
                    Text("Dim Only").tag(1)
                }
                .pickerStyle(.radioGroup)
                .help("Choose between sleeping displays or dimming them")

                if !settings.preventScreenLock {
                    Text(
                        "Turns off all displays and locks your Mac, just like closing the lid."
                            + " To control how quickly your password is required,"
                            + " adjust your Lock Screen settings."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    Button {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.Lock-Screen-Settings.extension") {
                            NSWorkspace.shared.open(url)
                        }
                    } label: {
                        HStack(spacing: 2) {
                            Text("Open Lock Screen Settings")
                            Image(systemName: "arrow.up.forward")
                                .imageScale(.small)
                        }
                    }
                    .font(.caption)
                    .help("Open macOS Lock Screen settings")
                } else {
                    Text("Dims screens without putting displays to sleep. Your session stays unlocked.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            #endif

            #if APPSTORE
                let showDimOptions = true
            #else
                let showDimOptions = settings.preventScreenLock
            #endif

            if showDimOptions {
                Toggle("Fade transition", isOn: $settings.fadeTransition)
                    .help(Text("Gradually dims displays instead of turning them off instantly"))

                Picker("Wake Displays:", selection: $settings.requireEscapeToDismiss) {
                    Text("Any input").tag(false)
                    Text("Escape key only").tag(true)
                }
                .pickerStyle(.radioGroup)
                .help("Choose how to wake displays after dimming")

                #if APPSTORE
                    Text(
                        "Dimmerly captures standard keyboard and pointer input while its overlays are active. "
                            + "macOS system shortcuts and media keys may still be handled by the system."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                #endif

                if !settings.requireEscapeToDismiss {
                    Toggle("Ignore mouse movement", isOn: $settings.ignoreMouseMovement)
                        .help(Text("Only wake the screen on keyboard input or mouse click, not mouse movement"))
                }
            }
        } header: {
            Label("Dimming", systemImage: "moon.fill")
        }
    }

    // MARK: - Idle Timer

    private var idleTimerSection: some View {
        @Bindable var settings = settings
        return Section {
            Toggle("Auto-dim after inactivity", isOn: $settings.idleTimerEnabled)
                .help("Automatically dim displays after a period of inactivity")
                .accessibilityValue(settings.idleTimerEnabled ? "\(settings.idleTimerMinutes) minutes" : "Off")

            if settings.idleTimerEnabled {
                Stepper(value: $settings.idleTimerMinutes, in: 1 ... 60) {
                    Text(
                        settings.idleTimerMinutes == 1
                            ? String(
                                localized: "1 minute",
                                comment: "Idle timer stepper label: singular"
                            )
                            : String(
                                format: NSLocalizedString(
                                    "%d minutes",
                                    comment: "Idle timer stepper label: number of minutes"
                                ),
                                settings.idleTimerMinutes
                            )
                    )
                }

                Text(
                    settings.idleTimerMinutes == 1
                        ? String(
                            localized: "Displays will dim automatically after 1 minute of inactivity.",
                            comment: "Idle timer description: singular"
                        )
                        : String(
                            format: NSLocalizedString(
                                "Displays will dim automatically after %d minutes of inactivity.",
                                comment: "Idle timer description"
                            ),
                            settings.idleTimerMinutes
                        )
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        } header: {
            Label("Idle Timer", systemImage: "timer")
        }
    }

    // MARK: - Color Temperature

    private var colorTemperatureSection: some View {
        @Bindable var settings = settings
        return Section {
            Toggle("Automatic color temperature", isOn: $settings.autoColorTempEnabled)
                .help("Adjust warmth automatically based on sunrise and sunset")
                .accessibilityValue(
                    settings.autoColorTempEnabled
                        ? "\(settings.dayTemperature)K day, \(settings.nightTemperature)K night"
                        : "Off"
                )

            if settings.autoColorTempEnabled {
                LocationPickerRow()

                LabeledContent("Day:") {
                    HStack(spacing: 4) {
                        Text("Warm")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .frame(width: 34, alignment: .trailing)
                            .accessibilityHidden(true)
                        Slider(
                            value: Binding(
                                get: { Double(settings.dayTemperature) },
                                set: { settings.dayTemperature = Int($0) }
                            ),
                            in: 2700 ... 6500,
                            step: 100
                        )
                        .accessibilityLabel("Day color temperature")
                        .accessibilityValue("\(settings.dayTemperature) Kelvin")
                        Text("Cool")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        Text("\(settings.dayTemperature)K")
                            .monospacedDigit()
                            .frame(width: 50, alignment: .trailing)
                            .accessibilityHidden(true)
                    }
                }

                LabeledContent("Night:") {
                    HStack(spacing: 4) {
                        Text("Warm")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .frame(width: 34, alignment: .trailing)
                            .accessibilityHidden(true)
                        Slider(
                            value: Binding(
                                get: { Double(settings.nightTemperature) },
                                set: { settings.nightTemperature = Int($0) }
                            ),
                            in: 1900 ... 4500,
                            step: 100
                        )
                        .accessibilityLabel("Night color temperature")
                        .accessibilityValue("\(settings.nightTemperature) Kelvin")
                        Text("Cool")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        Text("\(settings.nightTemperature)K")
                            .monospacedDigit()
                            .frame(width: 50, alignment: .trailing)
                            .accessibilityHidden(true)
                    }
                }

                Stepper(value: $settings.colorTempTransitionMinutes, in: 10 ... 120, step: 10) {
                    Text(
                        String(
                            format: NSLocalizedString(
                                "Transition: %d minutes",
                                comment: "Color temperature transition duration stepper label"
                            ),
                            settings.colorTempTransitionMinutes
                        )
                    )
                }

                Text("Adjusts gradually during sunrise and sunset.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Label("Color Temperature", systemImage: "thermometer.sun")
        }
    }

    // MARK: - Hardware Control (DDC/CI)

    #if !APPSTORE
        private var hardwareControlSection: some View {
            @Bindable var settings = settings
            return Section {
                Toggle("Use hardware controls when available", isOn: Binding(
                    get: { settings.ddcEnabled },
                    set: { newValue in
                        Task {
                            await applyDDCEnabledChange(
                                newValue,
                                settings: settings,
                                hardwareManager: hardwareManager
                            )
                        }
                    }
                ))
                .help("Uses DDC/CI to control compatible external displays directly. "
                    + "Unsupported displays continue using software brightness.")

                if settings.ddcEnabled {
                    let hardwareControlModesAvailable = isDDCControlModeAvailable(
                        .hardware,
                        hardwareManager: hardwareManager
                    )

                    if hardwareControlModesAvailable {
                        Picker("Brightness control:", selection: Binding(
                            get: { settings.ddcControlMode },
                            set: { settings.ddcControlMode = $0 }
                        )) {
                            ForEach(DDCControlMode.allCases) { mode in
                                Text(mode.displayName)
                                    .tag(mode)
                            }
                        }
                        .pickerStyle(.radioGroup)
                        .help("Choose how Dimmerly controls display brightness")
                        .onChange(of: settings.ddcControlMode) {
                            applyDDCRuntimeSettings(settings: settings, hardwareManager: hardwareManager)
                            brightnessManager.reapplyAll()
                        }

                        Text(settings.ddcControlMode.description)
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        DisclosureGroup("Advanced") {
                            ddcAdvancedStepperRow(
                                String(
                                    format: NSLocalizedString(
                                        "Poll every %d seconds",
                                        comment: "DDC polling interval stepper label"
                                    ),
                                    settings.ddcPollingInterval
                                )
                            ) {
                                Stepper("", value: $settings.ddcPollingInterval, in: 1 ... 30)
                                    .labelsHidden()
                                    .controlSize(.small)
                                    .accessibilityLabel("DDC polling interval")
                                    .accessibilityValue("\(settings.ddcPollingInterval) seconds")
                                    .help("How often to read hardware values from the monitor")
                                    .onChange(of: settings.ddcPollingInterval) {
                                        applyDDCRuntimeSettings(settings: settings, hardwareManager: hardwareManager)
                                        if settings.ddcEnabled {
                                            hardwareManager.startPolling()
                                        }
                                    }
                            }

                            ddcAdvancedStepperRow(
                                String(
                                    format: NSLocalizedString(
                                        "Write delay: %d ms",
                                        comment: "DDC write delay stepper label"
                                    ),
                                    settings.ddcWriteDelay
                                )
                            ) {
                                Stepper("", value: $settings.ddcWriteDelay, in: 20 ... 200, step: 10)
                                    .labelsHidden()
                                    .controlSize(.small)
                                    .accessibilityLabel("DDC write delay")
                                    .accessibilityValue("\(settings.ddcWriteDelay) milliseconds")
                                    .help("Minimum delay between DDC writes (increase if monitor is unresponsive)")
                                    .onChange(of: settings.ddcWriteDelay) {
                                        applyDDCRuntimeSettings(settings: settings, hardwareManager: hardwareManager)
                                    }
                            }
                        }
                    } else {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Hardware controls aren’t available")
                                    .fontWeight(.medium)

                                Text(
                                    "None of your connected displays supports direct hardware control. "
                                        + "Dimmerly is using software brightness and will switch automatically "
                                        + "when a compatible display is connected."
                                )
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        }
                        .padding(10)
                        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                        .accessibilityElement(children: .combine)
                    }

                    // Per-display DDC status
                    if !hardwareManager.capabilities.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Display compatibility")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            ForEach(Array(hardwareManager.capabilities.keys.sorted()), id: \.self) { displayID in
                                if let cap = hardwareManager.capabilities[displayID] {
                                    ddcDisplayStatusRow(displayID: displayID, capability: cap)
                                }
                            }
                        }
                    }
                }
            } header: {
                Label("Hardware Control", systemImage: "cable.connector.horizontal")
            }
        }

        private func ddcAdvancedStepperRow(
            _ label: String,
            @ViewBuilder control: () -> some View
        ) -> some View {
            HStack(alignment: .center, spacing: 8) {
                Text(label)
                    .lineLimit(1)
                    .layoutPriority(1)

                control()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }

        private func ddcDisplayStatusRow(
            displayID: CGDirectDisplayID,
            capability: HardwareDisplayCapability
        ) -> some View {
            let displayName = brightnessManager.displays.first(where: { $0.id == displayID })?.name
                ?? "Display \(displayID)"
            let statusText = ddcDisplayStatusText(for: capability)
            let supportsHardwareBrightness = capability.supportsDDC && capability.supportsBrightness

            return HStack(spacing: 6) {
                Image(systemName: ddcDisplayStatusSymbolName(for: capability))
                    .foregroundStyle(supportsHardwareBrightness ? Color.green : Color.secondary)
                    .font(.caption)

                Text(displayName)
                    .font(.caption)

                Spacer()

                Text(statusText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
                "\(displayName), \(ddcDisplayAccessibilityStatus(for: capability))"
            )
        }
    #endif
}

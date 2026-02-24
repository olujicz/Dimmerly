//
//  MenuBarPanel.swift
//  Dimmerly
//
//  Window-style MenuBarExtra content with per-display brightness sliders.
//

import SwiftUI

struct MenuBarPanel: View {
    @Environment(BrightnessManager.self) var brightnessManager
    @Environment(AppSettings.self) var settings
    @Environment(PresetManager.self) var presetManager
    @Environment(ColorTemperatureManager.self) var colorTempManager
    #if !APPSTORE
        @Environment(HardwareBrightnessManager.self) var hardwareManager
    #endif
    @Environment(\.openSettings) private var openSettings
    @AppStorage("showDisplayAdjustments") private var showAdjustments = false

    var body: some View {
        VStack(spacing: 0) {
            if brightnessManager.displays.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        displaySliders

                        Divider()
                        presetsSection
                            .padding(.horizontal, 20)
                            .padding(.vertical, 8)
                    }
                }
                .frame(maxHeight: 400)
            }

            Divider()

            turnOffButton
                .padding(.horizontal, 20)
                .padding(.vertical, 8)

            Divider()

            footer
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
        }
        .frame(width: 280)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "display")
                .font(.title)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("No External Displays")
                .font(.headline)
            Text("Connect an external display to adjust its brightness.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(20)
    }

    // MARK: - Sliders

    private var displaySliders: some View {
        VStack(spacing: 0) {
            ForEach(brightnessManager.displays) { display in
                if display.id != brightnessManager.displays.first?.id {
                    Divider()
                        .padding(.vertical, 8)
                }
                DisplayBrightnessRow(
                    display: display,
                    isBlanked: ScreenBlanker.shared.isDisplayBlanked(display.id),
                    showAdjustments: showAdjustments,
                    isAutoColorTemp: colorTempManager.isActive,
                    onChange: { newValue in
                        brightnessManager.setBrightness(for: display.id, to: newValue)
                    },
                    onWarmthChange: { newValue in
                        brightnessManager.setWarmth(for: display.id, to: newValue)
                    },
                    onContrastChange: { newValue in
                        brightnessManager.setContrast(for: display.id, to: newValue)
                    },
                    onToggleBlank: {
                        brightnessManager.toggleBlank(for: display.id)
                    }
                )
                #if !APPSTORE
                .ddcControls(
                        hardwareManager: hardwareManager,
                        displayID: display.id
                    )
                #endif
            }

            displayAdjustmentsDisclosure

            if showAdjustments {
                autoWarmthToggle
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(20)
    }

    private var displayAdjustmentsDisclosure: some View {
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                showAdjustments.toggle()
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .rotationEffect(.degrees(showAdjustments ? 90 : 0))
                Text("Display Adjustments")
                    .font(.callout)
                Spacer()
            }
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .padding(.top, 8)
        .accessibilityLabel(Text(showAdjustments ? "Hide display adjustments" : "Show display adjustments"))
        .help("Show warmth and contrast sliders")
    }

    // MARK: - Auto Warmth Toggle

    private var autoWarmthToggle: some View {
        @Bindable var settings = settings
        return VStack(spacing: 2) {
            HStack {
                Image(systemName: "sun.horizon")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .frame(width: 14)
                Text("Auto Warmth")
                    .font(.callout)
                Spacer()
                Toggle("", isOn: $settings.autoColorTempEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
            }

            if settings.autoColorTempEnabled {
                HStack {
                    autoWarmthStatusText
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.leading, 20)
            }
        }
        .padding(.top, 6)
    }

    @ViewBuilder
    private var autoWarmthStatusText: some View {
        if !LocationProvider.shared.hasLocation {
            Text("Set location in Settings")
        } else if let desc = colorTempManager.nextTransitionDescription() {
            Text("\(Int(colorTempManager.currentKelvin))K · \(desc)")
        } else {
            Text("\(Int(colorTempManager.currentKelvin))K")
        }
    }

    // MARK: - Presets

    private var presetsSection: some View {
        PresetsSectionView()
            .environment(presetManager)
            .environment(brightnessManager)
    }

    // MARK: - Turn Off Button

    private var turnOffButton: some View {
        Button {
            DisplayAction.performSleep(settings: settings)
        } label: {
            HStack {
                #if APPSTORE
                    Image(systemName: "sun.min.fill")
                    Text("Dim Displays")
                #else
                    Image(systemName: settings.preventScreenLock ? "sun.min.fill" : "moon.fill")
                    Text(settings.preventScreenLock ? "Dim Displays" : "Turn Displays Off")
                #endif
                Spacer()
                Text("↩")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .keyboardShortcut(.return, modifiers: [])
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 0) {
            Button {
                openSettings()
                NSApp.activate()
            } label: {
                FooterLabel("Settings", icon: "gear", shortcut: "⌘,")
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(",", modifiers: .command)
            .help("Open Dimmerly settings")

            Spacer()

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                FooterLabel("Quit", icon: "power", shortcut: "⌘Q")
            }
            .buttonStyle(.borderless)
            .keyboardShortcut("q", modifiers: .command)
            .help("Quit Dimmerly")
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }
}

// MARK: - Presets Section

private struct PresetsSectionView: View {
    @Environment(PresetManager.self) var presetManager
    @Environment(BrightnessManager.self) var brightnessManager
    @State private var isAddingPreset = false
    @State private var newPresetName = ""
    @State private var hoveredPresetID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Presets")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.bottom, 2)

            ForEach(Array(presetManager.presets.enumerated()), id: \.element.id) { index, preset in
                presetRow(preset, index: index)
            }

            if isAddingPreset {
                HStack(spacing: 4) {
                    TextField("Preset name", text: $newPresetName)
                        .textFieldStyle(.roundedBorder)
                        .font(.callout)
                        .onSubmit { savePreset() }
                        .onExitCommand { cancelAddPreset() }
                    Button {
                        cancelAddPreset()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(Text("Cancel"))
                    .help("Cancel adding preset")
                }
                .padding(.top, 2)
            } else if presetManager.presets.count < PresetManager.maxPresets {
                Button {
                    isAddingPreset = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus")
                        Text("Save Current")
                    }
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 3)
                    .padding(.horizontal, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Save current display settings as a preset")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Presets"))
    }

    private func presetRow(_ preset: BrightnessPreset, index: Int) -> some View {
        Button {
            presetManager.applyPreset(preset, to: brightnessManager, animated: true)
        } label: {
            HStack {
                Text(preset.name)
                    .font(.callout)
                    .lineLimit(1)
                Spacer()
                if let shortcut = preset.shortcut {
                    Text(shortcut.displayString)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else {
                    Text("\u{2318}\((index + 1) % 10)")
                        .font(.caption)
                        .foregroundStyle(.quaternary)
                }
            }
            .padding(.vertical, 3)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(hoveredPresetID == preset.id ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear))
            )
            .animation(.spring(response: 0.2, dampingFraction: 0.8), value: hoveredPresetID)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .keyboardShortcut(KeyEquivalent(Character("\((index + 1) % 10)")), modifiers: .command)
        .onHover { isHovered in
            hoveredPresetID = isHovered ? preset.id : nil
        }
        .accessibilityLabel(Text("Apply \(preset.name)"))
        .help(preset.name)
        .contextMenu {
            Button("Save Current Settings") {
                presetManager.updatePreset(id: preset.id, brightnessManager: brightnessManager)
            }
            Divider()
            Button("Delete", role: .destructive) {
                presetManager.deletePreset(id: preset.id)
            }
        }
    }

    private func savePreset() {
        let name = newPresetName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        presetManager.saveCurrentAsPreset(name: name, brightnessManager: brightnessManager)
        cancelAddPreset()
    }

    private func cancelAddPreset() {
        newPresetName = ""
        isAddingPreset = false
    }
}

// MARK: - Footer Label

private struct FooterLabel: View {
    let title: LocalizedStringKey
    let icon: String
    let shortcut: String?

    @State private var isHovered = false

    init(_ title: LocalizedStringKey, icon: String, shortcut: String? = nil) {
        self.title = title
        self.icon = icon
        self.shortcut = shortcut
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption)
            Text(title)
            if let shortcut {
                Text(shortcut)
                    .foregroundStyle(.tertiary)
                    .font(.caption)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isHovered ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear))
        )
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .animation(.spring(response: 0.2, dampingFraction: 0.8), value: isHovered)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Display Brightness Row

struct DisplayBrightnessRow: View {
    let display: ExternalDisplay
    let isBlanked: Bool
    let showAdjustments: Bool
    let isAutoColorTemp: Bool
    let onChange: (Double) -> Void
    let onWarmthChange: (Double) -> Void
    let onContrastChange: (Double) -> Void
    let onToggleBlank: () -> Void

    #if !APPSTORE
        /// Hardware volume change callback (nil if DDC not supported)
        var onVolumeChange: ((Double) -> Void)?
        /// Hardware mute toggle callback (nil if DDC not supported)
        var onMuteToggle: (() -> Void)?
        /// Input source change callback (nil if display doesn't support input switching)
        var onInputSourceChange: ((InputSource) -> Void)?
        /// Current hardware volume (0.0–1.0)
        var hardwareVolume: Double?
        /// Current mute state
        var isMuted: Bool = false
        /// Currently active input source (nil if unknown or unsupported)
        var activeInputSource: InputSource?
        /// Available input sources for this display (empty if unsupported)
        var availableInputSources: [InputSource] = []
        /// Whether this display supports DDC
        var hasDDC: Bool = false
    #endif

    @State private var sliderValue: Double
    @State private var warmthValue: Double
    @State private var contrastValue: Double
    #if !APPSTORE
        @State private var volumeValue: Double
    #endif

    init(
        display: ExternalDisplay,
        isBlanked: Bool,
        showAdjustments: Bool,
        isAutoColorTemp: Bool = false,
        onChange: @escaping (Double) -> Void,
        onWarmthChange: @escaping (Double) -> Void,
        onContrastChange: @escaping (Double) -> Void,
        onToggleBlank: @escaping () -> Void
    ) {
        self.display = display
        self.isBlanked = isBlanked
        self.showAdjustments = showAdjustments
        self.isAutoColorTemp = isAutoColorTemp
        self.onChange = onChange
        self.onWarmthChange = onWarmthChange
        self.onContrastChange = onContrastChange
        self.onToggleBlank = onToggleBlank
        _sliderValue = State(initialValue: display.brightness)
        _warmthValue = State(initialValue: display.warmth)
        _contrastValue = State(initialValue: display.contrast)
        #if !APPSTORE
            _volumeValue = State(initialValue: hardwareVolume ?? 0.5)
        #endif
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(display.name)
                    .font(.callout)
                    .lineLimit(1)

                #if !APPSTORE
                    if hasDDC {
                        Text("DDC")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.background)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(.blue.opacity(0.7)))
                            .help("Hardware control via DDC/CI")
                    }
                #endif

                Spacer()
                Text("\(Int(sliderValue * 100))%")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .accessibilityHidden(true)

                Button {
                    onToggleBlank()
                } label: {
                    Image(systemName: isBlanked ? "moon.fill" : "moon")
                        .font(.callout)
                        .foregroundStyle(isBlanked ? .primary : .secondary)
                }
                .buttonStyle(.borderless)
                .help(isBlanked ? Text("Restore display") : Text("Dim display"))
                .accessibilityLabel(isBlanked ? Text("Restore display") : Text("Dim display"))
            }

            HStack(spacing: 6) {
                Image(systemName: "sun.min")
                    .font(.caption2)
                    .frame(width: 12)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)

                Slider(
                    value: $sliderValue,
                    in: BrightnessManager.minimumBrightness ... 1
                )
                .accessibilityLabel(
                    String(
                        format: NSLocalizedString(
                            "%@ brightness",
                            comment: "Accessibility label: display brightness slider"
                        ),
                        display.name
                    )
                )
                .accessibilityValue(
                    String(
                        format: NSLocalizedString(
                            "%d percent",
                            comment: "Accessibility value: brightness percentage"
                        ),
                        Int(sliderValue * 100)
                    )
                )
                .onChange(of: sliderValue) {
                    onChange(sliderValue)
                }

                Image(systemName: "sun.max")
                    .font(.caption2)
                    .frame(width: 12)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .opacity(isBlanked ? 0.4 : 1.0)
            .disabled(isBlanked)

            if showAdjustments {
                VStack(spacing: 2) {
                    HStack(spacing: 6) {
                        Image(systemName: "thermometer.snowflake")
                            .font(.caption2)
                            .frame(width: 12)
                            .foregroundStyle(.blue)
                            .accessibilityHidden(true)

                        Slider(value: $warmthValue, in: 0 ... 1)
                            .tint(.orange)
                            .accessibilityLabel(
                                String(
                                    format: NSLocalizedString(
                                        "%@ warmth",
                                        comment: "Accessibility label: display warmth slider"
                                    ),
                                    display.name
                                )
                            )
                            .accessibilityValue(
                                String(
                                    format: NSLocalizedString(
                                        "%dK",
                                        comment: "Accessibility value: warmth in Kelvin"
                                    ),
                                    Int(BrightnessManager.kelvinForWarmth(warmthValue))
                                )
                            )
                            .onChange(of: warmthValue) {
                                onWarmthChange(warmthValue)
                            }

                        Image(systemName: "thermometer.sun")
                            .font(.caption2)
                            .frame(width: 12)
                            .foregroundStyle(.orange)
                            .accessibilityHidden(true)
                    }

                    HStack {
                        Text("\(Int(BrightnessManager.kelvinForWarmth(warmthValue)))K")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()

                        if isAutoColorTemp {
                            Text("Auto")
                                .font(.caption2)
                                .foregroundStyle(.background)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(.orange.opacity(0.7)))
                                .accessibilityHidden(true)
                        }

                        Spacer()
                    }
                    .padding(.leading, 18)
                }
                .opacity(isBlanked ? 0.4 : 1.0)
                .disabled(isBlanked)
                .transition(.opacity.combined(with: .move(edge: .top)))
                .animation(.spring(response: 0.3, dampingFraction: 0.8), value: showAdjustments)

                HStack(spacing: 6) {
                    Image(systemName: "circle.lefthalf.filled")
                        .font(.system(size: 9))
                        .frame(width: 12)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)

                    Slider(value: $contrastValue, in: 0 ... 1)
                        .accessibilityLabel(
                            String(
                                format: NSLocalizedString(
                                    "%@ contrast",
                                    comment: "Accessibility label: display contrast slider"
                                ),
                                display.name
                            )
                        )
                        .accessibilityValue(
                            String(
                                format: NSLocalizedString(
                                    "%d percent",
                                    comment: "Accessibility value: contrast percentage"
                                ),
                                Int(contrastValue * 100)
                            )
                        )
                        .onChange(of: contrastValue) {
                            onContrastChange(contrastValue)
                        }

                    Image(systemName: "circle.righthalf.filled")
                        .font(.system(size: 9))
                        .frame(width: 12)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                .opacity(isBlanked ? 0.4 : 1.0)
                .disabled(isBlanked)
                .transition(.opacity.combined(with: .move(edge: .top)))

                #if !APPSTORE

                    // MARK: Volume Slider + Mute (DDC only)

                    if hasDDC, onVolumeChange != nil {
                        HStack(spacing: 6) {
                            Button {
                                onMuteToggle?()
                            } label: {
                                Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2")
                                    .font(.caption2)
                                    .frame(width: 12)
                                    .foregroundStyle(isMuted ? .red : .secondary)
                            }
                            .buttonStyle(.borderless)
                            .help(isMuted ? "Unmute" : "Mute")
                            .accessibilityLabel(isMuted ? Text("Unmute") : Text("Mute"))

                            Slider(value: $volumeValue, in: 0 ... 1)
                                .accessibilityLabel(
                                    String(
                                        format: NSLocalizedString(
                                            "%@ volume",
                                            comment: "Accessibility label: display volume slider"
                                        ),
                                        display.name
                                    )
                                )
                                .accessibilityValue(
                                    String(
                                        format: NSLocalizedString(
                                            "%d percent",
                                            comment: "Accessibility value: volume percentage"
                                        ),
                                        Int(volumeValue * 100)
                                    )
                                )
                                .onChange(of: volumeValue) {
                                    onVolumeChange?(volumeValue)
                                }

                            Image(systemName: "speaker.wave.3")
                                .font(.caption2)
                                .frame(width: 12)
                                .foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                        }
                        .opacity(isBlanked ? 0.4 : 1.0)
                        .disabled(isBlanked)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }

                    // MARK: Input Source Picker (DDC only)

                    if hasDDC, !availableInputSources.isEmpty, onInputSourceChange != nil {
                        HStack(spacing: 6) {
                            Image(systemName: "rectangle.on.rectangle.angled")
                                .font(.caption2)
                                .frame(width: 12)
                                .foregroundStyle(.secondary)
                                .accessibilityHidden(true)

                            // Use a Menu-based picker for compact presentation.
                            // Picker with .menu style provides a native dropdown
                            // without taking up extra vertical space.
                            Menu {
                                // Group common modern inputs first for quick access
                                ForEach(availableInputSources, id: \.self) { source in
                                    Button {
                                        onInputSourceChange?(source)
                                    } label: {
                                        if source == activeInputSource {
                                            Label(source.displayName, systemImage: "checkmark")
                                        } else {
                                            Text(source.displayName)
                                        }
                                    }
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    Text(activeInputSource?.displayName ?? "Unknown")
                                        .font(.callout)
                                        .lineLimit(1)
                                    Image(systemName: "chevron.up.chevron.down")
                                        .font(.system(size: 8))
                                        .foregroundStyle(.tertiary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .menuStyle(.borderlessButton)
                            .accessibilityLabel(
                                String(
                                    format: NSLocalizedString(
                                        "%@ input source",
                                        comment: "Accessibility label: display input source picker"
                                    ),
                                    display.name
                                )
                            )
                            .accessibilityValue(activeInputSource?.displayName ?? "No input source detected")
                        }
                        .opacity(isBlanked ? 0.4 : 1.0)
                        .disabled(isBlanked)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                        // Warn that switching away from the current input may lose the display.
                        // This is inherent to DDC input switching — the monitor will switch
                        // to the new source, and if the Mac isn't connected on that port,
                        // the display will show "No Signal" until switched back (either via
                        // the monitor's OSD or by reconnecting to this app on the active input).
                        .help(
                            "Switch monitor input source. Switching away from the Mac's "
                                + "input will cause this display to show \"No Signal\" "
                                + "until switched back."
                        )
                    }
                #endif
            }
        }
        .onChange(of: display.brightness) {
            sliderValue = display.brightness
        }
        .onChange(of: display.warmth) {
            warmthValue = display.warmth
        }
        .onChange(of: display.contrast) {
            contrastValue = display.contrast
        }
        #if !APPSTORE
        .onChange(of: hardwareVolume) {
                if let vol = hardwareVolume {
                    volumeValue = vol
                }
            }
        #endif
            .accessibilityElement(children: .contain)
            .accessibilityLabel(display.name)
            .contextMenu {
                Button(isBlanked ? "Restore Display" : "Dim Display") {
                    onToggleBlank()
                }
                Divider()
                Button("Set to 100%") { onChange(1.0) }
                Button("Set to 50%") { onChange(0.5) }
                Button("Set to 25%") { onChange(0.25) }
                Divider()
                Button("Reset Warmth") { onWarmthChange(0.0) }
                Button("Reset Contrast") { onContrastChange(0.5) }
            }
    }
}

// MARK: - DDC Controls Modifier

#if !APPSTORE
    extension DisplayBrightnessRow {
        /// Convenience modifier to wire DDC hardware controls from HardwareBrightnessManager.
        ///
        /// Sets all DDC-related properties (volume, mute, hasDDC, callbacks) in one call,
        /// keeping the call site clean in `displaySliders`.
        func ddcControls(
            hardwareManager: HardwareBrightnessManager,
            displayID: CGDirectDisplayID
        ) -> DisplayBrightnessRow {
            var copy = self
            let hasDDC = hardwareManager.supportsDDC(for: displayID)
            copy.hasDDC = hasDDC

            if hasDDC {
                let cap = hardwareManager.capability(for: displayID)

                if cap?.supportsVolume == true {
                    copy.hardwareVolume = hardwareManager.hardwareVolume[displayID] ?? 0.5
                    copy.onVolumeChange = { newValue in
                        hardwareManager.setHardwareVolume(for: displayID, to: newValue)
                    }
                }

                if cap?.supportsAudioMute == true {
                    copy.isMuted = hardwareManager.hardwareMute[displayID] ?? false
                    copy.onMuteToggle = {
                        hardwareManager.toggleMute(for: displayID)
                    }
                }

                if cap?.supportsInputSource == true {
                    copy.activeInputSource = hardwareManager.activeInputSource[displayID]
                    copy.availableInputSources = hardwareManager.availableInputSources(for: displayID)
                    copy.onInputSourceChange = { source in
                        hardwareManager.setInputSource(for: displayID, to: source)
                    }
                }
            }

            return copy
        }
    }
#endif

//
//  MenuBarPanel.swift
//  Dimmerly
//
//  Window-style MenuBarExtra content with per-display brightness sliders.
//

import SwiftUI

struct MenuBarPanel: View {
    @EnvironmentObject var brightnessManager: BrightnessManager
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var presetManager: PresetManager
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
                .font(.system(size: 28))
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
            }

            displayAdjustmentsDisclosure
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

    // MARK: - Presets

    private var presetsSection: some View {
        PresetsSectionView()
            .environmentObject(presetManager)
            .environmentObject(brightnessManager)
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
    @EnvironmentObject var presetManager: PresetManager
    @EnvironmentObject var brightnessManager: BrightnessManager
    @State private var isAddingPreset = false
    @State private var newPresetName = ""
    @State private var hoveredPresetID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Presets")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.bottom, 2)

            ForEach(presetManager.presets) { preset in
                presetRow(preset)
            }

            if isAddingPreset {
                HStack(spacing: 4) {
                    TextField("Preset name", text: $newPresetName)
                        .textFieldStyle(.roundedBorder)
                        .font(.callout)
                        .onSubmit { savePreset() }
                        .onExitCommand { cancelAddPreset() }
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

    private func presetRow(_ preset: BrightnessPreset) -> some View {
        Button {
            presetManager.applyPreset(preset, to: brightnessManager)
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
    let onChange: (Double) -> Void
    let onWarmthChange: (Double) -> Void
    let onContrastChange: (Double) -> Void
    let onToggleBlank: () -> Void

    @State private var sliderValue: Double
    @State private var warmthValue: Double
    @State private var contrastValue: Double

    init(display: ExternalDisplay, isBlanked: Bool, showAdjustments: Bool, onChange: @escaping (Double) -> Void, onWarmthChange: @escaping (Double) -> Void, onContrastChange: @escaping (Double) -> Void, onToggleBlank: @escaping () -> Void) {
        self.display = display
        self.isBlanked = isBlanked
        self.showAdjustments = showAdjustments
        self.onChange = onChange
        self.onWarmthChange = onWarmthChange
        self.onContrastChange = onContrastChange
        self.onToggleBlank = onToggleBlank
        self._sliderValue = State(initialValue: display.brightness)
        self._warmthValue = State(initialValue: display.warmth)
        self._contrastValue = State(initialValue: display.contrast)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(display.name)
                    .font(.callout)
                    .lineLimit(1)
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

                Slider(value: $sliderValue, in: BrightnessManager.minimumBrightness...1)
                    .accessibilityLabel(
                        String(
                            format: NSLocalizedString("%@ brightness", comment: "Accessibility label: display brightness slider"),
                            display.name
                        )
                    )
                    .accessibilityValue(
                        String(
                            format: NSLocalizedString("%d percent", comment: "Accessibility value: brightness percentage"),
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
                HStack(spacing: 6) {
                    Image(systemName: "thermometer.snowflake")
                        .font(.caption2)
                        .frame(width: 12)
                        .foregroundStyle(.blue)
                        .accessibilityHidden(true)

                    Slider(value: $warmthValue, in: 0...1)
                        .tint(.orange)
                        .accessibilityLabel(
                            String(
                                format: NSLocalizedString("%@ warmth", comment: "Accessibility label: display warmth slider"),
                                display.name
                            )
                        )
                        .accessibilityValue(
                            String(
                                format: NSLocalizedString("%d percent", comment: "Accessibility value: warmth percentage"),
                                Int(warmthValue * 100)
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

                    Slider(value: $contrastValue, in: 0...1)
                        .accessibilityLabel(
                            String(
                                format: NSLocalizedString("%@ contrast", comment: "Accessibility label: display contrast slider"),
                                display.name
                            )
                        )
                        .accessibilityValue(
                            String(
                                format: NSLocalizedString("%d percent", comment: "Accessibility value: contrast percentage"),
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

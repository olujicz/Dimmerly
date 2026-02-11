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
                    onChange: { newValue in
                        brightnessManager.setBrightness(for: display.id, to: newValue)
                    },
                    onToggleBlank: {
                        brightnessManager.toggleBlank(for: display.id)
                    }
                )
            }
        }
        .padding(20)
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
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .keyboardShortcut(.return, modifiers: [])
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Group {
                if #available(macOS 14.0, *) {
                    SettingsLink {
                        FooterLabel("Settings...", shortcut: "⌘,")
                    }
                    .keyboardShortcut(",", modifiers: .command)
                } else {
                    Button {
                        NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
                    } label: {
                        FooterLabel("Settings...", shortcut: "⌘,")
                    }
                    .keyboardShortcut(",", modifiers: .command)
                }
            }
            .buttonStyle(.borderless)

            Button {
                showAboutPanel()
            } label: {
                Text("About Dimmerly")
            }
            .buttonStyle(.borderless)

            Spacer()

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                FooterLabel("Quit", shortcut: "⌘Q")
            }
            .buttonStyle(.borderless)
            .keyboardShortcut("q", modifiers: .command)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    private func showAboutPanel() {
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }

        let centeredStyle = NSMutableParagraphStyle()
        centeredStyle.alignment = .center

        let credits = NSMutableAttributedString()

        let description = NSAttributedString(
            string: NSLocalizedString("A macOS menu bar utility for putting your displays to sleep — with a single keyboard shortcut.\n", comment: "About panel description"),
            attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: centeredStyle,
            ]
        )
        credits.append(description)

        #if !APPSTORE
        let linkText = NSAttributedString(
            string: NSLocalizedString("Source Code on GitHub", comment: "About panel link label"),
            attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                .link: URL(string: "https://github.com/olujicz/Dimmerly") as Any,
                .paragraphStyle: centeredStyle,
            ]
        )
        credits.append(linkText)
        #endif

        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: credits,
        ])
    }
}

// MARK: - Presets Section

private struct PresetsSectionView: View {
    @EnvironmentObject var presetManager: PresetManager
    @EnvironmentObject var brightnessManager: BrightnessManager
    @State private var isAddingPreset = false
    @State private var newPresetName = ""
    @State private var hoveredPresetID: UUID?
    @State private var presetToDelete: BrightnessPreset?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Presets")
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(presetManager.presets) { preset in
                HStack {
                    Text(preset.name)
                        .font(.callout)
                        .lineLimit(1)
                    Spacer()
                    Button("Apply") {
                        presetManager.applyPreset(preset, to: brightnessManager)
                    }
                    .buttonStyle(.borderless)
                    .font(.callout)
                    .accessibilityLabel(Text("Apply \(preset.name)"))
                }
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(hoveredPresetID == preset.id ? Color.primary.opacity(0.06) : .clear)
                        .padding(.horizontal, -4)
                )
                .onHover { isHovered in
                    hoveredPresetID = isHovered ? preset.id : nil
                }
                .contextMenu {
                    Button("Apply Preset") {
                        presetManager.applyPreset(preset, to: brightnessManager)
                    }
                    Divider()
                    Button("Delete", role: .destructive) {
                        presetToDelete = preset
                    }
                }
            }
            .alert("Delete Preset?", isPresented: Binding(
                get: { presetToDelete != nil },
                set: { if !$0 { presetToDelete = nil } }
            )) {
                Button("Cancel", role: .cancel) { presetToDelete = nil }
                Button("Delete", role: .destructive) {
                    if let preset = presetToDelete {
                        presetManager.deletePreset(id: preset.id)
                    }
                    presetToDelete = nil
                }
            } message: {
                if let preset = presetToDelete {
                    Text("\"\(preset.name)\" will be permanently deleted.")
                }
            }

            if isAddingPreset {
                HStack(spacing: 4) {
                    TextField("Name this preset", text: $newPresetName)
                        .textFieldStyle(.roundedBorder)
                        .font(.callout)
                        .onSubmit {
                            savePreset()
                        }
                    Button("Save") {
                        savePreset()
                    }
                    .buttonStyle(.borderless)
                    .font(.callout)
                    .disabled(newPresetName.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button("Cancel") {
                        isAddingPreset = false
                        newPresetName = ""
                    }
                    .buttonStyle(.borderless)
                    .font(.callout)
                }
            } else if presetManager.presets.count < PresetManager.maxPresets {
                Button {
                    isAddingPreset = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus")
                        Text("Save Current")
                    }
                    .font(.callout)
                }
                .buttonStyle(.borderless)
            } else {
                Text("Maximum presets reached")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func savePreset() {
        let name = newPresetName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        presetManager.saveCurrentAsPreset(name: name, brightnessManager: brightnessManager)
        newPresetName = ""
        isAddingPreset = false
    }
}

// MARK: - Footer Label

private struct FooterLabel: View {
    let title: LocalizedStringKey
    let shortcut: String

    init(_ title: LocalizedStringKey, shortcut: String) {
        self.title = title
        self.shortcut = shortcut
    }

    var body: some View {
        HStack(spacing: 2) {
            Text(title)
            Text(shortcut)
                .foregroundStyle(.tertiary)
                .font(.caption)
        }
    }
}

// MARK: - Display Brightness Row

struct DisplayBrightnessRow: View {
    let display: ExternalDisplay
    let isBlanked: Bool
    let onChange: (Double) -> Void
    let onToggleBlank: () -> Void

    @State private var sliderValue: Double

    init(display: ExternalDisplay, isBlanked: Bool, onChange: @escaping (Double) -> Void, onToggleBlank: @escaping () -> Void) {
        self.display = display
        self.isBlanked = isBlanked
        self.onChange = onChange
        self.onToggleBlank = onToggleBlank
        self._sliderValue = State(initialValue: display.brightness)
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
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .opacity(isBlanked ? 0.4 : 1.0)
            .disabled(isBlanked)
        }
        .onChange(of: display.brightness) {
            sliderValue = display.brightness
        }
        .contextMenu {
            Button(isBlanked ? "Restore Display" : "Dim Display") {
                onToggleBlank()
            }
            Divider()
            Button("Set to 100%") { onChange(1.0) }
            Button("Set to 50%") { onChange(0.5) }
            Button("Set to 25%") { onChange(0.25) }
        }
    }
}

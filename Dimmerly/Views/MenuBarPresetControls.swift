//
//  MenuBarPresetControls.swift
//  Dimmerly
//

import AppKit
import SwiftUI

// MARK: - Presets Section

struct PresetsSectionView: View {
    @Environment(PresetManager.self) var presetManager
    @Environment(BrightnessManager.self) var brightnessManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isAddingPreset = false
    @State private var newPresetName = ""
    @State private var hoveredPresetID: UUID?
    @FocusState private var isPresetNameFieldFocused: Bool

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
                        .focused($isPresetNameFieldFocused)
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
                    isPresetNameFieldFocused = true
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
            .animation(reduceMotion ? nil : .spring(response: 0.2, dampingFraction: 0.8), value: hoveredPresetID)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        // Only bind the ⌘N shortcut when the row is actually showing that hint (no custom
        // shortcut assigned) — otherwise a preset with a custom shortcut like ⌥⌘B would still
        // silently respond to ⌘N too, with no visible affordance explaining why.
        .keyboardShortcut(
            preset.shortcut == nil
                ? KeyboardShortcut(KeyEquivalent(Character("\((index + 1) % 10)")), modifiers: .command)
                : nil
        )
        .onHover { isHovered in
            hoveredPresetID = isHovered ? preset.id : nil
        }
        .accessibilityLabel(Text("Apply \(preset.name)"))
        .accessibilityHint(Text("Applies saved brightness settings to all displays"))
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

struct FooterLabel: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
        .animation(reduceMotion ? nil : .spring(response: 0.2, dampingFraction: 0.8), value: isHovered)
        .onHover { isHovered = $0 }
        .accessibilityAddTraits(.isButton)
    }
}

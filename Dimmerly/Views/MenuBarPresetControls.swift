//
//  MenuBarPresetControls.swift
//  Dimmerly
//

import SwiftUI

// MARK: - Presets Section

struct PresetsSectionView: View {
    let selectedPresetID: UUID?

    @Environment(PresetManager.self) var presetManager
    @Environment(BrightnessManager.self) var brightnessManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isAddingPreset = false
    @State private var newPresetName = ""
    @State private var hoveredPresetID: UUID?
    /// The preset just applied from this panel, briefly marked with a checkmark in place
    /// of its shortcut hint so a click or ⌘N press visibly lands.
    @State private var confirmedPresetID: UUID?
    /// Bumped on every apply so the checkmark bounces again when the same preset is reapplied.
    @State private var confirmationCount = 0
    @State private var confirmationReset: Task<Void, Never>?
    @FocusState private var isPresetNameFieldFocused: Bool

    init(selectedPresetID: UUID? = nil) {
        self.selectedPresetID = selectedPresetID
    }

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
            confirmApplied(preset)
        } label: {
            HStack {
                Text(preset.name)
                    .font(.callout)
                    .lineLimit(1)
                Spacer()
                ZStack(alignment: .trailing) {
                    shortcutHint(for: preset, index: index)
                        .opacity(confirmedPresetID == preset.id ? 0 : 1)
                    // Always in the hierarchy, only faded in, so the bounce has a view to run on.
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tint)
                        .symbolEffect(.bounce, value: reduceMotion ? 0 : confirmationCount)
                        .opacity(confirmedPresetID == preset.id ? 1 : 0)
                        .accessibilityHidden(true)
                }
                .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: confirmedPresetID)
            }
            .padding(.vertical, 3)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background { presetRowBackground(for: preset) }
            .animation(reduceMotion ? nil : .spring(response: 0.2, dampingFraction: 0.8), value: hoveredPresetID)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .id(preset.id)
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

    @ViewBuilder
    private func shortcutHint(for preset: BrightnessPreset, index: Int) -> some View {
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

    private func confirmApplied(_ preset: BrightnessPreset) {
        confirmedPresetID = preset.id
        confirmationCount += 1
        confirmationReset?.cancel()
        confirmationReset = Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            confirmedPresetID = nil
        }
    }

    @ViewBuilder
    private func presetRowBackground(for preset: BrightnessPreset) -> some View {
        if selectedPresetID == preset.id {
            RoundedRectangle(cornerRadius: 8)
                .fill(.tint.opacity(0.20))
        } else {
            RoundedRectangle(cornerRadius: 8)
                .fill(hoveredPresetID == preset.id ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear))
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

// MARK: - Symbol Replacement

extension View {
    /// Swaps a changing SF Symbol with the system's replace animation, or instantly when
    /// Reduce Motion is on. Carries its own animation for `value`, so the swap animates even
    /// when the state behind it changes outside an animation transaction.
    func symbolReplaceTransition(value: some Equatable) -> some View {
        modifier(SymbolReplaceTransition(value: value))
    }
}

private struct SymbolReplaceTransition<Value: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let value: Value

    func body(content: Content) -> some View {
        content
            .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
            .animation(reduceMotion ? nil : .default, value: value)
    }
}

// MARK: - Footer Label

struct FooterLabel: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let title: LocalizedStringKey
    let icon: String
    let shortcut: String?
    let isHovered: Bool

    init(
        _ title: LocalizedStringKey,
        icon: String,
        shortcut: String? = nil,
        isHovered: Bool = false
    ) {
        self.title = title
        self.icon = icon
        self.shortcut = shortcut
        self.isHovered = isHovered
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
        .accessibilityAddTraits(.isButton)
    }
}

//
//  DimmerlyWidgetViews.swift
//  DimmerlyWidget
//
//  SwiftUI views for systemSmall and systemMedium widget families.
//

import AppIntents
import SwiftUI
import WidgetKit

struct DimmerlyWidgetEntryView: View {
    @Environment(\.widgetFamily) var family
    var entry: DimmerlyWidgetProvider.Entry

    var body: some View {
        switch family {
        case .systemSmall:
            SmallWidgetView()
        case .systemMedium:
            MediumWidgetView(presets: entry.presets)
        default:
            SmallWidgetView()
        }
    }
}

// MARK: - Small Widget

struct SmallWidgetView: View {
    var body: some View {
        Button(intent: DimDisplaysWidgetIntent()) {
            VStack(spacing: 8) {
                // largeTitle is 26 pt on macOS; the large symbol scale brings
                // the glyph back to roughly the previous fixed 32 pt.
                Image(systemName: "moon.fill")
                    .font(.largeTitle.weight(.medium))
                    .imageScale(.large)
                    .widgetAccentable()
                Text("Dim Displays")
                    .font(.system(.callout, weight: .semibold))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Dim Displays"))
    }
}

// MARK: - Medium Widget

struct MediumWidgetView: View {
    let presets: [WidgetPresetInfo]

    var body: some View {
        HStack(spacing: 0) {
            dimButton
            if !presets.isEmpty {
                presetButtons
                    .padding(.leading, 8)
            } else {
                emptyPresetsHint
                    .padding(.leading, 8)
            }
        }
        .padding(4)
    }

    private var dimButton: some View {
        Button(intent: DimDisplaysWidgetIntent()) {
            VStack(spacing: 6) {
                Image(systemName: "moon.fill")
                    .font(.largeTitle.weight(.medium))
                    .widgetAccentable()
                Text("Dim Displays")
                    .font(.system(.caption, weight: .semibold))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(WidgetButtonBackground(cornerRadius: 10, tint: .blue))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Dim Displays"))
    }

    private var emptyPresetsHint: some View {
        VStack(spacing: 4) {
            Image(systemName: "slider.horizontal.3")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("Add presets in Dimmerly")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var presetButtons: some View {
        VStack(spacing: 4) {
            ForEach(Array(presets.prefix(3))) { preset in
                Button(intent: ApplyPresetWidgetIntent(presetID: preset.id)) {
                    HStack(spacing: 4) {
                        Image(systemName: "sun.max.fill")
                            .font(.caption2)
                            .widgetAccentable()
                        Text(preset.name)
                            .font(.system(.caption, weight: .medium))
                            .lineLimit(1)
                        Spacer()
                    }
                    .padding(.horizontal, 8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(WidgetButtonBackground(cornerRadius: 8, tint: .orange))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Apply \(preset.name)"))
            }
        }
    }
}

// MARK: - Button Background

/// Rounded fill behind a widget button.
///
/// In full color it keeps the light brand tint. In the accented and vibrant
/// modes the system strips or remaps color, so a faint fixed hue would turn
/// into an arbitrary gray; a semantic fill adapts to those modes instead.
/// The fill is left out of the accent group so only the glyphs pick up the
/// accent color.
private struct WidgetButtonBackground: View {
    @Environment(\.widgetRenderingMode) private var renderingMode

    let cornerRadius: CGFloat
    let tint: Color

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if renderingMode == .fullColor {
            shape.fill(tint.opacity(0.1))
        } else {
            shape.fill(.fill.quaternary)
        }
    }
}

// MARK: - Preview

#Preview("Small", as: .systemSmall) {
    DimmerlyWidget()
} timeline: {
    PresetEntry(date: .now, presets: [])
}

#Preview("Medium", as: .systemMedium) {
    DimmerlyWidget()
} timeline: {
    PresetEntry(
        date: .now,
        presets: [
            WidgetPresetInfo(id: "movie-night", name: "Movie Night"),
            WidgetPresetInfo(id: "work", name: "Work"),
            WidgetPresetInfo(id: "bright", name: "Bright"),
        ]
    )
}

#Preview("Medium, No Presets", as: .systemMedium) {
    DimmerlyWidget()
} timeline: {
    PresetEntry(date: .now, presets: [])
}

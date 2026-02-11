//
//  DimmerlyWidgetViews.swift
//  DimmerlyWidget
//
//  SwiftUI views for systemSmall and systemMedium widget families.
//

import SwiftUI
import WidgetKit
import AppIntents

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
                Image(systemName: "moon.fill")
                    .font(.system(size: 32, weight: .medium))
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
                    .font(.system(size: 26, weight: .medium))
                    .widgetAccentable()
                Text("Dim Displays")
                    .font(.system(.caption, weight: .semibold))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.blue.opacity(0.1))
            )
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
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(.orange.opacity(0.1))
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Apply \(preset.name)"))
            }
        }
    }
}

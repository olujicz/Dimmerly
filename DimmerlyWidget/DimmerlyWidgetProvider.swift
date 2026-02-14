//
//  DimmerlyWidgetProvider.swift
//  DimmerlyWidget
//
//  TimelineProvider that reads preset data from shared App Group UserDefaults.
//

import WidgetKit

struct PresetEntry: TimelineEntry {
    let date: Date
    let presets: [WidgetPresetInfo]
}

struct DimmerlyWidgetProvider: TimelineProvider {
    private static let samplePresets = [
        WidgetPresetInfo(id: UUID().uuidString, name: "Movie Night"),
        WidgetPresetInfo(id: UUID().uuidString, name: "Work"),
        WidgetPresetInfo(id: UUID().uuidString, name: "Bright")
    ]

    func placeholder(in _: Context) -> PresetEntry {
        PresetEntry(date: Date(), presets: Self.samplePresets)
    }

    func getSnapshot(in context: Context, completion: @escaping (PresetEntry) -> Void) {
        if context.isPreview {
            completion(PresetEntry(date: Date(), presets: Self.samplePresets))
        } else {
            completion(PresetEntry(date: Date(), presets: loadPresets()))
        }
    }

    func getTimeline(in _: Context, completion: @escaping (Timeline<PresetEntry>) -> Void) {
        let entry = PresetEntry(date: Date(), presets: loadPresets())
        completion(Timeline(entries: [entry], policy: .never))
    }

    private func loadPresets() -> [WidgetPresetInfo] {
        guard let data = SharedConstants.sharedDefaults?.data(forKey: SharedConstants.widgetPresetsKey),
              let presets = try? JSONDecoder().decode([WidgetPresetInfo].self, from: data)
        else {
            return []
        }
        return presets
    }
}

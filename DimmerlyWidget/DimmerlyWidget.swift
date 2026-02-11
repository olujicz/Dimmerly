//
//  DimmerlyWidget.swift
//  DimmerlyWidget
//
//  WidgetKit widget providing quick-access dim and preset buttons.
//

import WidgetKit
import SwiftUI

struct DimmerlyWidget: Widget {
    let kind = "DimmerlyWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: DimmerlyWidgetProvider()) { entry in
            DimmerlyWidgetEntryView(entry: entry)
                .widgetURL(URL(string: "dimmerly://open"))
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Dimmerly")
        .description("Quickly dim displays or apply brightness presets.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

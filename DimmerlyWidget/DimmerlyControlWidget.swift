//
//  DimmerlyControlWidget.swift
//  DimmerlyWidget
//
//  Control Center button for quickly dimming all displays.
//

import WidgetKit
import SwiftUI
import AppIntents

@available(macOS 26.0, *)
struct DimmerlyControlWidget: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "rs.in.olujic.dimmerly.DimControl") {
            ControlWidgetButton(action: DimDisplaysWidgetIntent()) {
                Label("Dim Displays", systemImage: "moon.fill")
            }
        }
        .displayName("Dim Displays")
        .description("Quickly dim all connected displays.")
    }
}

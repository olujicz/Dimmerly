//
//  DimmerlyControlWidget.swift
//  DimmerlyWidget
//
//  Control Center button for quickly dimming all displays.
//

import AppIntents
import SwiftUI
import WidgetKit

// Gate the widget behind the compiler version that introduced
// ControlWidgetConfiguration so older toolchains can still build the widget
// extension. The matching SDK availability check remains on the declaration.
#if compiler(>=6.2)
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
#endif

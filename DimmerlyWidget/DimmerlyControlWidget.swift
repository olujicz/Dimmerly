//
//  DimmerlyControlWidget.swift
//  DimmerlyWidget
//
//  Control Center button for quickly dimming all displays.
//

import AppIntents
import SwiftUI
import WidgetKit

// ControlWidgetConfiguration is explicitly marked unavailable on macOS in
// current SDKs.  Gate the entire struct behind a compiler version check so
// CI passes on older toolchains.  When the macOS 26 SDK ships (expected
// with Swift ≥ 6.2), remove or adjust this guard.
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

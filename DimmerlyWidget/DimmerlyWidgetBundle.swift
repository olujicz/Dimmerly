//
//  DimmerlyWidgetBundle.swift
//  DimmerlyWidget
//

import SwiftUI
import WidgetKit

@main
struct DimmerlyWidgetBundle: WidgetBundle {
    var body: some Widget {
        DimmerlyWidget()
        #if compiler(>=6.2)
            if #available(macOS 26.0, *) {
                DimmerlyControlWidget()
            }
        #endif
    }
}

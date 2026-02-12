//
//  DimmerlyWidgetBundle.swift
//  DimmerlyWidget
//

import WidgetKit
import SwiftUI

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

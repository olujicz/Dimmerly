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
        if #available(macOS 26.0, *) {
            DimmerlyControlWidget()
        }
    }
}

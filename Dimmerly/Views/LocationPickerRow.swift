//
//  LocationPickerRow.swift
//  Dimmerly
//
//  Reusable location picker row used by the Schedule
//  and Color Temperature settings sections.
//

import SwiftUI

/// A self-contained row for picking or entering a location,
/// used wherever sunrise/sunset data is needed.
struct LocationPickerRow: View {
    @EnvironmentObject var locationProvider: LocationProvider

    @State private var showManualLocation = false

    var body: some View {
        Group {
            if locationProvider.hasLocation {
                LabeledContent {
                    Menu {
                        Button("Use Current Location") {
                            locationProvider.requestLocation()
                        }
                        Button("Enter Manually\u{2026}") {
                            showManualLocation = true
                        }
                        Divider()
                        Button("Clear Location", role: .destructive) {
                            locationProvider.clearLocation()
                        }
                    } label: {
                        Text(locationSummary)
                            .foregroundStyle(.secondary)
                    }
                } label: {
                    Label("Location", systemImage: "location.fill")
                }
            } else {
                LabeledContent {
                    HStack(spacing: 8) {
                        Button("Use Current") {
                            locationProvider.requestLocation()
                        }
                        Button("Enter Manually\u{2026}") {
                            showManualLocation = true
                        }
                    }
                } label: {
                    Label("Location", systemImage: "location.slash")
                }

                Text("A location is needed for sunrise and sunset features.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .sheet(isPresented: $showManualLocation) {
            ManualLocationSheet()
                .environmentObject(locationProvider)
        }
    }

    private var locationSummary: String {
        let lat = locationProvider.latitude ?? 0
        let lon = locationProvider.longitude ?? 0
        return String(format: "%.2f, %.2f", lat, lon)
    }
}

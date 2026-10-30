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
    @Environment(LocationProvider.self) var locationProvider

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
                    .accessibilityLabel(locationAccessibilityLabel)
                } label: {
                    Label("Location", systemImage: "location.fill")
                }
            } else {
                LabeledContent {
                    HStack(spacing: 8) {
                        Button("Use Current Location") {
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
                .environment(locationProvider)
        }
    }

    private static let coordinateFormat = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(2))

    /// Uses the person's decimal separator. The degree signs keep "48,85°, 2,35°" readable in
    /// comma-decimal languages, where a bare "48,85, 2,35" would not be.
    private var locationSummary: String {
        let lat = (locationProvider.latitude ?? 0).formatted(Self.coordinateFormat)
        let lon = (locationProvider.longitude ?? 0).formatted(Self.coordinateFormat)
        return String(
            localized: "\(lat)°, \(lon)°",
            comment: "Saved location shown in Settings: latitude, then longitude, in degrees"
        )
    }

    private var locationAccessibilityLabel: String {
        let lat = (locationProvider.latitude ?? 0).formatted(Self.coordinateFormat)
        let lon = (locationProvider.longitude ?? 0).formatted(Self.coordinateFormat)
        return String(
            localized: "Location: Latitude \(lat), Longitude \(lon)",
            comment: "Accessibility label for the saved location; values are coordinates"
        )
    }
}

//
//  LocationPickerRow.swift
//  Dimmerly
//
//  Reusable location picker row used by the Schedule
//  and Color Temperature settings sections.
//

import AppKit
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

            if let problem = locationProvider.accessProblem {
                accessProblemRow(problem)
            }
        }
        .sheet(isPresented: $showManualLocation) {
            ManualLocationSheet()
                .environment(locationProvider)
        }
        // Re-check on return from System Settings rather than trusting the last answer.
        .task { await locationProvider.refreshAccessProblem() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await locationProvider.refreshAccessProblem() }
        }
    }

    /// Says why "Use Current Location" didn't work and where to fix it. The text names the
    /// System Settings path as well, in case the button's URL stops resolving in a later macOS.
    private func accessProblemRow(_ problem: LocationAccessProblem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label {
                Text(accessProblemMessage(problem))
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            .font(.caption)
            .accessibilityElement(children: .combine)

            // Restricted access is set by a policy the person can't change in System Settings.
            if problem != .restricted {
                ExternalLinkButton(
                    title: Text("Open Location Services Settings"),
                    help: Text("Open Location Services in System Settings"),
                    action: { locationProvider.openLocationPrivacySettings() }
                )
                .font(.caption)
            }
        }
    }

    private func accessProblemMessage(_ problem: LocationAccessProblem) -> String {
        switch problem {
        case .servicesOff:
            String(
                localized: """
                Location Services is turned off. Turn it on in System Settings > Privacy & Security > \
                Location Services, or enter a location manually.
                """,
                comment: "Settings: Location Services is off for the whole Mac; names the System Settings path"
            )
        case .denied:
            String(
                localized: """
                Dimmerly doesn’t have access to your location. Allow it in System Settings > \
                Privacy & Security > Location Services, or enter a location manually.
                """,
                comment: "Settings: location access was turned down; names the System Settings path"
            )
        case .restricted:
            String(
                localized: "Location access is restricted on this Mac. Enter a location manually.",
                comment: "Settings: location access is blocked by a policy the person can't change"
            )
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

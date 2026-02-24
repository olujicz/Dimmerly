//
//  ScheduleViews.swift
//  Dimmerly
//
//  UI components for schedule-based auto-dimming.
//

import SwiftUI

// MARK: - Schedule Row

/// A row displaying a single schedule with toggle, description, and delete button.
/// Follows the PresetManagementRow visual pattern.
struct ScheduleRow: View {
    let schedule: DimmingSchedule
    let presetName: String?
    let triggerTimeDescription: String?
    let onToggle: () -> Void
    let onDelete: () -> Void

    @State private var showDeleteConfirmation = false
    @State private var isHovered = false
    @FocusState private var deleteButtonFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack {
            Toggle(schedule.name, isOn: Binding(
                get: { schedule.isEnabled },
                set: { _ in onToggle() }
            ))

            Spacer()

            Text(triggerSummary)
                .font(.callout)
                .foregroundStyle(.secondary)

            Button {
                showDeleteConfirmation = true
            } label: {
                Image(systemName: "trash")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .opacity(isHovered || deleteButtonFocused ? 1 : 0.3)
            .focused($deleteButtonFocused)
            .accessibilityLabel(Text("Delete \(schedule.name)"))
            .help(Text("Delete Schedule"))
            .alert("Delete Schedule?", isPresented: $showDeleteConfirmation) {
                Button("Cancel", role: .cancel) {}
                Button("Delete", role: .destructive) { onDelete() }
            } message: {
                Text("\"\(schedule.name)\" will be permanently deleted.")
            }
        }
        .onHover { isHovered = $0 }
        .animation(reduceMotion ? nil : .spring(response: 0.2, dampingFraction: 0.8), value: isHovered)

        if presetName == nil {
            Label(
                "The preset assigned to this schedule has been deleted.",
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.caption)
            .foregroundStyle(.red)
            .symbolRenderingMode(.multicolor)
        }
    }

    private var triggerSummary: String {
        var parts: [String] = []
        parts.append(schedule.trigger.displayDescription)
        if let timeDesc = triggerTimeDescription {
            parts.append("(\(timeDesc))")
        }
        if let name = presetName {
            parts.append("\u{2192} \(name)")
        } else {
            parts.append(
                "\u{2192} " + NSLocalizedString(
                    "Deleted Preset",
                    comment: "Schedule row: referenced preset was deleted"
                )
            )
        }
        return parts.joined(separator: " ")
    }
}

// MARK: - Add Schedule Sheet

/// Modal sheet for creating a new schedule
struct AddScheduleSheet: View {
    @Environment(ScheduleManager.self) var scheduleManager
    let presets: [BrightnessPreset]
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var triggerType = 0 // 0 = fixed, 1 = sunrise, 2 = sunset
    @State private var selectedTime = Calendar.current.date(from: DateComponents(hour: 20, minute: 0)) ?? Date()
    @State private var offsetMinutes = 0
    @State private var selectedPresetID: UUID?

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $name)
            }

            Section("Trigger") {
                Picker("Type", selection: $triggerType) {
                    Text("Fixed Time").tag(0)
                    Text("Sunrise").tag(1)
                    Text("Sunset").tag(2)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityLabel("Trigger type")

                if triggerType == 0 {
                    DatePicker(
                        "Time",
                        selection: $selectedTime,
                        displayedComponents: .hourAndMinute
                    )
                } else {
                    Stepper(value: $offsetMinutes, in: -120 ... 120, step: 5) {
                        LabeledContent("Offset") {
                            Text(offsetDescription)
                        }
                    }
                }
            }

            Section("Preset") {
                if presets.isEmpty {
                    Text("No presets available. Create a preset first.")
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Apply", selection: $selectedPresetID) {
                        Text("None").tag(nil as UUID?)
                        ForEach(presets) { preset in
                            Text(preset.name).tag(preset.id as UUID?)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 360, idealWidth: 400, minHeight: 280)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
                    .help("Discard and close")
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Add") { addSchedule() }
                    .disabled(!isValid)
                    .help("Create this schedule")
            }
        }
        .onAppear {
            if let first = presets.first {
                selectedPresetID = first.id
            }
        }
    }

    private var offsetDescription: String {
        if offsetMinutes == 0 {
            return triggerType == 1
                ? String(localized: "At sunrise", comment: "Schedule offset: exactly at sunrise")
                : String(localized: "At sunset", comment: "Schedule offset: exactly at sunset")
        } else if offsetMinutes > 0 {
            return String(
                format: NSLocalizedString("%d min after", comment: "Schedule offset: minutes after sunrise/sunset"),
                offsetMinutes
            )
        } else {
            return String(
                format: NSLocalizedString("%d min before", comment: "Schedule offset: minutes before sunrise/sunset"),
                abs(offsetMinutes)
            )
        }
    }

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && selectedPresetID != nil
    }

    private func addSchedule() {
        guard let presetID = selectedPresetID else { return }

        let trigger: ScheduleTrigger
        switch triggerType {
        case 1:
            trigger = .sunrise(offsetMinutes: offsetMinutes)
        case 2:
            trigger = .sunset(offsetMinutes: offsetMinutes)
        default:
            let components = Calendar.current.dateComponents([.hour, .minute], from: selectedTime)
            trigger = .fixedTime(hour: components.hour ?? 20, minute: components.minute ?? 0)
        }

        let schedule = DimmingSchedule(
            name: name.trimmingCharacters(in: .whitespaces),
            trigger: trigger,
            presetID: presetID
        )
        scheduleManager.addSchedule(schedule)
        dismiss()
    }
}

// MARK: - Manual Location Sheet

/// Modal sheet for entering latitude/longitude manually
struct ManualLocationSheet: View {
    @Environment(LocationProvider.self) var locationProvider
    @Environment(\.dismiss) private var dismiss

    @State private var latitudeText = ""
    @State private var longitudeText = ""
    @State private var validationError: String?

    var body: some View {
        Form {
            Section {
                TextField("Latitude", text: $latitudeText)
                    .help(Text("A value between -90 and 90"))
                TextField("Longitude", text: $longitudeText)
                    .help(Text("A value between -180 and 180"))
            } footer: {
                if let error = validationError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .symbolRenderingMode(.multicolor)
                } else {
                    Text(
                        "Enter your approximate coordinates for sunrise and sunset"
                            + " calculations. You can find these by searching for"
                            + " your city on a map."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 320, idealWidth: 380, minHeight: 180)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { saveLocation() }
                    .disabled(latitudeText.isEmpty || longitudeText.isEmpty)
            }
        }
        .onAppear {
            if let lat = locationProvider.latitude {
                latitudeText = String(format: "%.4f", lat)
            }
            if let lon = locationProvider.longitude {
                longitudeText = String(format: "%.4f", lon)
            }
        }
    }

    private func saveLocation() {
        guard let lat = Double(latitudeText),
              let lon = Double(longitudeText)
        else {
            validationError = NSLocalizedString(
                "Please enter valid numbers.",
                comment: "Location validation error: not a number"
            )
            return
        }
        guard lat >= -90, lat <= 90 else {
            validationError = NSLocalizedString(
                "Latitude must be between -90 and 90.",
                comment: "Location validation error: latitude out of range"
            )
            return
        }
        guard lon >= -180, lon <= 180 else {
            validationError = NSLocalizedString(
                "Longitude must be between -180 and 180.",
                comment: "Location validation error: longitude out of range"
            )
            return
        }

        validationError = nil
        locationProvider.setManualLocation(latitude: lat, longitude: lon)
        dismiss()
    }
}

//
//  SettingsScheduleTab.swift
//  Dimmerly
//

import AppKit
import SwiftUI

// MARK: - Schedule Tab

/// Schedule settings: preset schedules with sunrise/sunset triggers.
struct ScheduleSettingsTab: View {
    @Environment(AppSettings.self) var settings
    @Environment(ScheduleManager.self) var scheduleManager
    @Environment(PresetManager.self) var presetManager
    @Environment(\.undoManager) var undoManager

    @State private var showAddSchedule = false

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Toggle("Apply presets on a schedule", isOn: $settings.scheduleEnabled)
                    .help("Automatically apply brightness presets at scheduled times")

                if settings.scheduleEnabled {
                    LocationPickerRow()

                    ForEach(scheduleManager.schedules) { schedule in
                        let presetName = presetManager.presets.first(where: { $0.id == schedule.presetID })?.name
                        let triggerTime = triggerTimeDescription(for: schedule)
                        ScheduleRow(
                            schedule: schedule,
                            presetName: presetName,
                            triggerTimeDescription: triggerTime,
                            onToggle: { scheduleManager.toggleSchedule(id: schedule.id) },
                            onDelete: { scheduleManager.deleteSchedule(id: schedule.id, undoManager: undoManager) }
                        )
                    }

                    Button("Add Schedule\u{2026}") {
                        showAddSchedule = true
                    }
                    .help("Create a new scheduled preset")
                    .sheet(isPresented: $showAddSchedule) {
                        AddScheduleSheet(presets: presetManager.presets)
                            .environment(scheduleManager)
                    }
                }
            } header: {
                Label("Schedule", systemImage: "calendar.badge.clock")
            }
        }
        .formStyle(.grouped)
    }

    private func triggerTimeDescription(for schedule: DimmingSchedule) -> String? {
        guard schedule.trigger.requiresLocation else { return nil }
        guard let date = scheduleManager.resolveTriggerDate(schedule.trigger, on: Date()) else {
            return nil
        }
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter.string(from: date)
    }
}

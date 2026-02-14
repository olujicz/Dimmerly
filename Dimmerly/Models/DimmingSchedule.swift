//
//  DimmingSchedule.swift
//  Dimmerly
//
//  Model representing a scheduled brightness preset application.
//  Schedules reference presets by ID and trigger at specific times.
//

import Foundation

/// When a schedule should trigger
enum ScheduleTrigger: Codable, Equatable, Sendable {
    /// Cached formatter for fixed-time display (avoids allocation on every render)
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = DateFormatter.dateFormat(fromTemplate: "j:mm", options: 0, locale: .current)
        return f
    }()

    /// Triggers at a fixed time every day
    case fixedTime(hour: Int, minute: Int)
    /// Triggers at sunrise with an optional offset in minutes (negative = before)
    case sunrise(offsetMinutes: Int)
    /// Triggers at sunset with an optional offset in minutes (negative = before)
    case sunset(offsetMinutes: Int)

    /// Human-readable description of the trigger
    var displayDescription: String {
        switch self {
        case let .fixedTime(hour, minute):
            let components = DateComponents(hour: hour, minute: minute)
            if let date = Calendar.current.date(from: components) {
                return Self.timeFormatter.string(from: date)
            }
            return String(format: "%d:%02d", hour, minute)

        case let .sunrise(offset):
            if offset == 0 {
                return String(localized: "Sunrise", comment: "Schedule trigger: at sunrise")
            } else if offset > 0 {
                return String(
                    format: NSLocalizedString(
                        "%d min after sunrise",
                        comment: "Schedule trigger: minutes after sunrise"
                    ),
                    offset
                )
            } else {
                return String(
                    format: NSLocalizedString(
                        "%d min before sunrise",
                        comment: "Schedule trigger: minutes before sunrise"
                    ),
                    abs(offset)
                )
            }

        case let .sunset(offset):
            if offset == 0 {
                return String(localized: "Sunset", comment: "Schedule trigger: at sunset")
            } else if offset > 0 {
                return String(
                    format: NSLocalizedString(
                        "%d min after sunset",
                        comment: "Schedule trigger: minutes after sunset"
                    ),
                    offset
                )
            } else {
                return String(
                    format: NSLocalizedString(
                        "%d min before sunset",
                        comment: "Schedule trigger: minutes before sunset"
                    ),
                    abs(offset)
                )
            }
        }
    }

    /// Whether this trigger requires location data
    var requiresLocation: Bool {
        switch self {
        case .fixedTime: return false
        case .sunrise, .sunset: return true
        }
    }
}

/// A scheduled preset application
struct DimmingSchedule: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var name: String
    var trigger: ScheduleTrigger
    /// References a BrightnessPreset by its ID
    var presetID: UUID
    var isEnabled: Bool
    var createdAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        trigger: ScheduleTrigger,
        presetID: UUID,
        isEnabled: Bool = true,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.trigger = trigger
        self.presetID = presetID
        self.isEnabled = isEnabled
        self.createdAt = createdAt
    }
}

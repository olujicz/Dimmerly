//
//  BrightnessPreset.swift
//  Dimmerly
//
//  Model representing a saved brightness configuration across displays.
//

import Foundation

struct BrightnessPreset: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var name: String
    /// Map of display ID (as String) to brightness value (0.0–1.0)
    var displayBrightness: [String: Double]
    var createdAt: Date
    /// Optional global keyboard shortcut to apply this preset
    var shortcut: GlobalShortcut?
    /// When set, applies this brightness to all connected displays (ignores displayBrightness)
    var universalBrightness: Double?
    /// Map of display ID (as String) to warmth value (0.0–1.0). Optional for backward compat.
    var displayWarmth: [String: Double]?
    /// When set, applies this warmth to all connected displays. Optional for backward compat.
    var universalWarmth: Double?
    /// Map of display ID (as String) to contrast value (0.0–1.0). Optional for backward compat.
    var displayContrast: [String: Double]?
    /// When set, applies this contrast to all connected displays. Optional for backward compat.
    var universalContrast: Double?

    init(
        id: UUID = UUID(),
        name: String,
        displayBrightness: [String: Double] = [:],
        createdAt: Date = Date(),
        shortcut: GlobalShortcut? = nil,
        universalBrightness: Double? = nil,
        displayWarmth: [String: Double]? = nil,
        universalWarmth: Double? = nil,
        displayContrast: [String: Double]? = nil,
        universalContrast: Double? = nil
    ) {
        self.id = id
        self.name = name
        self.displayBrightness = displayBrightness
        self.createdAt = createdAt
        self.shortcut = shortcut
        self.universalBrightness = universalBrightness
        self.displayWarmth = displayWarmth
        self.universalWarmth = universalWarmth
        self.displayContrast = displayContrast
        self.universalContrast = universalContrast
    }
}

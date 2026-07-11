//
//  PresetEntity.swift
//  Dimmerly
//
//  AppEntity representing a saved brightness preset for Shortcuts.app.
//

import AppIntents
import Foundation

struct PresetEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "Preset")
    }

    static let defaultQuery = PresetEntityQuery()

    var id: String
    var name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }
}

struct PresetEntityQuery: EntityQuery {
    @MainActor
    func entities(for identifiers: [String]) async throws -> [PresetEntity] {
        let manager = PresetManager.shared
        return identifiers.compactMap { id in
            guard let preset = manager.presets.first(where: { $0.id.uuidString == id }) else { return nil }
            return PresetEntity(id: id, name: preset.name)
        }
    }

    @MainActor
    func suggestedEntities() async throws -> [PresetEntity] {
        PresetManager.shared.presets.map { preset in
            PresetEntity(id: preset.id.uuidString, name: preset.name)
        }
    }
}

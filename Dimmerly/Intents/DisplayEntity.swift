//
//  DisplayEntity.swift
//  Dimmerly
//
//  AppEntity representing a connected external display for Shortcuts.app.
//

import AppIntents
import CoreGraphics

struct DisplayEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "Display")
    }

    static let defaultQuery = DisplayEntityQuery()

    var id: String
    var name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }

    init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

struct DisplayEntityQuery: EntityQuery {
    @MainActor
    func entities(for identifiers: [String]) async throws -> [DisplayEntity] {
        let manager = BrightnessManager.shared
        return identifiers.compactMap { id in
            guard let display = manager.displays.first(where: { String($0.id) == id }) else { return nil }
            return DisplayEntity(id: id, name: display.name)
        }
    }

    @MainActor
    func suggestedEntities() async throws -> [DisplayEntity] {
        BrightnessManager.shared.displays.map { display in
            DisplayEntity(id: String(display.id), name: display.name)
        }
    }
}

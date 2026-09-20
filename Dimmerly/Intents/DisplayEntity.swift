//
//  DisplayEntity.swift
//  Dimmerly
//
//  AppEntity representing a connected display for Shortcuts.app.
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
}

enum DisplayEntityIdentifier {
    private static let stablePrefix = "display:"

    static func isSafelyPersistable(_ identifier: String) -> Bool {
        identifier.hasPrefix(stablePrefix)
    }
}

enum DisplayEntityFactory {
    private static func uniquelyIdentifiedDescriptors(
        from descriptors: [ConnectedDisplayDescriptor]
    ) -> [ConnectedDisplayDescriptor] {
        let persistableDescriptors = descriptors.filter {
            DisplayEntityIdentifier.isSafelyPersistable($0.stableIdentity)
        }
        let groupedDescriptors = Dictionary(grouping: persistableDescriptors, by: \.stableIdentity)
        return persistableDescriptors.filter {
            groupedDescriptors[$0.stableIdentity]?.count == 1
        }
    }

    static func makeEntities(from descriptors: [ConnectedDisplayDescriptor]) -> [DisplayEntity] {
        uniquelyIdentifiedDescriptors(from: descriptors).map { descriptor in
            DisplayEntity(id: descriptor.stableIdentity, name: descriptor.name)
        }
    }

    static func makeEntities(
        for identifiers: [String],
        from descriptors: [ConnectedDisplayDescriptor]
    ) -> [DisplayEntity] {
        let uniqueDescriptors = uniquelyIdentifiedDescriptors(from: descriptors)
        return identifiers.compactMap { identifier in
            guard DisplayEntityIdentifier.isSafelyPersistable(identifier) else { return nil }
            guard let descriptor = uniqueDescriptors.first(where: { $0.stableIdentity == identifier })
            else {
                return nil
            }
            return DisplayEntity(id: identifier, name: descriptor.name)
        }
    }
}

struct DisplayEntityQuery: EntityQuery {
    #if compiler(>=6.4)
        @available(macOS 27.0, *)
        static let allowedExecutionTargets: IntentExecutionTargets = .main
    #endif

    @MainActor
    func entities(for identifiers: [String]) async throws -> [DisplayEntity] {
        let manager = BrightnessManager.shared
        let descriptors = manager.displays.map { display in
            ConnectedDisplayDescriptor(
                id: display.id,
                stableIdentity: BrightnessManager.stableDisplayIdentity(for: display.id),
                name: display.name
            )
        }
        return DisplayEntityFactory.makeEntities(for: identifiers, from: descriptors)
    }

    @MainActor
    func suggestedEntities() async throws -> [DisplayEntity] {
        let descriptors = BrightnessManager.shared.displays.map { display in
            ConnectedDisplayDescriptor(
                id: display.id,
                stableIdentity: BrightnessManager.stableDisplayIdentity(for: display.id),
                name: display.name
            )
        }
        return DisplayEntityFactory.makeEntities(from: descriptors)
    }
}

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
    /// Validates against the same constant `BrightnessManager` stamps onto every stable identity,
    /// so the generator and the validator cannot drift apart.
    static func isSafelyPersistable(_ identifier: String) -> Bool {
        identifier.hasPrefix(BrightnessManager.stableIdentityPrefix)
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
        // Every unique descriptor is persistable by construction, so matching one is itself
        // proof that `identifier` passed the prefix check.
        let uniqueDescriptors = uniquelyIdentifiedDescriptors(from: descriptors)
        return identifiers.compactMap { identifier in
            uniqueDescriptors.first { $0.stableIdentity == identifier }
                .map { DisplayEntity(id: identifier, name: $0.name) }
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
        DisplayEntityFactory.makeEntities(for: identifiers, from: ConnectedDisplayDescriptor.connected())
    }

    @MainActor
    func suggestedEntities() async throws -> [DisplayEntity] {
        DisplayEntityFactory.makeEntities(from: ConnectedDisplayDescriptor.connected())
    }
}

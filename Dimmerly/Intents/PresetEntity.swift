//
//  PresetEntity.swift
//  Dimmerly
//
//  AppEntity representing a saved brightness preset for Shortcuts.app.
//

import AppIntents
import CoreSpotlight
import Foundation
import OSLog
import UniformTypeIdentifiers

private let presetEntityIndexName = "rs.in.olujic.dimmerly.presets"

struct PresetEntity: IndexedEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "Preset")
    }

    static let defaultQuery = PresetEntityQuery()

    var id: String
    var name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }

    var attributeSet: CSSearchableItemAttributeSet {
        let attributes = CSSearchableItemAttributeSet(contentType: .item)
        attributes.title = name
        attributes.contentDescription = "Dimmerly display brightness preset"
        attributes.keywords = ["Dimmerly", "brightness", "display", name]
        return attributes
    }
}

struct PresetEntityQuery: EntityQuery {
    #if compiler(>=6.4)
        @available(macOS 27.0, *)
        static let allowedExecutionTargets: IntentExecutionTargets = .main
    #endif

    @MainActor
    func entities(for identifiers: [String]) async throws -> [PresetEntity] {
        makePresetEntities(for: identifiers)
    }

    @MainActor
    func suggestedEntities() async throws -> [PresetEntity] {
        makePresetEntities()
    }

    @MainActor
    private func makePresetEntities(for identifiers: [String]? = nil) -> [PresetEntity] {
        let presets = PresetManager.shared.presets
        guard let identifiers else {
            return presets.map { preset in
                PresetEntity(id: preset.id.uuidString, name: preset.name)
            }
        }

        return identifiers.compactMap { id in
            guard let preset = presets.first(where: { $0.id.uuidString == id }) else { return nil }
            return PresetEntity(id: id, name: preset.name)
        }
    }
}

@MainActor
protocol PresetEntityIndexingClient: AnyObject {
    func deleteAll() async throws
    func index(_ entities: [PresetEntity]) async throws
}

private final class SearchableIndexAcknowledgement: @unchecked Sendable {
    private let handler: () -> Void

    init(_ handler: @escaping () -> Void) {
        self.handler = handler
    }

    func call() {
        handler()
    }
}

@MainActor
final class CSSearchablePresetEntityIndexingClient: NSObject, PresetEntityIndexingClient, CSSearchableIndexDelegate {
    let searchableIndex: CSSearchableIndex

    override init() {
        searchableIndex = CSSearchableIndex(name: presetEntityIndexName)
        super.init()
        searchableIndex.indexDelegate = self
    }

    func deleteAll() async throws {
        try await CSSearchableIndex(name: presetEntityIndexName).deleteAppEntities(ofType: PresetEntity.self)
    }

    func index(_ entities: [PresetEntity]) async throws {
        try await CSSearchableIndex(name: presetEntityIndexName).indexAppEntities(entities)
    }

    nonisolated func searchableIndex(
        _: CSSearchableIndex,
        reindexAllSearchableItemsWithAcknowledgementHandler acknowledgementHandler: @escaping () -> Void
    ) {
        let acknowledgement = SearchableIndexAcknowledgement(acknowledgementHandler)
        Task { @MainActor [weak self, acknowledgement] in
            defer { acknowledgement.call() }
            do {
                try await self?.reindexAll()
            } catch {
                presetEntityIndexLogger.error("Failed to recover all preset entities: \(error.localizedDescription)")
            }
        }
    }

    nonisolated func searchableIndex(
        _: CSSearchableIndex,
        reindexSearchableItemsWithIdentifiers identifiers: [String],
        acknowledgementHandler: @escaping () -> Void
    ) {
        let acknowledgement = SearchableIndexAcknowledgement(acknowledgementHandler)
        Task { @MainActor [weak self, acknowledgement] in
            defer { acknowledgement.call() }
            do {
                try await self?.reindex(identifiers: identifiers)
            } catch {
                presetEntityIndexLogger.error("Failed to recover preset entities: \(error.localizedDescription)")
            }
        }
    }

    private func reindexAll() async throws {
        let entities = try await PresetEntityQuery().suggestedEntities()
        try await deleteAll()
        try await index(entities)
    }

    private func reindex(identifiers: [String]) async throws {
        let entities = try await PresetEntityQuery().entities(for: identifiers)
        let foundIdentifiers = Set(entities.map(\.id))
        let missingIdentifiers = identifiers.filter { !foundIdentifiers.contains($0) }

        if !missingIdentifiers.isEmpty {
            try await CSSearchableIndex(name: presetEntityIndexName)
                .deleteSearchableItems(withIdentifiers: missingIdentifiers)
        }
        if !entities.isEmpty {
            try await index(entities)
        }
    }
}

#if compiler(>=6.4)
    @available(macOS 27.0, *)
    extension PresetEntityQuery: IndexedEntityQuery {
        func reindexEntities(
            for identifiers: [PresetEntity.ID],
            indexDescription _: CSSearchableIndexDescription
        ) async throws {
            let entities = await MainActor.run {
                makePresetEntities(for: identifiers)
            }
            try await CSSearchableIndex(name: presetEntityIndexName).indexAppEntities(entities)
        }

        func reindexAllEntities(indexDescription _: CSSearchableIndexDescription) async throws {
            let entities = await MainActor.run {
                makePresetEntities()
            }
            try await CSSearchableIndex(name: presetEntityIndexName).indexAppEntities(entities)
        }
    }
#endif

private let presetEntityIndexLogger = Logger(
    subsystem: "rs.in.olujic.dimmerly",
    category: "PresetEntityIndex"
)

@MainActor
final class AppEntityIndexingService {
    private static let maxIndexingAttempts = 3
    private static let indexingRetryDelayNanoseconds: UInt64 = 250_000_000

    static let shared = AppEntityIndexingService()

    private let indexClient: any PresetEntityIndexingClient
    private var pendingPresets: [BrightnessPreset]?
    private var indexingTask: Task<Void, Never>?

    init(indexClient: any PresetEntityIndexingClient = CSSearchablePresetEntityIndexingClient()) {
        self.indexClient = indexClient
    }

    func reindexPresets(_ presets: [BrightnessPreset]) {
        pendingPresets = presets
        guard indexingTask == nil else { return }

        indexingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { indexingTask = nil }

            while let presets = pendingPresets {
                pendingPresets = nil
                let entities = presets.map { preset in
                    PresetEntity(id: preset.id.uuidString, name: preset.name)
                }

                do {
                    try await indexSnapshot(entities)
                } catch is CancellationError {
                    return
                } catch {
                    presetEntityIndexLogger.error("Failed to index presets: \(error.localizedDescription)")
                }
            }
        }
    }

    private func indexSnapshot(_ entities: [PresetEntity]) async throws {
        for attempt in 1 ... Self.maxIndexingAttempts {
            do {
                try await indexClient.deleteAll()
                try await indexClient.index(entities)
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                guard attempt < Self.maxIndexingAttempts else { throw error }
                try await Task.sleep(nanoseconds: Self.indexingRetryDelayNanoseconds)
            }
        }
    }
}

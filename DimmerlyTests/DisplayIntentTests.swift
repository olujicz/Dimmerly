//
//  DisplayIntentTests.swift
//  DimmerlyTests
//

import AppIntents
import CoreGraphics
import CoreSpotlight
@testable import Dimmerly
import XCTest

@MainActor
final class DisplayIntentTests: XCTestCase {
    func testStableResolverRejectsMalformedAndDisconnectedIdentifiers() {
        XCTAssertThrowsError(try ConnectedDisplayResolver.resolve(
            DisplayEntity(id: "not-a-display", name: "Invalid"),
            connectedDescriptors: {
                [ConnectedDisplayDescriptor(id: 42, stableIdentity: "display:v123m456s789", name: "External")]
            }
        ))
        XCTAssertThrowsError(try ConnectedDisplayResolver.resolve(
            DisplayEntity(id: "display:v123m456s999", name: "Disconnected"),
            connectedDescriptors: {
                [ConnectedDisplayDescriptor(id: 42, stableIdentity: "display:v123m456s789", name: "External")]
            }
        ))
    }

    func testStableResolverMapsPersistedIdentityToAChangedNumericID() throws {
        let entity = DisplayEntity(id: "display:v123m456s789", name: "External")
        let resolved = try ConnectedDisplayResolver.resolve(entity) {
            [ConnectedDisplayDescriptor(id: 77, stableIdentity: "display:v123m456s789", name: "External")]
        }

        XCTAssertEqual(resolved, 77)
    }

    func testStableResolverRejectsLegacyNumericIDAfterDisplayIDReuse() {
        let entity = DisplayEntity(id: "42", name: "Former Display")
        XCTAssertThrowsError(try ConnectedDisplayResolver.resolve(entity) {
            [ConnectedDisplayDescriptor(id: 42, stableIdentity: "display:v123m456s789", name: "Different")]
        })
    }

    func testStableResolverRejectsNumericIdentifierEvenWhenDescriptorMatches() {
        let entity = DisplayEntity(id: "42", name: "Former Display")

        XCTAssertThrowsError(try ConnectedDisplayResolver.resolve(entity) {
            [ConnectedDisplayDescriptor(id: 42, stableIdentity: "42", name: "Reused Display")]
        })
    }

    func testDisplayEntityIdentifierOnlyAcceptsStableDescriptors() {
        XCTAssertTrue(DisplayEntityIdentifier.isSafelyPersistable("display:v123m456s789"))
        XCTAssertFalse(DisplayEntityIdentifier.isSafelyPersistable("legacy:42"))
        XCTAssertFalse(DisplayEntityIdentifier.isSafelyPersistable("42"))
    }

    func testDisplayEntityFactoryFiltersUnstableSuggestedEntities() throws {
        let stableIdentity = try XCTUnwrap(BrightnessManager.stableDisplayIdentity(
            vendor: 123,
            model: 456,
            serial: 789,
            unitNumber: 1
        ))
        let entities = DisplayEntityFactory.makeEntities(from: [
            ConnectedDisplayDescriptor(id: 42, stableIdentity: stableIdentity, name: "Stable"),
            ConnectedDisplayDescriptor(id: 43, stableIdentity: "43", name: "Legacy"),
        ])

        XCTAssertEqual(entities.map(\.id), [stableIdentity])
        XCTAssertEqual(entities.map(\.name), ["Stable"])
    }

    func testDisplayEntityFactoryFiltersUnstableEntityIdentifiers() throws {
        let stableIdentity = try XCTUnwrap(BrightnessManager.stableDisplayIdentity(
            vendor: 123,
            model: 456,
            serial: 789,
            unitNumber: 1
        ))
        let descriptors = [
            ConnectedDisplayDescriptor(id: 42, stableIdentity: stableIdentity, name: "Stable"),
            ConnectedDisplayDescriptor(id: 43, stableIdentity: "43", name: "Legacy"),
        ]

        let entities = DisplayEntityFactory.makeEntities(
            for: [stableIdentity, "43"],
            from: descriptors
        )

        XCTAssertEqual(entities.map(\.id), [stableIdentity])
        XCTAssertEqual(entities.map(\.name), ["Stable"])
    }

    func testDisplayEntityFactoryFiltersDuplicateStableSuggestedEntities() throws {
        let stableIdentity = try XCTUnwrap(BrightnessManager.stableDisplayIdentity(
            vendor: 123,
            model: 456,
            serial: 789,
            unitNumber: 1
        ))
        let entities = DisplayEntityFactory.makeEntities(from: [
            ConnectedDisplayDescriptor(id: 42, stableIdentity: stableIdentity, name: "First"),
            ConnectedDisplayDescriptor(id: 43, stableIdentity: stableIdentity, name: "Second"),
        ])

        XCTAssertTrue(entities.isEmpty)
    }

    func testDisplayEntityFactoryFiltersDuplicateStableEntityIdentifiers() throws {
        let stableIdentity = try XCTUnwrap(BrightnessManager.stableDisplayIdentity(
            vendor: 123,
            model: 456,
            serial: 789,
            unitNumber: 1
        ))
        let descriptors = [
            ConnectedDisplayDescriptor(id: 42, stableIdentity: stableIdentity, name: "First"),
            ConnectedDisplayDescriptor(id: 43, stableIdentity: stableIdentity, name: "Second"),
        ]

        let entities = DisplayEntityFactory.makeEntities(for: [stableIdentity], from: descriptors)

        XCTAssertTrue(entities.isEmpty)
    }

    func testStableResolverRejectsDuplicateStableIdentity() {
        let entity = DisplayEntity(id: "display:v123m456s789", name: "Duplicate")
        XCTAssertThrowsError(try ConnectedDisplayResolver.resolve(entity) {
            [
                ConnectedDisplayDescriptor(id: 7, stableIdentity: entity.id, name: "A"),
                ConnectedDisplayDescriptor(id: 8, stableIdentity: entity.id, name: "B"),
            ]
        })
    }

    func testDisplayIntentsExecuteAgainstConnectedDisplay() throws {
        let entity = DisplayEntity(id: "display:v123m456s789", name: "External")
        let command = DisplayIntentCommandSpy(
            connectedDisplayDescriptors: [
                ConnectedDisplayDescriptor(id: 42, stableIdentity: entity.id, name: entity.name),
            ]
        )

        let brightnessIntent = SetDisplayBrightnessIntent()
        brightnessIntent.display = entity
        brightnessIntent.brightness = 35
        try brightnessIntent.perform(using: command)

        let warmthIntent = SetDisplayWarmthIntent()
        warmthIntent.display = entity
        warmthIntent.warmth = 60
        try warmthIntent.perform(using: command)

        let contrastIntent = SetDisplayContrastIntent()
        contrastIntent.display = entity
        contrastIntent.contrast = 45
        try contrastIntent.perform(using: command)

        let dimIntent = ToggleDimIntent()
        dimIntent.display = entity
        try dimIntent.perform(using: command)

        XCTAssertEqual(command.brightnessCalls, [.init(value: 0.35, displayID: 42)])
        XCTAssertEqual(command.warmthCalls, [.init(value: 0.6, displayID: 42)])
        XCTAssertEqual(command.contrastCalls, [.init(value: 0.45, displayID: 42)])
        XCTAssertEqual(command.dimCalls, [42])
    }

    func testStaleDimIntentFailsWithoutInvokingCommand() {
        let command = DisplayIntentCommandSpy(connectedDisplayDescriptors: [])
        let intent = ToggleDimIntent()
        intent.display = DisplayEntity(id: "42", name: "Former Display")

        XCTAssertThrowsError(try intent.perform(using: command))
        XCTAssertTrue(command.dimCalls.isEmpty)
    }

    func testBrightnessIntentAcceptsSharedRangeBoundaries() throws {
        let entity = DisplayEntity(id: "display:v123m456s789", name: "External")
        let command = DisplayIntentCommandSpy(
            connectedDisplayDescriptors: [
                ConnectedDisplayDescriptor(id: 42, stableIdentity: entity.id, name: entity.name),
            ]
        )
        let intent = SetDisplayBrightnessIntent()
        intent.display = entity

        intent.brightness = 10
        try intent.perform(using: command)
        intent.brightness = 100
        try intent.perform(using: command)

        XCTAssertEqual(command.brightnessCalls.map(\.value), [0.1, 1.0])
    }

    func testBrightnessIntentRejectsValuesOutsideSharedRange() throws {
        let stableIdentity = try XCTUnwrap(BrightnessManager.stableDisplayIdentity(
            vendor: 123,
            model: 456,
            serial: 789,
            unitNumber: 1
        ))
        let command = DisplayIntentCommandSpy(connectedDisplayDescriptors: [
            ConnectedDisplayDescriptor(id: 42, stableIdentity: stableIdentity, name: "External"),
        ])
        let intent = SetDisplayBrightnessIntent()
        intent.display = DisplayEntity(id: stableIdentity, name: "External")

        intent.brightness = 9
        XCTAssertThrowsError(try intent.perform(using: command)) { error in
            guard case .brightnessOutOfRange = error as? DisplayIntentError else {
                return XCTFail("Expected brightnessOutOfRange, got \(error)")
            }
        }
        intent.brightness = 101
        XCTAssertThrowsError(try intent.perform(using: command)) { error in
            guard case .brightnessOutOfRange = error as? DisplayIntentError else {
                return XCTFail("Expected brightnessOutOfRange, got \(error)")
            }
        }

        XCTAssertTrue(command.brightnessCalls.isEmpty)
    }

    func testContrastIntentRejectsValuesOutsideSharedRange() {
        let command = DisplayIntentCommandSpy(connectedDisplayDescriptors: [])
        let intent = SetDisplayContrastIntent()
        intent.display = DisplayEntity(id: "42", name: "External")

        for value in [-1.0, 101.0] {
            intent.contrast = value
            XCTAssertThrowsError(try intent.perform(using: command)) { error in
                guard case .contrastOutOfRange = error as? DisplayIntentError else {
                    return XCTFail("Expected contrastOutOfRange, got \(error)")
                }
            }
        }

        XCTAssertTrue(command.contrastCalls.isEmpty)
    }

    func testContrastIntentAcceptsSharedRangeBoundaries() throws {
        let entity = DisplayEntity(id: "display:v123m456s789", name: "External")
        let command = DisplayIntentCommandSpy(
            connectedDisplayDescriptors: [
                ConnectedDisplayDescriptor(id: 42, stableIdentity: entity.id, name: entity.name),
            ]
        )
        let intent = SetDisplayContrastIntent()
        intent.display = entity

        intent.contrast = 0
        try intent.perform(using: command)
        intent.contrast = 100
        try intent.perform(using: command)

        XCTAssertEqual(command.contrastCalls.map(\.value), [0.0, 1.0])
    }

    func testWarmthIntentRejectsValuesOutsideSharedRange() {
        let command = DisplayIntentCommandSpy(connectedDisplayDescriptors: [])
        let intent = SetDisplayWarmthIntent()
        intent.display = DisplayEntity(id: "42", name: "External")

        for value in [-1.0, 101.0] {
            intent.warmth = value
            XCTAssertThrowsError(try intent.perform(using: command)) { error in
                guard case .warmthOutOfRange = error as? DisplayIntentError else {
                    return XCTFail("Expected warmthOutOfRange, got \(error)")
                }
            }
        }

        XCTAssertTrue(command.warmthCalls.isEmpty)
    }

    func testWarmthIntentAcceptsSharedRangeBoundaries() throws {
        let entity = DisplayEntity(id: "display:v123m456s789", name: "External")
        let command = DisplayIntentCommandSpy(
            connectedDisplayDescriptors: [
                ConnectedDisplayDescriptor(id: 42, stableIdentity: entity.id, name: entity.name),
            ]
        )
        let intent = SetDisplayWarmthIntent()
        intent.display = entity

        intent.warmth = 0
        try intent.perform(using: command)
        intent.warmth = 100
        try intent.perform(using: command)

        XCTAssertEqual(command.warmthCalls.map(\.value), [0.0, 1.0])
    }

    func testPresetEntityPublishesSpotlightAttributes() {
        let entity = PresetEntity(id: "preset-1", name: "Evening")
        let attributes = entity.attributeSet

        XCTAssertEqual(attributes.title, "Evening")
        XCTAssertEqual(attributes.contentDescription, "Dimmerly display brightness preset")
        XCTAssertTrue(attributes.keywords?.contains("brightness") == true)
    }

    func testOpenPresetIntentTargetsPresetEntities() {
        let intent: any OpenIntent = OpenPresetIntent()

        XCTAssertTrue(intent is OpenPresetIntent)
    }

    func testOpenPresetIntentPresentsSelectedPreset() throws {
        let fixture = IsolatedPresetManagerFixture()
        defer { fixture.cleanup() }
        let presetManager = fixture.manager
        let preset = BrightnessPreset(name: "Evening")
        presetManager.presets = [preset]
        let coordinator = MenuBarPanelCoordinator()
        var presentedPresetID: UUID?
        var didActivateApp = false
        coordinator.configureExternalPresentation(
            present: { presentedPresetID = $0 },
            dismiss: {}
        )
        let intent = OpenPresetIntent()
        intent.target = PresetEntity(id: preset.id.uuidString, name: preset.name)

        try intent.perform(
            using: presetManager,
            coordinator: coordinator,
            activateApp: { didActivateApp = true },
            presentationPath: .publicPopover
        )

        XCTAssertFalse(coordinator.isPresented)
        XCTAssertTrue(coordinator.isExternalPresentationActive)
        XCTAssertEqual(coordinator.requestedPresetID, preset.id)
        XCTAssertEqual(presentedPresetID, preset.id)
        XCTAssertTrue(didActivateApp)
    }

    func testSpotlightIndexingClientRegistersRecoveryDelegate() {
        let client = CSSearchablePresetEntityIndexingClient()

        XCTAssertTrue(client.searchableIndex.indexDelegate === client)
    }

    func testPresetIndexingCoalescesRapidUpdates() async {
        let client = PresetEntityIndexingClientSpy()
        let indexed = expectation(description: "latest preset snapshot indexed")
        client.indexedExpectation = indexed
        let service = AppEntityIndexingService(indexClient: client)

        service.reindexPresets([BrightnessPreset(name: "Initial")])
        service.reindexPresets([BrightnessPreset(name: "Latest")])

        await fulfillment(of: [indexed], timeout: 1.0)

        XCTAssertEqual(client.indexedSnapshots, [["Latest"]])
        XCTAssertEqual(client.deleteCount, 1)
    }

    func testPresetIndexingRetriesAfterTransientIndexFailure() async {
        let client = PresetEntityIndexingClientSpy()
        let indexed = expectation(description: "preset snapshot indexed after retry")
        client.indexedExpectation = indexed
        client.indexFailuresRemaining = 1
        let service = AppEntityIndexingService(indexClient: client)

        service.reindexPresets([BrightnessPreset(name: "Latest")])

        await fulfillment(of: [indexed], timeout: 2.0)

        XCTAssertEqual(client.indexedSnapshots, [["Latest"]])
        XCTAssertEqual(client.deleteCount, 2)
        XCTAssertEqual(client.indexAttempts, 2)
    }
}

@MainActor
private final class DisplayIntentCommandSpy: DisplayIntentCommanding {
    struct ValueCall: Equatable {
        let value: Double
        let displayID: CGDirectDisplayID
    }

    var connectedDisplayDescriptors: [ConnectedDisplayDescriptor]
    private(set) var brightnessCalls: [ValueCall] = []
    private(set) var warmthCalls: [ValueCall] = []
    private(set) var contrastCalls: [ValueCall] = []
    private(set) var dimCalls: [CGDirectDisplayID] = []

    init(
        connectedDisplayDescriptors: [ConnectedDisplayDescriptor]
    ) {
        self.connectedDisplayDescriptors = connectedDisplayDescriptors
    }

    func setBrightness(_ value: Double, for displayID: CGDirectDisplayID) {
        brightnessCalls.append(.init(value: value, displayID: displayID))
    }

    func setWarmth(_ value: Double, for displayID: CGDirectDisplayID) {
        warmthCalls.append(.init(value: value, displayID: displayID))
    }

    func setContrast(_ value: Double, for displayID: CGDirectDisplayID) {
        contrastCalls.append(.init(value: value, displayID: displayID))
    }

    func toggleDim(for displayID: CGDirectDisplayID) {
        dimCalls.append(displayID)
    }
}

@MainActor
private final class PresetEntityIndexingClientSpy: PresetEntityIndexingClient {
    private(set) var deleteCount = 0
    private(set) var indexAttempts = 0
    private(set) var indexedSnapshots: [[String]] = []
    var indexedExpectation: XCTestExpectation?
    var indexFailuresRemaining = 0

    func deleteAll() async throws {
        deleteCount += 1
    }

    func index(_ entities: [PresetEntity]) async throws {
        indexAttempts += 1
        if indexFailuresRemaining > 0 {
            indexFailuresRemaining -= 1
            throw PresetEntityIndexingClientSpyError.transient
        }
        indexedSnapshots.append(entities.map(\.name))
        indexedExpectation?.fulfill()
    }
}

private enum PresetEntityIndexingClientSpyError: Error {
    case transient
}

//
//  DisplayIntentTests.swift
//  DimmerlyTests
//

import CoreGraphics
@testable import Dimmerly
import XCTest

@MainActor
final class DisplayIntentTests: XCTestCase {
    func testResolverRejectsMalformedAndDisconnectedIdentifiers() {
        XCTAssertThrowsError(try ConnectedDisplayResolver.resolve(
            DisplayEntity(id: "not-a-display", name: "Invalid"),
            connectedIDs: { [42] }
        ))
        XCTAssertThrowsError(try ConnectedDisplayResolver.resolve(
            DisplayEntity(id: "42", name: "Disconnected"),
            connectedIDs: { [7] }
        ))
    }

    func testResolverReturnsConnectedDisplay() throws {
        let resolved = try ConnectedDisplayResolver.resolve(
            DisplayEntity(id: "42", name: "Connected"),
            connectedIDs: { [7, 42] }
        )

        XCTAssertEqual(resolved, 42)
    }

    func testDisplayIntentsExecuteAgainstConnectedDisplay() throws {
        let command = DisplayIntentCommandSpy(connectedDisplayIDs: [42])
        let entity = DisplayEntity(id: "42", name: "External")

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
        let command = DisplayIntentCommandSpy(connectedDisplayIDs: [])
        let intent = ToggleDimIntent()
        intent.display = DisplayEntity(id: "42", name: "Former Display")

        XCTAssertThrowsError(try intent.perform(using: command))
        XCTAssertTrue(command.dimCalls.isEmpty)
    }

    func testBrightnessIntentAcceptsSharedRangeBoundaries() throws {
        let command = DisplayIntentCommandSpy(connectedDisplayIDs: [42])
        let intent = SetDisplayBrightnessIntent()
        intent.display = DisplayEntity(id: "42", name: "External")

        intent.brightness = 10
        try intent.perform(using: command)
        intent.brightness = 100
        try intent.perform(using: command)

        XCTAssertEqual(command.brightnessCalls.map(\.value), [0.1, 1.0])
    }

    func testBrightnessIntentRejectsValuesOutsideSharedRange() {
        let command = DisplayIntentCommandSpy(connectedDisplayIDs: [42])
        let intent = SetDisplayBrightnessIntent()
        intent.display = DisplayEntity(id: "42", name: "External")

        intent.brightness = 9
        XCTAssertThrowsError(try intent.perform(using: command))
        intent.brightness = 101
        XCTAssertThrowsError(try intent.perform(using: command))

        XCTAssertTrue(command.brightnessCalls.isEmpty)
    }
}

@MainActor
private final class DisplayIntentCommandSpy: DisplayIntentCommanding {
    struct ValueCall: Equatable {
        let value: Double
        let displayID: CGDirectDisplayID
    }

    var connectedDisplayIDs: [CGDirectDisplayID]
    private(set) var brightnessCalls: [ValueCall] = []
    private(set) var warmthCalls: [ValueCall] = []
    private(set) var contrastCalls: [ValueCall] = []
    private(set) var dimCalls: [CGDirectDisplayID] = []

    init(connectedDisplayIDs: [CGDirectDisplayID]) {
        self.connectedDisplayIDs = connectedDisplayIDs
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

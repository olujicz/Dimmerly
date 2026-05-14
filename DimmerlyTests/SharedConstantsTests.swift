//
//  SharedConstantsTests.swift
//  DimmerlyTests
//
//  Unit tests for shared app-group resolution.
//

@testable import Dimmerly
import XCTest

final class SharedConstantsTests: XCTestCase {
    private var defaultsSuiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaultsSuiteName = "SharedConstantsTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuiteName)!
        defaults.removePersistentDomain(forName: defaultsSuiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        defaults = nil
        defaultsSuiteName = nil
        super.tearDown()
    }

    func testResolvedAppGroupIDUsesProvidedTeamPrefix() {
        XCTAssertEqual(
            SharedConstants.resolvedAppGroupID(
                teamIdentifierPrefix: "TEAM123.",
                bundleIdentifier: "rs.in.olujic.dimmerly"
            ),
            "TEAM123.rs.in.olujic.dimmerly"
        )
    }

    func testResolvedAppGroupIDAvoidsDoubleDot() {
        XCTAssertEqual(
            SharedConstants.resolvedAppGroupID(
                teamIdentifierPrefix: "TEAM123",
                bundleIdentifier: "rs.in.olujic.dimmerly"
            ),
            "TEAM123.rs.in.olujic.dimmerly"
        )
    }

    func testConsumeWidgetDimCommandReturnsTrueOnceAndClearsCommand() {
        SharedConstants.storeWidgetDimCommand(in: defaults)

        XCTAssertTrue(SharedConstants.consumeWidgetDimCommand(from: defaults))
        XCTAssertFalse(SharedConstants.consumeWidgetDimCommand(from: defaults))
    }

    func testConsumeWidgetPresetCommandReturnsUUIDOnceAndClearsCommand() {
        let id = UUID()
        SharedConstants.storeWidgetPresetCommand(id.uuidString, in: defaults)

        XCTAssertEqual(SharedConstants.consumeWidgetPresetCommand(from: defaults), id)
        XCTAssertNil(SharedConstants.consumeWidgetPresetCommand(from: defaults))
    }

    func testConsumeWidgetPresetCommandClearsInvalidCommand() {
        SharedConstants.storeWidgetPresetCommand("not-a-uuid", in: defaults)

        XCTAssertNil(SharedConstants.consumeWidgetPresetCommand(from: defaults))
        XCTAssertNil(defaults.string(forKey: SharedConstants.widgetPresetCommandKey))
    }
}

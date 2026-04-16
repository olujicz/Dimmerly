//
//  SharedConstantsTests.swift
//  DimmerlyTests
//
//  Unit tests for shared app-group resolution.
//

@testable import Dimmerly
import XCTest

final class SharedConstantsTests: XCTestCase {
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
}

//
//  DisplayNameResolverTests.swift
//  DimmerlyTests
//
//  Unit tests for display-name build configuration behavior.
//

@testable import Dimmerly
import XCTest

final class DisplayNameResolverTests: XCTestCase {
    func testIOKitFallbackAvailabilityMatchesBuildConfiguration() {
        #if APPSTORE
            XCTAssertFalse(DisplayNameResolver.usesIOKitFallbacks)
        #else
            XCTAssertTrue(DisplayNameResolver.usesIOKitFallbacks)
        #endif
    }
}

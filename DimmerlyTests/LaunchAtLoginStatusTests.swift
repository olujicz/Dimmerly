//
//  LaunchAtLoginStatusTests.swift
//  DimmerlyTests
//
//  Unit tests for how Service Management login item states are presented.
//

@testable import Dimmerly
import ServiceManagement
import XCTest

final class LaunchAtLoginStatusTests: XCTestCase {
    func testMapsServiceManagementStatuses() {
        XCTAssertEqual(LaunchAtLoginStatus(.enabled), .enabled)
        XCTAssertEqual(LaunchAtLoginStatus(.requiresApproval), .requiresApproval)
        XCTAssertEqual(LaunchAtLoginStatus(.notRegistered), .disabled)
        XCTAssertEqual(LaunchAtLoginStatus(.notFound), .disabled)
    }

    func testPendingApprovalStillCountsAsRequested() {
        XCTAssertTrue(LaunchAtLoginStatus.enabled.isRequested)
        XCTAssertTrue(LaunchAtLoginStatus.requiresApproval.isRequested)
        XCTAssertFalse(LaunchAtLoginStatus.disabled.isRequested)
    }
}

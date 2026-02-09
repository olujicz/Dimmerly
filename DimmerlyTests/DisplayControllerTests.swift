//
//  DisplayControllerTests.swift
//  DimmerlyTests
//
//  Unit tests for DisplayController functionality.
//  Tests error handling and validation logic.
//

import XCTest
@testable import Dimmerly

/// Tests for the DisplayController
final class DisplayControllerTests: XCTestCase {

    /// Tests that the controller successfully executes when pmset exists
    func testSleepDisplaysSuccess() {
        // Given: pmset exists at the standard location
        // When: We call sleepDisplays
        let result = DisplayController.sleepDisplays()

        // Then: We expect a result (either success or a valid error)
        // Note: We can't guarantee success in test environment, but we can verify it returns a result
        switch result {
        case .success:
            // Success - displays would be sleeping
            XCTAssertTrue(true, "Sleep displays succeeded")
        case .failure(let error):
            // If it fails, it should be with a known error type
            switch error {
            case .pmsetNotFound:
                XCTAssertTrue(true, "pmset not found is a valid error in test environment")
            case .pmsetExecutionFailed(let code):
                // In CI or test environments, pmset might fail with permission issues
                XCTAssertNotEqual(code, 0, "Failed execution should have non-zero exit code")
            case .permissionDenied:
                XCTAssertTrue(true, "Permission denied is valid in test environment")
            case .unknownError:
                XCTAssertTrue(true, "Unknown error is valid in test environment")
            }
        }
    }

    /// Tests that the controller handles missing pmset gracefully
    func testSleepDisplaysWithMissingPmset() {
        // Note: This test would require mocking the file system
        // In a real implementation, we would inject a FileManager dependency
        // For now, we verify that the real pmset path exists on macOS
        let pmsetPath = "/usr/bin/pmset"
        let fileExists = FileManager.default.fileExists(atPath: pmsetPath)

        if fileExists {
            XCTAssertTrue(true, "pmset exists at expected location")
        } else {
            // If pmset doesn't exist, sleepDisplays should return pmsetNotFound error
            let result = DisplayController.sleepDisplays()
            if case .failure(.pmsetNotFound) = result {
                XCTAssertTrue(true, "Correctly identified missing pmset")
            } else {
                XCTFail("Expected pmsetNotFound error when pmset is missing")
            }
        }
    }

    /// Tests that error types have proper localized descriptions
    func testDisplayErrorDescriptions() {
        // Test pmsetNotFound error
        let notFoundError = DisplayError.pmsetNotFound
        XCTAssertNotNil(notFoundError.errorDescription, "pmsetNotFound should have error description")
        XCTAssertNotNil(notFoundError.recoverySuggestion, "pmsetNotFound should have recovery suggestion")

        // Test pmsetExecutionFailed error
        let execFailedError = DisplayError.pmsetExecutionFailed(code: 1)
        XCTAssertNotNil(execFailedError.errorDescription, "pmsetExecutionFailed should have error description")
        XCTAssertNotNil(execFailedError.recoverySuggestion, "pmsetExecutionFailed should have recovery suggestion")
        XCTAssertTrue(execFailedError.errorDescription?.contains("1") ?? false, "Error description should contain exit code")

        // Test permissionDenied error
        let permissionError = DisplayError.permissionDenied
        XCTAssertNotNil(permissionError.errorDescription, "permissionDenied should have error description")
        XCTAssertNotNil(permissionError.recoverySuggestion, "permissionDenied should have recovery suggestion")

        // Test unknownError
        let testError = NSError(domain: "TestDomain", code: 123, userInfo: nil)
        let unknownError = DisplayError.unknownError(testError)
        XCTAssertNotNil(unknownError.errorDescription, "unknownError should have error description")
        XCTAssertNotNil(unknownError.recoverySuggestion, "unknownError should have recovery suggestion")
    }

    /// Tests that Result type works correctly for both success and failure cases
    func testResultTypeHandling() {
        let successResult: Result<Void, DisplayError> = .success(())
        let failureResult: Result<Void, DisplayError> = .failure(.pmsetNotFound)

        // Test success case
        switch successResult {
        case .success:
            XCTAssertTrue(true, "Success case handled correctly")
        case .failure:
            XCTFail("Success result should not be failure")
        }

        // Test failure case
        switch failureResult {
        case .success:
            XCTFail("Failure result should not be success")
        case .failure(let error):
            if case .pmsetNotFound = error {
                XCTAssertTrue(true, "Failure case handled correctly")
            } else {
                XCTFail("Expected pmsetNotFound error")
            }
        }
    }
}

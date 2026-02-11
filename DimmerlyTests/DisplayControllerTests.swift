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

    override func tearDown() {
        DisplayController.processRunner = nil
        super.tearDown()
    }

    /// Tests that a successful sleep returns .success
    func testSleepDisplaysSuccess() async {
        DisplayController.processRunner = { .success(()) }

        let result = await DisplayController.sleepDisplays()

        switch result {
        case .success:
            break // expected
        case .failure(let error):
            XCTFail("Expected success, got \(error)")
        }
    }

    /// Tests that pmsetNotFound is returned when pmset is missing
    func testSleepDisplaysPmsetNotFound() async {
        DisplayController.processRunner = { .failure(.pmsetNotFound) }

        let result = await DisplayController.sleepDisplays()

        if case .failure(.pmsetNotFound) = result {
            // expected
        } else {
            XCTFail("Expected pmsetNotFound failure")
        }
    }

    /// Tests that pmsetFailed propagates the exit status
    func testSleepDisplaysPmsetFailed() async {
        DisplayController.processRunner = { .failure(.pmsetFailed(status: 42)) }

        let result = await DisplayController.sleepDisplays()

        if case .failure(.pmsetFailed(let status)) = result {
            XCTAssertEqual(status, 42)
        } else {
            XCTFail("Expected pmsetFailed failure")
        }
    }

    /// Tests that error types have proper localized descriptions
    func testDisplayErrorDescriptions() {
        // Test pmsetNotFound error
        let pmsetNotFoundError = DisplayError.pmsetNotFound
        XCTAssertNotNil(pmsetNotFoundError.errorDescription, "pmsetNotFound should have error description")
        XCTAssertNotNil(pmsetNotFoundError.recoverySuggestion, "pmsetNotFound should have recovery suggestion")

        // Test pmsetFailed error
        let pmsetFailedError = DisplayError.pmsetFailed(status: 1)
        XCTAssertNotNil(pmsetFailedError.errorDescription, "pmsetFailed should have error description")
        XCTAssertNotNil(pmsetFailedError.recoverySuggestion, "pmsetFailed should have recovery suggestion")
        XCTAssertTrue(pmsetFailedError.errorDescription?.contains("1") ?? false, "Error description should contain exit status")

        // Test permissionDenied error
        let permissionError = DisplayError.permissionDenied
        XCTAssertNotNil(permissionError.errorDescription, "permissionDenied should have error description")
        XCTAssertNotNil(permissionError.recoverySuggestion, "permissionDenied should have recovery suggestion")

        // Test unknownError
        let unknownError = DisplayError.unknownError("Test error message")
        XCTAssertNotNil(unknownError.errorDescription, "unknownError should have error description")
        XCTAssertNotNil(unknownError.recoverySuggestion, "unknownError should have recovery suggestion")
    }

    /// Tests that Result type works correctly for both success and failure cases
    func testResultTypeHandling() {
        let successResult: Result<Void, DisplayError> = .success(())

        // Test success case
        switch successResult {
        case .success:
            XCTAssertTrue(true, "Success case handled correctly")
        case .failure:
            XCTFail("Success result should not be failure")
        }

        let failureResult: Result<Void, DisplayError> = .failure(.pmsetNotFound)

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

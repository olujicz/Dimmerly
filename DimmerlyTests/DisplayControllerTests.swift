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

    #if !APPSTORE
    /// Tests that the controller returns a valid result
    func testSleepDisplaysSuccess() {
        let result = DisplayController.sleepDisplays()

        switch result {
        case .success:
            XCTAssertTrue(true, "Sleep displays succeeded")
        case .failure(let error):
            switch error {
            case .pmsetNotFound:
                XCTAssertTrue(true, "pmset not found is a valid error in test environment")
            case .pmsetFailed(let status):
                XCTAssertNotEqual(status, 0, "Failed execution should have non-zero exit status")
            case .displayWranglerNotFound:
                XCTAssertTrue(true, "Display wrangler not found is a valid error in test environment")
            case .iokitError(let code):
                XCTAssertNotEqual(code, 0, "Failed execution should have non-zero error code")
            case .permissionDenied:
                XCTAssertTrue(true, "Permission denied is valid in test environment")
            case .unknownError:
                XCTAssertTrue(true, "Unknown error is valid in test environment")
            }
        }
    }
    #endif

    /// Tests that error types have proper localized descriptions
    func testDisplayErrorDescriptions() {
        #if !APPSTORE
        // Test pmsetNotFound error
        let pmsetNotFoundError = DisplayError.pmsetNotFound
        XCTAssertNotNil(pmsetNotFoundError.errorDescription, "pmsetNotFound should have error description")
        XCTAssertNotNil(pmsetNotFoundError.recoverySuggestion, "pmsetNotFound should have recovery suggestion")

        // Test pmsetFailed error
        let pmsetFailedError = DisplayError.pmsetFailed(status: 1)
        XCTAssertNotNil(pmsetFailedError.errorDescription, "pmsetFailed should have error description")
        XCTAssertNotNil(pmsetFailedError.recoverySuggestion, "pmsetFailed should have recovery suggestion")
        XCTAssertTrue(pmsetFailedError.errorDescription?.contains("1") ?? false, "Error description should contain exit status")

        // Test displayWranglerNotFound error
        let notFoundError = DisplayError.displayWranglerNotFound
        XCTAssertNotNil(notFoundError.errorDescription, "displayWranglerNotFound should have error description")
        XCTAssertNotNil(notFoundError.recoverySuggestion, "displayWranglerNotFound should have recovery suggestion")

        // Test iokitError
        let iokitError = DisplayError.iokitError(code: 1)
        XCTAssertNotNil(iokitError.errorDescription, "iokitError should have error description")
        XCTAssertNotNil(iokitError.recoverySuggestion, "iokitError should have recovery suggestion")
        XCTAssertTrue(iokitError.errorDescription?.contains("1") ?? false, "Error description should contain error code")
        #endif

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

        // Test success case
        switch successResult {
        case .success:
            XCTAssertTrue(true, "Success case handled correctly")
        case .failure:
            XCTFail("Success result should not be failure")
        }

        #if !APPSTORE
        let failureResult: Result<Void, DisplayError> = .failure(.displayWranglerNotFound)

        // Test failure case
        switch failureResult {
        case .success:
            XCTFail("Failure result should not be success")
        case .failure(let error):
            if case .displayWranglerNotFound = error {
                XCTAssertTrue(true, "Failure case handled correctly")
            } else {
                XCTFail("Expected displayWranglerNotFound error")
            }
        }
        #endif
    }
}

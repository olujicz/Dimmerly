//
//  DisplayController.swift
//  Dimmerly
//
//  Controller for managing display sleep operations.
//  Interfaces with the macOS pmset command-line utility.
//

import Foundation

/// Controller responsible for putting displays to sleep
struct DisplayController {
    /// The expected path to the pmset command-line utility
    private static let pmsetPath = "/usr/bin/pmset"

    /// Puts all connected displays to sleep immediately
    ///
    /// This method uses the macOS `pmset` utility to trigger display sleep.
    /// It performs validation before execution and returns detailed errors if the operation fails.
    ///
    /// - Returns: A Result indicating success or containing a DisplayError on failure
    ///
    /// Example:
    /// ```swift
    /// let result = DisplayController.sleepDisplays()
    /// switch result {
    /// case .success:
    ///     print("Displays successfully put to sleep")
    /// case .failure(let error):
    ///     AlertPresenter.showError(error)
    /// }
    /// ```
    ///
    /// - Note: This operation requires the pmset utility to be available at `/usr/bin/pmset`,
    ///         which is standard on macOS 10.9 and later.
    static func sleepDisplays() -> Result<Void, DisplayError> {
        // Validate that pmset exists before attempting to execute
        guard FileManager.default.fileExists(atPath: pmsetPath) else {
            return .failure(.pmsetNotFound)
        }

        // Create and configure the Process to execute pmset
        let task = Process()
        task.executableURL = URL(fileURLWithPath: pmsetPath)
        task.arguments = ["displaysleepnow"]

        do {
            // Execute the pmset command
            try task.run()

            // Wait for the command to complete
            task.waitUntilExit()

            // Check the exit status
            let exitCode = task.terminationStatus
            if exitCode == 0 {
                return .success(())
            } else {
                // Non-zero exit code indicates failure
                return .failure(.pmsetExecutionFailed(code: exitCode))
            }
        } catch let error as NSError {
            // Check if the error is permission-related
            if error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoPermissionError {
                return .failure(.permissionDenied)
            }
            // Wrap any other errors
            return .failure(.unknownError(error))
        } catch {
            // Catch any non-NSError errors
            return .failure(.unknownError(error))
        }
    }
}

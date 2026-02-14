//
//  DisplayError.swift
//  Dimmerly
//
//  Error types for display control operations.
//  Provides user-friendly error descriptions and recovery suggestions.
//

import Foundation

/// Errors that can occur during display sleep operations
enum DisplayError: LocalizedError, Sendable {
    /// The pmset utility was not found at /usr/bin/pmset
    case pmsetNotFound

    /// The pmset command exited with a non-zero status
    case pmsetFailed(status: Int32)

    /// The app does not have permission to execute system commands
    case permissionDenied

    /// An unexpected error occurred
    case unknownError(String)

    /// A user-friendly description of the error
    var errorDescription: String? {
        switch self {
        case .pmsetNotFound:
            return NSLocalizedString("Display Sleep Unavailable", comment: "Error title: pmset not found")
        case let .pmsetFailed(status):
            return String(
                format: NSLocalizedString(
                    "Failed to Sleep Displays (Exit %d)",
                    comment: "Error title: pmset non-zero exit"
                ),
                status
            )
        case .permissionDenied:
            return NSLocalizedString("Permission Denied", comment: "Error title: missing permissions")
        case .unknownError:
            return NSLocalizedString("Unexpected Error", comment: "Error title: unknown error")
        }
    }

    /// A suggestion for how the user might recover from the error
    var recoverySuggestion: String? {
        switch self {
        case .pmsetNotFound:
            return NSLocalizedString(
                "The pmset utility was not found at /usr/bin/pmset. This is unexpected — pmset is included with macOS.",
                comment: "Recovery: pmset not found"
            )
        case let .pmsetFailed(status):
            return String(
                format: NSLocalizedString(
                    "The pmset command failed with exit code %d. "
                    + "Check System Settings > Lock Screen and ensure display sleep is not disabled by policy.",
                    comment: "Recovery: pmset failed"
                ),
                status
            )
        case .permissionDenied:
            return NSLocalizedString(
                "Dimmerly does not have permission to control displays. "
                + "Please check System Settings > Privacy & Security.",
                comment: "Recovery: permission denied"
            )
        case let .unknownError(message):
            return String(
                format: NSLocalizedString(
                    "An unexpected error occurred: %@. Please try again or restart the app.",
                    comment: "Recovery: unknown error"
                ),
                message
            )
        }
    }
}

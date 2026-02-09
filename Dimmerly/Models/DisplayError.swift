//
//  DisplayError.swift
//  Dimmerly
//
//  Error types for display control operations.
//  Provides user-friendly error descriptions and recovery suggestions.
//

import Foundation

/// Errors that can occur during display sleep operations
enum DisplayError: LocalizedError {
    /// The pmset command-line utility was not found at the expected location
    case pmsetNotFound

    /// The pmset command failed to execute successfully
    case pmsetExecutionFailed(code: Int32)

    /// The app does not have permission to execute system commands
    case permissionDenied

    /// An unexpected error occurred
    case unknownError(Error)

    /// A user-friendly description of the error
    var errorDescription: String? {
        switch self {
        case .pmsetNotFound:
            return "Display Sleep Unavailable"
        case .pmsetExecutionFailed(let code):
            return "Failed to Sleep Displays (Error \(code))"
        case .permissionDenied:
            return "Permission Denied"
        case .unknownError:
            return "Unexpected Error"
        }
    }

    /// A suggestion for how the user might recover from the error
    var recoverySuggestion: String? {
        switch self {
        case .pmsetNotFound:
            return "The system utility 'pmset' could not be found. This is required to sleep displays. Please ensure you're running macOS 10.9 or later."
        case .pmsetExecutionFailed(let code):
            return "The display sleep command failed with exit code \(code). This may indicate insufficient permissions or a system configuration issue. Try running the app with administrator privileges."
        case .permissionDenied:
            return "Dimmerly does not have permission to execute system commands. Please check System Preferences > Security & Privacy."
        case .unknownError(let error):
            return "An unexpected error occurred: \(error.localizedDescription). Please try again or restart the app."
        }
    }
}

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
    #if !APPSTORE
    /// The IODisplayWrangler service was not found
    case displayWranglerNotFound

    /// IOKit returned a non-success status code
    case iokitError(code: Int32)
    #endif

    /// The app does not have permission to execute system commands
    case permissionDenied

    /// An unexpected error occurred
    case unknownError(Error)

    /// A user-friendly description of the error
    var errorDescription: String? {
        switch self {
        #if !APPSTORE
        case .displayWranglerNotFound:
            return "Display Sleep Unavailable"
        case .iokitError(let code):
            return "Failed to Sleep Displays (Error \(code))"
        #endif
        case .permissionDenied:
            return "Permission Denied"
        case .unknownError:
            return "Unexpected Error"
        }
    }

    /// A suggestion for how the user might recover from the error
    var recoverySuggestion: String? {
        switch self {
        #if !APPSTORE
        case .displayWranglerNotFound:
            return "The display wrangler service could not be found. This may indicate a system configuration issue."
        case .iokitError(let code):
            return "The display sleep command failed with IOKit error code \(code). Try restarting the app or your Mac."
        #endif
        case .permissionDenied:
            return "Dimmerly does not have permission to control displays. Please check System Settings > Privacy & Security."
        case .unknownError(let error):
            return "An unexpected error occurred: \(error.localizedDescription). Please try again or restart the app."
        }
    }
}

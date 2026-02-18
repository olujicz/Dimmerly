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
    #if !APPSTORE
        /// The pmset utility was not found at /usr/bin/pmset
        case pmsetNotFound

        /// The pmset command exited with a non-zero status
        case pmsetFailed(status: Int32)

        /// The display does not support DDC/CI hardware control.
        /// Common reasons: built-in HDMI on M1/entry M2, DisplayLink adapter, TV, or monitor
        /// with DDC disabled in OSD settings.
        case ddcNotSupported

        /// A DDC/CI VCP read operation failed (I2C bus error or monitor did not respond).
        case ddcReadFailed(vcp: UInt8)

        /// A DDC/CI VCP write operation failed (I2C bus error or monitor did not respond).
        case ddcWriteFailed(vcp: UInt8)

        /// No IOKit service (IOAVService or IOFramebuffer) could be found for the display.
        /// This typically means the display connection type doesn't support DDC.
        case ddcServiceNotFound

        /// The DDC/CI transaction timed out waiting for a monitor response.
        case ddcTimeout
    #endif

    /// The app does not have permission to execute system commands
    case permissionDenied

    /// An unexpected error occurred
    case unknownError(String)

    /// A user-friendly description of the error
    var errorDescription: String? {
        switch self {
        #if !APPSTORE
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
            case .ddcNotSupported:
                return NSLocalizedString(
                    "Hardware Control Unavailable",
                    comment: "Error title: DDC not supported"
                )
            case let .ddcReadFailed(vcp):
                return String(
                    format: NSLocalizedString(
                        "Failed to Read Display Setting (VCP 0x%02X)",
                        comment: "Error title: DDC read failed"
                    ),
                    vcp
                )
            case let .ddcWriteFailed(vcp):
                return String(
                    format: NSLocalizedString(
                        "Failed to Write Display Setting (VCP 0x%02X)",
                        comment: "Error title: DDC write failed"
                    ),
                    vcp
                )
            case .ddcServiceNotFound:
                return NSLocalizedString(
                    "Display Service Not Found",
                    comment: "Error title: DDC IOKit service not found"
                )
            case .ddcTimeout:
                return NSLocalizedString(
                    "Display Communication Timeout",
                    comment: "Error title: DDC transaction timeout"
                )
        #endif
        case .permissionDenied:
            return NSLocalizedString("Permission Denied", comment: "Error title: missing permissions")
        case .unknownError:
            return NSLocalizedString("Unexpected Error", comment: "Error title: unknown error")
        }
    }

    /// A suggestion for how the user might recover from the error
    var recoverySuggestion: String? {
        switch self {
        #if !APPSTORE
            case .pmsetNotFound:
                return NSLocalizedString(
                    "The pmset utility was not found at /usr/bin/pmset. "
                        + "This is unexpected — pmset is included with macOS.",
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
            case .ddcNotSupported:
                return NSLocalizedString(
                    "This display does not support DDC/CI hardware control. "
                        + "Common reasons: built-in HDMI on M1/M2 Macs, DisplayLink adapters, "
                        + "or the monitor has DDC/CI disabled in its OSD settings. "
                        + "Software brightness control (gamma) is still available.",
                    comment: "Recovery: DDC not supported"
                )
            case .ddcReadFailed:
                return NSLocalizedString(
                    "Could not read the display setting via DDC/CI. "
                        + "The monitor may be busy or the I2C bus encountered an error. "
                        + "Try again in a moment.",
                    comment: "Recovery: DDC read failed"
                )
            case .ddcWriteFailed:
                return NSLocalizedString(
                    "Could not write the display setting via DDC/CI. "
                        + "The monitor may not support this control or the I2C bus encountered an error. "
                        + "Try again in a moment.",
                    comment: "Recovery: DDC write failed"
                )
            case .ddcServiceNotFound:
                return NSLocalizedString(
                    "No IOKit display service was found for this monitor. "
                        + "This usually means the connection type (e.g., DisplayLink USB) "
                        + "does not support DDC/CI on macOS.",
                    comment: "Recovery: DDC service not found"
                )
            case .ddcTimeout:
                return NSLocalizedString(
                    "The display did not respond within the expected time. "
                        + "Some monitors need extra time to process DDC commands. "
                        + "Try again or check the display connection.",
                    comment: "Recovery: DDC timeout"
                )
        #endif
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

//
//  AlertPresenter.swift
//  Dimmerly
//
//  Utility for presenting error alerts to the user.
//  Uses NSAlert for reliable display in menu bar applications.
//

import AppKit

/// Utility for presenting user-facing alerts
@MainActor
struct AlertPresenter {
    /// Presents an error alert to the user
    ///
    /// This method displays a modal alert dialog with the error's localized description
    /// and recovery suggestion. The alert remains on screen until dismissed.
    ///
    /// - Parameter error: The error to display
    ///
    /// Example:
    /// ```swift
    /// let error = DisplayError.permissionDenied
    /// AlertPresenter.showError(error)
    /// ```
    static func showError(_ error: DisplayError) {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = error.localizedDescription
        alert.informativeText = error.recoverySuggestion ?? ""
        alert.alertStyle = .warning
        alert.addButton(withTitle: NSLocalizedString("OK", comment: "Alert dismiss button"))
        alert.runModal()
    }

    /// Presents a generic error alert for non-DisplayError cases
    ///
    /// - Parameters:
    ///   - title: The alert title
    ///   - message: The detailed error message
    static func showError(title: String, message: String) {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: NSLocalizedString("OK", comment: "Alert dismiss button"))
        alert.runModal()
    }
}

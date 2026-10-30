//
//  AlertPresenter.swift
//  Dimmerly
//
//  Utility for presenting error alerts to the user.
//  Uses NSAlert for reliable display in menu bar applications.
//

import AppKit

/// Utility for presenting user-facing alerts
///
/// `NSAlert.runModal()` blocks the caller until the alert is dismissed, but it only pumps
/// the main run loop's `.modalPanel` mode — `Timer`s scheduled in the `.default` mode alone
/// (the `Timer.scheduledTimer` convenience API's default) would otherwise appear to pause
/// while an alert is on screen. `ScheduleManager`, `IdleTimerManager`, and
/// `ColorTemperatureManager` register their polling timers in `.common` modes (which include
/// `.modalPanel`) specifically so they keep running during this alert, not just at app idle.
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

    /// Asks the user to confirm an action and returns whether they chose to go ahead.
    ///
    /// The menu bar panel uses this rather than SwiftUI's `.alert`: the panel is a
    /// `MenuBarExtra` window or a transient `NSPopover`, both of which close as soon as
    /// another window takes key, taking a SwiftUI alert and its pending action with them.
    /// `runModal()` returns the choice synchronously, so the action runs even after the
    /// panel has gone.
    static func confirm(_ confirmation: ConfirmationAlert) -> Bool {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = confirmation.title
        alert.informativeText = confirmation.message
        alert.alertStyle = .warning
        let confirmButton = alert.addButton(withTitle: confirmation.confirmButtonTitle)
        confirmButton.hasDestructiveAction = confirmation.isDestructive
        let cancelButton = alert.addButton(withTitle: NSLocalizedString("Cancel", comment: "Cancel button"))
        cancelButton.keyEquivalent = "\u{1b}"
        return alert.runModal() == .alertFirstButtonReturn
    }
}

/// The text of a confirmation alert, kept apart from `NSAlert` so it can be tested.
struct ConfirmationAlert: Equatable {
    let title: String
    let message: String
    let confirmButtonTitle: String
    let isDestructive: Bool

    /// Same wording as the delete confirmation in Settings > Shortcuts.
    static func deletePreset(named name: String) -> Self {
        Self(
            title: NSLocalizedString("Delete Preset?", comment: "Delete preset confirmation title"),
            message: String(
                format: NSLocalizedString(
                    "\"%@\" will be permanently deleted.",
                    comment: "Delete confirmation message"
                ),
                name
            ),
            confirmButtonTitle: NSLocalizedString("Delete", comment: "Delete button"),
            isDestructive: true
        )
    }

    /// Saving the current settings into an existing preset discards what it held, with no undo.
    static func updatePreset(named name: String) -> Self {
        Self(
            title: String(
                format: NSLocalizedString(
                    "Update \"%@\"?",
                    comment: "Confirmation title: replace a preset's saved settings with the current ones"
                ),
                name
            ),
            message: NSLocalizedString(
                "Its saved brightness, warmth, and contrast will be replaced with the current display settings.",
                comment: "Confirmation message: replace a preset's saved settings with the current ones"
            ),
            confirmButtonTitle: NSLocalizedString(
                "Update",
                comment: "Confirmation button: replace a preset's saved settings with the current ones"
            ),
            // The user picked this on purpose, so Return confirms it without a destructive style.
            isDestructive: false
        )
    }

    #if !APPSTORE
        /// Switching a monitor to an input the Mac isn't connected to leaves it showing
        /// "No Signal", and Dimmerly can't switch it back over that input.
        static func switchInputSource(displayName: String, sourceName: String) -> Self {
            Self(
                title: String(
                    format: NSLocalizedString(
                        "Switch %1$@ to %2$@?",
                        comment: "Confirmation title: switch a monitor (1) to another input source (2)"
                    ),
                    displayName,
                    sourceName
                ),
                message: NSLocalizedString(
                    """
                    If this Mac isn't connected to that input, the display shows "No Signal" \
                    until you switch it back with the monitor's own buttons.
                    """,
                    comment: "Confirmation message: switching a monitor's input source"
                ),
                confirmButtonTitle: NSLocalizedString(
                    "Switch",
                    comment: "Confirmation button: switch a monitor's input source"
                ),
                isDestructive: false
            )
        }
    #endif
}

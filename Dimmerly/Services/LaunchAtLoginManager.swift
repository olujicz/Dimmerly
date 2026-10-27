//
//  LaunchAtLoginManager.swift
//  Dimmerly
//
//  Manager for controlling whether the app launches at login.
//  Uses SMAppService for macOS 13.0+.
//

import Foundation
import ServiceManagement

/// Error type for launch-at-login operations
enum LaunchAtLoginError: LocalizedError {
    case registrationFailed(Error)
    case unregistrationFailed(Error)

    var errorDescription: String? {
        switch self {
        case let .registrationFailed(error):
            String(
                format: NSLocalizedString(
                    "Failed to enable launch at login: %@",
                    comment: "Error registering login item"
                ),
                error.localizedDescription
            )
        case let .unregistrationFailed(error):
            String(
                format: NSLocalizedString(
                    "Failed to disable launch at login: %@",
                    comment: "Error unregistering login item"
                ),
                error.localizedDescription
            )
        }
    }
}

/// Whether Dimmerly is set to launch at login, as far as the user needs to know.
enum LaunchAtLoginStatus: Equatable {
    case enabled
    /// Registered, but macOS won't launch it until the user allows it in Login Items.
    case requiresApproval
    case disabled

    init(_ status: SMAppService.Status) {
        switch status {
        case .enabled:
            self = .enabled
        case .requiresApproval:
            self = .requiresApproval
        default:
            self = .disabled
        }
    }

    /// The toggle stays on while approval is pending: the user asked for it, and turning it
    /// off would unregister the request they still need to approve.
    var isRequested: Bool {
        self != .disabled
    }
}

/// Manages the app's launch-at-login functionality
enum LaunchAtLoginManager {
    /// Registers the app to launch at login
    ///
    /// - Returns: A Result indicating success or failure
    @discardableResult
    static func enable() -> Result<Void, LaunchAtLoginError> {
        do {
            try SMAppService.mainApp.register()
            return .success(())
        } catch {
            return .failure(.registrationFailed(error))
        }
    }

    /// Unregisters the app from launching at login
    ///
    /// - Returns: A Result indicating success or failure
    @discardableResult
    static func disable() -> Result<Void, LaunchAtLoginError> {
        do {
            try SMAppService.mainApp.unregister()
            return .success(())
        } catch {
            return .failure(.unregistrationFailed(error))
        }
    }

    /// The current login item state, including whether it still needs the user's approval.
    static var status: LaunchAtLoginStatus {
        LaunchAtLoginStatus(SMAppService.mainApp.status)
    }

    /// Opens System Settings > General > Login Items, where pending approval is granted.
    static func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    /// Sets the launch-at-login state
    ///
    /// - Parameter enabled: Whether to enable or disable launch at login
    /// - Returns: A Result indicating success or failure
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Result<Void, LaunchAtLoginError> {
        if enabled {
            enable()
        } else {
            disable()
        }
    }
}

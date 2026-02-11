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
        case .registrationFailed(let error):
            return String(format: NSLocalizedString("Failed to enable launch at login: %@", comment: "Error registering login item"), error.localizedDescription)
        case .unregistrationFailed(let error):
            return String(format: NSLocalizedString("Failed to disable launch at login: %@", comment: "Error unregistering login item"), error.localizedDescription)
        }
    }
}

/// Manages the app's launch-at-login functionality
struct LaunchAtLoginManager {
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

    /// Checks whether the app is currently registered to launch at login
    ///
    /// - Returns: true if registered, false otherwise
    static var isEnabled: Bool {
        return SMAppService.mainApp.status == .enabled
    }

    /// Sets the launch-at-login state
    ///
    /// - Parameter enabled: Whether to enable or disable launch at login
    /// - Returns: A Result indicating success or failure
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Result<Void, LaunchAtLoginError> {
        if enabled {
            return enable()
        } else {
            return disable()
        }
    }
}

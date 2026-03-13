//
//  LaunchAtLoginSettingsTests.swift
//  DimmerlyTests
//
//  Tests for launch-at-login settings error handling.
//

@testable import Dimmerly
import XCTest

@MainActor
final class LaunchAtLoginSettingsTests: XCTestCase {
    func testApplyLaunchAtLoginChangeRestoresSettingAndReturnsAlertOnFailure() {
        let settings = AppSettings()
        settings.launchAtLogin = false

        let error = LaunchAtLoginError.registrationFailed(NSError(
            domain: "LaunchAtLoginTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Registration failed"]
        ))

        let alert = applyLaunchAtLoginChange(
            requestedValue: true,
            settings: settings,
            result: .failure(error)
        )

        XCTAssertFalse(settings.launchAtLogin)
        XCTAssertEqual(alert?.title, "Launch at Login Unavailable")
        XCTAssertEqual(
            alert?.message,
            "Failed to enable launch at login: Registration failed"
        )
    }
}

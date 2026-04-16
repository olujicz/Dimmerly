//
//  SharedConstants.swift
//  Dimmerly
//
//  Shared constants for App Group communication between main app and widget.
//

import Foundation
import Security

enum SharedConstants {
    static let appGroupID = resolvedAppGroupID()
    static let widgetPresetsKey = "widgetPresets"
    static let widgetPresetCommandKey = "widgetPresetCommand"

    /// Distributed notification posted by the widget to dim displays
    static let dimNotification = Notification.Name("rs.in.olujic.dimmerly.dim")
    /// Distributed notification posted by the widget to apply a preset
    static let presetNotification = Notification.Name("rs.in.olujic.dimmerly.preset")

    static func resolvedAppGroupID(
        teamIdentifierPrefix: String? = nil,
        bundleIdentifier: String = Bundle.main.bundleIdentifier ?? "rs.in.olujic.dimmerly"
    ) -> String {
        if let teamIdentifierPrefix, !teamIdentifierPrefix.isEmpty {
            let normalizedPrefix = teamIdentifierPrefix.hasSuffix(".")
                ? teamIdentifierPrefix
                : "\(teamIdentifierPrefix)."
            return "\(normalizedPrefix)\(bundleIdentifier)"
        }

        if let entitledAppGroupID = entitledAppGroupID() {
            return entitledAppGroupID
        }

        return bundleIdentifier
    }

    nonisolated(unsafe) static let sharedDefaults: UserDefaults? = {
        // Sandboxed apps (App Store, widget): containerURL creates the directory automatically.
        // Non-sandboxed apps (direct distribution): containerURL returns nil,
        // so we create ~/Library/Group Containers/GROUPID/ manually.
        if FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) == nil {
            let url = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Group Containers/\(appGroupID)")
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        return UserDefaults(suiteName: appGroupID)
    }()

    private static func entitledAppGroupID() -> String? {
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(
                  task,
                  "com.apple.security.application-groups" as CFString,
                  nil
              )
        else {
            return nil
        }

        let groups = value as? [String]
        return groups?.first
    }
}

/// Lightweight preset info shared between main app and widget via App Group UserDefaults.
struct WidgetPresetInfo: Codable, Identifiable {
    let id: String
    let name: String
}

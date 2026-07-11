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
    static let widgetDimCommandKey = "widgetDimCommand"
    static let widgetPresetCommandKey = "widgetPresetCommand"

    /// Last-resort app-group ID used only when the app-group entitlement can't be read
    /// (unsigned/ad-hoc dev builds) and no `teamIdentifierPrefix` was supplied. Must be a
    /// fixed value identical across the main app and widget-extension processes — falling
    /// back to each process's own `Bundle.main.bundleIdentifier` resolves to a *different*
    /// UserDefaults suite per process (the widget extension's bundle ID differs from the
    /// main app's), silently breaking preset sync and widget dim/preset commands.
    private static let unsignedBuildFallbackAppGroupID = "rs.in.olujic.dimmerly.unsigned-fallback"

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

        return unsignedBuildFallbackAppGroupID
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

    static func storeWidgetDimCommand(in defaults: UserDefaults? = sharedDefaults) {
        defaults?.set(true, forKey: widgetDimCommandKey)
    }

    static func consumeWidgetDimCommand(from defaults: UserDefaults? = sharedDefaults) -> Bool {
        guard defaults?.bool(forKey: widgetDimCommandKey) == true else { return false }
        defaults?.removeObject(forKey: widgetDimCommandKey)
        return true
    }

    static func storeWidgetPresetCommand(_ presetID: String, in defaults: UserDefaults? = sharedDefaults) {
        defaults?.set(presetID, forKey: widgetPresetCommandKey)
    }

    static func consumeWidgetPresetCommand(from defaults: UserDefaults? = sharedDefaults) -> UUID? {
        guard let presetIDString = defaults?.string(forKey: widgetPresetCommandKey) else { return nil }
        defaults?.removeObject(forKey: widgetPresetCommandKey)
        return UUID(uuidString: presetIDString)
    }
}

/// Lightweight preset info shared between main app and widget via App Group UserDefaults.
struct WidgetPresetInfo: Codable, Identifiable {
    let id: String
    let name: String
}

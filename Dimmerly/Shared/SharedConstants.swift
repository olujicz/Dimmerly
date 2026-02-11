//
//  SharedConstants.swift
//  Dimmerly
//
//  Shared constants for App Group communication between main app and widget.
//

import Foundation

enum SharedConstants {
    static let appGroupID = "MN5C3DH647.rs.in.olujic.dimmerly"
    static let widgetPresetsKey = "widgetPresets"

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
}

/// Lightweight preset info shared between main app and widget via App Group UserDefaults.
struct WidgetPresetInfo: Codable, Identifiable, Sendable {
    let id: String
    let name: String
}

//
//  SharedConstants.swift
//  Dimmerly
//
//  Shared constants for App Group communication between main app and widget.
//

import Foundation
import OSLog
import Security

private let sharedConstantsLogger = Logger(
    subsystem: "rs.in.olujic.dimmerly",
    category: "SharedConstants"
)

enum SharedConstants {
    static let appGroupID = resolvedAppGroupID()
    static let widgetPresetsKey = "widgetPresets"
    static let widgetDimCommandKey = "widgetDimCommand"
    static let widgetPresetCommandKey = "widgetPresetCommand"
    static let widgetDimStateCommandKey = "widgetDimStateCommand"
    static let widgetAutoWarmthCommandKey = "widgetAutoWarmthCommand"
    static let widgetActionNotification = Notification.Name("rs.in.olujic.dimmerly.widgetAction")
    private static let widgetActionRequestPrefix = "widgetActionRequest."
    private static let widgetActionAcknowledgementPrefix = "widgetActionAcknowledgement."

    /// State the main app publishes for the Control Center toggles to read. The extension
    /// never writes these keys, so a toggle can only show what the running app really did.
    static let controlDimStateKey = "controlDimState"
    static let controlAutoWarmthStateKey = "controlAutoWarmthState"

    /// Control Center control kinds. The main app reloads controls by kind when the state
    /// they show changes, so these must match the kinds the widget extension declares.
    static let dimControlKind = "rs.in.olujic.dimmerly.DimControl"
    static let dimToggleControlKind = "rs.in.olujic.dimmerly.DimToggleControl"
    static let autoWarmthControlKind = "rs.in.olujic.dimmerly.AutoWarmthControl"
    static let presetControlKind = "rs.in.olujic.dimmerly.PresetControl"

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
    /// Distributed notification posted by the Control Center dim toggle (value in shared defaults)
    static let dimStateNotification = Notification.Name("rs.in.olujic.dimmerly.dimState")
    /// Distributed notification posted by the Control Center Auto Warmth toggle (value in shared defaults)
    static let autoWarmthNotification = Notification.Name("rs.in.olujic.dimmerly.autoWarmth")

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
            do {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            } catch {
                // Best-effort only, so log and keep going rather than hard-failing: `cfprefsd`
                // owns the suite's plist and may serve it even when this manual `mkdir` can't
                // run. Returning nil here would cache the failure for the whole process
                // lifetime (this is a `static let`), permanently disabling widget sync for a
                // failure that `UserDefaults(suiteName:)` may not even care about.
                sharedConstantsLogger.error(
                    """
                    Could not create app-group container at \(url.path, privacy: .public): \
                    \(error.localizedDescription, privacy: .public)
                    """
                )
            }
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

    static func storeWidgetActionRequest(_ request: WidgetActionRequest, in defaults: UserDefaults) throws {
        try defaults.set(JSONEncoder().encode(request), forKey: widgetActionRequestPrefix + request.id.uuidString)
        defaults.synchronize()
    }

    /// The main app serializes consumption on MainActor and removes each request before
    /// applying it. Retried notifications therefore cannot apply an action twice.
    static func consumeWidgetActionRequest(
        _ id: UUID,
        from defaults: UserDefaults? = sharedDefaults,
        now: Date = Date()
    ) -> WidgetActionRequest? {
        let key = widgetActionRequestPrefix + id.uuidString
        defaults?.synchronize()
        guard let data = defaults?.data(forKey: key) else { return nil }
        defaults?.removeObject(forKey: key)
        guard let request = try? JSONDecoder().decode(WidgetActionRequest.self, from: data),
              request.id == id, request.expiresAt > now
        else { return nil }
        return request
    }

    static func acknowledgeWidgetAction(_ id: UUID, in defaults: UserDefaults? = sharedDefaults) {
        defaults?.set(true, forKey: widgetActionAcknowledgementPrefix + id.uuidString)
        defaults?.synchronize()
    }

    static func widgetActionWasAcknowledged(_ id: UUID, in defaults: UserDefaults) -> Bool {
        defaults.synchronize()
        return defaults.bool(forKey: widgetActionAcknowledgementPrefix + id.uuidString)
    }

    static func removeWidgetActionRequest(_ id: UUID, from defaults: UserDefaults) {
        defaults.removeObject(forKey: widgetActionRequestPrefix + id.uuidString)
        defaults.removeObject(forKey: widgetActionAcknowledgementPrefix + id.uuidString)
        defaults.synchronize()
    }

    /// Drop commands left by older extensions. Actions now execute directly or through acknowledged requests;
    /// a normal launch must never apply a tap made during a previous session.
    static func discardLegacyWidgetCommands(in defaults: UserDefaults? = sharedDefaults) {
        for key in [
            widgetDimCommandKey,
            widgetPresetCommandKey,
            widgetDimStateCommandKey,
            widgetAutoWarmthCommandKey,
        ] {
            defaults?.removeObject(forKey: key)
        }
    }

    /// Flushes a just-written widget command to `cfprefsd` before the caller signals the main app.
    ///
    /// `synchronize()` is documented as unnecessary for ordinary use, and it is — but this is the
    /// one case where it still earns its keep: the widget writes a command here and *immediately*
    /// posts a distributed notification, so the main app reads the suite from another process
    /// microseconds later. Without an explicit flush, the read can lose the race against the
    /// asynchronous transfer to `cfprefsd`; the tap then silently does nothing and the orphaned
    /// key can otherwise sit in the suite until it is discarded at the next launch.
    /// These helpers remain for notifications from older widget extensions.
    ///
    /// Keep this until the command channel stops depending on cross-process read-after-write.
    private static func flushWidgetCommand(_ defaults: UserDefaults?) {
        defaults?.synchronize()
    }

    static func storeWidgetDimCommand(in defaults: UserDefaults? = sharedDefaults) {
        defaults?.set(true, forKey: widgetDimCommandKey)
        flushWidgetCommand(defaults)
    }

    static func consumeWidgetDimCommand(from defaults: UserDefaults? = sharedDefaults) -> Bool {
        guard defaults?.bool(forKey: widgetDimCommandKey) == true else { return false }
        defaults?.removeObject(forKey: widgetDimCommandKey)
        return true
    }

    static func storeWidgetPresetCommand(_ presetID: String, in defaults: UserDefaults? = sharedDefaults) {
        defaults?.set(presetID, forKey: widgetPresetCommandKey)
        flushWidgetCommand(defaults)
    }

    static func consumeWidgetPresetCommand(from defaults: UserDefaults? = sharedDefaults) -> UUID? {
        guard let presetIDString = defaults?.string(forKey: widgetPresetCommandKey) else { return nil }
        defaults?.removeObject(forKey: widgetPresetCommandKey)
        return UUID(uuidString: presetIDString)
    }

    // MARK: - Control Center toggles

    static func storeWidgetDimStateCommand(_ isOn: Bool, in defaults: UserDefaults? = sharedDefaults) {
        defaults?.set(isOn, forKey: widgetDimStateCommandKey)
        flushWidgetCommand(defaults)
    }

    /// Returns the requested dim state once, or nil when no toggle command is pending.
    static func consumeWidgetDimStateCommand(from defaults: UserDefaults? = sharedDefaults) -> Bool? {
        consumeBoolCommand(forKey: widgetDimStateCommandKey, from: defaults)
    }

    static func storeWidgetAutoWarmthCommand(_ isOn: Bool, in defaults: UserDefaults? = sharedDefaults) {
        defaults?.set(isOn, forKey: widgetAutoWarmthCommandKey)
        flushWidgetCommand(defaults)
    }

    /// Returns the requested Auto Warmth state once, or nil when no toggle command is pending.
    static func consumeWidgetAutoWarmthCommand(from defaults: UserDefaults? = sharedDefaults) -> Bool? {
        consumeBoolCommand(forKey: widgetAutoWarmthCommandKey, from: defaults)
    }

    private static func consumeBoolCommand(forKey key: String, from defaults: UserDefaults?) -> Bool? {
        guard let value = defaults?.object(forKey: key) else { return nil }
        defaults?.removeObject(forKey: key)
        return value as? Bool
    }

    /// Whether Dimmerly last reported blanking any display. Missing state reads as off.
    static func publishedDimState(in defaults: UserDefaults? = sharedDefaults) -> Bool {
        defaults?.bool(forKey: controlDimStateKey) ?? false
    }

    /// Whether Dimmerly last reported Auto Warmth as on. Missing state reads as off, which is
    /// also the setting's own default.
    static func publishedAutoWarmthState(in defaults: UserDefaults? = sharedDefaults) -> Bool {
        defaults?.bool(forKey: controlAutoWarmthStateKey) ?? false
    }

    /// Records a state value for the extension to read. Returns true when the stored value changed.
    @discardableResult
    static func publishControlState(
        _ isOn: Bool,
        forKey key: String,
        in defaults: UserDefaults? = sharedDefaults
    ) -> Bool {
        guard let defaults else { return false }
        guard defaults.object(forKey: key) as? Bool != isOn else { return false }
        defaults.set(isOn, forKey: key)
        return true
    }

    // MARK: - Presets

    /// The presets the main app last shared with its widgets, in menu order.
    static func widgetPresets(in defaults: UserDefaults? = sharedDefaults) -> [WidgetPresetInfo] {
        guard let data = defaults?.data(forKey: widgetPresetsKey),
              let presets = try? JSONDecoder().decode([WidgetPresetInfo].self, from: data)
        else {
            return []
        }
        return presets
    }

    /// The shared preset with the given ID, or nil when none was chosen or it has since been deleted.
    static func widgetPreset(withID id: String?, in defaults: UserDefaults? = sharedDefaults) -> WidgetPresetInfo? {
        guard let id else { return nil }
        return widgetPresets(in: defaults).first { $0.id == id }
    }
}

/// Lightweight preset info shared between main app and widget via App Group UserDefaults.
struct WidgetPresetInfo: Codable, Identifiable, Equatable {
    let id: String
    let name: String
}

/// Codable operations shared by the extension and the app. Values travel with their
/// request ID, so simultaneous taps cannot overwrite one another's parameters.
enum WidgetActionCommand: Codable, Equatable {
    case dimDisplays
    case applyPreset(String)
    case setDimming(Bool)
    case setAutoWarmth(Bool)
}

struct WidgetActionRequest: Codable {
    let id: UUID
    let command: WidgetActionCommand
    let expiresAt: Date

    init(id: UUID = UUID(), command: WidgetActionCommand, expiresAt: Date) {
        self.id = id
        self.command = command
        self.expiresAt = expiresAt
    }
}

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
    static let widgetActionNotification = Notification.Name("rs.in.olujic.dimmerly.widgetAction")
    private static let widgetActionRequestPrefix = "widgetActionRequest."
    private static let widgetActionAcknowledgementPrefix = "widgetActionAcknowledgement."

    /// State the main app publishes for the Control Center toggles to read. The extension
    /// never writes these keys, so a toggle can only show what the running app really did.
    static let controlDimStateKey = "controlDimState"
    static let controlAutoWarmthStateKey = "controlAutoWarmthState"
    /// What the dim button does, so the widgets and the Control Center button can name it.
    static let displayOffModeKey = "displayOffMode"

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

    /// Records whether the app performed a request. The extension reports a failure to the user
    /// rather than claiming success for an action that did nothing.
    static func acknowledgeWidgetAction(
        _ id: UUID,
        succeeded: Bool,
        in defaults: UserDefaults? = sharedDefaults
    ) {
        defaults?.set(succeeded, forKey: widgetActionAcknowledgementPrefix + id.uuidString)
        defaults?.synchronize()
    }

    /// What the app acknowledged for a request, or nil while it has not answered.
    static func widgetActionOutcome(_ id: UUID, in defaults: UserDefaults) -> WidgetActionOutcome? {
        defaults.synchronize()
        guard let succeeded = defaults.object(forKey: widgetActionAcknowledgementPrefix + id.uuidString) as? Bool
        else { return nil }
        return succeeded ? .succeeded : .failed
    }

    static func removeWidgetActionRequest(_ id: UUID, from defaults: UserDefaults) {
        defaults.removeObject(forKey: widgetActionRequestPrefix + id.uuidString)
        defaults.removeObject(forKey: widgetActionAcknowledgementPrefix + id.uuidString)
        defaults.synchronize()
    }

    /// Keys of the single-purpose command channel that older widget extensions wrote before
    /// signalling the app. Nothing writes them any more.
    static let legacyWidgetCommandKeys = [
        "widgetDimCommand",
        "widgetPresetCommand",
        "widgetDimStateCommand",
        "widgetAutoWarmthCommand",
    ]

    /// Drop commands left by older extensions. Actions now execute through acknowledged requests;
    /// a normal launch must never apply a tap made during a previous session.
    ///
    /// Remove this one release after the legacy command channel was dropped, once no installed
    /// copy can still hold these keys.
    static func discardLegacyWidgetCommands(in defaults: UserDefaults? = sharedDefaults) {
        for key in legacyWidgetCommandKeys {
            defaults?.removeObject(forKey: key)
        }
    }

    /// Removes request and acknowledgement keys that no exchange will clean up any more.
    ///
    /// The extension removes its own keys when it stops waiting, so an acknowledgement the app
    /// writes after the extension's deadline, or a request left by an extension that was killed
    /// mid-wait, stays in the suite. Call at launch, before any request of this session has been
    /// handled. A request that has not expired is kept: the extension stores it right after
    /// LaunchServices reports the app open, which can be before the app gets here.
    static func discardStaleWidgetActionKeys(in defaults: UserDefaults? = sharedDefaults, now: Date = Date()) {
        guard let defaults else { return }
        for (key, value) in defaults.dictionaryRepresentation() {
            if key.hasPrefix(widgetActionAcknowledgementPrefix) {
                defaults.removeObject(forKey: key)
            } else if key.hasPrefix(widgetActionRequestPrefix) {
                let request = (value as? Data).flatMap { try? JSONDecoder().decode(WidgetActionRequest.self, from: $0) }
                if request.map({ $0.expiresAt <= now }) ?? true {
                    defaults.removeObject(forKey: key)
                }
            }
        }
    }

    // MARK: - Control Center toggles

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

    /// What the dim button does in the app, as the app last published it.
    ///
    /// App Store builds always dim, because the sandbox rules out real display sleep. Direct
    /// builds read the published mode. Missing or unreadable state reads as turning displays
    /// off: that is the setting's default, and a button that says "dim" must never lock the Mac.
    static func publishedDisplayOffMode(in defaults: UserDefaults? = sharedDefaults) -> DisplayOffMode {
        #if APPSTORE
            .dim
        #else
            defaults?.string(forKey: displayOffModeKey).flatMap(DisplayOffMode.init(rawValue:)) ?? .turnOff
        #endif
    }

    /// Records the dim button's mode for the extension to read. Returns true when it changed.
    @discardableResult
    static func publishDisplayOffMode(_ mode: DisplayOffMode, in defaults: UserDefaults? = sharedDefaults) -> Bool {
        guard let defaults else { return false }
        guard defaults.string(forKey: displayOffModeKey) != mode.rawValue else { return false }
        defaults.set(mode.rawValue, forKey: displayOffModeKey)
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

/// What the dim button, the widgets, and the Control Center button do when used.
enum DisplayOffMode: String {
    /// Blank the screens with Dimmerly's overlay. The session stays unlocked.
    case dim
    /// Put the displays to sleep through `pmset`, which locks the Mac.
    case turnOff
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

/// How the app answered a widget action request.
enum WidgetActionOutcome: Equatable {
    case succeeded
    /// The app handled the request but could not perform it, such as a preset that was deleted.
    case failed
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

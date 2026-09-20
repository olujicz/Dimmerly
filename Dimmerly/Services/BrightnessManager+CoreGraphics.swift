//
//  BrightnessManager+CoreGraphics.swift
//  Dimmerly
//
//  CoreGraphics display enumeration and stable identity helpers.
//

import CoreGraphics

extension BrightnessManager {
    /// Returns all active display IDs. Shared helper for display enumeration.
    ///
    /// Queries the active display count first rather than assuming a fixed upper bound, so
    /// setups with many displays (docks, KVMs) aren't silently truncated.
    static func activeDisplayIDs() -> [CGDirectDisplayID] {
        var displayCount: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &displayCount) == .success, displayCount > 0 else {
            return []
        }

        var displayIDs = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        guard CGGetActiveDisplayList(displayCount, &displayIDs, &displayCount) == .success else {
            return []
        }

        return Array(displayIDs.prefix(Int(displayCount)))
    }

    /// Builds the stable key a display's saved brightness, warmth, and contrast are stored under.
    ///
    /// `CGDirectDisplayID` cannot be used for this. macOS re-enumerates displays under a *new*
    /// ID after sleep/wake and after hot-plug, so an ID-keyed lookup misses on the way back and
    /// silently resets the display to defaults. Auto color temperature hides that for warmth on
    /// its next recalculation; nothing restores contrast, so it would stay reset.
    ///
    /// Vendor, model, and serial come from the monitor's EDID and survive re-enumeration and
    /// reboots. Serial is frequently unreported (0), so the unit number — which tracks the
    /// physical connection — stands in to keep two identical monitors apart.
    ///
    /// - Returns: A key derived from EDID metadata, or the legacy display-ID string when no
    ///   usable metadata exists.
    static func persistenceIdentity(
        vendor: UInt32,
        model: UInt32,
        serial: UInt32,
        unitNumber: UInt32,
        displayID: CGDirectDisplayID
    ) -> String {
        guard let identity = stableDisplayIdentity(
            vendor: vendor,
            model: model,
            serial: serial,
            unitNumber: unitNumber
        ) else {
            // Nothing stable to key on. Fall back to the legacy display-ID key rather than
            // collapsing every metadata-less display onto one shared key.
            return String(displayID)
        }
        return String(identity.dropFirst(stableIdentityPrefix.count))
    }

    /// Builds a persistable App Intent identity from display metadata without consulting
    /// CoreGraphics. A missing serial is only safe when the unit number is also usable.
    static func stableDisplayIdentity(
        vendor: UInt32,
        model: UInt32,
        serial: UInt32,
        unitNumber: UInt32
    ) -> String? {
        guard isUsableDisplayMetadata(vendor), isUsableDisplayMetadata(model) else { return nil }
        if isUsableDisplayMetadata(serial) {
            return "\(stableIdentityPrefix)v\(vendor)m\(model)s\(serial)"
        }
        guard isUsableDisplayMetadata(unitNumber) else { return nil }
        return "\(stableIdentityPrefix)v\(vendor)m\(model)u\(unitNumber)"
    }

    /// Identity used by App Intents and other persisted integrations. Stable EDID metadata is
    /// prefixed so a legacy numeric display ID can never silently target a newly-reused ID.
    static func stableDisplayIdentity(for displayID: CGDirectDisplayID) -> String {
        stableDisplayIdentity(
            vendor: CGDisplayVendorNumber(displayID),
            model: CGDisplayModelNumber(displayID),
            serial: CGDisplaySerialNumber(displayID),
            unitNumber: CGDisplayUnitNumber(displayID)
        ) ?? "legacy:\(displayID)"
    }

    /// CoreGraphics reports 0 for "not provided" and all-ones for "unknown".
    private static let stableIdentityPrefix = "display:"

    private static func isUsableDisplayMetadata(_ value: UInt32) -> Bool {
        value != 0 && value != UInt32.max
    }
}

//
//  DisplayNameResolver.swift
//  Dimmerly
//
//  Resolves a human-readable name for a given CGDirectDisplayID.
//
//  macOS display naming is unreliable: NSScreen.localizedName returns generic
//  "Unknown Display" strings for unsupported locales, and architecture-specific
//  IOKit keys differ between Intel and Apple Silicon. This resolver walks four
//  fallback stages to produce the best available name.
//

import AppKit
import CoreGraphics
import Foundation
import IOKit

enum DisplayNameResolver {
    /// Resolution strategy:
    /// 1. **NSScreen.localizedName** — fast, localized, works for ~90% of displays.
    /// 2. **Apple's display override plist** — English fallback for unsupported locales.
    /// 3. **EDID binary parsing via IOKit** — Intel: IODisplayConnect; Apple Silicon: IOPortTransportStateDisplayPort.
    /// 4. **Localized "Unknown Display"** — last resort.
    static func name(for displayID: CGDirectDisplayID) -> String {
        for screen in NSScreen.screens {
            let key = NSDeviceDescriptionKey("NSScreenNumber")
            if let screenNumber = screen.deviceDescription[key] as? CGDirectDisplayID,
               screenNumber == displayID
            {
                let name = screen.localizedName
                if !looksGeneric(name) {
                    return name
                }
            }
        }

        if let name = nameFromOverrides(for: displayID) {
            return name
        }

        if let name = nameFromEDID(for: displayID) {
            return name
        }

        return NSLocalizedString("Unknown Display", comment: "Fallback name when macOS cannot identify the display")
    }

    /// Detects "Unknown Display"-style fallbacks across multiple languages so we
    /// continue to stages 2–3 rather than returning a generic string.
    private static func looksGeneric(_ name: String) -> Bool {
        let lowercased = name.lowercased()
        return lowercased.contains("unknown") ||
            lowercased.contains("unbekannt") || // German
            lowercased.contains("inconnu") || // French
            lowercased.contains("desconocid") || // Spanish
            lowercased.contains("sconosciut") || // Italian
            lowercased.contains("onbekend") || // Dutch
            lowercased.contains("desconhecid") || // Portuguese
            lowercased.contains("不明") || // Japanese
            lowercased.contains("未知") || // Chinese
            lowercased.contains("알 수 없") || // Korean
            lowercased.contains("nepoznat") // Serbian
    }

    /// Reads name from Apple's bundled display override plist database at
    /// `/System/Library/Displays/Contents/Resources/Overrides/…`
    private static func nameFromOverrides(for displayID: CGDirectDisplayID) -> String? {
        let vendorHex = String(format: "%x", CGDisplayVendorNumber(displayID))
        let productHex = String(format: "%x", CGDisplayModelNumber(displayID))
        let basePath = "/System/Library/Displays/Contents/Resources/Overrides"
        let path = "\(basePath)/DisplayVendorID-\(vendorHex)/DisplayProductID-\(productHex)"

        guard let dict = NSDictionary(contentsOfFile: path) as? [String: Any] else {
            return nil
        }

        if let name = dict["DisplayProductName"] as? String, !name.isEmpty {
            return name
        }
        if let names = dict["DisplayProductName"] as? [String: String],
           let name = names.values.first, !name.isEmpty
        {
            return name
        }
        return nil
    }

    /// Parses display name from IOKit — tries Apple Silicon's
    /// `IOPortTransportStateDisplayPort` first, then Intel's `IODisplayConnect`.
    private static func nameFromEDID(for displayID: CGDirectDisplayID) -> String? {
        let targetModel = Int(CGDisplayModelNumber(displayID))

        if let name = nameFromTransportService(matchingProductID: targetModel) {
            return name
        }

        let targetVendor = Int(CGDisplayVendorNumber(displayID))
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("IODisplayConnect"),
            &iterator
        ) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }

        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer {
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }

            var properties: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let dict = properties?.takeRetainedValue() as? [String: Any]
            else {
                continue
            }

            guard let vendorID = dict["DisplayVendorID"] as? Int,
                  let productID = dict["DisplayProductID"] as? Int,
                  targetVendor == vendorID, targetModel == productID
            else {
                continue
            }

            if let info = IODisplayCreateInfoDictionary(service, 0)?.takeRetainedValue() as? [String: Any],
               let names = info["DisplayProductName"] as? [String: String],
               let name = names.values.first, !name.isEmpty
            {
                return name
            }

            if let edidData = dict["IODisplayEDID"] as? Data,
               let name = parseEDIDName(edidData)
            {
                return name
            }
        }

        return nil
    }

    /// Apple Silicon path: reads product info from `IOPortTransportStateDisplayPort`.
    private static func nameFromTransportService(matchingProductID targetModel: Int) -> String? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("IOPortTransportStateDisplayPort"),
            &iterator
        ) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }

        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer {
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }

            var properties: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let dict = properties?.takeRetainedValue() as? [String: Any]
            else {
                continue
            }

            guard let productID = dict["ProductID"] as? Int,
                  productID == targetModel
            else {
                continue
            }

            if let name = dict["ProductName"] as? String, !name.isEmpty {
                return name
            }

            if let edidData = dict["EDID"] as? Data,
               let name = parseEDIDName(edidData)
            {
                return name
            }
            if let metadata = dict["Metadata"] as? [String: Any],
               let edidData = metadata["EDID"] as? Data,
               let name = parseEDIDName(edidData)
            {
                return name
            }
        }

        return nil
    }

    /// Parses monitor name from raw EDID binary data (VESA E-EDID standard).
    ///
    /// EDID has 4 descriptor blocks of 18 bytes at offset 54. A descriptor whose
    /// first 3 bytes are 0x00 and byte 3 is 0xFC contains the display product name
    /// in bytes 5–17 (13 ASCII chars, padded with 0x0A or spaces).
    private static func parseEDIDName(_ edid: Data) -> String? {
        guard edid.count >= 128 else { return nil }

        for i in 0 ..< 4 {
            let offset = 54 + (i * 18)
            guard offset + 17 < edid.count else { continue }

            if edid[offset] == 0, edid[offset + 1] == 0, edid[offset + 2] == 0, edid[offset + 3] == 0xFC {
                let nameBytes = edid[(offset + 5) ... (offset + 17)]
                if let name = String(bytes: nameBytes, encoding: .ascii)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\n\r\0")),
                    !name.isEmpty
                {
                    return name
                }
            }
        }

        return nil
    }
}

//
//  HardwareDisplayCapability.swift
//  Dimmerly
//
//  Model describing the DDC/CI hardware control capabilities of an external display.
//  Each connected display is probed once on connection; results are cached here.
//

#if !APPSTORE

    import CoreGraphics
    import Foundation

    /// Describes the DDC/CI hardware control capabilities of an external display.
    ///
    /// When a display is connected, `HardwareBrightnessManager` probes it for DDC support
    /// and creates a capability record. This record is cached for the lifetime of the connection
    /// to avoid repeated ~40ms probes per VCP code.
    ///
    /// Capability probing is not free — each VCP code requires a full DDC round-trip (~40ms).
    /// Probing all codes takes ~360ms. This is why results are cached.
    struct HardwareDisplayCapability: Equatable {
        /// CoreGraphics display identifier this capability belongs to
        let displayID: CGDirectDisplayID

        /// Whether the display responded to any DDC/CI command at all.
        /// If `false`, all other fields are meaningless.
        let supportsDDC: Bool

        /// Set of VCP codes that the display responded to successfully.
        /// Empty if `supportsDDC` is `false`.
        let supportedCodes: Set<VCPCode>

        /// Cached maximum brightness value reported by the monitor (typically 100).
        /// Used to normalize brightness to 0.0–1.0 range.
        let maxBrightness: UInt16

        /// Cached maximum contrast value reported by the monitor (typically 100).
        let maxContrast: UInt16

        /// Cached maximum volume value reported by the monitor (typically 100).
        let maxVolume: UInt16

        // MARK: - Convenience Accessors

        /// Whether the display supports hardware brightness control (VCP 0x10)
        var supportsBrightness: Bool {
            supportedCodes.contains(.brightness)
        }

        /// Whether the display supports hardware contrast control (VCP 0x12)
        var supportsContrast: Bool {
            supportedCodes.contains(.contrast)
        }

        /// Whether the display supports volume control (VCP 0x62)
        var supportsVolume: Bool {
            supportedCodes.contains(.volume)
        }

        /// Whether the display supports audio mute control (VCP 0x8D)
        var supportsAudioMute: Bool {
            supportedCodes.contains(.audioMute)
        }

        /// Whether the display supports input source switching (VCP 0x60)
        var supportsInputSource: Bool {
            supportedCodes.contains(.inputSource)
        }

        /// Whether the display supports power mode control (VCP 0xD6)
        var supportsPowerMode: Bool {
            supportedCodes.contains(.powerMode)
        }

        /// Whether the display supports individual RGB gain adjustment
        var supportsRGBGain: Bool {
            supportedCodes.contains(.redGain)
                && supportedCodes.contains(.greenGain)
                && supportedCodes.contains(.blueGain)
        }

        // MARK: - Factory Methods

        /// Creates a capability record for a display that does not support DDC.
        static func notSupported(displayID: CGDirectDisplayID) -> HardwareDisplayCapability {
            HardwareDisplayCapability(
                displayID: displayID,
                supportsDDC: false,
                supportedCodes: [],
                maxBrightness: 0,
                maxContrast: 0,
                maxVolume: 0
            )
        }

        /// Probes a bounded set of known VCP codes and keeps the successful responses.
        ///
        /// The common controls are checked first. A silent display stops after those four
        /// reads; less common controls are checked after DDC has been confirmed, or when
        /// native brightness is intentionally excluded from discovery.
        /// Each read can involve transport retries, so call this on a background thread.
        ///
        /// - Parameter displayID: CoreGraphics display identifier to probe
        /// - Returns: Capability record with supported codes and max values
        static func probe(
            displayID: CGDirectDisplayID,
            skippingBrightness: Bool = false,
            read: ((VCPCode, CGDirectDisplayID) -> DDCReadResult?)? = nil
        ) -> HardwareDisplayCapability {
            let readResults = DDCController.capabilityReadResults(
                for: displayID,
                skippingBrightness: skippingBrightness,
                read: read
            )
            let supportedCodes = Set(readResults.keys)

            guard !supportedCodes.isEmpty else {
                return .notSupported(displayID: displayID)
            }

            return HardwareDisplayCapability(
                displayID: displayID,
                supportsDDC: true,
                supportedCodes: supportedCodes,
                maxBrightness: readResults[.brightness]?.maxValue ?? 100,
                maxContrast: readResults[.contrast]?.maxValue ?? 100,
                maxVolume: readResults[.volume]?.maxValue ?? 100
            )
        }
    }

    /// The hardware control mode for a display.
    ///
    /// Determines how Dimmerly adjusts display output:
    /// - Software: Uses CoreGraphics gamma tables (works everywhere)
    /// - Hardware: Uses a native backlight or DDC/CI when available, with software fallback
    enum DDCControlMode: String, CaseIterable, Identifiable {
        /// Use software gamma tables for brightness and color adjustments.
        case softwareOnly = "software"

        /// Use DDC for brightness when supported, with automatic software fallback.
        /// The existing raw value preserves settings written by previous releases.
        case hardware = "combined"

        var id: String {
            rawValue
        }

        var displayName: String {
            switch self {
            case .softwareOnly: String(localized: "Software", comment: "DDC control mode name")
            case .hardware: String(localized: "Hardware", comment: "DDC control mode name")
            }
        }

        // swiftlint:disable line_length
        var description: String {
            switch self {
            case .softwareOnly:
                String(
                    localized: "Uses gamma tables to adjust display output. Works with all displays but does not change the actual backlight.",
                    comment: "Description of software-only DDC control mode"
                )
            case .hardware:
                String(
                    localized: "Uses the display's native backlight or DDC for brightness when available, with gamma tables for warmth and contrast. Falls back to software brightness when hardware control is unavailable.",
                    comment: "Description of hardware DDC control mode"
                )
            }
        }
        // swiftlint:enable line_length
    }

#endif // !APPSTORE

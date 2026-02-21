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
    struct HardwareDisplayCapability: Sendable, Equatable {
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

        /// Probes a display for DDC/CI capabilities by reading each VCP code.
        ///
        /// This is an expensive operation (~360ms for all 9 codes). Call on a background
        /// thread and cache the result.
        ///
        /// - Parameter displayID: CoreGraphics display identifier to probe
        /// - Returns: Capability record with supported codes and max values
        static func probe(displayID: CGDirectDisplayID) -> HardwareDisplayCapability {
            let supportedCodes = DDCController.capabilities(for: displayID)

            guard !supportedCodes.isEmpty else {
                return .notSupported(displayID: displayID)
            }

            // Read max values for the key continuous controls
            let maxBrightness = DDCController.read(vcp: .brightness, for: displayID)?.maxValue ?? 100
            let maxContrast = DDCController.read(vcp: .contrast, for: displayID)?.maxValue ?? 100
            let maxVolume = DDCController.read(vcp: .volume, for: displayID)?.maxValue ?? 100

            return HardwareDisplayCapability(
                displayID: displayID,
                supportsDDC: true,
                supportedCodes: supportedCodes,
                maxBrightness: maxBrightness,
                maxContrast: maxContrast,
                maxVolume: maxVolume
            )
        }
    }

    /// The hardware control mode for a display.
    ///
    /// Determines how Dimmerly adjusts display output:
    /// - Software only: Uses CoreGraphics gamma tables (existing behavior, works everywhere)
    /// - Hardware only: Uses DDC/CI to control the monitor's backlight directly
    /// - Combined: DDC for backlight + gamma for fine color tuning (warmth/contrast)
    enum DDCControlMode: String, CaseIterable, Identifiable, Sendable {
        /// Use only software gamma tables (default, App Store safe)
        case softwareOnly = "software"

        /// Use only DDC/CI hardware commands (requires DDC support)
        case hardwareOnly = "hardware"

        /// Use DDC for brightness + software gamma for warmth/contrast
        case combined

        var id: String {
            rawValue
        }

        var displayName: String {
            switch self {
            case .softwareOnly: return String(localized: "Software Only", comment: "DDC control mode name")
            case .hardwareOnly: return String(localized: "Hardware Only", comment: "DDC control mode name")
            case .combined: return String(localized: "Combined", comment: "DDC control mode name")
            }
        }

        // swiftlint:disable line_length
        var description: String {
            switch self {
            case .softwareOnly:
                return String(
                    localized: "Uses gamma tables to adjust display output. Works with all displays but does not change the actual backlight.",
                    comment: "Description of software-only DDC control mode"
                )
            case .hardwareOnly:
                return String(
                    localized: "Controls the monitor's backlight directly via DDC/CI. Falls back to software brightness if DDC is not available.",
                    comment: "Description of hardware-only DDC control mode"
                )
            case .combined:
                return String(
                    localized: "Uses DDC for brightness and gamma tables for warmth and contrast. Automatically uses software brightness if DDC is not available.",
                    comment: "Description of combined DDC control mode"
                )
            }
        }
        // swiftlint:enable line_length
    }

#endif // !APPSTORE

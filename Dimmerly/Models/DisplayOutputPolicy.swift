//
//  DisplayOutputPolicy.swift
//  Dimmerly
//

import Foundation

/// Which mechanism owns brightness for a display. Exactly one applies, so this cannot express
/// the contradictory states two independent booleans could.
enum DisplayBrightnessOutput: Equatable, Sendable {
    /// The built-in panel's backlight owns brightness; gamma stays neutral.
    case builtInBacklight
    /// The built-in panel is in software fallback after a failed backlight write. Gamma carries
    /// brightness, but writes keep being attempted so the panel can recover.
    case builtInBacklightFallback
    /// A supported external display's native brightness controller owns brightness.
    case externalBacklight
    /// External native writes failed; gamma carries brightness while native writes can retry.
    case externalBacklightFallback
    /// DDC/CI owns brightness on an external display; gamma stays neutral.
    case ddc
    /// Software gamma owns brightness.
    case gamma

    /// Built-in displays are written to whether or not the backlight is currently healthy —
    /// that retry is the only thing that can move a display out of `builtInBacklightFallback`.
    var writesBuiltInBacklight: Bool {
        switch self {
        case .builtInBacklight, .builtInBacklightFallback: true
        case .externalBacklight, .externalBacklightFallback, .ddc, .gamma: false
        }
    }

    var writesExternalBacklight: Bool {
        switch self {
        case .externalBacklight, .externalBacklightFallback: true
        case .builtInBacklight, .builtInBacklightFallback, .ddc, .gamma: false
        }
    }
}

struct DisplayOutputPolicy: Equatable, Sendable {
    let output: DisplayBrightnessOutput
    let gammaBrightness: Double
    let appliesGammaColorAdjustments: Bool

    #if !APPSTORE
        static func resolve(
            mode: DDCControlMode,
            isBuiltIn: Bool,
            isDDCEnabled: Bool,
            supportsDDCBrightness: Bool,
            supportsNativeBacklight: Bool = false,
            experimentalNativeBrightnessEnabled: Bool = false,
            requestedBrightness: Double,
            builtInBacklightAvailable: Bool = true,
            nativeBacklightAvailable: Bool = true
        ) -> Self {
            if isBuiltIn {
                return Self(
                    output: builtInBacklightAvailable ? .builtInBacklight : .builtInBacklightFallback,
                    gammaBrightness: builtInBacklightAvailable ? 1 : requestedBrightness,
                    appliesGammaColorAdjustments: true
                )
            }

            let usesNativeBacklight = mode == .hardware
                && isDDCEnabled
                && experimentalNativeBrightnessEnabled
                && supportsNativeBacklight
            if usesNativeBacklight {
                return Self(
                    output: nativeBacklightAvailable ? .externalBacklight : .externalBacklightFallback,
                    gammaBrightness: nativeBacklightAvailable ? 1 : requestedBrightness,
                    appliesGammaColorAdjustments: true
                )
            }

            let usesDDC = mode == .hardware && isDDCEnabled && supportsDDCBrightness
            return Self(
                output: usesDDC ? .ddc : .gamma,
                gammaBrightness: usesDDC ? 1 : requestedBrightness,
                appliesGammaColorAdjustments: true
            )
        }
    #else
        static func resolve(requestedBrightness: Double) -> Self {
            Self(
                output: .gamma,
                gammaBrightness: requestedBrightness,
                appliesGammaColorAdjustments: true
            )
        }
    #endif
}

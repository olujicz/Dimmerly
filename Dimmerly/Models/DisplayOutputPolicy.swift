//
//  DisplayOutputPolicy.swift
//  Dimmerly
//

import Foundation

struct DisplayOutputPolicy: Equatable, Sendable {
    let usesBuiltInBacklight: Bool
    let usesDDCBrightness: Bool
    let gammaBrightness: Double
    let appliesGammaColorAdjustments: Bool

    #if !APPSTORE
        static func resolve(
            mode: DDCControlMode,
            isBuiltIn: Bool,
            isDDCEnabled: Bool,
            supportsDDCBrightness: Bool,
            requestedBrightness: Double
        ) -> Self {
            if isBuiltIn {
                return Self(
                    usesBuiltInBacklight: true,
                    usesDDCBrightness: false,
                    gammaBrightness: 1,
                    appliesGammaColorAdjustments: true
                )
            }

            let usesDDC = mode == .hardware && isDDCEnabled && supportsDDCBrightness
            return Self(
                usesBuiltInBacklight: false,
                usesDDCBrightness: usesDDC,
                gammaBrightness: usesDDC ? 1 : requestedBrightness,
                appliesGammaColorAdjustments: true
            )
        }
    #else
        static func resolve(requestedBrightness: Double) -> Self {
            Self(
                usesBuiltInBacklight: false,
                usesDDCBrightness: false,
                gammaBrightness: requestedBrightness,
                appliesGammaColorAdjustments: true
            )
        }
    #endif
}

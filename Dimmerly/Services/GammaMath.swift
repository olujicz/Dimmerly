//
//  GammaMath.swift
//  Dimmerly
//
//  Pure gamma-table math: color-temperature ↔ RGB, contrast S-curve, 256-entry LUT build.
//  Extracted from BrightnessManager; no hardware or state — safe to call from any actor.
//

import CoreGraphics
import Foundation

enum GammaMath {
    /// Calculates RGB values for a color temperature using Tanner Helland's blackbody approximation.
    ///
    /// Algorithm source: http://www.tannerhelland.com/4435/convert-temperature-rgb-algorithm-code/
    /// Based on blackbody radiation curves, approximated with piecewise polynomials.
    ///
    /// - Parameter kelvin: Color temperature in Kelvin (1000–40000, clamped internally)
    /// - Returns: RGB values normalized to 0.0–1.0
    static func rgbFromKelvin(_ kelvin: Double) -> (r: Double, g: Double, b: Double) {
        let temp = min(max(kelvin, 1000), 40000) / 100.0

        let r: Double
        if temp <= 66 {
            r = 1.0
        } else {
            let x = temp - 60
            r = min(max(329.698727446 * pow(x, -0.1332047592) / 255.0, 0), 1)
        }

        let g: Double
        if temp <= 66 {
            let x = temp
            g = min(max((99.4708025861 * log(x) - 161.1195681661) / 255.0, 0), 1)
        } else {
            let x = temp - 60
            g = min(max(288.1221695283 * pow(x, -0.0755148492) / 255.0, 0), 1)
        }

        let b: Double
        if temp >= 66 {
            b = 1.0
        } else if temp <= 19 {
            b = 0.0
        } else {
            let x = temp - 10
            b = min(max((138.5177312231 * log(x) - 305.0447927307) / 255.0, 0), 1)
        }

        return (r: r, g: g, b: b)
    }

    /// Maps a warmth value (0.0–1.0) to a color temperature in Kelvin.
    ///
    /// - 0.0 → 6500K (neutral daylight)
    /// - 1.0 → 1900K (very warm candlelight)
    static func kelvinForWarmth(_ warmth: Double) -> Double {
        6500.0 - warmth * (6500.0 - 1900.0)
    }

    /// Inverse of `kelvinForWarmth(_:)`.
    static func warmthForKelvin(_ kelvin: Double) -> Double {
        (6500.0 - kelvin) / (6500.0 - 1900.0)
    }

    /// Calculates RGB channel multipliers for a given warmth level using blackbody radiation.
    ///
    /// Normalized against the 6500K reference point so that warmth=0 produces (1, 1, 1).
    static func channelMultipliers(for warmth: Double) -> (r: Double, g: Double, b: Double) {
        guard warmth > 0 else { return (r: 1.0, g: 1.0, b: 1.0) }

        let kelvin = kelvinForWarmth(warmth)
        let target = rgbFromKelvin(kelvin)
        let reference = rgbFromKelvin(6500)

        return (
            r: min(target.r / reference.r, 1.0),
            g: min(target.g / reference.g, 1.0),
            b: min(target.b / reference.b, 1.0)
        )
    }

    /// Applies an S-curve contrast adjustment using a split power function.
    ///
    /// - `contrast > 0.5`: darkens shadows and brightens highlights (steeper slopes)
    /// - `contrast < 0.5`: reduces dynamic range (gentler slopes)
    /// - `contrast == 0.5`: identity
    static func applyContrast(_ t: Double, contrast: Double) -> Double {
        guard contrast != 0.5 else { return t }

        let exponent = pow(3.0, (contrast - 0.5) * 2.0)
        if t < 0.5 {
            return 0.5 * pow(2.0 * t, exponent)
        } else {
            return 1.0 - 0.5 * pow(2.0 * (1.0 - t), exponent)
        }
    }

    /// Builds a 256-entry gamma lookup table for a single color channel.
    static func buildTable(brightness: Double, channelMultiplier: Double, contrast: Double) -> [CGGammaValue] {
        let scale = brightness * channelMultiplier
        return (0 ..< 256).map { i in
            let t = Double(i) / 255.0
            let curved = applyContrast(t, contrast: contrast)
            return CGGammaValue(curved * scale)
        }
    }
}

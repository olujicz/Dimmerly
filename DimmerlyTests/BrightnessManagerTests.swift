//
//  BrightnessManagerTests.swift
//  DimmerlyTests
//
//  Unit tests for BrightnessManager pure math and instance methods.
//  Uses init(forTesting: true) to avoid hardware interaction.
//

@testable import Dimmerly
import XCTest

@MainActor
final class BrightnessManagerTests: XCTestCase {
    var bm: BrightnessManager!

    override func setUp() async throws {
        bm = BrightnessManager(forTesting: true)
        #if !APPSTORE
            HardwareBrightnessManager.shared.capabilities.removeAll()
            HardwareBrightnessManager.shared.controlMode = .hardware
            HardwareBrightnessManager.shared.enable()
        #endif
    }

    override func tearDown() async throws {
        #if !APPSTORE
            HardwareBrightnessManager.shared.capabilities.removeAll()
            HardwareBrightnessManager.shared.controlMode = .hardware
            await HardwareBrightnessManager.shared.disable()
        #endif
        bm = nil
    }

    // MARK: - channelMultipliers

    #if !APPSTORE
        func testRefreshPreservesBuiltInBrightnessAndSkipsBacklightWriteWhenReadFails() {
            let displayID: CGDirectDisplayID = 42
            var builtIn = ExternalDisplay(
                id: displayID,
                name: "Built-in",
                brightness: 0.37,
                warmth: 0.2,
                contrast: 0.6
            )
            builtIn.isBuiltIn = true
            bm.displays = [builtIn]
            bm.activeDisplayIDsHook = { [displayID] }
            bm.isBuiltInDisplayHook = { $0 == displayID }
            bm.readBuiltInBrightnessHook = { _ in nil }
            bm.applyGammaHook = { _, _, _, _ in }

            var backlightWrites: [(CGDirectDisplayID, Double)] = []
            bm.setBuiltInBacklightHook = { displayID, value in
                backlightWrites.append((displayID, value))
                return true
            }

            bm.refreshDisplays()

            XCTAssertEqual(bm.displays.count, 1)
            XCTAssertEqual(bm.displays[0].brightness, 0.37, accuracy: 0.001)
            XCTAssertTrue(
                backlightWrites.isEmpty,
                "A failed live read must not cause a persisted/default value to be written to the panel"
            )
        }

        func testDisplayOutputPolicyUsesSoftwareGammaBrightness() {
            let policy = DisplayOutputPolicy.resolve(
                mode: .softwareOnly,
                isBuiltIn: false,
                isDDCEnabled: true,
                supportsDDCBrightness: true,
                requestedBrightness: 0.35
            )

            XCTAssertEqual(policy, DisplayOutputPolicy(
                usesBuiltInBacklight: false,
                usesDDCBrightness: false,
                gammaBrightness: 0.35,
                appliesGammaColorAdjustments: true
            ))
        }

        func testDisplayOutputPolicyUsesDDCWithGammaColorAdjustments() {
            let policy = DisplayOutputPolicy.resolve(
                mode: .hardware,
                isBuiltIn: false,
                isDDCEnabled: true,
                supportsDDCBrightness: true,
                requestedBrightness: 0.35
            )

            XCTAssertEqual(policy, DisplayOutputPolicy(
                usesBuiltInBacklight: false,
                usesDDCBrightness: true,
                gammaBrightness: 1.0,
                appliesGammaColorAdjustments: true
            ))
        }

        func testDisplayOutputPolicyFallsBackWhenDDCIsUnavailable() {
            let policy = DisplayOutputPolicy.resolve(
                mode: .hardware,
                isBuiltIn: false,
                isDDCEnabled: true,
                supportsDDCBrightness: false,
                requestedBrightness: 0.35
            )

            XCTAssertFalse(policy.usesDDCBrightness)
            XCTAssertEqual(policy.gammaBrightness, 0.35)
        }

        func testDisplayOutputPolicyUsesBuiltInBacklight() {
            let policy = DisplayOutputPolicy.resolve(
                mode: .hardware,
                isBuiltIn: true,
                isDDCEnabled: true,
                supportsDDCBrightness: false,
                requestedBrightness: 0.35
            )

            XCTAssertTrue(policy.usesBuiltInBacklight)
            XCTAssertFalse(policy.usesDDCBrightness)
            XCTAssertEqual(policy.gammaBrightness, 1.0)
        }
    #endif

    func testChannelMultipliersNeutral() {
        let m = GammaMath.channelMultipliers(for: 0.0)
        XCTAssertEqual(m.r, 1.0)
        XCTAssertEqual(m.g, 1.0)
        XCTAssertEqual(m.b, 1.0)
    }

    func testChannelMultipliersMaxWarmth() {
        // warmth=1.0 → 1900K (Helland blackbody)
        let m = GammaMath.channelMultipliers(for: 1.0)
        XCTAssertEqual(m.r, 1.0, accuracy: 0.001)
        XCTAssertEqual(m.g, 0.519, accuracy: 0.001)
        XCTAssertEqual(m.b, 0.0, accuracy: 0.001)
    }

    func testChannelMultipliersMidpoint() {
        // warmth=0.5 → 4200K (Helland blackbody)
        let m = GammaMath.channelMultipliers(for: 0.5)
        XCTAssertEqual(m.r, 1.0, accuracy: 0.001)
        XCTAssertEqual(m.g, 0.829, accuracy: 0.001)
        XCTAssertEqual(m.b, 0.700, accuracy: 0.001)
    }

    func testChannelMultipliersMonotonicity() {
        // Green and blue channels should decrease as warmth increases
        let steps = stride(from: 0.0, through: 0.9, by: 0.1)
        for w in steps {
            let m1 = GammaMath.channelMultipliers(for: w)
            let m2 = GammaMath.channelMultipliers(for: w + 0.1)
            XCTAssertGreaterThanOrEqual(m1.g, m2.g, "Green should decrease with warmth")
            XCTAssertGreaterThanOrEqual(m1.b, m2.b, "Blue should decrease with warmth")
        }
    }

    // MARK: - rgbFromKelvin

    func testRgbFromKelvin6500() {
        let rgb = GammaMath.rgbFromKelvin(6500)
        XCTAssertEqual(rgb.r, 1.0, accuracy: 0.001)
        XCTAssertEqual(rgb.g, 0.997, accuracy: 0.001)
        XCTAssertEqual(rgb.b, 0.981, accuracy: 0.001)
    }

    func testRgbFromKelvin1900() {
        let rgb = GammaMath.rgbFromKelvin(1900)
        XCTAssertEqual(rgb.r, 1.0, accuracy: 0.001)
        XCTAssertEqual(rgb.g, 0.517, accuracy: 0.001)
        XCTAssertEqual(rgb.b, 0.0, accuracy: 0.001)
    }

    func testRgbFromKelvinHighTemp() {
        // At 10000K, all channels should be positive but blue should be high
        let rgb = GammaMath.rgbFromKelvin(10000)
        XCTAssertGreaterThan(rgb.r, 0)
        XCTAssertGreaterThan(rgb.g, 0)
        XCTAssertEqual(rgb.b, 1.0, "Blue should be 1.0 at temp >= 6600K")
    }

    func testRgbFromKelvinClampsLow() {
        // Should clamp to 1000K, not crash on extreme values
        let rgb = GammaMath.rgbFromKelvin(0)
        XCTAssertGreaterThan(rgb.r, 0)
    }

    // MARK: - kelvinForWarmth / warmthForKelvin

    func testKelvinForWarmthEndpoints() {
        XCTAssertEqual(GammaMath.kelvinForWarmth(0.0), 6500.0)
        XCTAssertEqual(GammaMath.kelvinForWarmth(1.0), 1900.0)
    }

    func testKelvinForWarmthMidpoint() {
        XCTAssertEqual(GammaMath.kelvinForWarmth(0.5), 4200.0)
    }

    func testWarmthForKelvinEndpoints() {
        XCTAssertEqual(GammaMath.warmthForKelvin(6500), 0.0)
        XCTAssertEqual(GammaMath.warmthForKelvin(1900), 1.0)
    }

    func testKelvinWarmthRoundTrip() {
        for warmth in stride(from: 0.0, through: 1.0, by: 0.1) {
            let kelvin = GammaMath.kelvinForWarmth(warmth)
            let roundTrip = GammaMath.warmthForKelvin(kelvin)
            XCTAssertEqual(roundTrip, warmth, accuracy: 0.0001, "Round-trip failed at warmth=\(warmth)")
        }
    }

    // MARK: - applyContrast

    func testApplyContrastIdentity() {
        // At contrast=0.5 (neutral), output should equal input
        for t in stride(from: 0.0, through: 1.0, by: 0.1) {
            XCTAssertEqual(GammaMath.applyContrast(t, contrast: 0.5), t, accuracy: 0.0001)
        }
    }

    func testApplyContrastEndpointPreservation() {
        // Endpoints 0.0 and 1.0 should be preserved at any contrast
        for c in [0.0, 0.25, 0.5, 0.75, 1.0] {
            XCTAssertEqual(GammaMath.applyContrast(0.0, contrast: c), 0.0, accuracy: 0.0001,
                           "t=0 should map to 0 at contrast=\(c)")
            XCTAssertEqual(GammaMath.applyContrast(1.0, contrast: c), 1.0, accuracy: 0.0001,
                           "t=1 should map to 1 at contrast=\(c)")
        }
    }

    func testApplyContrastMidpointPreservation() {
        // Midpoint t=0.5 should map to 0.5 at any contrast
        for c in [0.0, 0.25, 0.75, 1.0] {
            XCTAssertEqual(GammaMath.applyContrast(0.5, contrast: c), 0.5, accuracy: 0.0001,
                           "t=0.5 should map to 0.5 at contrast=\(c)")
        }
    }

    func testApplyContrastSteepening() {
        // At high contrast, values near 0 should be pushed lower, values near 1 pushed higher
        let highContrast = GammaMath.applyContrast(0.25, contrast: 0.9)
        XCTAssertLessThan(highContrast, 0.25, "High contrast should push low values lower")

        let highContrastHigh = GammaMath.applyContrast(0.75, contrast: 0.9)
        XCTAssertGreaterThan(highContrastHigh, 0.75, "High contrast should push high values higher")
    }

    func testApplyContrastFlattening() {
        // At low contrast, values near 0 should be pushed higher, values near 1 pushed lower
        let lowContrast = GammaMath.applyContrast(0.25, contrast: 0.1)
        XCTAssertGreaterThan(lowContrast, 0.25, "Low contrast should push low values higher")

        let lowContrastHigh = GammaMath.applyContrast(0.75, contrast: 0.1)
        XCTAssertLessThan(lowContrastHigh, 0.75, "Low contrast should push high values lower")
    }

    func testApplyContrastSymmetry() {
        // S-curve should be symmetric around 0.5
        for c in [0.0, 0.3, 0.7, 1.0] {
            let low = GammaMath.applyContrast(0.25, contrast: c)
            let high = GammaMath.applyContrast(0.75, contrast: c)
            XCTAssertEqual(low + high, 1.0, accuracy: 0.0001,
                           "S-curve should be symmetric at contrast=\(c)")
        }
    }

    // MARK: - Display lookups

    func testBrightnessForKnownDisplay() {
        bm.displays = [ExternalDisplay(id: 1, name: "Test", brightness: 0.6, warmth: 0.3, contrast: 0.4)]
        XCTAssertEqual(bm.brightness(for: 1), 0.6)
    }

    func testBrightnessForUnknownDisplay() {
        bm.displays = []
        XCTAssertEqual(bm.brightness(for: 999), 1.0, "Unknown display should return default 1.0")
    }

    func testWarmthForKnownDisplay() {
        bm.displays = [ExternalDisplay(id: 2, name: "Test", brightness: 1.0, warmth: 0.7, contrast: 0.5)]
        XCTAssertEqual(bm.warmth(for: 2), 0.7)
    }

    func testWarmthForUnknownDisplay() {
        bm.displays = []
        XCTAssertEqual(bm.warmth(for: 999), 0.0, "Unknown display should return default 0.0")
    }

    func testContrastForKnownDisplay() {
        bm.displays = [ExternalDisplay(id: 3, name: "Test", brightness: 1.0, warmth: 0.0, contrast: 0.8)]
        XCTAssertEqual(bm.contrast(for: 3), 0.8)
    }

    func testContrastForUnknownDisplay() {
        bm.displays = []
        XCTAssertEqual(bm.contrast(for: 999), 0.5, "Unknown display should return default 0.5")
    }

    // MARK: - Snapshots

    func testBrightnessSnapshotMultiDisplay() {
        // Snapshots are keyed by stable identity. The hook keeps that deterministic — without it
        // the key depends on whatever EDID the host machine reports for these display IDs.
        bm.displayIdentityHook = { "identity-\($0)" }
        bm.displays = [
            ExternalDisplay(id: 1, name: "A", brightness: 0.5),
            ExternalDisplay(id: 2, name: "B", brightness: 0.8),
        ]
        let snap = bm.currentBrightnessSnapshot()
        XCTAssertEqual(snap["identity-1"], 0.5)
        XCTAssertEqual(snap["identity-2"], 0.8)
        XCTAssertEqual(snap.count, 2)
    }

    func testBrightnessSnapshotEmpty() {
        bm.displays = []
        XCTAssertTrue(bm.currentBrightnessSnapshot().isEmpty)
    }

    func testWarmthSnapshotMultiDisplay() {
        bm.displayIdentityHook = { "identity-\($0)" }
        bm.displays = [
            ExternalDisplay(id: 1, name: "A", brightness: 1.0, warmth: 0.2),
            ExternalDisplay(id: 2, name: "B", brightness: 1.0, warmth: 0.9),
        ]
        let snap = bm.currentWarmthSnapshot()
        XCTAssertEqual(snap["identity-1"], 0.2)
        XCTAssertEqual(snap["identity-2"], 0.9)
    }

    func testContrastSnapshotMultiDisplay() {
        bm.displayIdentityHook = { "identity-\($0)" }
        bm.displays = [
            ExternalDisplay(id: 1, name: "A", brightness: 1.0, warmth: 0.0, contrast: 0.3),
            ExternalDisplay(id: 2, name: "B", brightness: 1.0, warmth: 0.0, contrast: 0.7),
        ]
        let snap = bm.currentContrastSnapshot()
        XCTAssertEqual(snap["identity-1"], 0.3)
        XCTAssertEqual(snap["identity-2"], 0.7)
    }

    // MARK: - Set all

    func testSetAllBrightness() {
        bm.displays = [
            ExternalDisplay(id: 1, name: "A", brightness: 0.5),
            ExternalDisplay(id: 2, name: "B", brightness: 0.8),
        ]
        bm.setAllBrightness(to: 0.4)
        XCTAssertEqual(bm.displays[0].brightness, 0.4)
        XCTAssertEqual(bm.displays[1].brightness, 0.4)
    }

    func testSetAllWarmth() {
        bm.displays = [
            ExternalDisplay(id: 1, name: "A", brightness: 1.0, warmth: 0.0),
            ExternalDisplay(id: 2, name: "B", brightness: 1.0, warmth: 0.5),
        ]
        bm.setAllWarmth(to: 0.7)
        XCTAssertEqual(bm.displays[0].warmth, 0.7)
        XCTAssertEqual(bm.displays[1].warmth, 0.7)
    }

    func testSetAllContrast() {
        bm.displays = [
            ExternalDisplay(id: 1, name: "A", brightness: 1.0, warmth: 0.0, contrast: 0.5),
            ExternalDisplay(id: 2, name: "B", brightness: 1.0, warmth: 0.0, contrast: 0.5),
        ]
        bm.setAllContrast(to: 0.9)
        XCTAssertEqual(bm.displays[0].contrast, 0.9)
        XCTAssertEqual(bm.displays[1].contrast, 0.9)
    }

    // MARK: - Clamping

    func testBrightnessClampsToMinimum() {
        bm.displays = [ExternalDisplay(id: 1, name: "A", brightness: 1.0)]
        bm.setBrightness(for: 1, to: 0.01)
        XCTAssertEqual(bm.displays[0].brightness, BrightnessManager.minimumBrightness,
                       "Brightness should clamp to minimum \(BrightnessManager.minimumBrightness)")
    }

    func testBrightnessClampsToMaximum() {
        bm.displays = [ExternalDisplay(id: 1, name: "A", brightness: 0.5)]
        bm.setBrightness(for: 1, to: 1.5)
        XCTAssertEqual(bm.displays[0].brightness, 1.0,
                       "Brightness should clamp to maximum 1.0")
    }

    func testWarmthClampsToRange() {
        bm.displays = [ExternalDisplay(id: 1, name: "A", brightness: 1.0, warmth: 0.5)]
        bm.setWarmth(for: 1, to: -0.5)
        XCTAssertEqual(bm.displays[0].warmth, 0.0, "Warmth should clamp to 0.0")

        bm.setWarmth(for: 1, to: 1.5)
        XCTAssertEqual(bm.displays[0].warmth, 1.0, "Warmth should clamp to 1.0")
    }

    func testContrastClampsToRange() {
        bm.displays = [ExternalDisplay(id: 1, name: "A", brightness: 1.0, warmth: 0.0, contrast: 0.5)]
        bm.setContrast(for: 1, to: -0.5)
        XCTAssertEqual(bm.displays[0].contrast, 0.0, "Contrast should clamp to 0.0")

        bm.setContrast(for: 1, to: 1.5)
        XCTAssertEqual(bm.displays[0].contrast, 1.0, "Contrast should clamp to 1.0")
    }

    // MARK: - Apply from preset values

    func testApplyBrightnessValuesMatchingDisplays() {
        bm.displays = [
            ExternalDisplay(id: 1, name: "A", brightness: 1.0),
            ExternalDisplay(id: 2, name: "B", brightness: 1.0),
        ]
        bm.applyBrightnessValues(["1": 0.3, "2": 0.6])
        XCTAssertEqual(bm.displays[0].brightness, 0.3)
        XCTAssertEqual(bm.displays[1].brightness, 0.6)
    }

    func testApplyBrightnessValuesNonMatchingDisplays() {
        bm.displays = [ExternalDisplay(id: 1, name: "A", brightness: 0.5)]
        bm.applyBrightnessValues(["999": 0.3])
        XCTAssertEqual(bm.displays[0].brightness, 0.5, "Non-matching ID should not change existing display")
    }

    func testApplyWarmthValuesMatchingDisplays() {
        bm.displays = [
            ExternalDisplay(id: 1, name: "A", brightness: 1.0, warmth: 0.0),
            ExternalDisplay(id: 2, name: "B", brightness: 1.0, warmth: 0.0),
        ]
        bm.applyWarmthValues(["1": 0.4, "2": 0.8])
        XCTAssertEqual(bm.displays[0].warmth, 0.4)
        XCTAssertEqual(bm.displays[1].warmth, 0.8)
    }

    func testApplyContrastValuesMatchingDisplays() {
        bm.displays = [
            ExternalDisplay(id: 1, name: "A", brightness: 1.0, warmth: 0.0, contrast: 0.5),
            ExternalDisplay(id: 2, name: "B", brightness: 1.0, warmth: 0.0, contrast: 0.5),
        ]
        bm.applyContrastValues(["1": 0.2, "2": 0.9])
        XCTAssertEqual(bm.displays[0].contrast, 0.2)
        XCTAssertEqual(bm.displays[1].contrast, 0.9)
    }

    func testSetBrightnessForUnknownDisplayIsNoOp() {
        bm.displays = [ExternalDisplay(id: 1, name: "A", brightness: 0.5)]
        bm.setBrightness(for: 999, to: 0.3)
        XCTAssertEqual(bm.displays[0].brightness, 0.5, "Should not change any display")
    }

    #if !APPSTORE
        func testAnimateToPresetSyncsBuiltInBacklightAtCompletion() async {
            var builtIn = ExternalDisplay(id: 1, name: "Built-in", brightness: 1.0, warmth: 0.0, contrast: 0.5)
            builtIn.isBuiltIn = true
            bm.displays = [builtIn]
            bm.canAnimateTransitionsHook = { true }

            let backlightSynced = expectation(description: "Built-in backlight is updated after animation")
            let finalGammaApplied = expectation(description: "Built-in gamma is restored without brightness dimming")
            finalGammaApplied.assertForOverFulfill = false
            var observedBrightnessValues: [Double] = []
            bm.setBuiltInBacklightHook = { displayID, value in
                XCTAssertEqual(displayID, 1)
                XCTAssertEqual(value, 0.4, accuracy: 0.001)
                backlightSynced.fulfill()
                return true
            }
            bm.applyGammaHook = { displayID, brightness, warmth, contrast in
                guard displayID == 1 else { return }
                observedBrightnessValues.append(brightness)
                guard abs(warmth - 0.2) < 0.001, abs(contrast - 0.7) < 0.001 else { return }
                finalGammaApplied.fulfill()
            }

            let preset = BrightnessPreset(
                name: "Animated",
                universalBrightness: 0.4,
                universalWarmth: 0.2,
                universalContrast: 0.7
            )

            XCTAssertTrue(bm.animateToPreset(preset))
            await fulfillment(of: [backlightSynced, finalGammaApplied], timeout: 1.0)
            XCTAssertEqual(bm.displays[0].brightness, 0.4, accuracy: 0.001)

            // Regression test for the double-dim bug: gamma brightness must stay pinned at
            // 1.0 for the entire hardware-controlled animation, never dipping toward the
            // interpolated model brightness (which would visibly darken the screen mid-preset).
            XCTAssertFalse(observedBrightnessValues.isEmpty)
            for value in observedBrightnessValues {
                XCTAssertEqual(value, 1.0, accuracy: 0.001)
            }
        }

        func testAnimateToPresetSyncsDDCBrightnessAndRestoresNeutralGammaBrightness() async {
            var external = ExternalDisplay(id: 2, name: "External", brightness: 1.0, warmth: 0.0, contrast: 0.5)
            external.supportsDDC = true
            bm.displays = [external]
            bm.canAnimateTransitionsHook = { true }

            HardwareBrightnessManager.shared.capabilities[2] = HardwareDisplayCapability(
                displayID: 2,
                supportsDDC: true,
                supportedCodes: [.brightness],
                maxBrightness: 100,
                maxContrast: 100,
                maxVolume: 0
            )
            HardwareBrightnessManager.shared.controlMode = .hardware
            HardwareBrightnessManager.shared.enable()

            let hardwareSynced = expectation(description: "External DDC brightness is updated after animation")
            let finalGammaApplied = expectation(
                description: "External gamma keeps warmth and contrast without software dimming"
            )
            finalGammaApplied.assertForOverFulfill = false
            var observedBrightnessValues: [Double] = []
            bm.setExternalHardwareBrightnessHook = { displayID, value in
                XCTAssertEqual(displayID, 2)
                XCTAssertEqual(value, 0.35, accuracy: 0.001)
                hardwareSynced.fulfill()
            }
            bm.applyGammaHook = { displayID, brightness, warmth, contrast in
                guard displayID == 2 else { return }
                observedBrightnessValues.append(brightness)
                guard abs(warmth - 0.3) < 0.001, abs(contrast - 0.65) < 0.001 else { return }
                finalGammaApplied.fulfill()
            }

            let preset = BrightnessPreset(
                name: "External Animated",
                universalBrightness: 0.35,
                universalWarmth: 0.3,
                universalContrast: 0.65
            )

            XCTAssertTrue(bm.animateToPreset(preset))
            await fulfillment(of: [hardwareSynced, finalGammaApplied], timeout: 1.0)
            XCTAssertEqual(bm.displays[0].brightness, 0.35, accuracy: 0.001)

            // Regression test for the double-dim bug: gamma brightness must stay pinned at
            // 1.0 for the entire hardware-controlled animation, never dipping toward the
            // interpolated model brightness (which would visibly darken the screen mid-preset).
            XCTAssertFalse(observedBrightnessValues.isEmpty)
            for value in observedBrightnessValues {
                XCTAssertEqual(value, 1.0, accuracy: 0.001)
            }
        }

        func testSetWarmthOnDDCDisplayKeepsGammaBrightnessNeutral() {
            var external = ExternalDisplay(id: 3, name: "External", brightness: 0.3, warmth: 0.0, contrast: 0.5)
            external.supportsDDC = true
            bm.displays = [external]

            HardwareBrightnessManager.shared.capabilities[3] = HardwareDisplayCapability(
                displayID: 3,
                supportsDDC: true,
                supportedCodes: [.brightness],
                maxBrightness: 100,
                maxContrast: 100,
                maxVolume: 0
            )
            HardwareBrightnessManager.shared.controlMode = .hardware
            HardwareBrightnessManager.shared.enable()

            let gammaApplied = expectation(
                description: "Warmth update preserves neutral gamma brightness on DDC display"
            )
            bm.applyGammaHook = { displayID, brightness, warmth, contrast in
                XCTAssertEqual(displayID, 3)
                XCTAssertEqual(brightness, 1.0, accuracy: 0.001)
                XCTAssertEqual(warmth, 0.7, accuracy: 0.001)
                XCTAssertEqual(contrast, 0.5, accuracy: 0.001)
                gammaApplied.fulfill()
            }

            bm.setWarmth(for: 3, to: 0.7)

            wait(for: [gammaApplied], timeout: 0.1)
        }

        func testDisabledDDCFallsBackToSoftwareGammaForExternalBrightness() async throws {
            var external = ExternalDisplay(id: 4, name: "External", brightness: 1.0, warmth: 0.0, contrast: 0.5)
            external.supportsDDC = true
            bm.displays = [external]

            HardwareBrightnessManager.shared.capabilities[4] = HardwareDisplayCapability(
                displayID: 4,
                supportsDDC: true,
                supportedCodes: [.brightness],
                maxBrightness: 100,
                maxContrast: 100,
                maxVolume: 0
            )
            HardwareBrightnessManager.shared.controlMode = .hardware
            await HardwareBrightnessManager.shared.disable()

            var hardwareWriteCount = 0
            var gammaBrightness: Double?
            bm.setExternalHardwareBrightnessHook = { _, _ in
                hardwareWriteCount += 1
            }
            bm.applyGammaHook = { _, brightness, _, _ in
                gammaBrightness = brightness
            }

            bm.setBrightness(for: 4, to: 0.4)

            XCTAssertEqual(hardwareWriteCount, 0)
            XCTAssertEqual(try XCTUnwrap(gammaBrightness), 0.4, accuracy: 0.001)
        }
    #endif

    // MARK: - buildTable

    func testBuildTableSize() {
        let table = GammaMath.buildTable(brightness: 1.0, channelMultiplier: 1.0, contrast: 0.5)
        XCTAssertEqual(table.count, 256, "Gamma table should have exactly 256 entries")
    }

    func testBuildTableEndpoints() {
        // Full brightness, no warmth, neutral contrast: entry 0 = 0.0, entry 255 = 1.0
        let table = GammaMath.buildTable(brightness: 1.0, channelMultiplier: 1.0, contrast: 0.5)
        XCTAssertEqual(table[0], 0.0, accuracy: 0.001, "First entry should be 0.0")
        XCTAssertEqual(table[255], 1.0, accuracy: 0.001, "Last entry should be 1.0")
    }

    func testBuildTableMonotonicity() {
        // At neutral contrast, table should be monotonically increasing
        let table = GammaMath.buildTable(brightness: 1.0, channelMultiplier: 1.0, contrast: 0.5)
        for i in 1 ..< table.count {
            XCTAssertGreaterThanOrEqual(table[i], table[i - 1],
                                        "Table should be monotonically increasing at neutral contrast (index \(i))")
        }
    }

    func testBuildTableHalfBrightness() {
        // At 50% brightness, the last entry should be ~0.5
        let table = GammaMath.buildTable(brightness: 0.5, channelMultiplier: 1.0, contrast: 0.5)
        XCTAssertEqual(table[255], 0.5, accuracy: 0.01, "Last entry at 50% brightness should be ~0.5")
    }

    func testBuildTableWarmthScaling() {
        // With blue channel multiplier of 0.56 at full brightness, last entry should be ~0.56
        let table = GammaMath.buildTable(brightness: 1.0, channelMultiplier: 0.56, contrast: 0.5)
        XCTAssertEqual(table[255], 0.56, accuracy: 0.01, "Last entry with 0.56 multiplier should be ~0.56")
        XCTAssertEqual(table[0], 0.0, accuracy: 0.001, "First entry should still be 0.0")
    }

    func testBuildTableHighContrastShape() {
        // High contrast should push low values lower and high values higher
        let neutral = GammaMath.buildTable(brightness: 1.0, channelMultiplier: 1.0, contrast: 0.5)
        let high = GammaMath.buildTable(brightness: 1.0, channelMultiplier: 1.0, contrast: 0.9)

        // Entry at 25% (index 64) should be lower with high contrast
        XCTAssertLessThan(high[64], neutral[64], "High contrast should push low values lower")
        // Entry at 75% (index 192) should be higher with high contrast
        XCTAssertGreaterThan(high[192], neutral[192], "High contrast should push high values higher")
    }

    // MARK: - Per-Display Persistence Identity

    /// `CGDirectDisplayID` is ephemeral — macOS re-enumerates a display under a new ID after
    /// sleep/wake — so the persistence key must not depend on it, or saved values are lost.
    func testPersistenceIdentityIsStableAcrossDisplayIDChangeWhenSerialIsAvailable() {
        let before = BrightnessManager.persistenceIdentity(
            vendor: 0x10AC, model: 0xD0A1, serial: 0x1234_5678, unitNumber: 1, displayID: 2
        )
        let after = BrightnessManager.persistenceIdentity(
            vendor: 0x10AC, model: 0xD0A1, serial: 0x1234_5678, unitNumber: 1, displayID: 11
        )

        XCTAssertEqual(before, after, "One physical display must map to one key across re-enumeration")
    }

    /// Many monitors report serial 0. Unit number identifies the physical connection, so it
    /// keeps two identical models apart without reintroducing the ephemeral display ID.
    func testPersistenceIdentityUsesUnitNumberWhenSerialIsMissing() {
        let before = BrightnessManager.persistenceIdentity(
            vendor: 0x10AC, model: 0xD0A1, serial: 0, unitNumber: 3, displayID: 2
        )
        let after = BrightnessManager.persistenceIdentity(
            vendor: 0x10AC, model: 0xD0A1, serial: 0, unitNumber: 3, displayID: 11
        )
        let identicalModelOnAnotherPort = BrightnessManager.persistenceIdentity(
            vendor: 0x10AC, model: 0xD0A1, serial: 0, unitNumber: 4, displayID: 12
        )

        XCTAssertEqual(before, after, "Same physical display must survive re-enumeration")
        XCTAssertNotEqual(before, identicalModelOnAnotherPort, "Two identical models must not collide")
    }

    /// With no usable EDID metadata there is nothing stable to key on, so fall back to the
    /// legacy display-ID key rather than collapsing every such display onto one key.
    func testPersistenceIdentityFallsBackToDisplayIDWhenMetadataUnavailable() {
        let key = BrightnessManager.persistenceIdentity(
            vendor: 0, model: 0, serial: 0, unitNumber: 0, displayID: 7
        )

        XCTAssertEqual(key, "7")
    }

    /// The reported bug: after a display re-enumerates under a new `CGDirectDisplayID`, its
    /// saved warmth and contrast were looked up under the new ID, found nothing, and silently
    /// reset to the 0.0 / 0.5 defaults. Auto color temperature papers over warmth on its next
    /// tick; nothing restores contrast.
    func testRefreshRestoresSavedWarmthAndContrastAfterDisplayIsReEnumeratedUnderNewID() throws {
        let suiteName = "BrightnessManagerTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let manager = BrightnessManager(forTesting: true, defaults: defaults)
        manager.applyGammaHook = { _, _, _, _ in }
        manager.isBuiltInDisplayHook = { _ in false }
        // One physical monitor, so both display IDs resolve to the same stable identity.
        manager.displayIdentityHook = { _ in "v4268m53409s305419896" }

        // Session one: the user's values are saved while the display is enumerated as ID 2.
        manager.activeDisplayIDsHook = { [2] }
        manager.displays = [
            ExternalDisplay(id: 2, name: "DELL S2723HC", brightness: 1.0, warmth: 0.47, contrast: 0.8),
        ]
        manager.persistAll()

        // After sleep/wake the same monitor comes back as ID 11.
        manager.displays = []
        manager.activeDisplayIDsHook = { [11] }
        manager.refreshDisplays()

        XCTAssertEqual(manager.displays.count, 1)
        XCTAssertEqual(manager.displays[0].id, 11)
        XCTAssertEqual(manager.displays[0].warmth, 0.47, accuracy: 0.0001, "Warmth must survive re-enumeration")
        XCTAssertEqual(manager.displays[0].contrast, 0.8, accuracy: 0.0001, "Contrast must survive re-enumeration")
    }

    /// Values written by earlier versions are keyed by raw display ID. Those users must not
    /// lose their settings the first time they launch a build that keys by stable identity.
    func testRefreshReadsLegacyDisplayIDKeyedValuesWhenNoIdentityKeyExists() throws {
        let suiteName = "BrightnessManagerTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // Exactly what a pre-fix release left behind.
        defaults.set(["4": 0.31], forKey: "dimmerlyDisplayWarmth")
        defaults.set(["4": 0.72], forKey: "dimmerlyDisplayContrast")

        let manager = BrightnessManager(forTesting: true, defaults: defaults)
        manager.applyGammaHook = { _, _, _, _ in }
        manager.isBuiltInDisplayHook = { _ in false }
        manager.displayIdentityHook = { _ in "v4268m53409s999" }
        manager.activeDisplayIDsHook = { [4] }
        manager.displays = []

        manager.refreshDisplays()

        XCTAssertEqual(manager.displays[0].warmth, 0.31, accuracy: 0.0001, "Legacy warmth must migrate")
        XCTAssertEqual(manager.displays[0].contrast, 0.72, accuracy: 0.0001, "Legacy contrast must migrate")
    }

    // MARK: - Re-Asserting Gamma After an External Reset

    /// macOS wipes the gamma table late in a display wake, after the app's wake handler has run.
    /// The model still holds the right warmth, so auto colour temperature's 60-second tick asks
    /// for the same value it already believes is applied. Previously `setWarmth` returned early on
    /// an unchanged value *before* touching gamma, so the hardware and the model could never
    /// reconcile and the display stayed un-warmed until the app was relaunched.
    func testSetWarmthReappliesGammaWhenTheValueIsUnchanged() {
        bm.displays = [ExternalDisplay(id: 7, name: "A", brightness: 1.0, warmth: 0.5, contrast: 0.5)]
        var appliedWarmth: [Double] = []
        bm.applyGammaHook = { _, _, warmth, _ in appliedWarmth.append(warmth) }

        bm.setWarmth(for: 7, to: 0.5)

        XCTAssertEqual(appliedWarmth, [0.5], "An unchanged value must still re-assert gamma")
    }

    /// Guards the other half: re-asserting must not disturb the stored value.
    func testSetWarmthWithUnchangedValueKeepsTheStoredWarmth() {
        bm.displays = [ExternalDisplay(id: 7, name: "A", brightness: 1.0, warmth: 0.5, contrast: 0.5)]
        bm.applyGammaHook = { _, _, _, _ in }

        bm.setWarmth(for: 7, to: 0.5)

        XCTAssertEqual(bm.displays[0].warmth, 0.5, accuracy: 0.0001)
    }

    // MARK: - Preset Values Across Display Re-Enumeration

    /// One physical monitor whose `CGDirectDisplayID` differs from the one a preset was saved
    /// under — the state after macOS re-enumerates a display on sleep/wake.
    private func managerWithReEnumeratedDisplay(
        identity: String,
        currentID: CGDirectDisplayID
    ) -> BrightnessManager {
        let manager = BrightnessManager(forTesting: true)
        manager.applyGammaHook = { _, _, _, _ in }
        manager.isBuiltInDisplayHook = { _ in false }
        manager.displayIdentityHook = { _ in identity }
        manager.displays = [
            ExternalDisplay(id: currentID, name: "DELL S2723HC", brightness: 1.0, warmth: 0.0, contrast: 0.5),
        ]
        return manager
    }

    /// Snapshots feed saved presets, so they must record the stable identity. Keyed by display ID
    /// they go stale the moment macOS re-enumerates the display.
    func testSnapshotsAreKeyedByStableIdentity() {
        let identity = "v16652m49551s3212"
        let manager = managerWithReEnumeratedDisplay(identity: identity, currentID: 2)
        manager.displays[0].warmth = 0.42
        manager.displays[0].contrast = 0.7

        XCTAssertEqual(Array(manager.currentBrightnessSnapshot().keys), [identity])
        XCTAssertEqual(Array(manager.currentWarmthSnapshot().keys), [identity])
        XCTAssertEqual(Array(manager.currentContrastSnapshot().keys), [identity])
    }

    /// A preset saved before re-enumeration must still apply afterwards. Previously the lookup
    /// keyed on the old display ID, so the display was silently skipped and the preset did nothing.
    func testApplyBrightnessValuesResolvesPresetSavedUnderIdentity() {
        let identity = "v16652m49551s3212"
        let manager = managerWithReEnumeratedDisplay(identity: identity, currentID: 11)

        manager.applyBrightnessValues([identity: 0.35])

        XCTAssertEqual(manager.displays[0].brightness, 0.35, accuracy: 0.0001)
    }

    func testApplyWarmthValuesResolvesPresetSavedUnderIdentity() {
        let identity = "v16652m49551s3212"
        let manager = managerWithReEnumeratedDisplay(identity: identity, currentID: 11)

        manager.applyWarmthValues([identity: 0.62])

        XCTAssertEqual(manager.displays[0].warmth, 0.62, accuracy: 0.0001)
    }

    func testApplyContrastValuesResolvesPresetSavedUnderIdentity() {
        let identity = "v16652m49551s3212"
        let manager = managerWithReEnumeratedDisplay(identity: identity, currentID: 11)

        manager.applyContrastValues([identity: 0.8])

        XCTAssertEqual(manager.displays[0].contrast, 0.8, accuracy: 0.0001)
    }

    /// Presets saved by earlier versions hold raw display-ID keys. Those must keep working, so
    /// nobody's existing presets break on upgrade.
    func testApplyValuesStillHonoursLegacyDisplayIDKeyedPresets() {
        let manager = managerWithReEnumeratedDisplay(identity: "v16652m49551s3212", currentID: 11)

        manager.applyBrightnessValues(["11": 0.4])
        manager.applyWarmthValues(["11": 0.55])
        manager.applyContrastValues(["11": 0.65])

        XCTAssertEqual(manager.displays[0].brightness, 0.4, accuracy: 0.0001)
        XCTAssertEqual(manager.displays[0].warmth, 0.55, accuracy: 0.0001)
        XCTAssertEqual(manager.displays[0].contrast, 0.65, accuracy: 0.0001)
    }

    /// The animated path builds its own per-display targets, so it needs the same resolution —
    /// applying a preset from the menu animates by default.
    func testAnimateToPresetResolvesPerDisplayValuesByIdentity() {
        let identity = "v16652m49551s3212"
        let manager = managerWithReEnumeratedDisplay(identity: identity, currentID: 11)
        manager.canAnimateTransitionsHook = { true }

        let preset = BrightnessPreset(
            name: "Evening",
            displayBrightness: [identity: 0.5],
            displayWarmth: [identity: 0.42],
            displayContrast: [identity: 0.6]
        )
        XCTAssertTrue(manager.animateToPreset(preset), "Animation should start")

        let settled = expectation(description: "animation reached the preset values")
        Task { @MainActor in
            for _ in 0 ..< 300 where abs(manager.displays[0].warmth - 0.42) > 0.001 {
                try? await Task.sleep(for: .milliseconds(10))
            }
            settled.fulfill()
        }
        wait(for: [settled], timeout: 5.0)

        XCTAssertEqual(manager.displays[0].brightness, 0.5, accuracy: 0.001)
        XCTAssertEqual(manager.displays[0].warmth, 0.42, accuracy: 0.001)
        XCTAssertEqual(manager.displays[0].contrast, 0.6, accuracy: 0.001)
    }
}

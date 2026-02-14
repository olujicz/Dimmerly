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
    }

    override func tearDown() async throws {
        bm = nil
    }

    // MARK: - channelMultipliers

    func testChannelMultipliersNeutral() {
        let m = BrightnessManager.channelMultipliers(for: 0.0)
        XCTAssertEqual(m.r, 1.0)
        XCTAssertEqual(m.g, 1.0)
        XCTAssertEqual(m.b, 1.0)
    }

    func testChannelMultipliersMaxWarmth() {
        let m = BrightnessManager.channelMultipliers(for: 1.0)
        XCTAssertEqual(m.r, 1.0, accuracy: 0.001)
        XCTAssertEqual(m.g, 0.82, accuracy: 0.001)
        XCTAssertEqual(m.b, 0.56, accuracy: 0.001)
    }

    func testChannelMultipliersMidpoint() {
        let m = BrightnessManager.channelMultipliers(for: 0.5)
        XCTAssertEqual(m.r, 1.0, accuracy: 0.001)
        XCTAssertEqual(m.g, 0.91, accuracy: 0.001)
        XCTAssertEqual(m.b, 0.78, accuracy: 0.001)
    }

    func testChannelMultipliersMonotonicity() {
        // Green and blue channels should decrease as warmth increases
        let steps = stride(from: 0.0, through: 0.9, by: 0.1)
        for w in steps {
            let m1 = BrightnessManager.channelMultipliers(for: w)
            let m2 = BrightnessManager.channelMultipliers(for: w + 0.1)
            XCTAssertGreaterThanOrEqual(m1.g, m2.g, "Green should decrease with warmth")
            XCTAssertGreaterThanOrEqual(m1.b, m2.b, "Blue should decrease with warmth")
        }
    }

    // MARK: - applyContrast

    func testApplyContrastIdentity() {
        // At contrast=0.5 (neutral), output should equal input
        for t in stride(from: 0.0, through: 1.0, by: 0.1) {
            XCTAssertEqual(BrightnessManager.applyContrast(t, contrast: 0.5), t, accuracy: 0.0001)
        }
    }

    func testApplyContrastEndpointPreservation() {
        // Endpoints 0.0 and 1.0 should be preserved at any contrast
        for c in [0.0, 0.25, 0.5, 0.75, 1.0] {
            XCTAssertEqual(BrightnessManager.applyContrast(0.0, contrast: c), 0.0, accuracy: 0.0001,
                           "t=0 should map to 0 at contrast=\(c)")
            XCTAssertEqual(BrightnessManager.applyContrast(1.0, contrast: c), 1.0, accuracy: 0.0001,
                           "t=1 should map to 1 at contrast=\(c)")
        }
    }

    func testApplyContrastMidpointPreservation() {
        // Midpoint t=0.5 should map to 0.5 at any contrast
        for c in [0.0, 0.25, 0.75, 1.0] {
            XCTAssertEqual(BrightnessManager.applyContrast(0.5, contrast: c), 0.5, accuracy: 0.0001,
                           "t=0.5 should map to 0.5 at contrast=\(c)")
        }
    }

    func testApplyContrastSteepening() {
        // At high contrast, values near 0 should be pushed lower, values near 1 pushed higher
        let highContrast = BrightnessManager.applyContrast(0.25, contrast: 0.9)
        XCTAssertLessThan(highContrast, 0.25, "High contrast should push low values lower")

        let highContrastHigh = BrightnessManager.applyContrast(0.75, contrast: 0.9)
        XCTAssertGreaterThan(highContrastHigh, 0.75, "High contrast should push high values higher")
    }

    func testApplyContrastFlattening() {
        // At low contrast, values near 0 should be pushed higher, values near 1 pushed lower
        let lowContrast = BrightnessManager.applyContrast(0.25, contrast: 0.1)
        XCTAssertGreaterThan(lowContrast, 0.25, "Low contrast should push low values higher")

        let lowContrastHigh = BrightnessManager.applyContrast(0.75, contrast: 0.1)
        XCTAssertLessThan(lowContrastHigh, 0.75, "Low contrast should push high values lower")
    }

    func testApplyContrastSymmetry() {
        // S-curve should be symmetric around 0.5
        for c in [0.0, 0.3, 0.7, 1.0] {
            let low = BrightnessManager.applyContrast(0.25, contrast: c)
            let high = BrightnessManager.applyContrast(0.75, contrast: c)
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
        bm.displays = [
            ExternalDisplay(id: 1, name: "A", brightness: 0.5),
            ExternalDisplay(id: 2, name: "B", brightness: 0.8)
        ]
        let snap = bm.currentBrightnessSnapshot()
        XCTAssertEqual(snap["1"], 0.5)
        XCTAssertEqual(snap["2"], 0.8)
        XCTAssertEqual(snap.count, 2)
    }

    func testBrightnessSnapshotEmpty() {
        bm.displays = []
        XCTAssertTrue(bm.currentBrightnessSnapshot().isEmpty)
    }

    func testWarmthSnapshotMultiDisplay() {
        bm.displays = [
            ExternalDisplay(id: 1, name: "A", brightness: 1.0, warmth: 0.2),
            ExternalDisplay(id: 2, name: "B", brightness: 1.0, warmth: 0.9)
        ]
        let snap = bm.currentWarmthSnapshot()
        XCTAssertEqual(snap["1"], 0.2)
        XCTAssertEqual(snap["2"], 0.9)
    }

    func testContrastSnapshotMultiDisplay() {
        bm.displays = [
            ExternalDisplay(id: 1, name: "A", brightness: 1.0, warmth: 0.0, contrast: 0.3),
            ExternalDisplay(id: 2, name: "B", brightness: 1.0, warmth: 0.0, contrast: 0.7)
        ]
        let snap = bm.currentContrastSnapshot()
        XCTAssertEqual(snap["1"], 0.3)
        XCTAssertEqual(snap["2"], 0.7)
    }

    // MARK: - Set all

    func testSetAllBrightness() {
        bm.displays = [
            ExternalDisplay(id: 1, name: "A", brightness: 0.5),
            ExternalDisplay(id: 2, name: "B", brightness: 0.8)
        ]
        bm.setAllBrightness(to: 0.4)
        XCTAssertEqual(bm.displays[0].brightness, 0.4)
        XCTAssertEqual(bm.displays[1].brightness, 0.4)
    }

    func testSetAllWarmth() {
        bm.displays = [
            ExternalDisplay(id: 1, name: "A", brightness: 1.0, warmth: 0.0),
            ExternalDisplay(id: 2, name: "B", brightness: 1.0, warmth: 0.5)
        ]
        bm.setAllWarmth(to: 0.7)
        XCTAssertEqual(bm.displays[0].warmth, 0.7)
        XCTAssertEqual(bm.displays[1].warmth, 0.7)
    }

    func testSetAllContrast() {
        bm.displays = [
            ExternalDisplay(id: 1, name: "A", brightness: 1.0, warmth: 0.0, contrast: 0.5),
            ExternalDisplay(id: 2, name: "B", brightness: 1.0, warmth: 0.0, contrast: 0.5)
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
            ExternalDisplay(id: 2, name: "B", brightness: 1.0)
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
            ExternalDisplay(id: 2, name: "B", brightness: 1.0, warmth: 0.0)
        ]
        bm.applyWarmthValues(["1": 0.4, "2": 0.8])
        XCTAssertEqual(bm.displays[0].warmth, 0.4)
        XCTAssertEqual(bm.displays[1].warmth, 0.8)
    }

    func testApplyContrastValuesMatchingDisplays() {
        bm.displays = [
            ExternalDisplay(id: 1, name: "A", brightness: 1.0, warmth: 0.0, contrast: 0.5),
            ExternalDisplay(id: 2, name: "B", brightness: 1.0, warmth: 0.0, contrast: 0.5)
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
}

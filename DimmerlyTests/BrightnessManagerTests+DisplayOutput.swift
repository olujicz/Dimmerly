//
//  BrightnessManagerTests+DisplayOutput.swift
//  DimmerlyTests
//
//  Characterization tests for hardware and software display output selection.
//

@testable import Dimmerly
import XCTest

@MainActor
extension BrightnessManagerTests {
    #if !APPSTORE
        func testTransientRefreshReadFailurePreservesNativeGammaAndSkipsBacklightWrite() {
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
            bm.isBuiltInBacklightAPIAvailableHook = { true }
            bm.readBuiltInBrightnessHook = { _ in nil }
            var gammaBrightness: Double?
            bm.applyGammaHook = { _, brightness, _, _ in
                gammaBrightness = brightness
            }

            var backlightWrites: [(CGDirectDisplayID, Double)] = []
            bm.setBuiltInBacklightHook = { displayID, value in
                backlightWrites.append((displayID, value))
                return true
            }

            bm.refreshDisplays()

            XCTAssertEqual(bm.displays.count, 1)
            XCTAssertEqual(bm.displays[0].brightness, 0.37, accuracy: 0.001)
            XCTAssertEqual(gammaBrightness ?? -1, 1.0, accuracy: 0.001)
            XCTAssertTrue(
                backlightWrites.isEmpty,
                "A transient read failure must not cause a model value to be written to the panel"
            )
        }

        func testLowSuccessfulBuiltInReadThenTransientRefreshFailureKeepsNativeGamma() {
            let displayID: CGDirectDisplayID = 43
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
            bm.isBuiltInBacklightAPIAvailableHook = { true }

            var nativeBrightness: Double? = 0.05
            bm.readBuiltInBrightnessHook = { _ in nativeBrightness }

            var gammaBrightness: [Double] = []
            bm.applyGammaHook = { id, brightness, _, _ in
                guard id == displayID else { return }
                gammaBrightness.append(brightness)
            }

            var backlightWrites: [Double] = []
            bm.setBuiltInBacklightHook = { _, value in
                backlightWrites.append(value)
                return true
            }

            bm.refreshDisplays()

            XCTAssertEqual(bm.displays[0].brightness, 0.05, accuracy: 0.001)
            XCTAssertTrue(backlightWrites.isEmpty)
            XCTAssertEqual(gammaBrightness.last ?? -1, 1.0, accuracy: 0.001)

            nativeBrightness = nil
            bm.refreshDisplays()

            XCTAssertEqual(bm.displays[0].brightness, 0.05, accuracy: 0.001)
            XCTAssertTrue(backlightWrites.isEmpty)
            XCTAssertEqual(gammaBrightness.last ?? -1, 1.0, accuracy: 0.001)
        }

        func testLowSuccessfulBuiltInReadDoesNotWriteBackDuringRefresh() {
            let displayID: CGDirectDisplayID = 48
            var builtIn = ExternalDisplay(id: displayID, name: "Built-in", brightness: 1.0)
            builtIn.isBuiltIn = true
            bm.displays = [builtIn]
            bm.activeDisplayIDsHook = { [displayID] }
            bm.isBuiltInDisplayHook = { $0 == displayID }
            bm.isBuiltInBacklightAPIAvailableHook = { true }
            bm.readBuiltInBrightnessHook = { _ in 0.05 }

            var backlightWrites: [Double] = []
            bm.setBuiltInBacklightHook = { _, value in
                backlightWrites.append(value)
                return false
            }
            var gammaBrightness: Double?
            bm.applyGammaHook = { _, brightness, _, _ in
                gammaBrightness = brightness
            }

            bm.refreshDisplays()

            XCTAssertEqual(bm.displays[0].brightness, 0.05, accuracy: 0.001)
            XCTAssertEqual(gammaBrightness ?? -1, 1.0, accuracy: 0.001)
            XCTAssertTrue(backlightWrites.isEmpty)
        }

        func testFailedBuiltInWriteIgnoresSuccessfulPollingRead() {
            let displayID: CGDirectDisplayID = 44
            var builtIn = ExternalDisplay(id: displayID, name: "Built-in", brightness: 1.0)
            builtIn.isBuiltIn = true
            bm.displays = [builtIn]
            bm.isBuiltInBacklightAPIAvailableHook = { true }
            bm.readBuiltInBrightnessHook = { _ in 0.8 }

            var writeCount = 0
            bm.setBuiltInBacklightHook = { _, _ in
                writeCount += 1
                return false
            }

            var gammaBrightness: [Double] = []
            bm.applyGammaHook = { _, brightness, _, _ in
                gammaBrightness.append(brightness)
            }

            bm.setBrightness(for: displayID, to: 0.35)
            bm.syncBuiltInBrightnessForTesting()
            bm.setWarmth(for: displayID, to: 0.2)

            XCTAssertEqual(writeCount, 1)
            XCTAssertEqual(bm.displays[0].brightness, 0.35, accuracy: 0.001)
            XCTAssertEqual(gammaBrightness.last ?? -1, 0.35, accuracy: 0.001)
        }

        func testFailedBuiltInWriteRefreshRetriesPreservedTarget() {
            let displayID: CGDirectDisplayID = 45
            var builtIn = ExternalDisplay(id: displayID, name: "Built-in", brightness: 1.0)
            builtIn.isBuiltIn = true
            bm.displays = [builtIn]
            bm.activeDisplayIDsHook = { [displayID] }
            bm.isBuiltInDisplayHook = { $0 == displayID }
            bm.isBuiltInBacklightAPIAvailableHook = { true }
            bm.readBuiltInBrightnessHook = { _ in 0.8 }

            var writes: [Double] = []
            bm.setBuiltInBacklightHook = { _, value in
                writes.append(value)
                return writes.count > 1
            }
            bm.applyGammaHook = { _, _, _, _ in }

            bm.setBrightness(for: displayID, to: 0.35)
            bm.refreshDisplays()

            XCTAssertEqual(writes, [0.35, 0.35])
            XCTAssertEqual(bm.displays[0].brightness, 0.35, accuracy: 0.001)
        }

        func testDisconnectedBuiltInPrunesWriteFailureFallback() {
            let displayID: CGDirectDisplayID = 46
            var builtIn = ExternalDisplay(id: displayID, name: "Built-in", brightness: 0.35)
            builtIn.isBuiltIn = true
            bm.displays = [builtIn]
            bm.activeDisplayIDsHook = { [displayID] }
            bm.isBuiltInDisplayHook = { $0 == displayID }
            bm.isBuiltInBacklightAPIAvailableHook = { true }
            bm.readBuiltInBrightnessHook = { _ in nil }

            bm.setBuiltInBacklightHook = { _, _ in false }
            bm.applyGammaHook = { _, _, _, _ in }
            bm.setBrightness(for: displayID, to: 0.35)

            bm.activeDisplayIDsHook = { [] }
            bm.refreshDisplays()

            var gammaBrightness: Double?
            bm.displays = [builtIn]
            bm.activeDisplayIDsHook = { [displayID] }
            bm.applyGammaHook = { _, brightness, _, _ in
                gammaBrightness = brightness
            }
            bm.refreshDisplays()

            XCTAssertEqual(gammaBrightness ?? -1, 1.0, accuracy: 0.001)
        }

        func testUnavailableBuiltInBacklightAPIUsesGammaAtStartup() throws {
            let suiteName = "BrightnessManagerTests-\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
            defer { defaults.removePersistentDomain(forName: suiteName) }
            defaults.set(["built-in-test": 0.37], forKey: "dimmerlyDisplayBrightness")

            let manager = BrightnessManager(forTesting: true, defaults: defaults)
            let displayID: CGDirectDisplayID = 47
            XCTAssertTrue(manager.displays.isEmpty)
            manager.displayIdentityHook = { _ in "built-in-test" }
            manager.activeDisplayIDsHook = { [displayID] }
            manager.isBuiltInDisplayHook = { $0 == displayID }
            manager.isBuiltInBacklightAPIAvailableHook = { false }

            var gammaBrightness: Double?
            manager.applyGammaHook = { _, brightness, _, _ in
                gammaBrightness = brightness
            }
            var backlightWrites: [Double] = []
            manager.setBuiltInBacklightHook = { _, value in
                backlightWrites.append(value)
                return true
            }

            manager.refreshDisplays()

            XCTAssertEqual(manager.displays.count, 1)
            XCTAssertEqual(manager.displays[0].brightness, 0.37, accuracy: 0.001)
            XCTAssertEqual(gammaBrightness ?? -1, 0.37, accuracy: 0.001)
            XCTAssertTrue(backlightWrites.isEmpty)
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
}

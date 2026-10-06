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
    func testPersistenceIdentityPreservesLegacyKeysForMissingUnitNumbers() {
        for unitNumber in [UInt32(0), UInt32.max] {
            let key = BrightnessManager.persistenceIdentity(
                vendor: 0x10AC, model: 0xD0A1, serial: 0, unitNumber: unitNumber, displayID: 11
            )

            XCTAssertEqual(key, "v4268m53409u\(unitNumber)")
            XCTAssertNil(BrightnessManager.stableDisplayIdentity(
                vendor: 0x10AC, model: 0xD0A1, serial: 0, unitNumber: unitNumber
            ))
        }
    }

    func testRefreshAndPresetsRestoreLegacyMissingUnitNumberKeysAfterIDChange() throws {
        for unitNumber in [UInt32(0), UInt32.max] {
            let suiteName = "BrightnessManagerTests-\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let legacyKey = "v4268m53409u\(unitNumber)"
            defaults.set([legacyKey: 0.35], forKey: "dimmerlyDisplayBrightness")
            defaults.set([legacyKey: 0.47], forKey: "dimmerlyDisplayWarmth")
            defaults.set([legacyKey: 0.8], forKey: "dimmerlyDisplayContrast")

            let manager = BrightnessManager(forTesting: true, defaults: defaults)
            manager.applyGammaHook = { _, _, _, _ in }
            manager.isBuiltInDisplayHook = { _ in false }
            manager.displayIdentityHook = { displayID in
                BrightnessManager.persistenceIdentity(
                    vendor: 0x10AC, model: 0xD0A1, serial: 0,
                    unitNumber: unitNumber, displayID: displayID
                )
            }
            manager.activeDisplayIDsHook = { [11] }
            manager.refreshDisplays()

            XCTAssertEqual(manager.displays[0].brightness, 0.35, accuracy: 0.0001)
            XCTAssertEqual(manager.displays[0].warmth, 0.47, accuracy: 0.0001)
            XCTAssertEqual(manager.displays[0].contrast, 0.8, accuracy: 0.0001)

            manager.applyBrightnessValues([legacyKey: 0.6])
            manager.applyWarmthValues([legacyKey: 0.2])
            manager.applyContrastValues([legacyKey: 0.7])

            XCTAssertEqual(manager.displays[0].brightness, 0.6, accuracy: 0.0001)
            XCTAssertEqual(manager.displays[0].warmth, 0.2, accuracy: 0.0001)
            XCTAssertEqual(manager.displays[0].contrast, 0.7, accuracy: 0.0001)
        }
    }

    #if !APPSTORE
        /// Installs a single built-in display plus the hooks every built-in output test needs,
        /// so each test only spells out the part that actually differs.
        @discardableResult
        private func installBuiltInDisplay(
            id displayID: CGDirectDisplayID,
            brightness: Double = 1.0,
            warmth: Double = 0.0,
            contrast: Double = ExternalDisplay.neutralContrast
        ) -> ExternalDisplay {
            var builtIn = ExternalDisplay(
                id: displayID,
                name: "Built-in",
                brightness: brightness,
                warmth: warmth,
                contrast: contrast
            )
            builtIn.isBuiltIn = true
            bm.displays = [builtIn]
            bm.activeDisplayIDsHook = { [displayID] }
            bm.isBuiltInDisplayHook = { $0 == displayID }
            bm.isBuiltInBacklightAPIAvailableHook = { true }
            return builtIn
        }

        func testTransientRefreshReadFailurePreservesNativeGammaAndSkipsBacklightWrite() {
            let displayID: CGDirectDisplayID = 42
            installBuiltInDisplay(id: displayID, brightness: 0.37, warmth: 0.2, contrast: 0.6)
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
            installBuiltInDisplay(id: displayID, brightness: 0.37, warmth: 0.2, contrast: 0.6)

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
            installBuiltInDisplay(id: displayID, brightness: 1.0)
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
            installBuiltInDisplay(id: displayID, brightness: 1.0)
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
            let builtIn = installBuiltInDisplay(id: displayID, brightness: 0.35)
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
                output: .gamma,
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
                output: .ddc,
                gammaBrightness: 1.0,
                appliesGammaColorAdjustments: true
            ))
        }

        func testDisplayOutputPolicyPrefersNativeExternalBacklightOverDDC() {
            let policy = DisplayOutputPolicy.resolve(
                mode: .hardware,
                isBuiltIn: false,
                isDDCEnabled: true,
                supportsDDCBrightness: true,
                supportsNativeBacklight: true,
                experimentalNativeBrightnessEnabled: true,
                requestedBrightness: 0.35
            )

            XCTAssertEqual(policy.output, .externalBacklight)
            XCTAssertEqual(policy.gammaBrightness, 1.0)
        }

        func testDisplayOutputPolicyKeepsNativeExternalBacklightInSoftwareFallback() {
            let policy = DisplayOutputPolicy.resolve(
                mode: .hardware,
                isBuiltIn: false,
                isDDCEnabled: true,
                supportsDDCBrightness: true,
                supportsNativeBacklight: true,
                experimentalNativeBrightnessEnabled: true,
                requestedBrightness: 0.35,
                nativeBacklightAvailable: false
            )

            XCTAssertEqual(policy.output, .externalBacklightFallback)
            XCTAssertEqual(policy.gammaBrightness, 0.35)
        }

        func testDisplayOutputPolicySoftwareOnlyIgnoresNativeExternalBacklight() {
            let policy = DisplayOutputPolicy.resolve(
                mode: .softwareOnly,
                isBuiltIn: false,
                isDDCEnabled: true,
                supportsDDCBrightness: true,
                supportsNativeBacklight: true,
                requestedBrightness: 0.35
            )

            XCTAssertEqual(policy.output, .gamma)
            XCTAssertEqual(policy.gammaBrightness, 0.35)
        }

        func testDisplayOutputPolicyKeepsNativeBacklightOptInOffByDefault() {
            let policy = DisplayOutputPolicy.resolve(
                mode: .hardware,
                isBuiltIn: false,
                isDDCEnabled: true,
                supportsDDCBrightness: true,
                supportsNativeBacklight: true,
                requestedBrightness: 0.35
            )

            XCTAssertEqual(policy.output, .ddc)
            XCTAssertEqual(policy.gammaBrightness, 1.0)
        }

        func testNativeExternalBacklightWriteWinsOverDDCWithoutGammaDoubleDimming() {
            let displayID: CGDirectDisplayID = 91
            HardwareBrightnessManager.shared.applyRuntimeSettings(
                controlMode: .hardware,
                pollingInterval: 5,
                writeDelayMilliseconds: 50,
                experimentalNativeBrightnessEnabled: true
            )
            var external = ExternalDisplay(id: displayID, name: "Apple Studio Display", brightness: 1.0)
            external.supportsDDC = true
            external.supportsNativeBacklight = true
            bm.displays = [external]

            HardwareBrightnessManager.shared.capabilities[displayID] = HardwareDisplayCapability(
                displayID: displayID,
                supportsDDC: true,
                supportedCodes: [.brightness],
                maxBrightness: 100,
                maxContrast: 100,
                maxVolume: 0
            )

            var nativeWrites: [(CGDirectDisplayID, Double)] = []
            bm.setExternalNativeBacklightHook = { id, value in
                nativeWrites.append((id, value))
                return true
            }
            var ddcWrites = 0
            bm.setExternalHardwareBrightnessHook = { _, _ in ddcWrites += 1 }
            var gammaBrightness: Double?
            bm.applyGammaHook = { id, brightness, _, _ in
                guard id == displayID else { return }
                gammaBrightness = brightness
            }

            bm.setBrightness(for: displayID, to: 0.35)

            XCTAssertEqual(nativeWrites.count, 1)
            XCTAssertEqual(nativeWrites[0].0, displayID)
            XCTAssertEqual(nativeWrites[0].1, 0.35, accuracy: 0.001)
            XCTAssertEqual(ddcWrites, 0)
            XCTAssertEqual(gammaBrightness ?? -1, 1.0, accuracy: 0.001)
        }

        func testFailedNativeExternalBacklightWriteFallsBackToGammaThenRecovers() {
            let displayID: CGDirectDisplayID = 92
            HardwareBrightnessManager.shared.applyRuntimeSettings(
                controlMode: .hardware,
                pollingInterval: 5,
                writeDelayMilliseconds: 50,
                experimentalNativeBrightnessEnabled: true
            )
            var external = ExternalDisplay(id: displayID, name: "LG UltraFine", brightness: 1.0)
            external.supportsNativeBacklight = true
            bm.displays = [external]

            var nativeWriteSucceeds = false
            bm.setExternalNativeBacklightHook = { _, _ in nativeWriteSucceeds }
            var gammaBrightness: Double?
            bm.applyGammaHook = { id, brightness, _, _ in
                guard id == displayID else { return }
                gammaBrightness = brightness
            }

            bm.setBrightness(for: displayID, to: 0.35)
            XCTAssertEqual(gammaBrightness ?? -1, 0.35, accuracy: 0.001)

            nativeWriteSucceeds = true
            bm.setBrightness(for: displayID, to: 0.4)
            XCTAssertEqual(gammaBrightness ?? -1, 1.0, accuracy: 0.001)
        }

        func testOptingOutRestoresDDCBrightnessWrites() {
            let displayID: CGDirectDisplayID = 96
            HardwareBrightnessManager.shared.capabilities[displayID] = HardwareDisplayCapability(
                displayID: displayID,
                supportsDDC: true,
                supportedCodes: [.brightness],
                maxBrightness: 100,
                maxContrast: 100,
                maxVolume: 0
            )
            var external = ExternalDisplay(id: displayID, name: "Apple Studio Display", brightness: 1.0)
            external.supportsNativeBacklight = true
            bm.displays = [external]
            var nativeWrites = 0
            bm.setExternalNativeBacklightHook = { _, _ in
                nativeWrites += 1
                return true
            }
            var ddcWrites = 0
            bm.setExternalHardwareBrightnessHook = { _, _ in ddcWrites += 1 }

            HardwareBrightnessManager.shared.applyRuntimeSettings(
                controlMode: .hardware,
                pollingInterval: 5,
                writeDelayMilliseconds: 50,
                experimentalNativeBrightnessEnabled: true
            )
            HardwareBrightnessManager.shared.applyRuntimeSettings(
                controlMode: .hardware,
                pollingInterval: 5,
                writeDelayMilliseconds: 50,
                experimentalNativeBrightnessEnabled: false
            )

            bm.setBrightness(for: displayID, to: 0.35)

            XCTAssertEqual(nativeWrites, 0)
            XCTAssertEqual(ddcWrites, 1)
        }

        func testNativeExternalReadDiscoversCapabilityAfterOptIn() {
            let displayID: CGDirectDisplayID = 93
            var external = ExternalDisplay(id: displayID, name: "Apple Studio Display", brightness: 0.4)
            external.supportsDDC = true
            bm.displays = [external]
            bm.displayIdentityHook = { _ in "studio-display" }
            bm.activeDisplayIDsHook = { [displayID] }
            bm.isBuiltInDisplayHook = { _ in false }
            bm.readExternalNativeBacklightHook = { _ in 0.9 }
            HardwareBrightnessManager.shared.applyRuntimeSettings(
                controlMode: .hardware,
                pollingInterval: 5,
                writeDelayMilliseconds: 50,
                experimentalNativeBrightnessEnabled: true
            )

            var gammaBrightness: Double?
            bm.applyGammaHook = { _, brightness, _, _ in gammaBrightness = brightness }

            bm.refreshDisplays()

            XCTAssertTrue(bm.displays[0].supportsNativeBacklight)
            XCTAssertEqual(bm.displays[0].brightness, 0.9, accuracy: 0.001)
            XCTAssertEqual(gammaBrightness ?? -1, 1.0, accuracy: 0.001)

            bm.synchronizeExternalHardwareBrightness(for: displayID, to: 0.2)
            XCTAssertEqual(
                bm.displays[0].brightness,
                0.9,
                accuracy: 0.001,
                "A queued DDC read must not overwrite a display discovered as native-capable"
            )
        }

        func testNativeReadsAndWritesStopWhenOptInIsOff() {
            let displayID: CGDirectDisplayID = 97
            bm.displays = [ExternalDisplay(id: displayID, name: "External", brightness: 0.4)]
            bm.activeDisplayIDsHook = { [displayID] }
            bm.isBuiltInDisplayHook = { _ in false }
            bm.displayIdentityHook = { _ in "native-test-display" }
            bm.applyGammaHook = { _, _, _, _ in }
            var reads = 0
            var writes = 0
            bm.readExternalNativeBacklightHook = { _ in
                reads += 1
                return 0.8
            }
            bm.setExternalNativeBacklightHook = { _, _ in
                writes += 1
                return true
            }

            bm.refreshDisplays()
            bm.syncBuiltInBrightnessForTesting()
            bm.setBrightness(for: displayID, to: 0.3)
            XCTAssertEqual(reads, 0)
            XCTAssertEqual(writes, 0)

            HardwareBrightnessManager.shared.applyRuntimeSettings(
                controlMode: .hardware, pollingInterval: 5, writeDelayMilliseconds: 50,
                experimentalNativeBrightnessEnabled: true
            )
            bm.refreshDisplays()
            XCTAssertEqual(reads, 1)
            XCTAssertTrue(bm.displays[0].supportsNativeBacklight)

            HardwareBrightnessManager.shared.applyRuntimeSettings(
                controlMode: .hardware, pollingInterval: 5, writeDelayMilliseconds: 50,
                experimentalNativeBrightnessEnabled: false
            )
            bm.syncBuiltInBrightnessForTesting()
            bm.setBrightness(for: displayID, to: 0.3)
            bm.refreshDisplays()
            XCTAssertEqual(reads, 1, "Cached native support must not allow reads after opt-out")
            XCTAssertEqual(writes, 0, "Cached native support must not allow writes after opt-out")
            XCTAssertFalse(bm.displays[0].supportsNativeBacklight)
        }

        func testSoftwareOnlyDoesNotProbeOrProjectExternalNativeBrightness() {
            let displayID: CGDirectDisplayID = 95
            let external = ExternalDisplay(id: displayID, name: "Apple Studio Display", brightness: 0.4)
            bm.displays = [external]
            bm.displayIdentityHook = { _ in "studio-display" }
            bm.activeDisplayIDsHook = { [displayID] }
            bm.isBuiltInDisplayHook = { _ in false }
            var nativeReads = 0
            bm.readExternalNativeBacklightHook = { _ in
                nativeReads += 1
                return 0.9
            }
            HardwareBrightnessManager.shared.applyRuntimeSettings(
                controlMode: .softwareOnly,
                pollingInterval: 5,
                writeDelayMilliseconds: 50,
                experimentalNativeBrightnessEnabled: true
            )
            var gammaBrightness: Double?
            bm.applyGammaHook = { _, brightness, _, _ in gammaBrightness = brightness }

            bm.refreshDisplays()

            XCTAssertEqual(nativeReads, 0)
            XCTAssertFalse(bm.displays[0].supportsNativeBacklight)
            XCTAssertEqual(bm.displays[0].brightness, 0.4, accuracy: 0.001)
            XCTAssertEqual(gammaBrightness ?? -1, 0.4, accuracy: 0.001)
        }

        func testReusedDisplayIDDoesNotInheritNativeBacklightCapabilityAfterIdentityChange() async {
            let displayID: CGDirectDisplayID = 94
            var previous = ExternalDisplay(id: displayID, name: "Previous", brightness: 0.4)
            previous.supportsNativeBacklight = true
            bm.displays = [previous]
            var identity = "old-display"
            bm.displayIdentityHook = { _ in identity }
            bm.activeDisplayIDsHook = { [displayID] }
            bm.readExternalNativeBacklightHook = { _ in nil }
            HardwareBrightnessManager.shared.applyRuntimeSettings(
                controlMode: .hardware,
                pollingInterval: 5,
                writeDelayMilliseconds: 50,
                experimentalNativeBrightnessEnabled: true
            )
            await HardwareBrightnessManager.shared.disable()
            identity = "replacement-display"

            bm.refreshDisplays()

            XCTAssertFalse(bm.displays[0].supportsNativeBacklight)
            XCTAssertFalse(bm.supportsNativeBacklight(for: displayID))
        }

        func testDisplayOutputPolicyFallsBackWhenDDCIsUnavailable() {
            let policy = DisplayOutputPolicy.resolve(
                mode: .hardware,
                isBuiltIn: false,
                isDDCEnabled: true,
                supportsDDCBrightness: false,
                requestedBrightness: 0.35
            )

            XCTAssertEqual(policy.output, .gamma)
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

            XCTAssertEqual(policy.output, .builtInBacklight)
            XCTAssertTrue(policy.output.writesBuiltInBacklight)
            XCTAssertEqual(policy.gammaBrightness, 1.0)
        }

        func testDisplayOutputPolicyKeepsWritingBuiltInBacklightWhileInSoftwareFallback() {
            let policy = DisplayOutputPolicy.resolve(
                mode: .hardware,
                isBuiltIn: true,
                isDDCEnabled: true,
                supportsDDCBrightness: false,
                requestedBrightness: 0.35,
                builtInBacklightAvailable: false
            )

            XCTAssertEqual(policy.output, .builtInBacklightFallback)
            XCTAssertTrue(
                policy.output.writesBuiltInBacklight,
                "A panel in fallback must keep being written to, otherwise it can never recover"
            )
            XCTAssertEqual(policy.gammaBrightness, 0.35, "Gamma carries brightness while the panel is unhealthy")
        }

    #endif
}

#if !APPSTORE
    extension HardwareBrightnessManagerTests {
        func testRapidOptInChangesPreserveNewBrightnessWriteAccounting() async {
            let writeStarted = expectation(description: "New brightness write reached hardware")
            let recorder = BlockingDDCRecorder(firstCallStarted: writeStarted)
            var mock = MockDDCInterface()
            mock.writeHandler = { code, _, _ in
                recorder.record(code)
                return true
            }
            let manager = HardwareBrightnessManager(forTesting: true, ddcInterface: mock)
            manager.enable()
            manager.capabilities[84] = HardwareDisplayCapability(
                displayID: 84, supportsDDC: true, supportedCodes: [.brightness],
                maxBrightness: 100, maxContrast: 100, maxVolume: 0
            )

            manager.setHardwareBrightness(for: 84, to: 0.2)
            for enabled in [true, false] {
                manager.applyRuntimeSettings(
                    controlMode: .hardware, pollingInterval: 5, writeDelayMilliseconds: 50,
                    experimentalNativeBrightnessEnabled: enabled
                )
            }
            manager.setHardwareBrightness(for: 84, to: 0.7)
            await fulfillment(of: [writeStarted], timeout: 1)

            XCTAssertEqual(
                manager.pendingWorkCountForTesting, 1,
                "Cleanup from the old brightness request must not erase the new in-flight write"
            )
            recorder.releaseFirstCall()
            await manager.disable()
        }

        func testOptingInInvalidatesQueuedDDCBrightnessWrite() async {
            let displayID: CGDirectDisplayID = 83
            let probeStarted = expectation(description: "DDC probe blocks the write queue")
            let unexpectedWrite = expectation(description: "Stale DDC brightness write is dropped")
            unexpectedWrite.isInverted = true
            let blockingProbe = BlockingDDCRecorder(firstCallStarted: probeStarted)
            var mock = MockDDCInterface()
            mock.probeWithSkipHandler = { probedID, _ in
                blockingProbe.record(.brightness)
                return HardwareDisplayCapability(
                    displayID: probedID,
                    supportsDDC: true,
                    supportedCodes: [.brightness],
                    maxBrightness: 100,
                    maxContrast: 100,
                    maxVolume: 0
                )
            }
            mock.writeHandler = { code, _, _ in
                if code == .brightness {
                    unexpectedWrite.fulfill()
                }
                return true
            }
            let manager = HardwareBrightnessManager(
                forTesting: true,
                ddcInterface: mock,
                connectedExternalDisplayIDsProvider: { [displayID] },
                displayRefreshHandler: {},
                nativeBrightnessSupportProvider: { $0 == displayID }
            )
            manager.enable()
            manager.capabilities[displayID] = HardwareDisplayCapability(
                displayID: displayID,
                supportsDDC: true,
                supportedCodes: [.brightness],
                maxBrightness: 100,
                maxContrast: 100,
                maxVolume: 0
            )
            manager.probeAllDisplays()
            await fulfillment(of: [probeStarted], timeout: 1)
            manager.setHardwareBrightness(for: displayID, to: 0.3)
            try? await Task.sleep(for: .milliseconds(200))
            manager.applyRuntimeSettings(
                controlMode: .hardware,
                pollingInterval: 5,
                writeDelayMilliseconds: 50,
                experimentalNativeBrightnessEnabled: true
            )
            blockingProbe.releaseFirstCall()

            await fulfillment(of: [unexpectedWrite], timeout: 0.3)
        }

        func testNativeBrightnessRemainsOptInOffForDDCProbeReadAndWrite() async {
            let displayID: CGDirectDisplayID = 82
            let didReadBrightness = expectation(description: "DDC brightness remains readable")
            let skipBrightness = LockedBoolRecorder()
            let writes = LockedWriteRecorder()
            var mock = MockDDCInterface()
            mock.probeWithSkipHandler = { probedID, skippingBrightness in
                skipBrightness.record(skippingBrightness)
                return HardwareDisplayCapability(
                    displayID: probedID,
                    supportsDDC: true,
                    supportedCodes: [.brightness],
                    maxBrightness: 100,
                    maxContrast: 100,
                    maxVolume: 0
                )
            }
            mock.readHandler = { code, _ in
                guard code == .brightness else { return nil }
                didReadBrightness.fulfill()
                return DDCReadResult(currentValue: 50, maxValue: 100)
            }
            mock.writeHandler = { code, value, targetID in
                writes.record(code: code, value: value, displayID: targetID)
                return true
            }
            let manager = HardwareBrightnessManager(
                forTesting: true,
                ddcInterface: mock,
                connectedExternalDisplayIDsProvider: { [displayID] },
                displayRefreshHandler: {},
                nativeBrightnessSupportProvider: { $0 == displayID }
            )
            manager.enable()
            manager.probeAllDisplays()

            await fulfillment(of: [didReadBrightness], timeout: 1)
            XCTAssertFalse(manager.experimentalNativeBrightnessEnabled)
            XCTAssertFalse(skipBrightness.value)
            manager.setHardwareBrightness(for: displayID, to: 0.25)
            try? await Task.sleep(for: .milliseconds(250))
            XCTAssertEqual(writes.values.map(\.code), [.brightness])
        }
    }

#endif

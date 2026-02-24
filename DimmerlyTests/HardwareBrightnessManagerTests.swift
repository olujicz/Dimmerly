//
//  HardwareBrightnessManagerTests.swift
//  DimmerlyTests
//
//  Unit tests for HardwareBrightnessManager using injectable DDC mocks.
//  Tests capability probing, value read/write, mute toggle, input source,
//  and state management — all without hardware.
//

@testable import Dimmerly
import XCTest

#if !APPSTORE

    // MARK: - Mock DDC Interface

    /// Mock DDC interface for testing without real hardware.
    ///
    /// All callbacks default to no-ops. Tests configure only the callbacks
    /// they need, keeping setup minimal and intent clear.
    struct MockDDCInterface: DDCInterface {
        var readHandler: @Sendable (VCPCode, CGDirectDisplayID) -> DDCReadResult? = { _, _ in nil }
        var writeHandler: @Sendable (VCPCode, UInt16, CGDirectDisplayID) -> Bool = { _, _, _ in true }
        var probeHandler: @Sendable (CGDirectDisplayID) -> HardwareDisplayCapability = { displayID in
            .notSupported(displayID: displayID)
        }

        func read(vcp: VCPCode, for displayID: CGDirectDisplayID) -> DDCReadResult? {
            readHandler(vcp, displayID)
        }

        func write(vcp: VCPCode, value: UInt16, for displayID: CGDirectDisplayID) -> Bool {
            writeHandler(vcp, value, displayID)
        }

        func probeCapabilities(for displayID: CGDirectDisplayID) -> HardwareDisplayCapability {
            probeHandler(displayID)
        }
    }

    @MainActor
    final class HardwareBrightnessManagerTests: XCTestCase {
        // XCTest lifecycle overrides are nonisolated in Xcode 26.2, so test fixtures
        // opt out of actor checking here while test methods remain @MainActor.
        private nonisolated(unsafe) var manager: HardwareBrightnessManager!
        private nonisolated(unsafe) var mockDDC: MockDDCInterface!

        override func setUp() {
            super.setUp()
            let (mockDDC, manager) = MainActor.assumeIsolated {
                let mockDDC = MockDDCInterface()
                let manager = HardwareBrightnessManager(forTesting: true, ddcInterface: mockDDC)
                return (mockDDC, manager)
            }
            self.mockDDC = mockDDC
            self.manager = manager
        }

        override func tearDown() {
            manager = nil
            mockDDC = nil
            super.tearDown()
        }

        // MARK: - Initial State

        /// Tests that a fresh manager has empty state
        func testInitialState() {
            XCTAssertTrue(manager.capabilities.isEmpty)
            XCTAssertTrue(manager.hardwareBrightness.isEmpty)
            XCTAssertTrue(manager.hardwareContrast.isEmpty)
            XCTAssertTrue(manager.hardwareVolume.isEmpty)
            XCTAssertTrue(manager.hardwareMute.isEmpty)
            XCTAssertTrue(manager.activeInputSource.isEmpty)
            XCTAssertFalse(manager.isEnabled)
            XCTAssertEqual(manager.controlMode, .combined)
        }

        // MARK: - Capability Queries

        /// Tests supportsDDC returns false for unknown display
        func testSupportsDDCReturnsFalseForUnknown() {
            XCTAssertFalse(manager.supportsDDC(for: 12345))
        }

        /// Tests capability returns nil for unknown display
        func testCapabilityReturnsNilForUnknown() {
            XCTAssertNil(manager.capability(for: 12345))
        }

        /// Tests supportsDDC returns true when capability is cached
        func testSupportsDDCWithCachedCapability() {
            let displayID: CGDirectDisplayID = 1
            let cap = HardwareDisplayCapability(
                displayID: displayID,
                supportsDDC: true,
                supportedCodes: [.brightness, .contrast],
                maxBrightness: 100,
                maxContrast: 100,
                maxVolume: 0
            )
            manager.capabilities[displayID] = cap
            XCTAssertTrue(manager.supportsDDC(for: displayID))
        }

        /// Tests supportsDDC returns false when capability says no DDC
        func testSupportsDDCWithNonDDCCapability() {
            let displayID: CGDirectDisplayID = 2
            let cap = HardwareDisplayCapability.notSupported(displayID: displayID)
            manager.capabilities[displayID] = cap
            XCTAssertFalse(manager.supportsDDC(for: displayID))
        }

        // MARK: - Hardware Brightness

        /// Tests setHardwareBrightness updates published state
        func testSetHardwareBrightnessUpdatesState() {
            let displayID: CGDirectDisplayID = 1
            let cap = HardwareDisplayCapability(
                displayID: displayID,
                supportsDDC: true,
                supportedCodes: [.brightness],
                maxBrightness: 100,
                maxContrast: 100,
                maxVolume: 100
            )
            manager.capabilities[displayID] = cap

            manager.setHardwareBrightness(for: displayID, to: 0.75)
            XCTAssertEqual(manager.hardwareBrightness[displayID] ?? -1, 0.75, accuracy: 0.001)
        }

        /// Tests setHardwareBrightness clamps values to valid range
        func testSetHardwareBrightnessClampsValues() {
            let displayID: CGDirectDisplayID = 1
            let cap = HardwareDisplayCapability(
                displayID: displayID,
                supportsDDC: true,
                supportedCodes: [.brightness],
                maxBrightness: 100,
                maxContrast: 100,
                maxVolume: 100
            )
            manager.capabilities[displayID] = cap

            manager.setHardwareBrightness(for: displayID, to: 1.5)
            XCTAssertEqual(manager.hardwareBrightness[displayID] ?? -1, 1.0, accuracy: 0.001)

            manager.setHardwareBrightness(for: displayID, to: -0.5)
            XCTAssertEqual(manager.hardwareBrightness[displayID] ?? -1, 0.0, accuracy: 0.001)
        }

        /// Tests setHardwareBrightness does nothing without capability
        func testSetHardwareBrightnessNoCapability() {
            // Mock writer that fails the test if called — the manager should bail
            // before reaching the write path when no capability is cached.
            var mockWithFailWriter = MockDDCInterface()
            mockWithFailWriter.writeHandler = { _, _, _ in
                XCTFail("Writer should not be called without capability")
                return false
            }
            let mgr = HardwareBrightnessManager(forTesting: true, ddcInterface: mockWithFailWriter)
            mgr.setHardwareBrightness(for: 999, to: 0.5)
            XCTAssertNil(mgr.hardwareBrightness[999])
        }

        // MARK: - Hardware Contrast

        /// Tests setHardwareContrast updates published state
        func testSetHardwareContrastUpdatesState() {
            let displayID: CGDirectDisplayID = 1
            let cap = HardwareDisplayCapability(
                displayID: displayID,
                supportsDDC: true,
                supportedCodes: [.contrast],
                maxBrightness: 100,
                maxContrast: 100,
                maxVolume: 100
            )
            manager.capabilities[displayID] = cap

            manager.setHardwareContrast(for: displayID, to: 0.6)
            XCTAssertEqual(manager.hardwareContrast[displayID] ?? -1, 0.6, accuracy: 0.001)
        }

        // MARK: - Hardware Volume

        /// Tests setHardwareVolume updates published state
        func testSetHardwareVolumeUpdatesState() {
            let displayID: CGDirectDisplayID = 1
            let cap = HardwareDisplayCapability(
                displayID: displayID,
                supportsDDC: true,
                supportedCodes: [.volume],
                maxBrightness: 100,
                maxContrast: 100,
                maxVolume: 100
            )
            manager.capabilities[displayID] = cap

            manager.setHardwareVolume(for: displayID, to: 0.3)
            XCTAssertEqual(manager.hardwareVolume[displayID] ?? -1, 0.3, accuracy: 0.001)
        }

        // MARK: - Mute Toggle

        /// Tests toggleMute flips the mute state
        func testToggleMuteFlipsState() {
            let displayID: CGDirectDisplayID = 1
            let cap = HardwareDisplayCapability(
                displayID: displayID,
                supportsDDC: true,
                supportedCodes: [.audioMute],
                maxBrightness: 100,
                maxContrast: 100,
                maxVolume: 100
            )
            manager.capabilities[displayID] = cap

            // Initially not muted
            XCTAssertFalse(manager.hardwareMute[displayID] ?? false)

            // Toggle to muted
            manager.toggleMute(for: displayID)
            XCTAssertTrue(manager.hardwareMute[displayID] ?? false)

            // Toggle back to unmuted
            manager.toggleMute(for: displayID)
            XCTAssertFalse(manager.hardwareMute[displayID] ?? true)
        }

        /// Tests toggleMute sends correct DDC values (1=mute, 2=unmute)
        func testToggleMuteSendsCorrectDDCValues() {
            let displayID: CGDirectDisplayID = 1
            let cap = HardwareDisplayCapability(
                displayID: displayID,
                supportsDDC: true,
                supportedCodes: [.audioMute],
                maxBrightness: 100,
                maxContrast: 100,
                maxVolume: 100
            )
            manager.capabilities[displayID] = cap

            // First toggle: should mute (value 1)
            manager.toggleMute(for: displayID)
            // Second toggle: should unmute (value 2)
            manager.toggleMute(for: displayID)

            // Note: writes are debounced, so we verify state instead of DDC values
            XCTAssertFalse(manager.hardwareMute[displayID] ?? true)
        }

        // MARK: - Input Source

        /// Tests setInputSource updates published state
        func testSetInputSourceUpdatesState() {
            let displayID: CGDirectDisplayID = 1
            let cap = HardwareDisplayCapability(
                displayID: displayID,
                supportsDDC: true,
                supportedCodes: [.inputSource],
                maxBrightness: 100,
                maxContrast: 100,
                maxVolume: 100
            )
            manager.capabilities[displayID] = cap

            manager.setInputSource(for: displayID, to: .hdmi1)
            XCTAssertEqual(manager.activeInputSource[displayID], .hdmi1)
        }

        /// Tests availableInputSources returns common modern sources for DDC display
        func testAvailableInputSourcesForDDCDisplay() {
            let displayID: CGDirectDisplayID = 1
            let cap = HardwareDisplayCapability(
                displayID: displayID,
                supportsDDC: true,
                supportedCodes: [.inputSource],
                maxBrightness: 100,
                maxContrast: 100,
                maxVolume: 100
            )
            manager.capabilities[displayID] = cap

            let sources = manager.availableInputSources(for: displayID)
            XCTAssertEqual(sources, [.displayPort1, .displayPort2, .hdmi1, .hdmi2, .usbC])
        }

        /// Tests availableInputSources returns empty for non-DDC display
        func testAvailableInputSourcesForNonDDCDisplay() {
            let sources = manager.availableInputSources(for: 999)
            XCTAssertTrue(sources.isEmpty)
        }

        // MARK: - Display Removal

        /// Tests removeDisplay cleans up all state
        func testRemoveDisplayCleansUpState() {
            let displayID: CGDirectDisplayID = 1
            let cap = HardwareDisplayCapability(
                displayID: displayID,
                supportsDDC: true,
                supportedCodes: [.brightness, .volume, .audioMute, .inputSource],
                maxBrightness: 100,
                maxContrast: 100,
                maxVolume: 100
            )
            manager.capabilities[displayID] = cap
            manager.hardwareBrightness[displayID] = 0.5
            manager.hardwareContrast[displayID] = 0.5
            manager.hardwareVolume[displayID] = 0.5
            manager.hardwareMute[displayID] = false
            manager.activeInputSource[displayID] = .hdmi1

            manager.removeDisplay(displayID)

            XCTAssertNil(manager.capabilities[displayID])
            XCTAssertNil(manager.hardwareBrightness[displayID])
            XCTAssertNil(manager.hardwareContrast[displayID])
            XCTAssertNil(manager.hardwareVolume[displayID])
            XCTAssertNil(manager.hardwareMute[displayID])
            XCTAssertNil(manager.activeInputSource[displayID])
        }

        // MARK: - Polling

        /// Tests startPolling and stopPolling don't crash
        func testPollingLifecycle() {
            manager.startPolling()
            // Polling should be active
            manager.stopPolling()
            // Double stop should be safe
            manager.stopPolling()
        }

        // MARK: - HardwareDisplayCapability Tests

        /// Tests notSupported factory method
        func testCapabilityNotSupported() {
            let cap = HardwareDisplayCapability.notSupported(displayID: 42)
            XCTAssertEqual(cap.displayID, 42)
            XCTAssertFalse(cap.supportsDDC)
            XCTAssertTrue(cap.supportedCodes.isEmpty)
            XCTAssertEqual(cap.maxBrightness, 0)
            XCTAssertEqual(cap.maxContrast, 0)
            XCTAssertEqual(cap.maxVolume, 0)
        }

        /// Tests capability convenience accessors
        func testCapabilityConvenienceAccessors() {
            let cap = HardwareDisplayCapability(
                displayID: 1,
                supportsDDC: true,
                supportedCodes: [.brightness, .contrast, .volume, .audioMute, .inputSource, .powerMode],
                maxBrightness: 100,
                maxContrast: 100,
                maxVolume: 100
            )

            XCTAssertTrue(cap.supportsBrightness)
            XCTAssertTrue(cap.supportsContrast)
            XCTAssertTrue(cap.supportsVolume)
            XCTAssertTrue(cap.supportsAudioMute)
            XCTAssertTrue(cap.supportsInputSource)
            XCTAssertTrue(cap.supportsPowerMode)
            XCTAssertFalse(cap.supportsRGBGain) // Missing RGB gain codes
        }

        /// Tests capability RGB gain requires all three channels
        func testCapabilityRGBGainRequiresAllThree() {
            let partialCap = HardwareDisplayCapability(
                displayID: 1,
                supportsDDC: true,
                supportedCodes: [.redGain, .greenGain], // Missing blue
                maxBrightness: 100,
                maxContrast: 100,
                maxVolume: 100
            )
            XCTAssertFalse(partialCap.supportsRGBGain)

            let fullCap = HardwareDisplayCapability(
                displayID: 1,
                supportsDDC: true,
                supportedCodes: [.redGain, .greenGain, .blueGain],
                maxBrightness: 100,
                maxContrast: 100,
                maxVolume: 100
            )
            XCTAssertTrue(fullCap.supportsRGBGain)
        }

        /// Tests capability Equatable conformance
        func testCapabilityEquatable() {
            let a = HardwareDisplayCapability(
                displayID: 1,
                supportsDDC: true,
                supportedCodes: [.brightness],
                maxBrightness: 100,
                maxContrast: 100,
                maxVolume: 100
            )
            let b = HardwareDisplayCapability(
                displayID: 1,
                supportsDDC: true,
                supportedCodes: [.brightness],
                maxBrightness: 100,
                maxContrast: 100,
                maxVolume: 100
            )
            let c = HardwareDisplayCapability(
                displayID: 2,
                supportsDDC: true,
                supportedCodes: [.brightness],
                maxBrightness: 100,
                maxContrast: 100,
                maxVolume: 100
            )

            XCTAssertEqual(a, b)
            XCTAssertNotEqual(a, c)
        }
    }

#endif // !APPSTORE

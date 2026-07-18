//
//  DDCControllerTests.swift
//  DimmerlyTests
//
//  Unit tests for DDC/CI controller types and enumerations.
//  Tests VCPCode, InputSource, DDCReadResult, and related model logic.
//
//  Note: Actual DDC I/O (read/write/capabilities) requires hardware and
//  cannot be meaningfully unit tested. Those paths are tested via
//  HardwareBrightnessManagerTests using injectable mocks.
//

@testable import Dimmerly
import XCTest

#if !APPSTORE

    final class DDCControllerTests: XCTestCase {
        func testPacketCodecBuildsServiceAndIntelGetRequests() {
            XCTAssertEqual(
                DDCPacketCodec.getRequest(for: .brightness, includeHostAddress: false),
                [0x82, 0x01, 0x10, 0xAC]
            )
            XCTAssertEqual(
                DDCPacketCodec.getRequest(for: .brightness, includeHostAddress: true),
                [0x51, 0x82, 0x01, 0x10, 0xAC]
            )
        }

        func testPacketCodecBuildsServiceAndIntelSetRequests() {
            XCTAssertEqual(
                DDCPacketCodec.setRequest(for: .brightness, value: 0x1234, includeHostAddress: false),
                [0x84, 0x03, 0x10, 0x12, 0x34, 0x8E]
            )
            XCTAssertEqual(
                DDCPacketCodec.setRequest(for: .brightness, value: 0x1234, includeHostAddress: true),
                [0x51, 0x84, 0x03, 0x10, 0x12, 0x34, 0x8E]
            )
        }

        func testPacketCodecChecksum() {
            XCTAssertEqual(DDCPacketCodec.checksum(for: [0x6E, 0x51, 0x82, 0x01, 0x10]), 0xAC)
        }

        func testPacketCodecParsesValidGetReply() {
            let reply = makeReply(vcp: .brightness, maximum: 100, current: 42)

            XCTAssertEqual(
                DDCPacketCodec.parseGetReply(reply, expectedVCP: .brightness),
                DDCReadResult(currentValue: 42, maxValue: 100)
            )
        }

        func testPacketCodecRejectsInvalidReplies() {
            let valid = makeReply(vcp: .brightness, maximum: 100, current: 42)

            XCTAssertNil(DDCPacketCodec.parseGetReply([], expectedVCP: .brightness))
            XCTAssertNil(DDCPacketCodec.parseGetReply(Array(valid.dropLast()), expectedVCP: .brightness))
            XCTAssertNil(DDCPacketCodec.parseGetReply(replacing(valid, at: 0, with: 0x6F), expectedVCP: .brightness))
            XCTAssertNil(DDCPacketCodec.parseGetReply(replacing(valid, at: 1, with: 0x87), expectedVCP: .brightness))
            XCTAssertNil(DDCPacketCodec.parseGetReply(replacing(valid, at: 2, with: 0x03), expectedVCP: .brightness))
            XCTAssertNil(DDCPacketCodec.parseGetReply(replacing(valid, at: 3, with: 0x01), expectedVCP: .brightness))
            XCTAssertNil(DDCPacketCodec.parseGetReply(replacing(valid, at: 4, with: 0x12), expectedVCP: .brightness))
            XCTAssertNil(DDCPacketCodec.parseGetReply(replacing(valid, at: 10, with: 0x00), expectedVCP: .brightness))
        }

        private func makeReply(
            vcp: VCPCode,
            maximum: UInt16,
            current: UInt16
        ) -> [UInt8] {
            var reply: [UInt8] = [
                0x6E, 0x88, 0x02, 0x00, vcp.rawValue, 0x00,
                UInt8(maximum >> 8), UInt8(maximum & 0xFF),
                UInt8(current >> 8), UInt8(current & 0xFF),
            ]
            reply.append(DDCPacketCodec.checksum(for: [0x50] + reply))
            return reply
        }

        private func replacing(_ bytes: [UInt8], at index: Int, with value: UInt8) -> [UInt8] {
            var copy = bytes
            copy[index] = value
            return copy
        }

        // MARK: - VCPCode Tests

        /// Tests that all VCP codes have the expected raw values per MCCS v2.2a
        func testVCPCodeRawValues() {
            XCTAssertEqual(VCPCode.brightness.rawValue, 0x10)
            XCTAssertEqual(VCPCode.contrast.rawValue, 0x12)
            XCTAssertEqual(VCPCode.redGain.rawValue, 0x16)
            XCTAssertEqual(VCPCode.greenGain.rawValue, 0x18)
            XCTAssertEqual(VCPCode.blueGain.rawValue, 0x1A)
            XCTAssertEqual(VCPCode.volume.rawValue, 0x62)
            XCTAssertEqual(VCPCode.audioMute.rawValue, 0x8D)
            XCTAssertEqual(VCPCode.inputSource.rawValue, 0x60)
            XCTAssertEqual(VCPCode.powerMode.rawValue, 0xD6)
        }

        /// Tests that allCases contains all 9 expected VCP codes
        func testVCPCodeAllCases() {
            XCTAssertEqual(VCPCode.allCases.count, 9)
        }

        /// Tests that each VCP code has a non-empty display name
        func testVCPCodeDisplayNames() {
            for code in VCPCode.allCases {
                XCTAssertFalse(code.displayName.isEmpty, "VCPCode \(code) has empty display name")
            }
        }

        /// Tests specific display name values
        func testVCPCodeSpecificDisplayNames() {
            XCTAssertEqual(VCPCode.brightness.displayName, "Brightness")
            XCTAssertEqual(VCPCode.contrast.displayName, "Contrast")
            XCTAssertEqual(VCPCode.volume.displayName, "Volume")
            XCTAssertEqual(VCPCode.audioMute.displayName, "Audio Mute")
            XCTAssertEqual(VCPCode.inputSource.displayName, "Input Source")
            XCTAssertEqual(VCPCode.powerMode.displayName, "Power Mode")
        }

        // MARK: - InputSource Tests

        /// Tests that InputSource raw values match MCCS v2.2a Table 8-27
        func testInputSourceRawValues() {
            XCTAssertEqual(InputSource.vga1.rawValue, 1)
            XCTAssertEqual(InputSource.dvi1.rawValue, 3)
            XCTAssertEqual(InputSource.displayPort1.rawValue, 15)
            XCTAssertEqual(InputSource.displayPort2.rawValue, 16)
            XCTAssertEqual(InputSource.hdmi1.rawValue, 17)
            XCTAssertEqual(InputSource.hdmi2.rawValue, 18)
            XCTAssertEqual(InputSource.usbC.rawValue, 27)
        }

        /// Tests that allCases contains all 17 input sources
        func testInputSourceAllCases() {
            XCTAssertEqual(InputSource.allCases.count, 17)
        }

        /// Tests that each input source has a non-empty display name
        func testInputSourceDisplayNames() {
            for source in InputSource.allCases {
                XCTAssertFalse(source.displayName.isEmpty, "InputSource \(source) has empty display name")
            }
        }

        /// Tests specific input source display names
        func testInputSourceSpecificDisplayNames() {
            XCTAssertEqual(InputSource.displayPort1.displayName, "DisplayPort 1")
            XCTAssertEqual(InputSource.hdmi1.displayName, "HDMI 1")
            XCTAssertEqual(InputSource.usbC.displayName, "USB-C")
        }

        /// Tests that InputSource can be initialized from raw value
        func testInputSourceFromRawValue() {
            XCTAssertEqual(InputSource(rawValue: 15), .displayPort1)
            XCTAssertEqual(InputSource(rawValue: 17), .hdmi1)
            XCTAssertEqual(InputSource(rawValue: 27), .usbC)
            XCTAssertNil(InputSource(rawValue: 99), "Unknown raw value should return nil")
        }

        // MARK: - DDCReadResult Tests

        /// Tests DDCReadResult equality
        func testDDCReadResultEquality() {
            let a = DDCReadResult(currentValue: 50, maxValue: 100)
            let b = DDCReadResult(currentValue: 50, maxValue: 100)
            let c = DDCReadResult(currentValue: 75, maxValue: 100)

            XCTAssertEqual(a, b)
            XCTAssertNotEqual(a, c)
        }

        /// Tests DDCReadResult value storage
        func testDDCReadResultValues() {
            let result = DDCReadResult(currentValue: 42, maxValue: 100)
            XCTAssertEqual(result.currentValue, 42)
            XCTAssertEqual(result.maxValue, 100)
        }

        /// Tests normalization of DDCReadResult to 0.0–1.0 range
        func testDDCReadResultNormalization() {
            let result = DDCReadResult(currentValue: 50, maxValue: 100)
            let normalized = Double(result.currentValue) / Double(result.maxValue)
            XCTAssertEqual(normalized, 0.5, accuracy: 0.001)

            let fullResult = DDCReadResult(currentValue: 100, maxValue: 100)
            let fullNormalized = Double(fullResult.currentValue) / Double(fullResult.maxValue)
            XCTAssertEqual(fullNormalized, 1.0, accuracy: 0.001)

            let zeroResult = DDCReadResult(currentValue: 0, maxValue: 100)
            let zeroNormalized = Double(zeroResult.currentValue) / Double(zeroResult.maxValue)
            XCTAssertEqual(zeroNormalized, 0.0, accuracy: 0.001)
        }

        // MARK: - DDCControlMode Tests

        /// Tests DDCControlMode raw values
        func testDDCControlModeRawValues() {
            XCTAssertEqual(DDCControlMode.softwareOnly.rawValue, "software")
            XCTAssertEqual(DDCControlMode.hardware.rawValue, "combined")
        }

        /// Tests DDCControlMode exposes only the two user-facing modes.
        func testDDCControlModeAllCases() {
            XCTAssertEqual(DDCControlMode.allCases, [.softwareOnly, .hardware])
        }

        /// Tests DDCControlMode display names are non-empty
        func testDDCControlModeDisplayNames() {
            for mode in DDCControlMode.allCases {
                XCTAssertFalse(mode.displayName.isEmpty, "\(mode) has empty displayName")
            }
        }

        /// Tests DDCControlMode descriptions are non-empty
        func testDDCControlModeDescriptions() {
            for mode in DDCControlMode.allCases {
                XCTAssertFalse(mode.description.isEmpty, "\(mode) has empty description")
            }
        }

        /// Tests DDCControlMode can be created from raw value
        func testDDCControlModeFromRawValue() {
            XCTAssertEqual(DDCControlMode(rawValue: "software"), .softwareOnly)
            XCTAssertEqual(DDCControlMode(rawValue: "combined"), .hardware)
            XCTAssertNil(DDCControlMode(rawValue: "hardware"))
            XCTAssertNil(DDCControlMode(rawValue: "invalid"))
        }

        /// Tests DDCControlMode Identifiable conformance
        func testDDCControlModeIdentifiable() {
            for mode in DDCControlMode.allCases {
                XCTAssertEqual(mode.id, mode.rawValue)
            }
        }
    }

#endif // !APPSTORE

//
//  DDCControllerTests.swift
//  DimmerlyTests
//
//  Unit tests for DDC/CI controller types and enumerations.
//  Tests VCPCode, InputSource, DDCReadResult, and related model logic.
//
//  Note: Actual DDC service discovery requires hardware and cannot be meaningfully
//  unit tested. The address routing, I2C operation forwarding and Apple Silicon
//  retry loops are covered here with injectable operations; higher-level paths are
//  tested via HardwareBrightnessManagerTests.
//

@testable import Dimmerly
import IOKit
import XCTest

#if !APPSTORE

    final class DDCControllerTests: XCTestCase {
        func testAppleSiliconReadContractUsesZeroOffsetAndElevenByteReply() {
            XCTAssertEqual(DDCAppleSiliconReadContract.dataAddress, 0)
            XCTAssertEqual(DDCAppleSiliconReadContract.replyLength, 11)
        }

        func testAppleSiliconTransportUsesMCDP29xxChipAddressOnlyForMatchingProvider() {
            XCTAssertEqual(
                DDCAppleSiliconTransport.chipAddress(for: "AppleDCPMCDP29XX"),
                0xB7
            )
            XCTAssertEqual(
                DDCAppleSiliconTransport.chipAddress(for: "AppleDCP"),
                0x37
            )
            XCTAssertEqual(
                DDCAppleSiliconTransport.chipAddress(for: nil),
                0x37
            )
        }

        func testDisplayIdentityRejectsConflictingSerialForVendorAndModelMatch() {
            XCTAssertTrue(
                DDCDisplayIdentityMatcher.matches(
                    candidate: DDCDisplayIdentity(
                        vendorID: 0x1234, modelID: 0x5678, serialNumber: nil
                    ),
                    expected: DDCDisplayIdentity(
                        vendorID: 0x1234, modelID: 0x5678, serialNumber: 42
                    )
                )
            )
            XCTAssertTrue(
                DDCDisplayIdentityMatcher.matches(
                    candidate: DDCDisplayIdentity(
                        vendorID: 0x1234, modelID: 0x5678, serialNumber: 42
                    ),
                    expected: DDCDisplayIdentity(
                        vendorID: 0x1234, modelID: 0x5678, serialNumber: 42
                    )
                )
            )
            XCTAssertFalse(
                DDCDisplayIdentityMatcher.matches(
                    candidate: DDCDisplayIdentity(
                        vendorID: 0x1234, modelID: 0x5678, serialNumber: 7
                    ),
                    expected: DDCDisplayIdentity(
                        vendorID: 0x1234, modelID: 0x5678, serialNumber: 42
                    )
                )
            )
        }

        func testDisplayIdentityConflictRequiresTwoKnownDifferentValues() {
            let expected = DDCDisplayIdentity(vendorID: 0x1234, modelID: 0x5678, serialNumber: 42)

            XCTAssertTrue(
                DDCDisplayIdentityMatcher.hasKnownConflict(
                    candidate: DDCDisplayIdentity(vendorID: 0x1234, modelID: 0x5678, serialNumber: 7),
                    expected: expected
                )
            )
            XCTAssertFalse(
                DDCDisplayIdentityMatcher.hasKnownConflict(
                    candidate: DDCDisplayIdentity(vendorID: 0x1234, modelID: 0x5678, serialNumber: nil),
                    expected: expected
                )
            )
            XCTAssertFalse(
                DDCDisplayIdentityMatcher.hasKnownConflict(
                    candidate: DDCDisplayIdentity(vendorID: nil, modelID: nil, serialNumber: nil),
                    expected: expected
                )
            )
        }

        func testIntelCandidateSelectorUsesExactSerialWhenModelsAreIdentical() {
            let expected = DDCDisplayIdentity(vendorID: 0x1234, modelID: 0x5678, serialNumber: 42)
            let candidates = [
                DDCDisplayIdentity(vendorID: 0x1234, modelID: 0x5678, serialNumber: 7),
                DDCDisplayIdentity(vendorID: 0x1234, modelID: 0x5678, serialNumber: 42),
            ]

            XCTAssertEqual(
                DDCDisplayCandidateSelector.uniqueCandidateIndex(
                    expected: expected,
                    candidates: candidates
                ),
                1
            )
        }

        func testIntelCandidateSelectorRefusesAmbiguousModelOnlyMatch() {
            let expected = DDCDisplayIdentity(vendorID: 0x1234, modelID: 0x5678, serialNumber: nil)
            let candidates = [
                DDCDisplayIdentity(vendorID: 0x1234, modelID: 0x5678, serialNumber: 7),
                DDCDisplayIdentity(vendorID: 0x1234, modelID: 0x5678, serialNumber: 42),
            ]

            XCTAssertNil(
                DDCDisplayCandidateSelector.uniqueCandidateIndex(
                    expected: expected,
                    candidates: candidates
                )
            )
        }

        func testIntelCandidateSelectorRefusesExpectedSerialWithoutExactCandidate() {
            let expected = DDCDisplayIdentity(vendorID: 0x1234, modelID: 0x5678, serialNumber: 42)
            let candidates = [
                DDCDisplayIdentity(vendorID: 0x1234, modelID: 0x5678, serialNumber: nil),
            ]

            XCTAssertNil(
                DDCDisplayCandidateSelector.uniqueCandidateIndex(
                    expected: expected,
                    candidates: candidates
                )
            )
        }

        func testAppleSiliconCandidateSelectorPrefersExactSerialOverSeriallessCandidate() {
            let expectedDisplays = [
                DDCDisplayIdentity(vendorID: 0x1234, modelID: 0x5678, serialNumber: 42),
                DDCDisplayIdentity(vendorID: 0x1234, modelID: 0x5678, serialNumber: nil),
            ]
            let candidates = [
                DDCDisplayIdentity(vendorID: 0x1234, modelID: 0x5678, serialNumber: nil),
                DDCDisplayIdentity(vendorID: 0x1234, modelID: 0x5678, serialNumber: 42),
            ]

            XCTAssertEqual(
                DDCDisplayCandidateSelector.uniqueCandidateIndex(
                    expectedIndex: 0,
                    expectedDisplays: expectedDisplays,
                    candidates: candidates
                ),
                1
            )
        }

        func testAppleSiliconCandidateSelectorAllowsUniqueModelMatchWhenSerialIsMissing() {
            let expectedDisplays = [
                DDCDisplayIdentity(vendorID: 0x1234, modelID: 0x5678, serialNumber: 42),
                DDCDisplayIdentity(vendorID: 0x1234, modelID: 0x9ABC, serialNumber: nil),
            ]
            let candidates = [
                DDCDisplayIdentity(vendorID: 0x1234, modelID: 0x5678, serialNumber: nil),
            ]

            XCTAssertEqual(
                DDCDisplayCandidateSelector.uniqueCandidateIndex(
                    expectedIndex: 0,
                    expectedDisplays: expectedDisplays,
                    candidates: candidates
                ),
                0
            )
        }

        func testAppleSiliconCandidateSelectorRejectsSeriallessServiceSharedByExpectedDisplays() {
            let expectedDisplays = [
                DDCDisplayIdentity(vendorID: 0x1234, modelID: 0x5678, serialNumber: nil),
                DDCDisplayIdentity(vendorID: 0x1234, modelID: 0x5678, serialNumber: nil),
            ]
            let candidates = [
                DDCDisplayIdentity(vendorID: 0x1234, modelID: 0x5678, serialNumber: nil),
            ]

            XCTAssertNil(
                DDCDisplayCandidateSelector.uniqueCandidateIndex(
                    expectedIndex: 0,
                    expectedDisplays: expectedDisplays,
                    candidates: candidates
                )
            )
            XCTAssertNil(
                DDCDisplayCandidateSelector.uniqueCandidateIndex(
                    expectedIndex: 1,
                    expectedDisplays: expectedDisplays,
                    candidates: candidates
                )
            )
        }

        func testAppleSiliconCandidateSelectorDoesNotAssignExactSerialServiceToUnknownPeer() {
            let expectedDisplays = [
                DDCDisplayIdentity(vendorID: 0x1234, modelID: 0x5678, serialNumber: 42),
                DDCDisplayIdentity(vendorID: 0x1234, modelID: 0x5678, serialNumber: nil),
            ]
            let candidates = [
                DDCDisplayIdentity(vendorID: 0x1234, modelID: 0x5678, serialNumber: 42),
            ]

            XCTAssertEqual(
                DDCDisplayCandidateSelector.uniqueCandidateIndex(
                    expectedIndex: 0,
                    expectedDisplays: expectedDisplays,
                    candidates: candidates
                ),
                0
            )
            XCTAssertNil(
                DDCDisplayCandidateSelector.uniqueCandidateIndex(
                    expectedIndex: 1,
                    expectedDisplays: expectedDisplays,
                    candidates: candidates
                )
            )
        }

        func testAppleSiliconCandidateSelectorTreatsMaximumSerialAsMissingIdentity() {
            let expectedDisplays = [
                DDCDisplayIdentity(vendorID: 0x1234, modelID: 0x5678, serialNumber: .max),
                DDCDisplayIdentity(vendorID: 0x1234, modelID: 0x9ABC, serialNumber: .max),
            ]
            let candidates = [
                DDCDisplayIdentity(vendorID: 0x1234, modelID: 0x5678, serialNumber: .max),
            ]

            XCTAssertEqual(
                DDCDisplayCandidateSelector.uniqueCandidateIndex(
                    expectedIndex: 0,
                    expectedDisplays: expectedDisplays,
                    candidates: candidates
                ),
                0
            )
            XCTAssertNil(
                DDCDisplayCandidateSelector.uniqueCandidateIndex(
                    expectedIndex: 1,
                    expectedDisplays: expectedDisplays,
                    candidates: candidates
                )
            )
        }

        func testAppleSiliconCandidateSelectorStillRejectsAmbiguousMaximumSerials() {
            let expectedDisplays = [
                DDCDisplayIdentity(vendorID: 0x1234, modelID: 0x5678, serialNumber: .max),
                DDCDisplayIdentity(vendorID: 0x1234, modelID: 0x5678, serialNumber: .max),
            ]
            let candidates = [
                DDCDisplayIdentity(vendorID: 0x1234, modelID: 0x5678, serialNumber: .max),
            ]

            XCTAssertNil(
                DDCDisplayCandidateSelector.uniqueCandidateIndex(
                    expectedIndex: 0,
                    expectedDisplays: expectedDisplays,
                    candidates: candidates
                )
            )
            XCTAssertNil(
                DDCDisplayCandidateSelector.uniqueCandidateIndex(
                    expectedIndex: 1,
                    expectedDisplays: expectedDisplays,
                    candidates: candidates
                )
            )
        }

        func testAppleSiliconI2CTransportForwardsChipAddressToReadAndWrite() {
            var writeAddresses: [UInt32] = []
            var readAddresses: [UInt32] = []
            let transport = DDCAppleSiliconI2CTransport(
                writeI2C: { address, _, _ in
                    writeAddresses.append(address)
                    return KERN_SUCCESS
                },
                readI2C: { address, _, _ in
                    readAddresses.append(address)
                    return KERN_SUCCESS
                }
            )

            var writeData = [UInt8](repeating: 0, count: 4)
            var readData = [UInt8](repeating: 0, count: 11)
            XCTAssertEqual(
                transport.write(&writeData, chipAddress: 0xB7, register: 0x51),
                KERN_SUCCESS
            )
            XCTAssertEqual(
                transport.read(&readData, chipAddress: 0x37, register: 0),
                KERN_SUCCESS
            )

            XCTAssertEqual(writeAddresses, [0xB7])
            XCTAssertEqual(readAddresses, [0x37])
        }

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

        func testPacketCodecParsesNonContinuousGetReplyWithZeroMaximum() {
            let reply = makeReply(vcp: .inputSource, maximum: 0, current: 17)

            XCTAssertEqual(
                DDCPacketCodec.parseGetReply(reply, expectedVCP: .inputSource),
                DDCReadResult(currentValue: 17, maxValue: 0)
            )
        }

        func testPacketCodecRejectsContinuousGetReplyWithZeroMaximum() {
            let reply = makeReply(vcp: .brightness, maximum: 0, current: 0)

            XCTAssertNil(DDCPacketCodec.parseGetReply(reply, expectedVCP: .brightness))
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

        // MARK: - Silent monitor detection

        func testSilentProbeRecordsWhetherADDCTransportWasReachable() {
            var queried: [CGDirectDisplayID] = []
            let reachable = HardwareDisplayCapability.probe(
                displayID: 81,
                read: { _, _ in nil },
                transportReachable: { displayID in
                    queried.append(displayID)
                    return true
                }
            )
            let unreachable = HardwareDisplayCapability.probe(
                displayID: 82,
                read: { _, _ in nil },
                transportReachable: { _ in false }
            )

            XCTAssertFalse(reachable.supportsDDC)
            XCTAssertTrue(reachable.transportReachable, "A found service that never answers is a silent monitor")
            XCTAssertEqual(queried, [81])
            XCTAssertFalse(unreachable.supportsDDC)
            XCTAssertFalse(unreachable.transportReachable)
            XCTAssertNotEqual(reachable, HardwareDisplayCapability.notSupported(displayID: 81))
        }

        func testRespondingProbeDoesNotQueryTransportReachability() {
            var queried = false
            let capability = HardwareDisplayCapability.probe(
                displayID: 83,
                read: { code, _ in code == .brightness ? DDCReadResult(currentValue: 40, maxValue: 100) : nil },
                transportReachable: { _ in
                    queried = true
                    return false
                }
            )

            XCTAssertTrue(capability.supportsDDC)
            XCTAssertTrue(capability.transportReachable, "A reply proves the transport is reachable")
            XCTAssertFalse(queried)
        }

        // MARK: - Read batches

        func testReadBatchLooksUpTheTransportOnceForConsecutiveReads() {
            let fake = FakeBatchTransports()

            let results = fake.runBatch { read in
                [VCPCode.brightness, .contrast, .volume, .inputSource].map(read)
            }

            XCTAssertEqual(fake.lookups, 1)
            XCTAssertEqual(fake.transportReads.map(\.vcp), [.brightness, .contrast, .volume, .inputSource])
            XCTAssertEqual(Set(fake.transportReads.map(\.transport)), [1])
            XCTAssertTrue(fake.fallbackReads.isEmpty)
            XCTAssertEqual(results, Array(repeating: FakeBatchTransports.answer, count: 4))
        }

        func testReadBatchFailureFallsBackAndLooksUpTheTransportAgain() {
            let fake = FakeBatchTransports(failingReads: [.contrast])

            let results = fake.runBatch { read in
                [VCPCode.brightness, .contrast, .volume].map(read)
            }

            XCTAssertEqual(fake.lookups, 2, "A transport that failed a read must not be reused")
            XCTAssertEqual(fake.transportReads.map(\.vcp), [.brightness, .contrast, .volume])
            XCTAssertEqual(fake.transportReads.map(\.transport), [1, 1, 2])
            XCTAssertEqual(fake.fallbackReads, [.contrast])
            let answer = FakeBatchTransports.answer
            XCTAssertEqual(results, [answer, FakeBatchTransports.fallbackAnswer, answer])
        }

        func testReadBatchWithoutTransportLooksUpAndFallsBackForEveryRead() {
            let fake = FakeBatchTransports(availableTransports: 0)

            let results = fake.runBatch { read in
                [VCPCode.brightness, .contrast].map(read)
            }

            XCTAssertEqual(fake.lookups, 2)
            XCTAssertTrue(fake.transportReads.isEmpty)
            XCTAssertEqual(fake.fallbackReads, [.brightness, .contrast])
            XCTAssertEqual(results, [FakeBatchTransports.fallbackAnswer, FakeBatchTransports.fallbackAnswer])
        }

        func testReadBatchesNeverShareATransport() {
            let fake = FakeBatchTransports()

            _ = fake.runBatch { read in read(.brightness) }
            _ = fake.runBatch { read in read(.brightness) }

            XCTAssertEqual(fake.lookups, 2)
            XCTAssertEqual(fake.transportReads.map(\.transport), [1, 2])
            XCTAssertTrue(fake.liveTransports.isEmpty, "Each batch releases its transport when it ends")
        }

        func testEndedReadBatchLooksUpTheTransportForEveryRead() {
            let fake = FakeBatchTransports()
            let batch = fake.makeBatch()
            XCTAssertNotNil(batch.read(.brightness))
            batch.end()

            XCTAssertTrue(fake.liveTransports.isEmpty)
            XCTAssertNotNil(batch.read(.contrast))
            XCTAssertNotNil(batch.read(.volume))

            XCTAssertEqual(fake.lookups, 3)
            XCTAssertEqual(fake.transportReads.map(\.transport), [1, 2, 3])
        }

        #if arch(arm64)

            /// Reusing the transport inside a batch must not change the retry loop: a
            /// failing read still spends all three attempts before the fallbacks run.
            func testBatchedServiceReadKeepsTheFullRetryBudgetBeforeFallingBack() {
                let bus = ScriptedI2CBus(reads: [
                    makeReply(vcp: .brightness, maximum: 100, current: 42), nil, nil, nil,
                ])
                var lookups = 0
                var fallbacks: [VCPCode] = []

                let results = DDCReadBatch<ScriptedI2CBus>.run(
                    resolve: {
                        lookups += 1
                        return bus
                    },
                    read: { bus, vcp in
                        DDCController.readVCP(using: bus.transport, chipAddress: 0x37, vcp: vcp, sleep: bus.sleep)
                    },
                    fallback: { vcp in
                        fallbacks.append(vcp)
                        return nil
                    },
                    { read in [VCPCode.brightness, .contrast].map(read) }
                )

                XCTAssertEqual(results, [DDCReadResult(currentValue: 42, maxValue: 100), nil])
                XCTAssertEqual(lookups, 1)
                XCTAssertEqual(fallbacks, [.contrast])
                let attempt: [ScriptedI2CBus.Event] = [
                    .write(chip: 0x37, register: 0x51), .sleep(10), .write(chip: 0x37, register: 0x51),
                    .sleep(50), .read(chip: 0x37, register: 0),
                ]
                XCTAssertEqual(
                    bus.events,
                    attempt + attempt + [.sleep(20)] + attempt + [.sleep(20)] + attempt
                )
            }

            // MARK: - Apple Silicon retry loops

            func testServiceReadSendsEachRequestTwiceBeforeReading() {
                let bus = ScriptedI2CBus(reads: [makeReply(vcp: .brightness, maximum: 100, current: 42)])

                let result = DDCController.readVCP(
                    using: bus.transport, chipAddress: 0x37, vcp: .brightness, sleep: bus.sleep
                )

                XCTAssertEqual(result, DDCReadResult(currentValue: 42, maxValue: 100))
                XCTAssertEqual(bus.events, [
                    .write(chip: 0x37, register: 0x51), .sleep(10), .write(chip: 0x37, register: 0x51),
                    .sleep(50), .read(chip: 0x37, register: 0),
                ])
            }

            /// Monitors such as the Philips 276E8V drop the first write; the second cycle
            /// of the same attempt must be enough.
            func testServiceWriteSucceedsWhenOnlyTheSecondCycleIsAcknowledged() {
                let bus = ScriptedI2CBus(writes: [kIOReturnError, KERN_SUCCESS])

                XCTAssertTrue(DDCController.writeVCP(
                    using: bus.transport, chipAddress: 0x37, vcp: .brightness, value: 30, sleep: bus.sleep
                ))
                XCTAssertEqual(bus.events, [
                    .write(chip: 0x37, register: 0x51), .sleep(10), .write(chip: 0x37, register: 0x51),
                ])
            }

            /// Mirrors the loop `readViaDirect` used before it shared `readVCP`: one write
            /// per attempt, a 20 ms pause before each retry, 50 ms before each read.
            func testDirectReadSendsOneWritePerAttemptAndRetriesFailedWritesAndReads() {
                let bus = ScriptedI2CBus(
                    writes: [kIOReturnError, KERN_SUCCESS, KERN_SUCCESS],
                    reads: [nil, makeReply(vcp: .contrast, maximum: 100, current: 55)]
                )

                let result = DDCController.readVCP(
                    using: bus.transport,
                    chipAddress: 0xB7,
                    vcp: .contrast,
                    writeCycles: DDCController.directWriteCyclesPerAttempt,
                    sleep: bus.sleep
                )

                XCTAssertEqual(result, DDCReadResult(currentValue: 55, maxValue: 100))
                XCTAssertEqual(bus.events, [
                    .write(chip: 0xB7, register: 0x51),
                    .sleep(20), .write(chip: 0xB7, register: 0x51), .sleep(50), .read(chip: 0xB7, register: 0),
                    .sleep(20), .write(chip: 0xB7, register: 0x51), .sleep(50), .read(chip: 0xB7, register: 0),
                ])
            }

            func testDirectReadGivesUpAfterThreeInvalidReplies() {
                let invalid = [UInt8](repeating: 0, count: DDCAppleSiliconReadContract.replyLength)
                let bus = ScriptedI2CBus(reads: [invalid, invalid, invalid, invalid])

                XCTAssertNil(DDCController.readVCP(
                    using: bus.transport,
                    chipAddress: 0x37,
                    vcp: .brightness,
                    writeCycles: DDCController.directWriteCyclesPerAttempt,
                    sleep: bus.sleep
                ))
                let attempt: [ScriptedI2CBus.Event] = [
                    .write(chip: 0x37, register: 0x51), .sleep(50), .read(chip: 0x37, register: 0),
                ]
                XCTAssertEqual(bus.events, attempt + [.sleep(20)] + attempt + [.sleep(20)] + attempt)
            }

            func testDirectWriteSendsOneWritePerAttemptForThreeAttempts() {
                let failing = ScriptedI2CBus(writes: [kIOReturnError, kIOReturnError, kIOReturnError, KERN_SUCCESS])
                XCTAssertFalse(DDCController.writeVCP(
                    using: failing.transport,
                    chipAddress: 0x37,
                    vcp: .volume,
                    value: 10,
                    writeCycles: DDCController.directWriteCyclesPerAttempt,
                    sleep: failing.sleep
                ))
                XCTAssertEqual(failing.events, [
                    .write(chip: 0x37, register: 0x51), .sleep(20),
                    .write(chip: 0x37, register: 0x51), .sleep(20),
                    .write(chip: 0x37, register: 0x51),
                ])

                let recovering = ScriptedI2CBus(writes: [kIOReturnError, KERN_SUCCESS])
                XCTAssertTrue(DDCController.writeVCP(
                    using: recovering.transport,
                    chipAddress: 0x37,
                    vcp: .volume,
                    value: 10,
                    writeCycles: DDCController.directWriteCyclesPerAttempt,
                    sleep: recovering.sleep
                ))
                XCTAssertEqual(recovering.events, [
                    .write(chip: 0x37, register: 0x51), .sleep(20), .write(chip: 0x37, register: 0x51),
                ])
            }

            func testDirectWriteSendsTheSameSetRequestAsTheServicePath() {
                let bus = ScriptedI2CBus()

                XCTAssertTrue(DDCController.writeVCP(
                    using: bus.transport,
                    chipAddress: 0x37,
                    vcp: .brightness,
                    value: 0x0123,
                    writeCycles: DDCController.directWriteCyclesPerAttempt,
                    sleep: bus.sleep
                ))
                XCTAssertEqual(
                    bus.writtenPackets,
                    [DDCPacketCodec.setRequest(for: .brightness, value: 0x0123, includeHostAddress: false)]
                )
            }

        #endif
    }

    /// Hands out numbered transports to `DDCReadBatch` and records lookups, reads,
    /// fallbacks, and which transports are still retained.
    private final class FakeBatchTransports {
        final class Transport {
            let number: Int
            private let onRelease: () -> Void

            init(number: Int, onRelease: @escaping () -> Void) {
                self.number = number
                self.onRelease = onRelease
            }

            deinit {
                onRelease()
            }
        }

        static let answer = DDCReadResult(currentValue: 40, maxValue: 100)
        static let fallbackAnswer = DDCReadResult(currentValue: 7, maxValue: 100)

        private(set) var lookups = 0
        private(set) var transportReads: [(transport: Int, vcp: VCPCode)] = []
        private(set) var fallbackReads: [VCPCode] = []
        private(set) var liveTransports: Set<Int> = []
        private let availableTransports: Int
        private let failingReads: Set<VCPCode>

        init(availableTransports: Int = .max, failingReads: Set<VCPCode> = []) {
            self.availableTransports = availableTransports
            self.failingReads = failingReads
        }

        func makeBatch() -> DDCReadBatch<Transport> {
            DDCReadBatch(resolve: resolve, read: read, fallback: fallback)
        }

        func runBatch<Result>(_ body: (_ read: (VCPCode) -> DDCReadResult?) -> Result) -> Result {
            DDCReadBatch.run(resolve: resolve, read: read, fallback: fallback, body)
        }

        private func resolve() -> Transport? {
            lookups += 1
            guard lookups <= availableTransports else { return nil }
            let number = lookups
            liveTransports.insert(number)
            return Transport(number: number) { [weak self] in
                self?.liveTransports.remove(number)
            }
        }

        private func read(_ transport: Transport, _ vcp: VCPCode) -> DDCReadResult? {
            transportReads.append((transport.number, vcp))
            return failingReads.contains(vcp) ? nil : Self.answer
        }

        private func fallback(_ vcp: VCPCode) -> DDCReadResult? {
            fallbackReads.append(vcp)
            return Self.fallbackAnswer
        }
    }

    #if arch(arm64)

        /// Fake I2C bus that answers writes and reads from scripts and records the
        /// order of bus operations and pauses. Unscripted writes succeed; unscripted
        /// or `nil` reads fail.
        private final class ScriptedI2CBus {
            enum Event: Equatable {
                case write(chip: UInt32, register: UInt32)
                case read(chip: UInt32, register: UInt32)
                case sleep(UInt32)
            }

            private(set) var events: [Event] = []
            private(set) var writtenPackets: [[UInt8]] = []
            private var writes: [IOReturn]
            private var reads: [[UInt8]?]

            init(writes: [IOReturn] = [], reads: [[UInt8]?] = []) {
                self.writes = writes
                self.reads = reads
            }

            var transport: DDCAppleSiliconI2CTransport {
                DDCAppleSiliconI2CTransport(
                    writeI2C: { [self] chip, register, data in
                        events.append(.write(chip: chip, register: register))
                        writtenPackets.append(data)
                        return writes.isEmpty ? KERN_SUCCESS : writes.removeFirst()
                    },
                    readI2C: { [self] chip, register, data in
                        events.append(.read(chip: chip, register: register))
                        guard !reads.isEmpty, let reply = reads.removeFirst() else { return kIOReturnError }
                        data = reply
                        return KERN_SUCCESS
                    }
                )
            }

            func sleep(_ milliseconds: UInt32) {
                events.append(.sleep(milliseconds))
            }
        }

    #endif

#endif // !APPSTORE

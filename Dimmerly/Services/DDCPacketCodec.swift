//
//  DDCPacketCodec.swift
//  Dimmerly
//
//  Pure DDC/CI packet construction and validation.
//

import Foundation

#if !APPSTORE

    /// IOAVService read parameters used by Apple Silicon DDC transports.
    ///
    /// DDC writes use the host source address (`0x51`) as their data address,
    /// while reads use offset zero and return the 11-byte Get VCP reply.
    enum DDCAppleSiliconReadContract {
        static let dataAddress: UInt32 = 0
        static let replyLength = 11
    }

    /// DDC chip-address routing for Apple Silicon display bridges.
    ///
    /// Most Apple Silicon display paths expose the monitor at the standard DDC/CI
    /// address `0x37`. MCDP29xx bridges used by some HDMI paths expose it at `0xB7`
    /// instead. The provider-class check is intentionally exact: this address must
    /// never be used as a speculative fallback on an unrelated display path.
    enum DDCAppleSiliconTransport {
        static let defaultChipAddress: UInt32 = 0x37
        static let mcdp29xxChipAddress: UInt32 = 0xB7
        static let mcdp29xxProviderClass = "AppleDCPMCDP29XX"

        static func chipAddress(for providerClass: String?) -> UInt32 {
            providerClass == mcdp29xxProviderClass
                ? mcdp29xxChipAddress
                : defaultChipAddress
        }
    }

    /// A display identity assembled from registry properties or EDID fields.
    struct DDCDisplayIdentity {
        let vendorID: UInt32?
        let modelID: UInt32?
        let serialNumber: UInt32?
    }

    /// Matches a registry or EDID identity while rejecting a known serial conflict.
    ///
    /// Vendor/product pairs are not unique when multiple identical monitors are
    /// connected. A candidate with the expected vendor and product is acceptable
    /// when its serial is absent, but not when it reports a different non-zero serial.
    enum DDCDisplayIdentityMatcher {
        static func matches(
            candidate: DDCDisplayIdentity,
            expected: DDCDisplayIdentity
        ) -> Bool {
            guard candidate.vendorID == expected.vendorID else { return false }
            if let expectedSerialNumber = expected.serialNumber,
               expectedSerialNumber != 0,
               let candidateSerialNumber = candidate.serialNumber,
               candidateSerialNumber != 0,
               candidateSerialNumber != expectedSerialNumber
            {
                return false
            }

            if candidate.modelID == expected.modelID {
                return true
            }
            guard let expectedSerialNumber = expected.serialNumber, expectedSerialNumber != 0 else {
                return false
            }
            return candidate.serialNumber == expectedSerialNumber
        }
    }

    enum DDCPacketCodec {
        private static let displayWriteAddress: UInt8 = 0x6E
        private static let hostSourceAddress: UInt8 = 0x51
        private static let hostWriteAddress: UInt8 = 0x50
        private static let getVCPFeatureOpcode: UInt8 = 0x01
        private static let setVCPFeatureOpcode: UInt8 = 0x03
        private static let getVCPFeatureReplyOpcode: UInt8 = 0x02
        private static let getRequestLength: UInt8 = 0x82
        private static let setRequestLength: UInt8 = 0x84
        private static let getReplyLength: UInt8 = 0x88
        private static let getReplyPacketLength = 11

        static func checksum(for bytes: [UInt8]) -> UInt8 {
            bytes.reduce(0, ^)
        }

        static func getRequest(for vcp: VCPCode, includeHostAddress: Bool) -> [UInt8] {
            let payload = [getRequestLength, getVCPFeatureOpcode, vcp.rawValue]
            let packetChecksum = checksum(for: [displayWriteAddress, hostSourceAddress] + payload)
            return (includeHostAddress ? [hostSourceAddress] : []) + payload + [packetChecksum]
        }

        static func setRequest(for vcp: VCPCode, value: UInt16, includeHostAddress: Bool) -> [UInt8] {
            let payload = [
                setRequestLength,
                setVCPFeatureOpcode,
                vcp.rawValue,
                UInt8(value >> 8),
                UInt8(value & 0xFF),
            ]
            let packetChecksum = checksum(for: [displayWriteAddress, hostSourceAddress] + payload)
            return (includeHostAddress ? [hostSourceAddress] : []) + payload + [packetChecksum]
        }

        static func parseGetReply(_ data: [UInt8], expectedVCP: VCPCode) -> DDCReadResult? {
            guard data.count >= getReplyPacketLength,
                  data[0] == displayWriteAddress,
                  data[1] == getReplyLength
            else {
                return nil
            }

            let packet = Array(data.prefix(getReplyPacketLength))
            guard checksum(for: [hostWriteAddress] + packet) == 0,
                  packet[2] == getVCPFeatureReplyOpcode,
                  packet[3] == 0,
                  packet[4] == expectedVCP.rawValue
            else {
                return nil
            }

            let maxValue = (UInt16(packet[6]) << 8) | UInt16(packet[7])
            switch expectedVCP {
            case .brightness, .contrast, .redGain, .greenGain, .blueGain, .volume:
                guard maxValue > 0 else { return nil }
            case .inputSource, .audioMute, .powerMode:
                break
            }

            let currentValue = (UInt16(packet[8]) << 8) | UInt16(packet[9])
            return DDCReadResult(currentValue: currentValue, maxValue: maxValue)
        }
    }

#endif

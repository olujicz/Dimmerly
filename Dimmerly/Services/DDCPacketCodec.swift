//
//  DDCPacketCodec.swift
//  Dimmerly
//
//  Pure DDC/CI packet construction and validation.
//

import Foundation

#if !APPSTORE

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
            guard maxValue > 0 else { return nil }

            let currentValue = (UInt16(packet[8]) << 8) | UInt16(packet[9])
            return DDCReadResult(currentValue: currentValue, maxValue: maxValue)
        }
    }

#endif

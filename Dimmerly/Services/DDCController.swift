//
//  DDCController.swift
//  Dimmerly
//
//  Low-level DDC/CI (Display Data Channel / Command Interface) controller for
//  reading and writing VCP (Virtual Control Panel) codes on external monitors.
//
//  DDC/CI is a VESA standard that allows software to control monitor settings
//  (brightness, contrast, volume, input source, etc.) over the display cable's
//  auxiliary channel. This file implements the I/O layer for macOS.
//
//  Architecture support:
//  - Apple Silicon: Uses IOAVService (private IOKit class) for DDC transactions
//  - Intel Macs: Uses IOI2CRequest via IOFramebufferI2CInterface
//
//  Known limitations:
//  - Built-in HDMI on M1/entry M2 Macs does not support DDC (USB-C/DP works)
//  - DisplayLink USB adapters do not support DDC on macOS
//  - Some EIZO monitors use a proprietary USB protocol instead of DDC/CI
//  - Most TVs do not implement DDC/CI (they use CEC instead)
//  - Not available in App Store builds (IOKit access requires entitlements
//    incompatible with the App Sandbox)
//  - DDC transactions are slow (~40ms per read/write) — callers must
//    debounce and rate-limit to avoid blocking the monitor's MCU
//  - Some monitors only implement a subset of MCCS commands; always
//    check capabilities before assuming a VCP code is supported
//  - Monitors may silently ignore writes to unsupported VCP codes
//  - DDC/CI has no authentication — any process can control the display
//
//  References:
//  - VESA Monitor Control Command Set (MCCS) Standard v2.2a
//  - MonitorControl (MIT): https://github.com/MonitorControl/MonitorControl
//  - m1ddc (MIT): https://github.com/waydabber/m1ddc
//  - AppleSiliconDDC (MIT): https://github.com/waydabber/AppleSiliconDDC
//

#if !APPSTORE

    import CoreGraphics
    import Foundation
    import IOKit

    // MARK: - VCP Code Definitions

    /// MCCS (Monitor Control Command Set) VCP code definitions.
    ///
    /// These are standardized Virtual Control Panel codes defined in the VESA MCCS v2.2a
    /// specification. Each code controls a specific monitor parameter.
    ///
    /// Not all monitors support all codes — use `DDCController.capabilities(for:)` to probe
    /// which codes a specific display implements.
    enum VCPCode: UInt8, CaseIterable, Sendable {
        /// Display luminance / backlight brightness (0–100)
        /// Continuous, Read/Write. Most universally supported code.
        case brightness = 0x10

        /// Display contrast ratio (0–100)
        /// Continuous, Read/Write. Controls the contrast curve.
        case contrast = 0x12

        /// Red video gain (0–100)
        /// Continuous, Read/Write. Adjusts red channel intensity.
        case redGain = 0x16

        /// Green video gain (0–100)
        /// Continuous, Read/Write. Adjusts green channel intensity.
        case greenGain = 0x18

        /// Blue video gain (0–100)
        /// Continuous, Read/Write. Adjusts blue channel intensity.
        case blueGain = 0x1A

        /// Audio speaker volume (0–100)
        /// Continuous, Read/Write. Controls built-in speaker volume.
        case volume = 0x62

        /// Audio mute control
        /// Non-Continuous, Read/Write. Values: 1 = muted, 2 = unmuted.
        case audioMute = 0x8D

        /// Active input source selector
        /// Non-Continuous, Read/Write.
        /// Common values: 15=DP1, 16=DP2, 17=HDMI1, 18=HDMI2, 27=USB-C
        case inputSource = 0x60

        /// Display power mode
        /// Non-Continuous, Read/Write.
        /// Values: 1=on, 4=standby, 5=off (DPMS states)
        case powerMode = 0xD6

        /// Human-readable name for UI display
        var displayName: String {
            switch self {
            case .brightness: return "Brightness"
            case .contrast: return "Contrast"
            case .redGain: return "Red Gain"
            case .greenGain: return "Green Gain"
            case .blueGain: return "Blue Gain"
            case .volume: return "Volume"
            case .audioMute: return "Audio Mute"
            case .inputSource: return "Input Source"
            case .powerMode: return "Power Mode"
            }
        }
    }

    /// Known input source values per MCCS v2.2a Table 8-27.
    ///
    /// Monitor manufacturers may use non-standard values. These cover the most
    /// common sources found in modern monitors.
    enum InputSource: UInt16, CaseIterable, Sendable {
        case vga1 = 1
        case vga2 = 2
        case dvi1 = 3
        case dvi2 = 4
        case composite1 = 5
        case composite2 = 6
        case sVideo1 = 7
        case sVideo2 = 8
        case tuner1 = 9
        case component1 = 10
        case component2 = 11
        case component3 = 12
        case displayPort1 = 15
        case displayPort2 = 16
        case hdmi1 = 17
        case hdmi2 = 18
        case usbC = 27

        var displayName: String {
            switch self {
            case .vga1: return "VGA 1"
            case .vga2: return "VGA 2"
            case .dvi1: return "DVI 1"
            case .dvi2: return "DVI 2"
            case .composite1: return "Composite 1"
            case .composite2: return "Composite 2"
            case .sVideo1: return "S-Video 1"
            case .sVideo2: return "S-Video 2"
            case .tuner1: return "Tuner 1"
            case .component1: return "Component 1"
            case .component2: return "Component 2"
            case .component3: return "Component 3"
            case .displayPort1: return "DisplayPort 1"
            case .displayPort2: return "DisplayPort 2"
            case .hdmi1: return "HDMI 1"
            case .hdmi2: return "HDMI 2"
            case .usbC: return "USB-C"
            }
        }
    }

    // MARK: - DDC Read Result

    /// Result of a DDC/CI VCP read operation.
    ///
    /// DDC returns both the current value and the maximum supported value,
    /// which is essential for normalizing to a 0.0–1.0 range.
    struct DDCReadResult: Sendable, Equatable {
        /// Current value reported by the monitor
        let currentValue: UInt16
        /// Maximum supported value for this VCP code
        let maxValue: UInt16
    }

    // MARK: - DDC Controller

    /// Low-level DDC/CI controller for reading and writing monitor VCP codes via IOKit.
    ///
    /// This controller handles the platform-specific I/O for DDC/CI communication:
    /// - On Apple Silicon, it uses `IOAVService` (private class) via `IOAVServiceReadI2C`/`IOAVServiceWriteI2C`
    /// - On Intel Macs, it uses `IOI2CRequest` via `IOFBGetI2CInterfaceCount`/`IOFBCopyI2CInterfaceForBus`
    ///
    /// All operations are synchronous and take ~40ms per transaction due to I2C bus speed.
    /// Callers should dispatch DDC operations off the main thread and rate-limit writes
    /// to prevent overwhelming the monitor's embedded microcontroller.
    ///
    /// Thread safety: This controller is stateless and all methods are safe to call from
    /// any thread. However, concurrent DDC operations to the same display may interleave
    /// and produce garbled results — serialize access per display externally.
    ///
    /// Usage:
    /// ```swift
    /// let controller = DDCController()
    /// // Read current brightness
    /// if let result = controller.read(vcp: .brightness, for: displayID) {
    ///     print("Brightness: \(result.currentValue)/\(result.maxValue)")
    /// }
    /// // Set brightness to 50%
    /// controller.write(vcp: .brightness, value: 50, for: displayID)
    /// ```
    enum DDCController {
        // MARK: - DDC I2C Protocol Constants

        /// Standard DDC/CI I2C slave address (0x37 << 1 = 0x6E for write, 0x6F for read).
        /// All DDC/CI monitors respond on this address per VESA E-DDC standard.
        private static let ddcI2CAddress: UInt32 = 0x37

        /// Source address identifying the host (0x51). Used in DDC/CI packet checksums.
        private static let hostAddress: UInt8 = 0x51

        /// DDC/CI "Get VCP Feature" command opcode.
        private static let getVCPOpcode: UInt8 = 0x01

        /// DDC/CI "Set VCP Feature" command opcode.
        private static let setVCPOpcode: UInt8 = 0x03

        /// DDC/CI "Get VCP Feature Reply" opcode (expected in read responses).
        private static let getVCPReplyOpcode: UInt8 = 0x02

        /// Delay between write and read in a DDC transaction (milliseconds).
        /// Monitors need time to process the command and prepare the response.
        /// 40ms is conservative; some fast monitors work with 10ms.
        private static let transactionDelayMs: UInt32 = 40

        // MARK: - Public API

        /// Reads the current and maximum value of a VCP code from a display.
        ///
        /// Performs a DDC/CI "Get VCP Feature" transaction:
        /// 1. Finds the IOKit service for the given display
        /// 2. Sends a "Get VCP" command packet
        /// 3. Waits for the monitor to prepare its response (~40ms)
        /// 4. Reads and parses the response packet
        ///
        /// - Parameters:
        ///   - vcp: The VCP code to read
        ///   - displayID: CoreGraphics display identifier
        /// - Returns: Current and max values, or `nil` if the read failed
        ///
        /// Failure reasons include: display not supporting DDC, I2C bus error,
        /// monitor returning an error response, or IOKit service not found.
        static func read(vcp: VCPCode, for displayID: CGDirectDisplayID) -> DDCReadResult? {
            #if arch(arm64)
                return readAppleSilicon(vcp: vcp, for: displayID)
            #else
                return readIntel(vcp: vcp, for: displayID)
            #endif
        }

        /// Writes a value to a VCP code on a display.
        ///
        /// Performs a DDC/CI "Set VCP Feature" transaction:
        /// 1. Finds the IOKit service for the given display
        /// 2. Sends a "Set VCP" command packet with the new value
        ///
        /// There is no acknowledgment — DDC writes are fire-and-forget. To verify
        /// the write took effect, perform a subsequent read after a short delay.
        ///
        /// - Parameters:
        ///   - vcp: The VCP code to write
        ///   - value: The new value (must be within the VCP code's valid range)
        ///   - displayID: CoreGraphics display identifier
        /// - Returns: `true` if the I2C write was dispatched successfully
        @discardableResult
        static func write(vcp: VCPCode, value: UInt16, for displayID: CGDirectDisplayID) -> Bool {
            #if arch(arm64)
                return writeAppleSilicon(vcp: vcp, value: value, for: displayID)
            #else
                return writeIntel(vcp: vcp, value: value, for: displayID)
            #endif
        }

        /// Probes a display to determine which VCP codes it supports.
        ///
        /// Attempts to read each VCP code and collects the ones that return valid responses.
        /// This is an expensive operation (~40ms * number of codes) and should be called
        /// once per display connection, with results cached.
        ///
        /// - Parameter displayID: CoreGraphics display identifier
        /// - Returns: Set of VCP codes that the display responded to successfully
        static func capabilities(for displayID: CGDirectDisplayID) -> Set<VCPCode> {
            var supported = Set<VCPCode>()
            for code in VCPCode.allCases where read(vcp: code, for: displayID) != nil {
                supported.insert(code)
            }
            return supported
        }

        /// Checks if a display appears to support DDC/CI by attempting a brightness read.
        ///
        /// Brightness (VCP 0x10) is the most universally supported DDC code.
        /// If a monitor responds to a brightness read, it almost certainly supports DDC/CI.
        ///
        /// - Parameter displayID: CoreGraphics display identifier
        /// - Returns: `true` if the display responded to a DDC brightness read
        static func supportsDDC(for displayID: CGDirectDisplayID) -> Bool {
            read(vcp: .brightness, for: displayID) != nil
        }

        // MARK: - Apple Silicon Implementation

        #if arch(arm64)

            /// Finds the IOAVService for a given display on Apple Silicon.
            ///
            /// On Apple Silicon, external displays are exposed via IOAVService objects in the
            /// IOKit registry. This method maps a `CGDirectDisplayID` to its corresponding
            /// IOAVService by matching the `Location` property against the display's serial number
            /// or by iterating all services and matching based on DisplayPort transport info.
            ///
            /// The approach used here (iterating IOAVService instances) is derived from the
            /// open-source m1ddc and MonitorControl projects (both MIT licensed).
            ///
            /// - Parameter displayID: CoreGraphics display identifier
            /// - Returns: IOKit service handle, or `IO_OBJECT_NULL` if not found.
            ///           Caller must release with `IOObjectRelease`.
            private static func findIOAVService(for displayID: CGDirectDisplayID) -> io_service_t {
                // Get vendor and model from CoreGraphics to match against IOKit
                let vendorID = CGDisplayVendorNumber(displayID)
                let modelID = CGDisplayModelNumber(displayID)
                let serialNumber = CGDisplaySerialNumber(displayID)

                var iterator: io_iterator_t = 0
                guard IOServiceGetMatchingServices(
                    kIOMainPortDefault,
                    IOServiceMatching("IOAVService"),
                    &iterator
                ) == KERN_SUCCESS else {
                    return IO_OBJECT_NULL
                }
                defer { IOObjectRelease(iterator) }

                var service = IOIteratorNext(iterator)
                while service != IO_OBJECT_NULL {
                    // Check if this service matches our display by walking up to the
                    // display transport parent and comparing EDID-derived IDs
                    if matchesDisplay(
                        service: service, vendorID: vendorID,
                        modelID: modelID, serialNumber: serialNumber
                    ) {
                        return service // Caller must release
                    }
                    IOObjectRelease(service)
                    service = IOIteratorNext(iterator)
                }

                // Fallback: if only one external display and one IOAVService, assume match.
                // This handles monitors where EDID vendor/model don't match CG-reported values.
                var fallbackIterator: io_iterator_t = 0
                guard IOServiceGetMatchingServices(
                    kIOMainPortDefault,
                    IOServiceMatching("IOAVService"),
                    &fallbackIterator
                ) == KERN_SUCCESS else {
                    return IO_OBJECT_NULL
                }
                defer { IOObjectRelease(fallbackIterator) }

                var services: [io_service_t] = []
                var s = IOIteratorNext(fallbackIterator)
                while s != IO_OBJECT_NULL {
                    services.append(s)
                    s = IOIteratorNext(fallbackIterator)
                }

                let externalDisplays: [CGDirectDisplayID] = {
                    var displayCount: UInt32 = 0
                    CGGetActiveDisplayList(0, nil, &displayCount)
                    var displays = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
                    CGGetActiveDisplayList(displayCount, &displays, &displayCount)
                    return displays.filter { CGDisplayIsBuiltin($0) == 0 }
                }()
                if services.count == 1 && externalDisplays.count == 1 && externalDisplays.first == displayID {
                    return services[0] // Caller must release
                }

                // Clean up unreturned services
                for svc in services {
                    IOObjectRelease(svc)
                }
                return IO_OBJECT_NULL
            }

            /// Checks if an IOAVService corresponds to a specific display by examining
            /// the IOKit registry hierarchy for matching EDID properties.
            private static func matchesDisplay(
                service: io_service_t,
                vendorID: UInt32,
                modelID: UInt32,
                serialNumber: UInt32
            ) -> Bool {
                // Walk up the registry to find the parent with EDID/display info
                var parent: io_registry_entry_t = 0
                var current = service

                // Walk up a few levels looking for display properties
                for _ in 0 ..< 5 {
                    var nextParent: io_registry_entry_t = 0
                    guard IORegistryEntryGetParentEntry(current, kIOServicePlane, &nextParent) == KERN_SUCCESS else {
                        break
                    }
                    if current != service {
                        IOObjectRelease(current)
                    }
                    current = nextParent
                    parent = nextParent

                    var properties: Unmanaged<CFMutableDictionary>?
                    guard IORegistryEntryCreateCFProperties(
                        parent, &properties, kCFAllocatorDefault, 0
                    ) == KERN_SUCCESS,
                        let dict = properties?.takeRetainedValue() as? [String: Any]
                    else {
                        continue
                    }

                    // Check for ProductID/VendorID match (Apple Silicon display properties)
                    if let productID = dict["ProductID"] as? UInt32,
                       let vid = dict["VendorID"] as? UInt32
                    {
                        if productID == modelID && vid == vendorID {
                            if current != service { IOObjectRelease(current) }
                            return true
                        }
                    }

                    // Check for DisplayVendorID/DisplayProductID match (standard IOKit display)
                    if let displayVendorID = dict["DisplayVendorID"] as? UInt32,
                       let displayProductID = dict["DisplayProductID"] as? UInt32
                    {
                        if displayVendorID == vendorID && displayProductID == modelID {
                            if current != service { IOObjectRelease(current) }
                            return true
                        }
                    }

                    // Check for serial number match
                    if serialNumber != 0, let sn = dict["DisplaySerialNumber"] as? UInt32, sn == serialNumber {
                        if current != service { IOObjectRelease(current) }
                        return true
                    }
                }

                if current != service {
                    IOObjectRelease(current)
                }
                return false
            }

            /// Reads a VCP code via IOAVService on Apple Silicon.
            ///
            /// DDC/CI read protocol:
            /// 1. Write: [slave_addr, length|0x80, get_vcp_opcode, vcp_code, checksum]
            /// 2. Wait ~40ms for monitor to process
            /// 3. Read: [result_code, get_vcp_reply_opcode, vcp_code, type, max_hi, max_lo, cur_hi, cur_lo, checksum]
            private static func readAppleSilicon(vcp: VCPCode, for displayID: CGDirectDisplayID) -> DDCReadResult? {
                let service = findIOAVService(for: displayID)
                guard service != IO_OBJECT_NULL else { return nil }
                defer { IOObjectRelease(service) }

                // Build the "Get VCP Feature" command packet
                // DDC/CI packet format: [length|0x80, source_addr, opcode, vcp_code]
                // Checksum: XOR of all bytes including the destination address (0x6E)
                let length: UInt8 = 0x82 // 2 bytes payload | 0x80 flag
                let checksum = UInt8(ddcI2CAddress << 1) ^ hostAddress ^ length ^ getVCPOpcode ^ vcp.rawValue
                var writeData: [UInt8] = [hostAddress, length, getVCPOpcode, vcp.rawValue, checksum]

                // Send the get command
                var result = IOAVServiceWriteI2C(service, ddcI2CAddress, 0, &writeData, UInt32(writeData.count))
                guard result == KERN_SUCCESS else { return nil }

                // Wait for monitor to prepare response
                usleep(transactionDelayMs * 1000)

                // Read response (12 bytes: DDC/CI reply packet)
                var readData = [UInt8](repeating: 0, count: 12)
                result = IOAVServiceReadI2C(service, ddcI2CAddress, 0, &readData, UInt32(readData.count))
                guard result == KERN_SUCCESS else { return nil }

                // Parse the response
                return parseDDCResponse(readData, expectedVCP: vcp)
            }

            /// Writes a VCP code via IOAVService on Apple Silicon.
            ///
            /// DDC/CI write protocol:
            /// Write: [slave_addr, length|0x80, set_vcp_opcode, vcp_code, value_hi, value_lo, checksum]
            private static func writeAppleSilicon(
                vcp: VCPCode, value: UInt16, for displayID: CGDirectDisplayID
            ) -> Bool {
                let service = findIOAVService(for: displayID)
                guard service != IO_OBJECT_NULL else { return false }
                defer { IOObjectRelease(service) }

                let valueHi = UInt8((value >> 8) & 0xFF)
                let valueLo = UInt8(value & 0xFF)
                let length: UInt8 = 0x84 // 4 bytes payload | 0x80 flag
                let checksum = UInt8(ddcI2CAddress << 1) ^ hostAddress ^ length
                    ^ setVCPOpcode ^ vcp.rawValue ^ valueHi ^ valueLo
                var writeData: [UInt8] = [
                    hostAddress, length, setVCPOpcode, vcp.rawValue, valueHi, valueLo, checksum,
                ]

                let result = IOAVServiceWriteI2C(service, ddcI2CAddress, 0, &writeData, UInt32(writeData.count))
                return result == KERN_SUCCESS
            }

        #endif

        // MARK: - Intel Implementation

        #if arch(x86_64)

            /// Finds the IOFramebuffer service for a given display on Intel Macs.
            ///
            /// On Intel Macs, each display is connected via an IOFramebuffer which exposes
            /// I2C interfaces for DDC communication. This method maps a `CGDirectDisplayID`
            /// to the correct IOFramebuffer by matching vendor/product IDs via IODisplayConnect.
            private static func findFramebufferService(for displayID: CGDirectDisplayID) -> io_service_t {
                let vendorID = CGDisplayVendorNumber(displayID)
                let modelID = CGDisplayModelNumber(displayID)

                var iterator: io_iterator_t = 0
                guard IOServiceGetMatchingServices(
                    kIOMainPortDefault,
                    IOServiceMatching("IODisplayConnect"),
                    &iterator
                ) == KERN_SUCCESS else {
                    return IO_OBJECT_NULL
                }
                defer { IOObjectRelease(iterator) }

                var service = IOIteratorNext(iterator)
                while service != IO_OBJECT_NULL {
                    var properties: Unmanaged<CFMutableDictionary>?
                    guard IORegistryEntryCreateCFProperties(
                        service, &properties, kCFAllocatorDefault, 0
                    ) == KERN_SUCCESS,
                        let dict = properties?.takeRetainedValue() as? [String: Any]
                    else {
                        IOObjectRelease(service)
                        service = IOIteratorNext(iterator)
                        continue
                    }

                    if let vid = dict["DisplayVendorID"] as? UInt32,
                       let pid = dict["DisplayProductID"] as? UInt32,
                       vid == vendorID, pid == modelID
                    {
                        // Found matching display — get the framebuffer parent
                        var framebuffer: io_service_t = 0
                        if IORegistryEntryGetParentEntry(service, kIOServicePlane, &framebuffer) == KERN_SUCCESS {
                            IOObjectRelease(service)
                            return framebuffer
                        }
                    }

                    IOObjectRelease(service)
                    service = IOIteratorNext(iterator)
                }

                return IO_OBJECT_NULL
            }

            /// Reads a VCP code via IOI2CRequest on Intel Macs.
            private static func readIntel(vcp: VCPCode, for displayID: CGDirectDisplayID) -> DDCReadResult? {
                let framebuffer = findFramebufferService(for: displayID)
                guard framebuffer != IO_OBJECT_NULL else { return nil }
                defer { IOObjectRelease(framebuffer) }

                // Check for I2C interface availability
                var busCount: IOItemCount = 0
                guard IOFBGetI2CInterfaceCount(framebuffer, &busCount) == KERN_SUCCESS, busCount > 0 else {
                    return nil
                }

                // Get the I2C interface for bus 0
                var interface: io_service_t = 0
                guard IOFBCopyI2CInterfaceForBus(framebuffer, 0, &interface) == KERN_SUCCESS else {
                    return nil
                }
                defer { IOObjectRelease(interface) }

                // Open a connection to the I2C interface
                var connect: IOI2CConnectRef?
                guard IOI2CInterfaceOpen(interface, 0, &connect) == KERN_SUCCESS, let connect else {
                    return nil
                }
                defer { IOI2CInterfaceClose(connect, 0) }

                // Build the DDC "Get VCP" command
                let length: UInt8 = 0x82
                let checksum = UInt8(ddcI2CAddress << 1) ^ hostAddress ^ length ^ getVCPOpcode ^ vcp.rawValue
                var writeData: [UInt8] = [hostAddress, length, getVCPOpcode, vcp.rawValue, checksum]

                // Prepare write request
                var writeRequest = IOI2CRequest()
                writeRequest.sendAddress = ddcI2CAddress << 1
                writeRequest.sendTransactionType = IOOptionBits(kIOI2CSimpleTransactionType)
                writeRequest.sendBuffer = vm_address_t(bitPattern: UnsafeMutablePointer(&writeData))
                writeRequest.sendBytes = UInt32(writeData.count)

                guard IOI2CSendRequest(connect, 0, &writeRequest) == KERN_SUCCESS,
                      writeRequest.result == KERN_SUCCESS
                else {
                    return nil
                }

                // Wait for monitor
                usleep(transactionDelayMs * 1000)

                // Prepare read request
                var readData = [UInt8](repeating: 0, count: 12)
                var readRequest = IOI2CRequest()
                readRequest.replyAddress = (ddcI2CAddress << 1) | 0x01
                readRequest.replyTransactionType = IOOptionBits(kIOI2CSimpleTransactionType)
                readRequest.replyBuffer = vm_address_t(bitPattern: UnsafeMutablePointer(&readData))
                readRequest.replyBytes = UInt32(readData.count)

                guard IOI2CSendRequest(connect, 0, &readRequest) == KERN_SUCCESS,
                      readRequest.result == KERN_SUCCESS
                else {
                    return nil
                }

                return parseDDCResponse(readData, expectedVCP: vcp)
            }

            /// Writes a VCP code via IOI2CRequest on Intel Macs.
            private static func writeIntel(vcp: VCPCode, value: UInt16, for displayID: CGDirectDisplayID) -> Bool {
                let framebuffer = findFramebufferService(for: displayID)
                guard framebuffer != IO_OBJECT_NULL else { return false }
                defer { IOObjectRelease(framebuffer) }

                var busCount: IOItemCount = 0
                guard IOFBGetI2CInterfaceCount(framebuffer, &busCount) == KERN_SUCCESS, busCount > 0 else {
                    return false
                }

                var interface: io_service_t = 0
                guard IOFBCopyI2CInterfaceForBus(framebuffer, 0, &interface) == KERN_SUCCESS else {
                    return false
                }
                defer { IOObjectRelease(interface) }

                var connect: IOI2CConnectRef?
                guard IOI2CInterfaceOpen(interface, 0, &connect) == KERN_SUCCESS, let connect else {
                    return false
                }
                defer { IOI2CInterfaceClose(connect, 0) }

                let valueHi = UInt8((value >> 8) & 0xFF)
                let valueLo = UInt8(value & 0xFF)
                let length: UInt8 = 0x84
                let checksum = UInt8(ddcI2CAddress << 1) ^ hostAddress ^ length
                    ^ setVCPOpcode ^ vcp.rawValue ^ valueHi ^ valueLo
                var writeData: [UInt8] = [
                    hostAddress, length, setVCPOpcode, vcp.rawValue, valueHi, valueLo, checksum,
                ]

                var request = IOI2CRequest()
                request.sendAddress = ddcI2CAddress << 1
                request.sendTransactionType = IOOptionBits(kIOI2CSimpleTransactionType)
                request.sendBuffer = vm_address_t(bitPattern: UnsafeMutablePointer(&writeData))
                request.sendBytes = UInt32(writeData.count)

                return IOI2CSendRequest(connect, 0, &request) == KERN_SUCCESS
                    && request.result == KERN_SUCCESS
            }

        #endif

        // MARK: - Response Parsing

        /// Parses a DDC/CI "Get VCP Feature Reply" response packet.
        ///
        /// DDC/CI response format (11+ bytes):
        /// ```
        /// Byte 0:  Source address (0x6E)
        /// Byte 1:  Length | 0x80 (should be 0x88 for 8-byte payload)
        /// Byte 2:  Result code (0x00 = no error)
        /// Byte 3:  Reply opcode (0x02 = Get VCP Reply)
        /// Byte 4:  VCP code being replied to
        /// Byte 5:  VCP type (0x00 = set parameter, 0x01 = momentary)
        /// Byte 6:  Max value high byte
        /// Byte 7:  Max value low byte
        /// Byte 8:  Current value high byte
        /// Byte 9:  Current value low byte
        /// Byte 10: Checksum (XOR of all bytes)
        /// ```
        ///
        /// - Parameters:
        ///   - data: Raw response bytes from I2C read
        ///   - expectedVCP: The VCP code we expect in the reply
        /// - Returns: Parsed current and max values, or `nil` if the response is invalid
        private static func parseDDCResponse(_ data: [UInt8], expectedVCP: VCPCode) -> DDCReadResult? {
            // Minimum response length check
            guard data.count >= 11 else { return nil }

            // Verify this is a valid VCP reply
            let replyOpcode = data[3]
            guard replyOpcode == getVCPReplyOpcode else { return nil }

            // Check result code (byte 2): 0x00 = success
            let resultCode = data[2]
            guard resultCode == 0x00 else { return nil }

            // Verify the reply is for the VCP code we asked about
            let repliedVCP = data[4]
            guard repliedVCP == expectedVCP.rawValue else { return nil }

            // Extract values
            let maxValue = (UInt16(data[6]) << 8) | UInt16(data[7])
            let currentValue = (UInt16(data[8]) << 8) | UInt16(data[9])

            // Sanity check: max should be > 0
            guard maxValue > 0 else { return nil }

            return DDCReadResult(currentValue: currentValue, maxValue: maxValue)
        }
    }

    // MARK: - IOAVService Bridging (Apple Silicon)

    // These functions are private IOKit symbols that are available on Apple Silicon Macs.
    // They are used by MonitorControl, m1ddc, and other DDC tools. Apple has not formally
    // documented them, but they have remained stable since macOS 11 (Big Sur).
//
    // The symbols are resolved at link time from IOKit.framework — no dlsym needed.
    // If Apple ever removes these symbols, the app will fail to link, not crash at runtime.

    #if arch(arm64)

        /// Writes data to an I2C device via IOAVService.
        ///
        /// - Parameters:
        ///   - service: IOAVService handle from IOKit
        ///   - address: I2C slave address (7-bit, not shifted)
        ///   - register: I2C register (typically 0 for DDC)
        ///   - data: Buffer of bytes to write
        ///   - length: Number of bytes to write
        /// - Returns: IOKit result code (KERN_SUCCESS on success)
        @_silgen_name("IOAVServiceWriteI2C")
        private func IOAVServiceWriteI2C(
            _ service: io_service_t,
            _ address: UInt32,
            _ register: UInt32,
            _ data: UnsafeMutablePointer<UInt8>,
            _ length: UInt32
        ) -> IOReturn

        /// Reads data from an I2C device via IOAVService.
        ///
        /// - Parameters:
        ///   - service: IOAVService handle from IOKit
        ///   - address: I2C slave address (7-bit, not shifted)
        ///   - register: I2C register (typically 0 for DDC)
        ///   - data: Buffer to receive read bytes
        ///   - length: Number of bytes to read
        /// - Returns: IOKit result code (KERN_SUCCESS on success)
        @_silgen_name("IOAVServiceReadI2C")
        private func IOAVServiceReadI2C(
            _ service: io_service_t,
            _ address: UInt32,
            _ register: UInt32,
            _ data: UnsafeMutablePointer<UInt8>,
            _ length: UInt32
        ) -> IOReturn

    #endif

#endif // !APPSTORE

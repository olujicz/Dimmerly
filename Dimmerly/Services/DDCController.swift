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
//  - Apple Silicon M1–M3: Uses IOAVService (private IOKit class) for DDC transactions
//  - Apple Silicon M4+: Uses DCPAVServiceProxy → IOAVServiceCreateWithService → IOAVService
//  - Intel Macs: Uses IOI2CRequest via IOFramebufferI2CInterface
//
//  Known limitations:
//  - Built-in HDMI on M1/entry M2/M4 Macs may not support DDC (USB-C/DP works)
//  - DisplayLink USB adapters do not support DDC on macOS
//  - Some EIZO monitors use a proprietary USB protocol instead of DDC/CI
//  - Most TVs do not implement DDC/CI (they use CEC instead)
//  - Not available in App Store builds (IOKit access requires entitlements
//    incompatible with the App Sandbox)
//  - DDC transactions are slow (~50ms per read/write) — callers must
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
    /// On Apple Silicon, multiple I2C transport paths are tried in order:
    /// 1. IOAVService (standard path, works for USB-C/DP on all Apple Silicon)
    /// 2. IOAVDevice (alternative DCP firmware path, may help for HDMI)
    /// 3. Direct IOConnectCallMethod (last resort, tries raw IOConnect selectors)
    ///
    /// Each transport uses retry logic (multiple write cycles and retry attempts) to
    /// improve reliability on noisy I2C buses, matching MonitorControl and m1ddc behavior.
    ///
    /// All operations are synchronous and take ~50ms per transaction due to I2C bus speed.
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

        /// Source address identifying the host (0x51). Used in DDC/CI packet checksums
        /// and as the I2C register/sub-address byte for Apple Silicon DDC transactions.
        private static let hostAddress: UInt8 = 0x51

        /// DDC/CI "Get VCP Feature" command opcode.
        private static let getVCPOpcode: UInt8 = 0x01

        /// DDC/CI "Set VCP Feature" command opcode.
        private static let setVCPOpcode: UInt8 = 0x03

        /// DDC/CI "Get VCP Feature Reply" opcode (expected in read responses).
        private static let getVCPReplyOpcode: UInt8 = 0x02

        /// Delay between write and read in a DDC transaction (milliseconds).
        /// Monitors need time to process the command and prepare the response.
        /// 50ms works reliably across monitors; some fast monitors work with 10ms.
        private static let transactionDelayMs: UInt32 = 50

        /// Number of times to send each DDC write command per attempt.
        /// Sending the command twice improves reliability on noisy I2C buses,
        /// matching the behavior of MonitorControl and m1ddc.
        private static let writeCyclesPerAttempt = 2

        /// Delay between write cycles within a single attempt (milliseconds).
        private static let writeCycleDelayMs: UInt32 = 10

        /// Maximum number of retry attempts for a DDC transaction.
        private static let maxRetryAttempts = 3

        /// Delay between retry attempts (milliseconds).
        private static let retryDelayMs: UInt32 = 20

        // MARK: - Public API

        /// Reads the current and maximum value of a VCP code from a display.
        ///
        /// Performs a DDC/CI "Get VCP Feature" transaction:
        /// 1. Finds the IOKit service for the given display
        /// 2. Sends a "Get VCP" command packet
        /// 3. Waits for the monitor to prepare its response (~50ms)
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
        /// This is an expensive operation (~50ms * number of codes) and should be called
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

            /// IOKit class names that expose DDC I2C services on Apple Silicon.
            ///
            /// - `DCPAVServiceProxy`: M4+ Macs (new DCP display pipeline architecture)
            /// - `IOAVService`: M1/M2/M3 Macs (original Apple Silicon display pipeline)
            ///
            /// Order matters: DCPAVServiceProxy is checked first because on M4 Macs it is
            /// the only class present. On M1–M3, IOAVService is present and DCPAVServiceProxy
            /// is absent, so the first iteration is a no-op.
            private static let avServiceClassNames = ["DCPAVServiceProxy", "IOAVService"]

            // Dynamically loaded IOAVDevice I2C functions for the alternative HDMI path.
            //
            // DCPAVDeviceProxy is a separate IOKit class from DCPAVServiceProxy that may
            // route I2C differently through the DCP firmware for HDMI connections. These
            // symbols may not exist on all macOS versions; using dlsym ensures the app
            // links and runs even if they are absent.

            /// dlsym handle for searching all loaded images (RTLD_DEFAULT = -2).
            /// The C macro `RTLD_DEFAULT` isn't importable in Swift.
            private nonisolated(unsafe) static let dlDefault = UnsafeMutableRawPointer(bitPattern: -2)

            private static let avDeviceCreate: (
                @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
            )? = {
                guard let handle = dlDefault,
                      let sym = dlsym(handle, "IOAVDeviceCreateWithService") else { return nil }
                return unsafeBitCast(
                    sym,
                    to: (@convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?).self
                )
            }()

            private typealias AVDeviceI2CFn = @convention(c) (
                CFTypeRef, UInt32, UInt32, UnsafeMutablePointer<UInt8>, UInt32
            ) -> IOReturn

            private static let avDeviceWrite: AVDeviceI2CFn? = {
                guard let handle = dlDefault,
                      let sym = dlsym(handle, "IOAVDeviceWriteI2C") else { return nil }
                return unsafeBitCast(sym, to: AVDeviceI2CFn.self)
            }()

            private static let avDeviceRead: AVDeviceI2CFn? = {
                guard let handle = dlDefault,
                      let sym = dlsym(handle, "IOAVDeviceReadI2C") else { return nil }
                return unsafeBitCast(sym, to: AVDeviceI2CFn.self)
            }()

            // MARK: Service Discovery

            /// Finds and creates an IOAVService for a given display on Apple Silicon.
            ///
            /// On Apple Silicon, external displays are exposed via IOAVService or
            /// DCPAVServiceProxy objects in the IOKit registry. This method:
            /// 1. Searches both class names (M4+ uses DCPAVServiceProxy, M1–M3 uses IOAVService)
            /// 2. Matches the registry entry to the display via EDID vendor/model/serial
            /// 3. Creates an IOAVService CFTypeRef via `IOAVServiceCreateWithService`
            ///
            /// The approach is derived from the open-source m1ddc, MonitorControl, and
            /// i2c_on_macOS projects (all MIT licensed).
            ///
            /// - Parameter displayID: CoreGraphics display identifier
            /// - Returns: IOAVService object for I2C operations, or `nil` if not found.
            ///           The returned CFTypeRef is retained and managed by ARC.
            private static func findIOAVService(for displayID: CGDirectDisplayID) -> CFTypeRef? {
                let vendorID = CGDisplayVendorNumber(displayID)
                let modelID = CGDisplayModelNumber(displayID)
                let serialNumber = CGDisplaySerialNumber(displayID)

                // Strategy 1: Match by EDID vendor/model/serial via parent walk
                for className in avServiceClassNames {
                    var iterator: io_iterator_t = 0
                    guard IOServiceGetMatchingServices(
                        kIOMainPortDefault,
                        IOServiceMatching(className),
                        &iterator
                    ) == KERN_SUCCESS else {
                        continue
                    }
                    defer { IOObjectRelease(iterator) }

                    var service = IOIteratorNext(iterator)
                    while service != IO_OBJECT_NULL {
                        if matchesDisplay(
                            service: service, vendorID: vendorID,
                            modelID: modelID, serialNumber: serialNumber
                        ) {
                            let avService = IOAVServiceCreateWithService(nil, service)
                            IOObjectRelease(service)
                            return avService?.takeRetainedValue()
                        }
                        IOObjectRelease(service)
                        service = IOIteratorNext(iterator)
                    }
                }

                // Strategy 2: If only one external display and one service, assume match.
                // This handles monitors where EDID vendor/model don't match CG-reported values.
                for className in avServiceClassNames {
                    var iterator: io_iterator_t = 0
                    guard IOServiceGetMatchingServices(
                        kIOMainPortDefault,
                        IOServiceMatching(className),
                        &iterator
                    ) == KERN_SUCCESS else {
                        continue
                    }
                    defer { IOObjectRelease(iterator) }

                    var services: [io_service_t] = []
                    var s = IOIteratorNext(iterator)
                    while s != IO_OBJECT_NULL {
                        services.append(s)
                        s = IOIteratorNext(iterator)
                    }

                    let externalDisplays: [CGDirectDisplayID] = {
                        var displayCount: UInt32 = 0
                        CGGetActiveDisplayList(0, nil, &displayCount)
                        var displays = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
                        CGGetActiveDisplayList(displayCount, &displays, &displayCount)
                        return displays.filter { CGDisplayIsBuiltin($0) == 0 }
                    }()

                    if services.count == 1 && externalDisplays.count == 1
                        && externalDisplays.first == displayID
                    {
                        let avService = IOAVServiceCreateWithService(nil, services[0])
                        for svc in services {
                            IOObjectRelease(svc)
                        }
                        return avService?.takeRetainedValue()
                    }

                    for svc in services {
                        IOObjectRelease(svc)
                    }
                }

                return nil
            }

            /// Finds and creates an IOAVDevice for a given display (HDMI fallback path).
            ///
            /// DCPAVDeviceProxy is an alternative IOKit class that routes I2C through
            /// a different path in the DCP firmware. This may enable DDC on HDMI ports
            /// where the standard DCPAVServiceProxy path fails.
            ///
            /// - Parameter displayID: CoreGraphics display identifier
            /// - Returns: IOAVDevice object for I2C operations, or `nil` if not available
            private static func findIOAVDevice(for displayID: CGDirectDisplayID) -> CFTypeRef? {
                guard let createFn = avDeviceCreate else { return nil }

                let vendorID = CGDisplayVendorNumber(displayID)
                let modelID = CGDisplayModelNumber(displayID)
                let serialNumber = CGDisplaySerialNumber(displayID)

                var iterator: io_iterator_t = 0
                guard IOServiceGetMatchingServices(
                    kIOMainPortDefault,
                    IOServiceMatching("DCPAVDeviceProxy"),
                    &iterator
                ) == KERN_SUCCESS else {
                    return nil
                }
                defer { IOObjectRelease(iterator) }

                var service = IOIteratorNext(iterator)
                while service != IO_OBJECT_NULL {
                    if matchesDisplay(
                        service: service, vendorID: vendorID,
                        modelID: modelID, serialNumber: serialNumber
                    ) {
                        let device = createFn(nil, service)
                        IOObjectRelease(service)
                        return device?.takeRetainedValue()
                    }
                    IOObjectRelease(service)
                    service = IOIteratorNext(iterator)
                }

                return nil
            }

            /// Finds the raw IOKit service entry for direct IOConnectCallMethod access.
            ///
            /// Returns an un-wrapped io_service_t (not converted to IOAVService/IOAVDevice)
            /// for use with IOServiceOpen + IOConnectCallMethod. Caller must release via
            /// IOObjectRelease.
            private static func findRawService(for displayID: CGDirectDisplayID) -> io_service_t? {
                let vendorID = CGDisplayVendorNumber(displayID)
                let modelID = CGDisplayModelNumber(displayID)
                let serialNumber = CGDisplaySerialNumber(displayID)

                let allClassNames = avServiceClassNames + ["DCPAVDeviceProxy"]
                for className in allClassNames {
                    var iterator: io_iterator_t = 0
                    guard IOServiceGetMatchingServices(
                        kIOMainPortDefault,
                        IOServiceMatching(className),
                        &iterator
                    ) == KERN_SUCCESS else {
                        continue
                    }
                    defer { IOObjectRelease(iterator) }

                    var service = IOIteratorNext(iterator)
                    while service != IO_OBJECT_NULL {
                        if matchesDisplay(
                            service: service, vendorID: vendorID,
                            modelID: modelID, serialNumber: serialNumber
                        ) {
                            return service
                        }
                        IOObjectRelease(service)
                        service = IOIteratorNext(iterator)
                    }
                }

                return nil
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

            // MARK: Apple Silicon Read/Write (Multi-Transport)

            /// Reads a VCP code on Apple Silicon, trying multiple I2C transport paths.
            ///
            /// Transport priority:
            /// 1. IOAVService — standard path, works for USB-C/DP on all Apple Silicon
            /// 2. IOAVDevice — alternative DCP firmware path, may help for HDMI
            /// 3. Direct IOConnectCallMethod — last resort with raw IOConnect selectors
            ///
            /// Each transport uses retry logic with multiple write cycles per attempt.
            private static func readAppleSilicon(vcp: VCPCode, for displayID: CGDirectDisplayID) -> DDCReadResult? {
                if let avService = findIOAVService(for: displayID) {
                    if let result = readViaService(avService: avService, vcp: vcp) {
                        return result
                    }
                }

                if let avDevice = findIOAVDevice(for: displayID) {
                    if let result = readViaDevice(avDevice: avDevice, vcp: vcp) {
                        return result
                    }
                }

                if let service = findRawService(for: displayID) {
                    defer { IOObjectRelease(service) }
                    if let result = readViaDirect(service: service, vcp: vcp) {
                        return result
                    }
                }

                return nil
            }

            /// Writes a VCP code on Apple Silicon, trying multiple I2C transport paths.
            ///
            /// Transport priority matches `readAppleSilicon`.
            private static func writeAppleSilicon(
                vcp: VCPCode, value: UInt16, for displayID: CGDirectDisplayID
            ) -> Bool {
                if let avService = findIOAVService(for: displayID) {
                    if writeViaService(avService: avService, vcp: vcp, value: value) {
                        return true
                    }
                }

                if let avDevice = findIOAVDevice(for: displayID) {
                    if writeViaDevice(avDevice: avDevice, vcp: vcp, value: value) {
                        return true
                    }
                }

                if let service = findRawService(for: displayID) {
                    defer { IOObjectRelease(service) }
                    if writeViaDirect(service: service, vcp: vcp, value: value) {
                        return true
                    }
                }

                return false
            }

            // MARK: IOAVService Transport (Standard Path)

            /// Reads a VCP code via IOAVService with retry logic.
            ///
            /// The `hostAddress` (0x51) is passed as the I2C register/sub-address parameter,
            /// matching the behavior of MonitorControl, m1ddc, and AppleSiliconDDC. The
            /// checksum includes 0x51 even though it is not in the packet body, because the
            /// I2C hardware transmits it as part of the frame.
            private static func readViaService(avService: CFTypeRef, vcp: VCPCode) -> DDCReadResult? {
                let length: UInt8 = 0x82
                let checksum = UInt8(ddcI2CAddress << 1) ^ hostAddress ^ length ^ getVCPOpcode ^ vcp.rawValue

                for attempt in 0 ..< maxRetryAttempts {
                    if attempt > 0 { usleep(retryDelayMs * 1000) }

                    var writeData: [UInt8] = [length, getVCPOpcode, vcp.rawValue, checksum]
                    var writeOK = false
                    for cycle in 0 ..< writeCyclesPerAttempt {
                        if cycle > 0 { usleep(writeCycleDelayMs * 1000) }
                        let r = IOAVServiceWriteI2C(
                            avService, ddcI2CAddress, UInt32(hostAddress),
                            &writeData, UInt32(writeData.count)
                        )
                        if r == KERN_SUCCESS { writeOK = true }
                    }
                    guard writeOK else { continue }

                    usleep(transactionDelayMs * 1000)

                    var readData = [UInt8](repeating: 0, count: 12)
                    let r = IOAVServiceReadI2C(
                        avService, ddcI2CAddress, UInt32(hostAddress),
                        &readData, UInt32(readData.count)
                    )
                    guard r == KERN_SUCCESS else { continue }

                    if let result = parseDDCResponse(readData, expectedVCP: vcp) {
                        return result
                    }
                }
                return nil
            }

            /// Writes a VCP code via IOAVService with retry logic.
            private static func writeViaService(avService: CFTypeRef, vcp: VCPCode, value: UInt16) -> Bool {
                let valueHi = UInt8((value >> 8) & 0xFF)
                let valueLo = UInt8(value & 0xFF)
                let length: UInt8 = 0x84
                let checksum = UInt8(ddcI2CAddress << 1) ^ hostAddress ^ length
                    ^ setVCPOpcode ^ vcp.rawValue ^ valueHi ^ valueLo

                for attempt in 0 ..< maxRetryAttempts {
                    if attempt > 0 { usleep(retryDelayMs * 1000) }

                    var writeData: [UInt8] = [length, setVCPOpcode, vcp.rawValue, valueHi, valueLo, checksum]
                    var writeOK = false
                    for cycle in 0 ..< writeCyclesPerAttempt {
                        if cycle > 0 { usleep(writeCycleDelayMs * 1000) }
                        let r = IOAVServiceWriteI2C(
                            avService, ddcI2CAddress, UInt32(hostAddress),
                            &writeData, UInt32(writeData.count)
                        )
                        if r == KERN_SUCCESS { writeOK = true }
                    }
                    if writeOK { return true }
                }
                return false
            }

            // MARK: IOAVDevice Transport (HDMI Fallback)

            /// Reads a VCP code via IOAVDevice (alternative I2C path for HDMI).
            private static func readViaDevice(avDevice: CFTypeRef, vcp: VCPCode) -> DDCReadResult? {
                guard let writeFn = avDeviceWrite, let readFn = avDeviceRead else {
                    return nil
                }

                let length: UInt8 = 0x82
                let checksum = UInt8(ddcI2CAddress << 1) ^ hostAddress ^ length ^ getVCPOpcode ^ vcp.rawValue

                for attempt in 0 ..< maxRetryAttempts {
                    if attempt > 0 { usleep(retryDelayMs * 1000) }

                    var writeData: [UInt8] = [length, getVCPOpcode, vcp.rawValue, checksum]
                    var writeOK = false
                    for cycle in 0 ..< writeCyclesPerAttempt {
                        if cycle > 0 { usleep(writeCycleDelayMs * 1000) }
                        let r = writeFn(
                            avDevice, ddcI2CAddress, UInt32(hostAddress),
                            &writeData, UInt32(writeData.count)
                        )
                        if r == KERN_SUCCESS { writeOK = true }
                    }
                    guard writeOK else { continue }

                    usleep(transactionDelayMs * 1000)

                    var readData = [UInt8](repeating: 0, count: 12)
                    let r = readFn(
                        avDevice, ddcI2CAddress, UInt32(hostAddress),
                        &readData, UInt32(readData.count)
                    )
                    guard r == KERN_SUCCESS else { continue }

                    if let result = parseDDCResponse(readData, expectedVCP: vcp) {
                        return result
                    }
                }
                return nil
            }

            /// Writes a VCP code via IOAVDevice (alternative I2C path for HDMI).
            private static func writeViaDevice(avDevice: CFTypeRef, vcp: VCPCode, value: UInt16) -> Bool {
                guard let writeFn = avDeviceWrite else { return false }

                let valueHi = UInt8((value >> 8) & 0xFF)
                let valueLo = UInt8(value & 0xFF)
                let length: UInt8 = 0x84
                let checksum = UInt8(ddcI2CAddress << 1) ^ hostAddress ^ length
                    ^ setVCPOpcode ^ vcp.rawValue ^ valueHi ^ valueLo

                for attempt in 0 ..< maxRetryAttempts {
                    if attempt > 0 { usleep(retryDelayMs * 1000) }

                    var writeData: [UInt8] = [length, setVCPOpcode, vcp.rawValue, valueHi, valueLo, checksum]
                    var writeOK = false
                    for cycle in 0 ..< writeCyclesPerAttempt {
                        if cycle > 0 { usleep(writeCycleDelayMs * 1000) }
                        let r = writeFn(
                            avDevice, ddcI2CAddress, UInt32(hostAddress),
                            &writeData, UInt32(writeData.count)
                        )
                        if r == KERN_SUCCESS { writeOK = true }
                    }
                    if writeOK { return true }
                }
                return false
            }

            // MARK: Direct IOConnect Transport (Last Resort)

            /// Reads a VCP code via direct IOConnectCallMethod (last-resort fallback).
            ///
            /// Opens a user client connection to the raw IOKit service and calls
            /// IOConnectCallMethod with known I2C selectors. This bypasses the
            /// IOAVService/IOAVDevice wrapper functions and may work when the
            /// higher-level paths fail.
            ///
            /// Tries selector pairs: 24/25 (IOAVService I2C) and 6/7 (IOAVDevice I2C).
            private static func readViaDirect(service: io_service_t, vcp: VCPCode) -> DDCReadResult? {
                var connect: io_connect_t = 0
                guard IOServiceOpen(service, mach_task_self_, 0, &connect) == KERN_SUCCESS else {
                    return nil
                }
                defer { IOServiceClose(connect) }

                let length: UInt8 = 0x82
                let checksum = UInt8(ddcI2CAddress << 1) ^ hostAddress ^ length ^ getVCPOpcode ^ vcp.rawValue

                let selectorPairs: [(write: UInt32, read: UInt32)] = [(24, 25), (6, 7)]

                for (writeSel, readSel) in selectorPairs {
                    for attempt in 0 ..< maxRetryAttempts {
                        if attempt > 0 { usleep(retryDelayMs * 1000) }

                        var writeData: [UInt8] = [length, getVCPOpcode, vcp.rawValue, checksum]
                        var scalarIn: [UInt64] = [UInt64(ddcI2CAddress), UInt64(hostAddress)]

                        let wr = writeData.withUnsafeMutableBufferPointer { wBuf in
                            scalarIn.withUnsafeMutableBufferPointer { sBuf in
                                IOConnectCallMethod(
                                    connect, writeSel,
                                    sBuf.baseAddress, UInt32(sBuf.count),
                                    wBuf.baseAddress, wBuf.count,
                                    nil, nil, nil, nil
                                )
                            }
                        }
                        guard wr == KERN_SUCCESS else { continue }

                        usleep(transactionDelayMs * 1000)

                        var readData = [UInt8](repeating: 0, count: 12)
                        var outSize = readData.count

                        let rr = readData.withUnsafeMutableBufferPointer { rBuf in
                            scalarIn.withUnsafeMutableBufferPointer { sBuf in
                                IOConnectCallMethod(
                                    connect, readSel,
                                    sBuf.baseAddress, UInt32(sBuf.count),
                                    nil, 0,
                                    nil, nil,
                                    rBuf.baseAddress, &outSize
                                )
                            }
                        }
                        guard rr == KERN_SUCCESS else { continue }

                        if let result = parseDDCResponse(readData, expectedVCP: vcp) {
                            return result
                        }
                    }
                }
                return nil
            }

            /// Writes a VCP code via direct IOConnectCallMethod (last-resort fallback).
            private static func writeViaDirect(service: io_service_t, vcp: VCPCode, value: UInt16) -> Bool {
                var connect: io_connect_t = 0
                guard IOServiceOpen(service, mach_task_self_, 0, &connect) == KERN_SUCCESS else {
                    return false
                }
                defer { IOServiceClose(connect) }

                let valueHi = UInt8((value >> 8) & 0xFF)
                let valueLo = UInt8(value & 0xFF)
                let length: UInt8 = 0x84
                let checksum = UInt8(ddcI2CAddress << 1) ^ hostAddress ^ length
                    ^ setVCPOpcode ^ vcp.rawValue ^ valueHi ^ valueLo

                let selectorPairs: [(write: UInt32, read: UInt32)] = [(24, 25), (6, 7)]

                for (writeSel, _) in selectorPairs {
                    for attempt in 0 ..< maxRetryAttempts {
                        if attempt > 0 { usleep(retryDelayMs * 1000) }

                        var writeData: [UInt8] = [
                            length, setVCPOpcode, vcp.rawValue, valueHi, valueLo, checksum,
                        ]
                        var scalarIn: [UInt64] = [UInt64(ddcI2CAddress), UInt64(hostAddress)]

                        let r = writeData.withUnsafeMutableBufferPointer { wBuf in
                            scalarIn.withUnsafeMutableBufferPointer { sBuf in
                                IOConnectCallMethod(
                                    connect, writeSel,
                                    sBuf.baseAddress, UInt32(sBuf.count),
                                    wBuf.baseAddress, wBuf.count,
                                    nil, nil, nil, nil
                                )
                            }
                        }
                        if r == KERN_SUCCESS { return true }
                    }
                }
                return false
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

                // Send write request. Use withUnsafeMutableBufferPointer to guarantee pointer
                // lifetime — the buffer must remain valid through the IOI2CSendRequest call.
                let writeSuccess: Bool = writeData.withUnsafeMutableBufferPointer { writeBuffer in
                    var writeRequest = IOI2CRequest()
                    writeRequest.sendAddress = ddcI2CAddress << 1
                    writeRequest.sendTransactionType = IOOptionBits(kIOI2CSimpleTransactionType)
                    writeRequest.sendBuffer = vm_address_t(bitPattern: writeBuffer.baseAddress)
                    writeRequest.sendBytes = UInt32(writeBuffer.count)

                    return IOI2CSendRequest(connect, 0, &writeRequest) == KERN_SUCCESS
                        && writeRequest.result == KERN_SUCCESS
                }
                guard writeSuccess else { return nil }

                // Wait for monitor to prepare response.
                // Blocks the calling thread (~50ms). Acceptable because all DDC I/O is
                // dispatched to a detached task, never on the main thread or cooperative pool.
                usleep(transactionDelayMs * 1000)

                // Read response. Same pointer-lifetime guarantee via withUnsafeMutableBufferPointer.
                var readData = [UInt8](repeating: 0, count: 12)
                let readSuccess: Bool = readData.withUnsafeMutableBufferPointer { readBuffer in
                    var readRequest = IOI2CRequest()
                    readRequest.replyAddress = (ddcI2CAddress << 1) | 0x01
                    readRequest.replyTransactionType = IOOptionBits(kIOI2CSimpleTransactionType)
                    readRequest.replyBuffer = vm_address_t(bitPattern: readBuffer.baseAddress)
                    readRequest.replyBytes = UInt32(readBuffer.count)

                    return IOI2CSendRequest(connect, 0, &readRequest) == KERN_SUCCESS
                        && readRequest.result == KERN_SUCCESS
                }
                guard readSuccess else { return nil }

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

                // Use withUnsafeMutableBufferPointer to guarantee pointer lifetime —
                // the buffer must remain valid through the IOI2CSendRequest call.
                return writeData.withUnsafeMutableBufferPointer { writeBuffer in
                    var request = IOI2CRequest()
                    request.sendAddress = ddcI2CAddress << 1
                    request.sendTransactionType = IOOptionBits(kIOI2CSimpleTransactionType)
                    request.sendBuffer = vm_address_t(bitPattern: writeBuffer.baseAddress)
                    request.sendBytes = UInt32(writeBuffer.count)

                    return IOI2CSendRequest(connect, 0, &request) == KERN_SUCCESS
                        && request.result == KERN_SUCCESS
                }
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

    // These free functions bridge to private IOKit symbols for DDC/CI I2C access on
    // Apple Silicon Macs. They are declared with `@_silgen_name` so the linker resolves
    // them directly from IOKit.framework — no `dlsym` or runtime lookup is needed.
    //
    // The symbols are undocumented but have been stable since macOS 11 (Big Sur) and
    // are used by MonitorControl, m1ddc, and other DDC tools. If Apple ever removes
    // these symbols, the app will fail to **link** (a build-time error), not crash
    // at runtime.
    //
    // On M1–M3, the IOKit registry contains `IOAVService` instances directly.
    // On M4+, the registry contains `DCPAVServiceProxy` instead, which must be
    // converted to an IOAVService via `IOAVServiceCreateWithService` before the
    // I2C functions can be used. The I2C functions accept the resulting CFTypeRef
    // (an IOAVService object), not the raw `io_service_t` registry handle.
    //
    // Because these are free functions (not methods on a type), they cannot be declared
    // inside `DDCController`. Swift's `@_silgen_name` requires a top-level or
    // file-scope function declaration to emit the correct symbol reference.
    //
    // IOAVDevice symbols (IOAVDeviceCreateWithService, IOAVDeviceWriteI2C,
    // IOAVDeviceReadI2C) are loaded dynamically via dlsym in DDCController
    // because they may not exist on all macOS versions.

    #if arch(arm64)

        /// Creates an IOAVService object from an IOKit registry entry.
        ///
        /// On M4+ Macs, the IOKit class is `DCPAVServiceProxy` rather than `IOAVService`.
        /// This function bridges any compatible registry entry into an IOAVService that
        /// the I2C read/write functions accept. On M1–M3, it works with `IOAVService`
        /// entries as well (effectively a no-op wrapper).
        ///
        /// - Parameters:
        ///   - allocator: CF allocator, pass `nil` for the default allocator
        ///   - service: IOKit registry entry (IOAVService or DCPAVServiceProxy)
        /// - Returns: Retained IOAVService reference, or `nil` if creation failed
        @_silgen_name("IOAVServiceCreateWithService")
        private func IOAVServiceCreateWithService(
            _ allocator: CFAllocator?,
            _ service: io_service_t
        ) -> Unmanaged<CFTypeRef>?

        /// Writes data to an I2C device via IOAVService.
        ///
        /// - Parameters:
        ///   - service: IOAVService object from `IOAVServiceCreateWithService`
        ///   - address: I2C slave address (7-bit, not shifted)
        ///   - register: I2C sub-address byte (0x51 for DDC/CI host address)
        ///   - data: Buffer of bytes to write
        ///   - length: Number of bytes to write
        /// - Returns: IOKit result code (KERN_SUCCESS on success)
        @_silgen_name("IOAVServiceWriteI2C")
        private func IOAVServiceWriteI2C(
            _ service: CFTypeRef,
            _ address: UInt32,
            _ register: UInt32,
            _ data: UnsafeMutablePointer<UInt8>,
            _ length: UInt32
        ) -> IOReturn

        /// Reads data from an I2C device via IOAVService.
        ///
        /// - Parameters:
        ///   - service: IOAVService object from `IOAVServiceCreateWithService`
        ///   - address: I2C slave address (7-bit, not shifted)
        ///   - register: I2C sub-address byte (0x51 for DDC/CI host address)
        ///   - data: Buffer to receive read bytes
        ///   - length: Number of bytes to read
        /// - Returns: IOKit result code (KERN_SUCCESS on success)
        @_silgen_name("IOAVServiceReadI2C")
        private func IOAVServiceReadI2C(
            _ service: CFTypeRef,
            _ address: UInt32,
            _ register: UInt32,
            _ data: UnsafeMutablePointer<UInt8>,
            _ length: UInt32
        ) -> IOReturn

    #endif

#endif // !APPSTORE

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
//  - Some built-in HDMI paths require the MCDP29xx bridge address; those are routed
//    to 0xB7 when the DCP provider advertises AppleDCPMCDP29XX
//  - DisplayLink USB adapters are not controlled by this native IOKit transport
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
    import OSLog

    /// Injectable Apple Silicon I2C operations used by each DDC transport wrapper.
    /// Keeping the chip address as an explicit operation argument makes the bridge
    /// routing testable without opening private IOKit services in unit tests.
    struct DDCAppleSiliconI2CTransport {
        typealias WriteOperation = (
            _ chipAddress: UInt32,
            _ register: UInt32,
            _ data: inout [UInt8]
        ) -> IOReturn
        typealias ReadOperation = WriteOperation

        private let writeI2C: WriteOperation
        private let readI2C: ReadOperation?

        init(writeI2C: @escaping WriteOperation, readI2C: ReadOperation? = nil) {
            self.writeI2C = writeI2C
            self.readI2C = readI2C
        }

        @discardableResult
        func write(
            _ data: inout [UInt8],
            chipAddress: UInt32,
            register: UInt32
        ) -> IOReturn {
            writeI2C(chipAddress, register, &data)
        }

        @discardableResult
        func read(
            _ data: inout [UInt8],
            chipAddress: UInt32,
            register: UInt32
        ) -> IOReturn {
            guard let readI2C else { return kIOReturnUnsupported }
            return readI2C(chipAddress, register, &data)
        }
    }

    // MARK: - VCP Code Definitions

    /// MCCS (Monitor Control Command Set) VCP code definitions.
    ///
    /// These are standardized Virtual Control Panel codes defined in the VESA MCCS v2.2a
    /// specification. Each code controls a specific monitor parameter.
    ///
    /// Not all monitors support all codes — use `HardwareDisplayCapability.probe(displayID:)` to probe
    /// which codes a specific display implements.
    enum VCPCode: UInt8, CaseIterable {
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
            case .brightness: String(localized: "Brightness", comment: "DDC VCP code name")
            case .contrast: String(localized: "Contrast", comment: "DDC VCP code name")
            case .redGain: String(localized: "Red Gain", comment: "DDC VCP code name")
            case .greenGain: String(localized: "Green Gain", comment: "DDC VCP code name")
            case .blueGain: String(localized: "Blue Gain", comment: "DDC VCP code name")
            case .volume: String(localized: "Volume", comment: "DDC VCP code name")
            case .audioMute: String(localized: "Audio Mute", comment: "DDC VCP code name")
            case .inputSource: String(localized: "Input Source", comment: "DDC VCP code name")
            case .powerMode: String(localized: "Power Mode", comment: "DDC VCP code name")
            }
        }
    }

    /// Known input source values per MCCS v2.2a Table 8-27.
    ///
    /// Monitor manufacturers may use non-standard values. These cover the most
    /// common sources found in modern monitors.
    enum InputSource: UInt16, CaseIterable {
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
            case .vga1: String(localized: "VGA 1", comment: "Monitor input source name")
            case .vga2: String(localized: "VGA 2", comment: "Monitor input source name")
            case .dvi1: String(localized: "DVI 1", comment: "Monitor input source name")
            case .dvi2: String(localized: "DVI 2", comment: "Monitor input source name")
            case .composite1: String(localized: "Composite 1", comment: "Monitor input source name")
            case .composite2: String(localized: "Composite 2", comment: "Monitor input source name")
            case .sVideo1: String(localized: "S-Video 1", comment: "Monitor input source name")
            case .sVideo2: String(localized: "S-Video 2", comment: "Monitor input source name")
            case .tuner1: String(localized: "Tuner 1", comment: "Monitor input source name")
            case .component1: String(localized: "Component 1", comment: "Monitor input source name")
            case .component2: String(localized: "Component 2", comment: "Monitor input source name")
            case .component3: String(localized: "Component 3", comment: "Monitor input source name")
            case .displayPort1: String(localized: "DisplayPort 1", comment: "Monitor input source name")
            case .displayPort2: String(localized: "DisplayPort 2", comment: "Monitor input source name")
            case .hdmi1: String(localized: "HDMI 1", comment: "Monitor input source name")
            case .hdmi2: String(localized: "HDMI 2", comment: "Monitor input source name")
            case .usbC: String(localized: "USB-C", comment: "Monitor input source name")
            }
        }
    }

    // MARK: - DDC Read Result

    /// Result of a DDC/CI VCP read operation.
    ///
    /// DDC returns both the current value and the maximum supported value,
    /// which is essential for normalizing to a 0.0–1.0 range.
    struct DDCReadResult: Equatable {
        /// Current value reported by the monitor
        let currentValue: UInt16
        /// Maximum supported value for this VCP code
        let maxValue: UInt16
    }

    // MARK: - DDC Controller

    /// Low-level DDC/CI controller for reading and writing monitor VCP codes via IOKit.
    ///
    /// Platform support:
    /// - Apple Silicon: IOAVService → IOAVDevice → IOConnectCallMethod (fallback chain)
    /// - Intel: IOI2CRequest via IOFramebuffer
    ///
    /// All operations are synchronous (~50ms per transaction). Callers should dispatch
    /// off the main thread and rate-limit writes. Thread-safe but serialize per display.
    enum DDCController { // swiftlint:disable:this type_body_length
        private static let logger = Logger(
            subsystem: Bundle.main.bundleIdentifier ?? "rs.in.olujic.dimmerly",
            category: "DDCController"
        )

        // MARK: - DDC I2C Protocol Constants

        /// Default DDC/CI I2C slave address (0x37 << 1 = 0x6E for write,
        /// 0x6F for read). MCDP29xx bridge paths select their alternate address
        /// during Apple Silicon service discovery; Intel uses this default.
        private static let ddcI2CAddress: UInt32 = DDCAppleSiliconTransport.defaultChipAddress

        /// Source address identifying the host (0x51). Used in DDC/CI packet checksums
        /// and as the I2C register/sub-address byte for Apple Silicon DDC transactions.
        private static let hostAddress: UInt8 = 0x51

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

        /// Common controls establish DDC support without requiring brightness readback.
        /// Ordinary silent displays stop after these four codes to limit queue occupancy.
        private static let primaryCapabilityProbeCodes: [VCPCode] = [
            .brightness, .contrast, .volume, .inputSource,
        ]

        private static let optionalCapabilityProbeCodes: [VCPCode] = [
            .audioMute, .powerMode, .redGain, .greenGain, .blueGain,
        ]

        /// Continuous controls need a positive maximum to normalize their current value.
        private static let continuousCapabilityCodes: Set<VCPCode> = [
            .brightness, .contrast, .redGain, .greenGain, .blueGain, .volume,
        ]

        /// Reads known VCP codes, retaining their values for range normalization.
        /// Native-brightness displays probe all other codes because their brightness is
        /// deliberately omitted and they may expose only optional DDC controls.
        /// Injected reader supports deterministic tests without opening IOKit services.
        static func capabilityReadResults(
            for displayID: CGDirectDisplayID,
            skippingBrightness: Bool = false,
            read reader: ((VCPCode, CGDirectDisplayID) -> DDCReadResult?)? = nil
        ) -> [VCPCode: DDCReadResult] {
            let readCode = reader ?? { code, targetDisplayID in
                DDCController.read(vcp: code, for: targetDisplayID)
            }
            var results: [VCPCode: DDCReadResult] = [:]

            for code in primaryCapabilityProbeCodes where !(skippingBrightness && code == .brightness) {
                if let result = validCapabilityRead(readCode, code: code, displayID: displayID) {
                    results[code] = result
                }
            }

            guard skippingBrightness || !results.isEmpty else { return results }
            for code in optionalCapabilityProbeCodes {
                if let result = validCapabilityRead(readCode, code: code, displayID: displayID) {
                    results[code] = result
                }
            }
            return results
        }

        private static func validCapabilityRead(
            _ read: (VCPCode, CGDirectDisplayID) -> DDCReadResult?,
            code: VCPCode,
            displayID: CGDirectDisplayID
        ) -> DDCReadResult? {
            guard let result = read(code, displayID) else { return nil }
            guard !continuousCapabilityCodes.contains(code) || result.maxValue > 0 else { return nil }
            return result
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

            /// An Apple Silicon I2C service together with the chip address used by the
            /// display bridge. Most paths use the standard DDC address; MCDP29xx HDMI
            /// bridges use their alternate address.
            private struct AppleSiliconDDCTransport {
                let service: CFTypeRef
                let chipAddress: UInt32
            }

            /// A raw Apple Silicon IOKit service together with its DDC chip address.
            /// The raw service is borrowed from the iterator and must be released by
            /// the caller after the direct IOConnect operation completes.
            private struct AppleSiliconRawDDCTransport {
                let service: io_service_t
                let chipAddress: UInt32
            }

            /// Returns the DDC chip address for an Apple Silicon display service.
            ///
            /// MCDP29xx bridges advertise their provider class on the parent registry
            /// entry and route DDC/CI through `0xB7`. This mirrors m1ddc's detection,
            /// while keeping the normal `0x37` address as the safe default.
            private static func ddcChipAddress(for service: io_service_t) -> UInt32 {
                var parent: io_registry_entry_t = IO_OBJECT_NULL
                guard IORegistryEntryGetParentEntry(
                    service, kIOServicePlane, &parent
                ) == KERN_SUCCESS else {
                    return DDCAppleSiliconTransport.defaultChipAddress
                }
                defer { IOObjectRelease(parent) }

                let providerClass = IORegistryEntryCreateCFProperty(
                    parent,
                    "EPICProviderClass" as CFString,
                    kCFAllocatorDefault,
                    0
                )?.takeRetainedValue() as? String

                return DDCAppleSiliconTransport.chipAddress(for: providerClass)
            }

            private struct AppleSiliconRegistryCandidate {
                let service: io_service_t
                let identity: DDCDisplayIdentity
                let chipAddress: UInt32
            }

            private struct AppleSiliconDisplaySelectionContext {
                let identities: [DDCDisplayIdentity]
                let expectedIndex: Int
            }

            /// Finds and creates an IOAVService only when registry identity selects one
            /// service for this display without also claiming it for another display.
            private static func findIOAVTransport(for displayID: CGDirectDisplayID) -> AppleSiliconDDCTransport? {
                for className in avServiceClassNames {
                    let candidates = registryCandidates(className: className)
                    defer { release(candidates) }
                    if let candidate = selectedCandidate(for: displayID, in: candidates, identity: \.identity),
                       let avService = IOAVServiceCreateWithService(nil, candidate.service)?.takeRetainedValue()
                    {
                        return AppleSiliconDDCTransport(service: avService, chipAddress: candidate.chipAddress)
                    }
                }

                // Some Apple Silicon registry trees omit display identity properties. In
                // that case, read EDID from each candidate and apply the same ambiguity
                // checks before using any candidate for a VCP transaction.
                for className in avServiceClassNames {
                    let services = matchingServices(className: className)
                    defer { services.forEach { IOObjectRelease($0) } }

                    var candidates: [(identity: DDCDisplayIdentity, transport: AppleSiliconDDCTransport)] = []
                    for service in services {
                        guard let avService = IOAVServiceCreateWithService(nil, service)?.takeRetainedValue(),
                              let identity = displayIdentity(fromEDIDOn: avService)
                        else {
                            continue
                        }
                        candidates.append((
                            identity: identity,
                            transport: AppleSiliconDDCTransport(
                                service: avService,
                                chipAddress: ddcChipAddress(for: service)
                            )
                        ))
                    }

                    if let candidate = selectedCandidate(for: displayID, in: candidates, identity: \.identity) {
                        return candidate.transport
                    }
                }

                return findSoleAVTransport(for: displayID)
            }

            /// Preserves the single-monitor fallback when the active display topology
            /// proves there is exactly one possible service. Any identity field that is
            /// available must agree with the requested display.
            private static func findSoleAVTransport(for displayID: CGDirectDisplayID) -> AppleSiliconDDCTransport? {
                guard let context = displaySelectionContext(for: displayID),
                      context.identities.count == 1,
                      context.expectedIndex == 0
                else {
                    return nil
                }

                var services: [io_service_t] = []
                var seenRegistryIDs = Set<UInt64>()
                for className in avServiceClassNames {
                    for service in matchingServices(className: className) {
                        var registryID: UInt64 = 0
                        if IORegistryEntryGetRegistryEntryID(service, &registryID) == KERN_SUCCESS,
                           !seenRegistryIDs.insert(registryID).inserted
                        {
                            IOObjectRelease(service)
                            continue
                        }
                        services.append(service)
                    }
                }
                defer { services.forEach { IOObjectRelease($0) } }

                guard services.count == 1, let service = services.first else { return nil }
                let expectedIdentity = context.identities[0]
                func conflicts(_ identity: DDCDisplayIdentity?) -> Bool {
                    identity.map {
                        DDCDisplayIdentityMatcher.hasKnownConflict(candidate: $0, expected: expectedIdentity)
                    } ?? false
                }

                guard !conflicts(registryIdentity(for: service)),
                      let avService = IOAVServiceCreateWithService(nil, service)?.takeRetainedValue(),
                      !conflicts(displayIdentity(fromEDIDOn: avService))
                else {
                    return nil
                }
                return AppleSiliconDDCTransport(
                    service: avService,
                    chipAddress: ddcChipAddress(for: service)
                )
            }

            /// Finds and creates an IOAVDevice for a given display (HDMI fallback path).
            ///
            /// DCPAVDeviceProxy is an alternative IOKit class that routes I2C through
            /// a different path in the DCP firmware. This may enable DDC on HDMI ports
            /// where the standard DCPAVServiceProxy path fails.
            ///
            /// - Parameter displayID: CoreGraphics display identifier
            /// - Returns: IOAVDevice object for I2C operations, or `nil` if not available
            private static func findIOAVDevice(for displayID: CGDirectDisplayID) -> AppleSiliconDDCTransport? {
                guard let createFn = avDeviceCreate else { return nil }
                let candidates = registryCandidates(className: "DCPAVDeviceProxy")
                defer { release(candidates) }

                guard let candidate = selectedCandidate(for: displayID, in: candidates, identity: \.identity),
                      let device = createFn(nil, candidate.service)?.takeRetainedValue()
                else {
                    return nil
                }
                return AppleSiliconDDCTransport(service: device, chipAddress: candidate.chipAddress)
            }

            /// Finds the raw IOKit service entry for direct IOConnectCallMethod access.
            ///
            /// Returns an un-wrapped io_service_t (not converted to IOAVService/IOAVDevice)
            /// for use with IOServiceOpen + IOConnectCallMethod. Caller must release via
            /// IOObjectRelease.
            private static func findRawTransport(for displayID: CGDirectDisplayID) -> AppleSiliconRawDDCTransport? {
                let allClassNames = avServiceClassNames + ["DCPAVDeviceProxy"]
                for className in allClassNames {
                    let candidates = registryCandidates(className: className)
                    defer { release(candidates) }
                    if let candidate = selectedCandidate(for: displayID, in: candidates, identity: \.identity) {
                        // Retained for the caller; the deferred release balances the iterator's reference.
                        IOObjectRetain(candidate.service)
                        return AppleSiliconRawDDCTransport(
                            service: candidate.service,
                            chipAddress: candidate.chipAddress
                        )
                    }
                }

                return nil
            }

            private static func matchingServices(className: String) -> [io_service_t] {
                var iterator: io_iterator_t = 0
                guard IOServiceGetMatchingServices(
                    kIOMainPortDefault,
                    IOServiceMatching(className),
                    &iterator
                ) == KERN_SUCCESS else {
                    return []
                }
                defer { IOObjectRelease(iterator) }

                var services: [io_service_t] = []
                var service = IOIteratorNext(iterator)
                while service != IO_OBJECT_NULL {
                    services.append(service)
                    service = IOIteratorNext(iterator)
                }
                return services
            }

            /// Collects every service with registry identity while releasing services that
            /// cannot participate in a safe identity match.
            private static func registryCandidates(className: String) -> [AppleSiliconRegistryCandidate] {
                let services = matchingServices(className: className)
                var candidates: [AppleSiliconRegistryCandidate] = []
                for service in services {
                    guard let identity = registryIdentity(for: service) else {
                        IOObjectRelease(service)
                        continue
                    }
                    candidates.append(AppleSiliconRegistryCandidate(
                        service: service,
                        identity: identity,
                        chipAddress: ddcChipAddress(for: service)
                    ))
                }
                return candidates
            }

            private static func release(_ candidates: [AppleSiliconRegistryCandidate]) {
                candidates.forEach { IOObjectRelease($0.service) }
            }

            private static func registryIdentity(for service: io_service_t) -> DDCDisplayIdentity? {
                var current = service
                defer {
                    if current != service {
                        IOObjectRelease(current)
                    }
                }

                var vendorID: UInt32?
                var modelID: UInt32?
                var serialNumber: UInt32?

                for _ in 0 ..< 5 {
                    var parent: io_registry_entry_t = IO_OBJECT_NULL
                    guard IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent) == KERN_SUCCESS else {
                        break
                    }
                    if current != service {
                        IOObjectRelease(current)
                    }
                    current = parent

                    var properties: Unmanaged<CFMutableDictionary>?
                    guard IORegistryEntryCreateCFProperties(
                        current, &properties, kCFAllocatorDefault, 0
                    ) == KERN_SUCCESS,
                        let dict = properties?.takeRetainedValue() as? [String: Any]
                    else {
                        continue
                    }

                    vendorID = vendorID ?? (dict["VendorID"] as? UInt32) ?? (dict["DisplayVendorID"] as? UInt32)
                    modelID = modelID ?? (dict["ProductID"] as? UInt32) ?? (dict["DisplayProductID"] as? UInt32)
                    serialNumber = serialNumber ?? (dict["DisplaySerialNumber"] as? UInt32)
                }

                guard vendorID != nil || modelID != nil || serialNumber != nil else { return nil }
                return DDCDisplayIdentity(
                    vendorID: vendorID,
                    modelID: modelID,
                    serialNumber: serialNumber
                )
            }

            private static func displaySelectionContext(
                for displayID: CGDirectDisplayID
            ) -> AppleSiliconDisplaySelectionContext? {
                var displayCount: UInt32 = 0
                guard CGGetActiveDisplayList(0, nil, &displayCount) == .success else { return nil }
                var displayIDs = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
                guard CGGetActiveDisplayList(displayCount, &displayIDs, &displayCount) == .success else {
                    return nil
                }

                let externalDisplayIDs = displayIDs.prefix(Int(displayCount)).filter {
                    CGDisplayIsBuiltin($0) == 0
                }

                guard let expectedIndex = externalDisplayIDs.firstIndex(of: displayID) else { return nil }
                let identities = externalDisplayIDs.map { externalDisplayID in
                    let serial = CGDisplaySerialNumber(externalDisplayID)
                    return DDCDisplayIdentity(
                        vendorID: CGDisplayVendorNumber(externalDisplayID),
                        modelID: CGDisplayModelNumber(externalDisplayID),
                        serialNumber: serial
                    )
                }
                return AppleSiliconDisplaySelectionContext(
                    identities: identities,
                    expectedIndex: expectedIndex
                )
            }

            /// Returns the candidate that identity selection assigns to this display, if any.
            private static func selectedCandidate<Candidate>(
                for displayID: CGDirectDisplayID,
                in candidates: [Candidate],
                identity: (Candidate) -> DDCDisplayIdentity
            ) -> Candidate? {
                guard let context = displaySelectionContext(for: displayID),
                      let index = DDCDisplayCandidateSelector.uniqueCandidateIndex(
                          expectedIndex: context.expectedIndex,
                          expectedDisplays: context.identities,
                          candidates: candidates.map(identity)
                      )
                else {
                    return nil
                }
                return candidates[index]
            }

            /// Checks if an IOAVService corresponds to a specific display by reading its
            /// EDID and matching the manufacturer/product/serial fields.
            ///
            /// Tries `IOAVServiceCopyEDID` first (DCP firmware path, more reliable on M4+),
            /// then falls back to raw I2C read at address 0x50.
            ///
            /// EDID bytes 8–9: Manufacturer ID (big-endian PNP compressed ASCII)
            /// EDID bytes 10–11: Product code (little-endian)
            /// EDID bytes 12–15: Serial number (little-endian)
            ///
            /// CoreGraphics reports vendor as the raw 2-byte manufacturer code and model
            /// as the product code, so these can be compared directly.
            private static func displayIdentity(fromEDIDOn avService: CFTypeRef) -> DDCDisplayIdentity? {
                guard let edid = readEDID(from: avService) else { return nil }

                let edidVendor = UInt32(edid[8]) << 8 | UInt32(edid[9])
                let edidProduct = UInt16(edid[10]) | (UInt16(edid[11]) << 8)
                let edidSerial = UInt32(edid[12]) | (UInt32(edid[13]) << 8)
                    | (UInt32(edid[14]) << 16) | (UInt32(edid[15]) << 24)

                return DDCDisplayIdentity(
                    vendorID: edidVendor,
                    modelID: UInt32(edidProduct),
                    serialNumber: edidSerial
                )
            }

            /// Reads the first 128 bytes of EDID from an IOAVService.
            ///
            /// Prefers `IOAVServiceCopyEDID` (DCP firmware path) which is more reliable
            /// on M4+ Macs where raw I2C may be restricted. Falls back to raw I2C read
            /// at address 0x50 for older Apple Silicon.
            private static func readEDID(from avService: CFTypeRef) -> [UInt8]? {
                // Strategy 1: IOAVServiceCopyEDID (DCP firmware path, reliable on M4+)
                var edidData: CFData?
                if IOAVServiceCopyEDID(avService, &edidData) == KERN_SUCCESS,
                   let data = edidData
                {
                    let length = CFDataGetLength(data)
                    guard length >= 128 else { return nil }
                    guard let ptr = CFDataGetBytePtr(data) else { return nil }
                    var edid = [UInt8](repeating: 0, count: 128)
                    for i in 0 ..< 128 {
                        edid[i] = ptr[i]
                    }
                    // Validate EDID header: 00 FF FF FF FF FF FF 00
                    guard edid[0] == 0x00, edid[1] == 0xFF, edid[2] == 0xFF, edid[7] == 0x00 else {
                        return nil
                    }
                    return edid
                }

                // Strategy 2: Raw I2C read at EDID address 0x50
                var edid = [UInt8](repeating: 0, count: 128)
                let result = IOAVServiceReadI2C(avService, 0x50, 0x00, &edid, 128)
                guard result == KERN_SUCCESS else { return nil }
                guard edid[0] == 0x00, edid[1] == 0xFF, edid[2] == 0xFF, edid[7] == 0x00 else {
                    return nil
                }
                return edid
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
                if let avTransport = findIOAVTransport(for: displayID) {
                    if let result = readViaService(
                        avService: avTransport.service,
                        chipAddress: avTransport.chipAddress,
                        vcp: vcp
                    ) {
                        return result
                    }
                }

                if let avDevice = findIOAVDevice(for: displayID) {
                    if let result = readViaDevice(
                        avDevice: avDevice.service,
                        chipAddress: avDevice.chipAddress,
                        vcp: vcp
                    ) {
                        return result
                    }
                }

                if let rawTransport = findRawTransport(for: displayID) {
                    defer { IOObjectRelease(rawTransport.service) }
                    if let result = readViaDirect(
                        service: rawTransport.service,
                        chipAddress: rawTransport.chipAddress,
                        vcp: vcp
                    ) {
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
                if let avTransport = findIOAVTransport(for: displayID) {
                    if writeViaService(
                        avService: avTransport.service,
                        chipAddress: avTransport.chipAddress,
                        vcp: vcp,
                        value: value
                    ) {
                        return true
                    }
                }

                if let avDevice = findIOAVDevice(for: displayID) {
                    if writeViaDevice(
                        avDevice: avDevice.service,
                        chipAddress: avDevice.chipAddress,
                        vcp: vcp,
                        value: value
                    ) {
                        return true
                    }
                }

                if let rawTransport = findRawTransport(for: displayID) {
                    defer { IOObjectRelease(rawTransport.service) }
                    if writeViaDirect(
                        service: rawTransport.service,
                        chipAddress: rawTransport.chipAddress,
                        vcp: vcp,
                        value: value
                    ) {
                        return true
                    }
                }

                return false
            }

            // MARK: IOAVService Transport (Standard Path)

            /// Reads a VCP code via IOAVService with retry logic.
            ///
            /// Writes use `hostAddress` (0x51) as the I2C register/sub-address. Reads use
            /// offset zero, matching MonitorControl's Apple Silicon transport contract.
            /// IOAVServiceWriteI2C transmits 0x51 on the bus as a data byte before the
            /// payload, so it remains included in the checksum per DDC/CI spec.
            private static func readViaService(
                avService: CFTypeRef,
                chipAddress: UInt32,
                vcp: VCPCode
            ) -> DDCReadResult? {
                let vcpHex = String(format: "%02X", vcp.rawValue)
                let transport = DDCAppleSiliconI2CTransport(
                    writeI2C: { address, register, data in
                        IOAVServiceWriteI2C(
                            avService, address, register, &data, UInt32(data.count)
                        )
                    },
                    readI2C: { address, register, data in
                        IOAVServiceReadI2C(
                            avService, address, register, &data, UInt32(data.count)
                        )
                    }
                )
                for attempt in 0 ..< maxRetryAttempts {
                    if attempt > 0 {
                        usleep(retryDelayMs * 1000)
                    }

                    var writeData = DDCPacketCodec.getRequest(for: vcp, includeHostAddress: false)
                    var writeOK = false
                    var lastWriteResult = IOReturn(kIOReturnError)
                    for cycle in 0 ..< writeCyclesPerAttempt {
                        if cycle > 0 {
                            usleep(writeCycleDelayMs * 1000)
                        }
                        lastWriteResult = transport.write(
                            &writeData,
                            chipAddress: chipAddress,
                            register: UInt32(hostAddress)
                        )
                        if lastWriteResult == KERN_SUCCESS {
                            writeOK = true
                        }
                    }
                    guard writeOK else {
                        logger.debug("DDC write 0x\(vcpHex, privacy: .public) failed: \(lastWriteResult)")
                        continue
                    }

                    usleep(transactionDelayMs * 1000)

                    var readData = [UInt8](
                        repeating: 0,
                        count: DDCAppleSiliconReadContract.replyLength
                    )
                    let r = transport.read(
                        &readData,
                        chipAddress: chipAddress,
                        register: DDCAppleSiliconReadContract.dataAddress
                    )
                    guard r == KERN_SUCCESS else {
                        logger.debug("DDC read 0x\(vcpHex, privacy: .public) attempt \(attempt + 1) failed: \(r)")
                        continue
                    }

                    if let result = DDCPacketCodec.parseGetReply(readData, expectedVCP: vcp) {
                        return result
                    }

                    let replyHex = readData.map { String(format: "%02X", $0) }.joined(separator: " ")
                    logger.debug("Invalid DDC reply 0x\(vcpHex, privacy: .public): \(replyHex, privacy: .public)")
                }
                return nil
            }

            /// Writes a VCP code via IOAVService with retry logic.
            private static func writeViaService(
                avService: CFTypeRef,
                chipAddress: UInt32,
                vcp: VCPCode,
                value: UInt16
            ) -> Bool {
                let transport = DDCAppleSiliconI2CTransport(
                    writeI2C: { address, register, data in
                        IOAVServiceWriteI2C(
                            avService, address, register, &data, UInt32(data.count)
                        )
                    }
                )
                for attempt in 0 ..< maxRetryAttempts {
                    if attempt > 0 {
                        usleep(retryDelayMs * 1000)
                    }

                    var writeData = DDCPacketCodec.setRequest(for: vcp, value: value, includeHostAddress: false)
                    var writeOK = false
                    for cycle in 0 ..< writeCyclesPerAttempt {
                        if cycle > 0 {
                            usleep(writeCycleDelayMs * 1000)
                        }
                        let r = transport.write(
                            &writeData,
                            chipAddress: chipAddress,
                            register: UInt32(hostAddress)
                        )
                        if r == KERN_SUCCESS {
                            writeOK = true
                        }
                    }
                    if writeOK {
                        return true
                    }
                }
                return false
            }

            // MARK: IOAVDevice Transport (HDMI Fallback)

            /// Reads a VCP code via IOAVDevice (alternative I2C path for HDMI).
            private static func readViaDevice(
                avDevice: CFTypeRef,
                chipAddress: UInt32,
                vcp: VCPCode
            ) -> DDCReadResult? {
                guard let writeFn = avDeviceWrite, let readFn = avDeviceRead else {
                    return nil
                }
                let transport = DDCAppleSiliconI2CTransport(
                    writeI2C: { address, register, data in
                        writeFn(
                            avDevice, address, register, &data, UInt32(data.count)
                        )
                    },
                    readI2C: { address, register, data in
                        readFn(
                            avDevice, address, register, &data, UInt32(data.count)
                        )
                    }
                )

                for attempt in 0 ..< maxRetryAttempts {
                    if attempt > 0 {
                        usleep(retryDelayMs * 1000)
                    }

                    var writeData = DDCPacketCodec.getRequest(for: vcp, includeHostAddress: false)
                    var writeOK = false
                    for cycle in 0 ..< writeCyclesPerAttempt {
                        if cycle > 0 {
                            usleep(writeCycleDelayMs * 1000)
                        }
                        let r = transport.write(
                            &writeData,
                            chipAddress: chipAddress,
                            register: UInt32(hostAddress)
                        )
                        if r == KERN_SUCCESS {
                            writeOK = true
                        }
                    }
                    guard writeOK else { continue }

                    usleep(transactionDelayMs * 1000)

                    var readData = [UInt8](
                        repeating: 0,
                        count: DDCAppleSiliconReadContract.replyLength
                    )
                    let r = transport.read(
                        &readData,
                        chipAddress: chipAddress,
                        register: DDCAppleSiliconReadContract.dataAddress
                    )
                    guard r == KERN_SUCCESS else { continue }

                    if let result = DDCPacketCodec.parseGetReply(readData, expectedVCP: vcp) {
                        return result
                    }
                }
                return nil
            }

            /// Writes a VCP code via IOAVDevice (alternative I2C path for HDMI).
            private static func writeViaDevice(
                avDevice: CFTypeRef,
                chipAddress: UInt32,
                vcp: VCPCode,
                value: UInt16
            ) -> Bool {
                guard let writeFn = avDeviceWrite else { return false }
                let transport = DDCAppleSiliconI2CTransport(
                    writeI2C: { address, register, data in
                        writeFn(
                            avDevice, address, register, &data, UInt32(data.count)
                        )
                    }
                )

                for attempt in 0 ..< maxRetryAttempts {
                    if attempt > 0 {
                        usleep(retryDelayMs * 1000)
                    }

                    var writeData = DDCPacketCodec.setRequest(for: vcp, value: value, includeHostAddress: false)
                    var writeOK = false
                    for cycle in 0 ..< writeCyclesPerAttempt {
                        if cycle > 0 {
                            usleep(writeCycleDelayMs * 1000)
                        }
                        let r = transport.write(
                            &writeData,
                            chipAddress: chipAddress,
                            register: UInt32(hostAddress)
                        )
                        if r == KERN_SUCCESS {
                            writeOK = true
                        }
                    }
                    if writeOK {
                        return true
                    }
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
            private static func readViaDirect(
                service: io_service_t,
                chipAddress: UInt32,
                vcp: VCPCode
            ) -> DDCReadResult? {
                var connect: io_connect_t = 0
                guard IOServiceOpen(service, mach_task_self_, 0, &connect) == KERN_SUCCESS else {
                    return nil
                }
                defer { IOServiceClose(connect) }

                let selectorPairs: [(write: UInt32, read: UInt32)] = [(24, 25), (6, 7)]

                for (writeSel, readSel) in selectorPairs {
                    let transport = DDCAppleSiliconI2CTransport(
                        writeI2C: { address, register, data in
                            var scalarIn: [UInt64] = [UInt64(address), UInt64(register)]
                            return data.withUnsafeMutableBufferPointer { buffer in
                                scalarIn.withUnsafeMutableBufferPointer { scalars in
                                    IOConnectCallMethod(
                                        connect, writeSel,
                                        scalars.baseAddress, UInt32(scalars.count),
                                        buffer.baseAddress, buffer.count,
                                        nil, nil, nil, nil
                                    )
                                }
                            }
                        },
                        readI2C: { address, register, data in
                            var outSize = data.count
                            var scalarIn: [UInt64] = [UInt64(address), UInt64(register)]
                            return data.withUnsafeMutableBufferPointer { buffer in
                                scalarIn.withUnsafeMutableBufferPointer { scalars in
                                    IOConnectCallMethod(
                                        connect, readSel,
                                        scalars.baseAddress, UInt32(scalars.count),
                                        nil, 0,
                                        nil, nil,
                                        buffer.baseAddress, &outSize
                                    )
                                }
                            }
                        }
                    )

                    for attempt in 0 ..< maxRetryAttempts {
                        if attempt > 0 {
                            usleep(retryDelayMs * 1000)
                        }

                        var writeData = DDCPacketCodec.getRequest(for: vcp, includeHostAddress: false)
                        let wr = transport.write(
                            &writeData,
                            chipAddress: chipAddress,
                            register: UInt32(hostAddress)
                        )
                        guard wr == KERN_SUCCESS else { continue }

                        usleep(transactionDelayMs * 1000)

                        var readData = [UInt8](
                            repeating: 0,
                            count: DDCAppleSiliconReadContract.replyLength
                        )
                        let rr = transport.read(
                            &readData,
                            chipAddress: chipAddress,
                            register: DDCAppleSiliconReadContract.dataAddress
                        )
                        guard rr == KERN_SUCCESS else { continue }

                        if let result = DDCPacketCodec.parseGetReply(readData, expectedVCP: vcp) {
                            return result
                        }
                    }
                }
                return nil
            }

            /// Writes a VCP code via direct IOConnectCallMethod (last-resort fallback).
            private static func writeViaDirect(
                service: io_service_t,
                chipAddress: UInt32,
                vcp: VCPCode,
                value: UInt16
            ) -> Bool {
                var connect: io_connect_t = 0
                guard IOServiceOpen(service, mach_task_self_, 0, &connect) == KERN_SUCCESS else {
                    return false
                }
                defer { IOServiceClose(connect) }

                let selectorPairs: [(write: UInt32, read: UInt32)] = [(24, 25), (6, 7)]

                for (writeSel, _) in selectorPairs {
                    let transport = DDCAppleSiliconI2CTransport(
                        writeI2C: { address, register, data in
                            var scalarIn: [UInt64] = [UInt64(address), UInt64(register)]
                            return data.withUnsafeMutableBufferPointer { buffer in
                                scalarIn.withUnsafeMutableBufferPointer { scalars in
                                    IOConnectCallMethod(
                                        connect, writeSel,
                                        scalars.baseAddress, UInt32(scalars.count),
                                        buffer.baseAddress, buffer.count,
                                        nil, nil, nil, nil
                                    )
                                }
                            }
                        }
                    )

                    for attempt in 0 ..< maxRetryAttempts {
                        if attempt > 0 {
                            usleep(retryDelayMs * 1000)
                        }

                        var writeData = DDCPacketCodec.setRequest(
                            for: vcp,
                            value: value,
                            includeHostAddress: false
                        )
                        let r = transport.write(
                            &writeData,
                            chipAddress: chipAddress,
                            register: UInt32(hostAddress)
                        )
                        if r == KERN_SUCCESS {
                            return true
                        }
                    }
                }
                return false
            }

        #endif
    }

    #if arch(x86_64)

        // MARK: - Intel Implementation

        extension DDCController {
            /// Finds the IOFramebuffer service for a given display on Intel Macs.
            ///
            /// On Intel Macs, each display is connected via an IOFramebuffer which exposes
            /// I2C interfaces for DDC communication. This method maps a `CGDirectDisplayID`
            /// to the correct IOFramebuffer by matching vendor/product/serial identity via
            /// IODisplayConnect. Identical model matches remain ambiguous without a serial.
            private static func findFramebufferService(for displayID: CGDirectDisplayID) -> io_service_t {
                let vendorID = CGDisplayVendorNumber(displayID)
                let modelID = CGDisplayModelNumber(displayID)
                let expectedIdentity = DDCDisplayIdentity(
                    vendorID: vendorID,
                    modelID: modelID,
                    serialNumber: CGDisplaySerialNumber(displayID)
                )

                var iterator: io_iterator_t = 0
                guard IOServiceGetMatchingServices(
                    kIOMainPortDefault,
                    IOServiceMatching("IODisplayConnect"),
                    &iterator
                ) == KERN_SUCCESS else {
                    return IO_OBJECT_NULL
                }
                defer { IOObjectRelease(iterator) }

                var candidates: [(service: io_service_t, identity: DDCDisplayIdentity)] = []
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

                    let candidateIdentity = DDCDisplayIdentity(
                        vendorID: dict["DisplayVendorID"] as? UInt32,
                        modelID: dict["DisplayProductID"] as? UInt32,
                        serialNumber: (dict["DisplaySerialNumber"] as? UInt32)
                            ?? (dict["SerialNumber"] as? UInt32)
                    )
                    if DDCDisplayIdentityMatcher.matches(
                        candidate: candidateIdentity,
                        expected: expectedIdentity
                    ) {
                        // Retain the framebuffer parent until the selector has established a
                        // unique candidate. The display service itself is released immediately.
                        var framebuffer: io_service_t = 0
                        if IORegistryEntryGetParentEntry(service, kIOServicePlane, &framebuffer) == KERN_SUCCESS {
                            candidates.append((service: framebuffer, identity: candidateIdentity))
                        }
                    }

                    IOObjectRelease(service)
                    service = IOIteratorNext(iterator)
                }

                guard let selectedIndex = DDCDisplayCandidateSelector.uniqueCandidateIndex(
                    expected: expectedIdentity,
                    candidates: candidates.map(\.identity)
                ) else {
                    for candidate in candidates {
                        IOObjectRelease(candidate.service)
                    }
                    return IO_OBJECT_NULL
                }

                for (index, candidate) in candidates.enumerated() where index != selectedIndex {
                    IOObjectRelease(candidate.service)
                }
                return candidates[selectedIndex].service
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
                var writeData = DDCPacketCodec.getRequest(for: vcp, includeHostAddress: true)

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

                return DDCPacketCodec.parseGetReply(readData, expectedVCP: vcp)
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

                var writeData = DDCPacketCodec.setRequest(for: vcp, value: value, includeHostAddress: true)

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
        }

    #endif

    // MARK: - IOAVService Bridging (Apple Silicon)

    // Private IOKit symbols for DDC/CI I2C access, linked via @_silgen_name.
    // Stable since macOS 11; used by MonitorControl, m1ddc, AppleSiliconDDC.
    // Must be file-scope (Swift @_silgen_name requires top-level declarations).
    // IOAVDevice symbols are loaded via dlsym instead (may not exist on all versions).

    #if arch(arm64)

        @_silgen_name("IOAVServiceCreateWithService")
        private func IOAVServiceCreateWithService(
            _ allocator: CFAllocator?,
            _ service: io_service_t
        ) -> Unmanaged<CFTypeRef>?

        @_silgen_name("IOAVServiceWriteI2C")
        private func IOAVServiceWriteI2C(
            _ service: CFTypeRef,
            _ address: UInt32,
            _ register: UInt32,
            _ data: UnsafeMutablePointer<UInt8>,
            _ length: UInt32
        ) -> IOReturn

        @_silgen_name("IOAVServiceReadI2C")
        private func IOAVServiceReadI2C(
            _ service: CFTypeRef,
            _ address: UInt32,
            _ register: UInt32,
            _ data: UnsafeMutablePointer<UInt8>,
            _ length: UInt32
        ) -> IOReturn

        /// Copies EDID via DCP firmware path — more reliable than raw I2C on M4+.
        @_silgen_name("IOAVServiceCopyEDID")
        private func IOAVServiceCopyEDID(
            _ service: CFTypeRef,
            _ edid: UnsafeMutablePointer<CFData?>
        ) -> IOReturn

    #endif

    // Keep the platform-specific DDC fallbacks together so their protocol behavior stays aligned.
    // swiftlint:disable:next file_length
#endif // !APPSTORE

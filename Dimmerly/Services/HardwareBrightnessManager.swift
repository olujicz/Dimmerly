//
//  HardwareBrightnessManager.swift
//  Dimmerly
//
//  Manages DDC/CI hardware display control for external monitors.
//  Provides brightness, volume, input source, and power mode control
//  via the DDC/CI protocol, integrating with BrightnessManager for
//  hybrid software+hardware control.
//
//  This manager is only available in direct distribution builds (#if !APPSTORE)
//  because DDC requires IOKit access incompatible with the App Sandbox.
//
//  Known limitations:
//  - DDC transactions are slow (~40ms each). All DDC I/O is dispatched to
//    a serial background queue to avoid blocking the main thread.
//  - Writes are rate-limited (minimum 50ms between writes to the same display)
//    to prevent overwhelming the monitor's embedded MCU.
//  - VCP reads are cached with a configurable polling interval (default 5s)
//    to avoid excessive I2C traffic.
//  - Display capability probing happens once per connection (~360ms).
//  - Some monitors take 100–200ms to apply DDC changes — UI feedback may lag.
//  - Monitors may silently clamp or ignore out-of-range values.
//

#if !APPSTORE

    import Combine
    import CoreGraphics
    import Foundation

    /// Manages hardware (DDC/CI) display control for external monitors.
    ///
    /// Responsibilities:
    /// - Probes displays for DDC capability on connection
    /// - Reads/writes hardware brightness, contrast, volume, input source
    /// - Caches VCP reads to minimize I2C traffic
    /// - Rate-limits writes to prevent MCU overload
    /// - Integrates with BrightnessManager for hybrid control
    ///
    /// Thread safety: Published properties are updated on @MainActor.
    /// DDC I/O is dispatched to a serial background queue.
    @MainActor
    class HardwareBrightnessManager: ObservableObject {
        static let shared = HardwareBrightnessManager()

        // MARK: - Published State

        /// Cached DDC capabilities per display (keyed by CGDirectDisplayID).
        /// Updated when displays connect/disconnect.
        /// Cached DDC capabilities per display (keyed by CGDirectDisplayID).
        /// Internal setter for @testable test access; set via probeAllDisplays() at runtime.
        @Published var capabilities: [CGDirectDisplayID: HardwareDisplayCapability] = [:]

        /// Current hardware brightness values (0.0–1.0) per display.
        /// Updated from DDC reads and user writes.
        @Published var hardwareBrightness: [CGDirectDisplayID: Double] = [:]

        /// Current hardware contrast values (0.0–1.0) per display.
        @Published var hardwareContrast: [CGDirectDisplayID: Double] = [:]

        /// Current hardware volume values (0.0–1.0) per display.
        @Published var hardwareVolume: [CGDirectDisplayID: Double] = [:]

        /// Current audio mute state per display (true = muted).
        @Published var hardwareMute: [CGDirectDisplayID: Bool] = [:]

        /// Current input source per display.
        @Published var activeInputSource: [CGDirectDisplayID: InputSource] = [:]

        /// Whether DDC hardware control is globally enabled.
        /// Controlled by AppSettings.ddcEnabled.
        @Published var isEnabled: Bool = false

        /// The active control mode (software, hardware, or combined).
        @Published var controlMode: DDCControlMode = .combined

        // MARK: - Private State

        /// Serial queue for DDC I/O operations (prevents interleaved transactions).
        private let ddcQueue = DispatchQueue(label: "com.dimmerly.ddc", qos: .userInitiated)

        /// Timestamps of the last write per display (for rate limiting).
        private var lastWriteTime: [CGDirectDisplayID: Date] = [:]

        /// Minimum interval between DDC writes to the same display.
        private let minimumWriteInterval: TimeInterval = 0.05 // 50ms

        /// Pending write tasks per display (for debouncing rapid slider changes).
        private var pendingWrites: [CGDirectDisplayID: Task<Void, Never>] = [:]

        /// Background polling task for reading hardware values.
        private var pollingTask: Task<Void, Never>?

        /// Polling interval for DDC reads (seconds).
        var pollingInterval: TimeInterval = 5.0

        /// Write debounce delay (seconds).
        private let writeDebounceDelay: TimeInterval = 0.1

        // MARK: - Test Support

        /// Injectable DDC read function for testing.
        /// When non-nil, called instead of DDCController.read.
        nonisolated(unsafe) static var ddcReader: ((VCPCode, CGDirectDisplayID) -> DDCReadResult?)?

        /// Injectable DDC write function for testing.
        /// When non-nil, called instead of DDCController.write.
        nonisolated(unsafe) static var ddcWriter: ((VCPCode, UInt16, CGDirectDisplayID) -> Bool)?

        /// Injectable capability prober for testing.
        /// When non-nil, called instead of HardwareDisplayCapability.probe.
        nonisolated(unsafe) static var capabilityProber: ((CGDirectDisplayID) -> HardwareDisplayCapability)?

        // MARK: - Initialization

        init() {}

        /// Test-only initializer that skips hardware interaction.
        init(forTesting _: Bool) {}

        // MARK: - Public API

        /// Returns the DDC capability record for a display, if available.
        func capability(for displayID: CGDirectDisplayID) -> HardwareDisplayCapability? {
            capabilities[displayID]
        }

        /// Returns whether a display supports DDC hardware control.
        func supportsDDC(for displayID: CGDirectDisplayID) -> Bool {
            capabilities[displayID]?.supportsDDC ?? false
        }

        /// Probes all currently connected external displays for DDC capabilities.
        ///
        /// Called when:
        /// - DDC is enabled for the first time
        /// - Displays are connected/disconnected
        /// - The app launches with DDC enabled
        ///
        /// Probing is done on a background queue to avoid blocking the UI (~360ms per display).
        func probeAllDisplays() {
            let displayIDs = BrightnessManager.activeDisplayIDs().filter { CGDisplayIsBuiltin($0) == 0 }

            Task.detached { [weak self] in
                var results: [CGDirectDisplayID: HardwareDisplayCapability] = [:]

                for displayID in displayIDs {
                    let capability: HardwareDisplayCapability
                    if let prober = HardwareBrightnessManager.capabilityProber {
                        capability = prober(displayID)
                    } else {
                        capability = HardwareDisplayCapability.probe(displayID: displayID)
                    }
                    results[displayID] = capability
                }

                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.capabilities = results
                    // Read initial values for DDC-capable displays
                    for (displayID, cap) in results where cap.supportsDDC {
                        self.readAllValues(for: displayID)
                    }
                }
            }
        }

        /// Sets the hardware brightness for a display via DDC/CI.
        ///
        /// The value is normalized from 0.0–1.0 to the display's VCP max value.
        /// Writes are debounced to prevent overwhelming the monitor during slider drags.
        ///
        /// - Parameters:
        ///   - displayID: CoreGraphics display identifier
        ///   - value: Brightness value (0.0–1.0)
        func setHardwareBrightness(for displayID: CGDirectDisplayID, to value: Double) {
            guard let cap = capabilities[displayID], cap.supportsBrightness else { return }

            let clamped = min(max(value, 0.0), 1.0)
            hardwareBrightness[displayID] = clamped

            let rawValue = UInt16(clamped * Double(cap.maxBrightness))
            debouncedWrite(vcp: .brightness, value: rawValue, for: displayID)
        }

        /// Sets the hardware contrast for a display via DDC/CI.
        ///
        /// - Parameters:
        ///   - displayID: CoreGraphics display identifier
        ///   - value: Contrast value (0.0–1.0)
        func setHardwareContrast(for displayID: CGDirectDisplayID, to value: Double) {
            guard let cap = capabilities[displayID], cap.supportsContrast else { return }

            let clamped = min(max(value, 0.0), 1.0)
            hardwareContrast[displayID] = clamped

            let rawValue = UInt16(clamped * Double(cap.maxContrast))
            debouncedWrite(vcp: .contrast, value: rawValue, for: displayID)
        }

        /// Sets the hardware volume for a display via DDC/CI.
        ///
        /// - Parameters:
        ///   - displayID: CoreGraphics display identifier
        ///   - value: Volume value (0.0–1.0)
        func setHardwareVolume(for displayID: CGDirectDisplayID, to value: Double) {
            guard let cap = capabilities[displayID], cap.supportsVolume else { return }

            let clamped = min(max(value, 0.0), 1.0)
            hardwareVolume[displayID] = clamped

            let rawValue = UInt16(clamped * Double(cap.maxVolume))
            debouncedWrite(vcp: .volume, value: rawValue, for: displayID)
        }

        /// Toggles audio mute for a display via DDC/CI.
        ///
        /// DDC mute values: 1 = muted, 2 = unmuted (per MCCS v2.2a).
        ///
        /// - Parameter displayID: CoreGraphics display identifier
        func toggleMute(for displayID: CGDirectDisplayID) {
            guard let cap = capabilities[displayID], cap.supportsAudioMute else { return }

            let currentlyMuted = hardwareMute[displayID] ?? false
            let newMuted = !currentlyMuted
            hardwareMute[displayID] = newMuted

            let rawValue: UInt16 = newMuted ? 1 : 2
            debouncedWrite(vcp: .audioMute, value: rawValue, for: displayID)
        }

        /// Sets the input source for a display via DDC/CI.
        ///
        /// - Parameters:
        ///   - displayID: CoreGraphics display identifier
        ///   - source: The input source to switch to
        func setInputSource(for displayID: CGDirectDisplayID, to source: InputSource) {
            guard let cap = capabilities[displayID], cap.supportsInputSource else { return }

            activeInputSource[displayID] = source
            debouncedWrite(vcp: .inputSource, value: source.rawValue, for: displayID)
        }

        /// Returns the available input sources for a display.
        ///
        /// If the display supports input source switching, returns all standard sources.
        /// In practice, monitors only respond to sources they physically have, silently
        /// ignoring invalid ones.
        func availableInputSources(for displayID: CGDirectDisplayID) -> [InputSource] {
            guard supportsDDC(for: displayID),
                  capabilities[displayID]?.supportsInputSource == true
            else {
                return []
            }
            return InputSource.allCases
        }

        /// Starts background polling for hardware values.
        ///
        /// Periodically reads brightness, contrast, and volume from DDC-capable displays
        /// to detect changes made via the monitor's OSD or remote control.
        func startPolling() {
            stopPolling()
            pollingTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(self?.pollingInterval ?? 5.0))
                    guard !Task.isCancelled else { return }
                    await self?.pollAllDisplays()
                }
            }
        }

        /// Stops the background polling task.
        func stopPolling() {
            pollingTask?.cancel()
            pollingTask = nil
        }

        /// Cleans up state for disconnected displays.
        func removeDisplay(_ displayID: CGDirectDisplayID) {
            capabilities.removeValue(forKey: displayID)
            hardwareBrightness.removeValue(forKey: displayID)
            hardwareContrast.removeValue(forKey: displayID)
            hardwareVolume.removeValue(forKey: displayID)
            hardwareMute.removeValue(forKey: displayID)
            activeInputSource.removeValue(forKey: displayID)
            pendingWrites[displayID]?.cancel()
            pendingWrites.removeValue(forKey: displayID)
            lastWriteTime.removeValue(forKey: displayID)
        }

        // MARK: - Private: DDC Read

        // swiftlint:disable cyclomatic_complexity

        /// Reads all supported VCP values for a display.
        private func readAllValues(for displayID: CGDirectDisplayID) {
            guard let cap = capabilities[displayID], cap.supportsDDC else { return }

            Task.detached { [weak self] in
                var brightness: Double?
                var contrast: Double?
                var volume: Double?
                var muted: Bool?
                var inputSource: InputSource?

                if cap.supportsBrightness {
                    if let result = self?.performRead(vcp: .brightness, for: displayID) {
                        brightness = Double(result.currentValue) / Double(result.maxValue)
                    }
                }

                if cap.supportsContrast {
                    if let result = self?.performRead(vcp: .contrast, for: displayID) {
                        contrast = Double(result.currentValue) / Double(result.maxValue)
                    }
                }

                if cap.supportsVolume {
                    if let result = self?.performRead(vcp: .volume, for: displayID) {
                        volume = Double(result.currentValue) / Double(result.maxValue)
                    }
                }

                if cap.supportsAudioMute {
                    if let result = self?.performRead(vcp: .audioMute, for: displayID) {
                        muted = result.currentValue == 1
                    }
                }

                if cap.supportsInputSource {
                    if let result = self?.performRead(vcp: .inputSource, for: displayID) {
                        inputSource = InputSource(rawValue: result.currentValue)
                    }
                }

                // Apply all read values on the main actor in a single hop
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    if let brightness { self.hardwareBrightness[displayID] = brightness }
                    if let contrast { self.hardwareContrast[displayID] = contrast }
                    if let volume { self.hardwareVolume[displayID] = volume }
                    if let muted { self.hardwareMute[displayID] = muted }
                    if let inputSource { self.activeInputSource[displayID] = inputSource }
                }
            }
        }

        // swiftlint:enable cyclomatic_complexity

        /// Performs a single DDC read, using the test mock if available.
        private nonisolated func performRead(vcp: VCPCode, for displayID: CGDirectDisplayID) -> DDCReadResult? {
            if let reader = HardwareBrightnessManager.ddcReader {
                return reader(vcp, displayID)
            }
            return DDCController.read(vcp: vcp, for: displayID)
        }

        /// Polls all DDC-capable displays for updated values.
        private func pollAllDisplays() {
            for (displayID, cap) in capabilities where cap.supportsDDC {
                readAllValues(for: displayID)
            }
        }

        // MARK: - Private: DDC Write

        /// Debounces DDC writes to prevent overwhelming the monitor.
        ///
        /// When the user drags a slider, this coalesces rapid changes into a single
        /// DDC write after the debounce delay. A per-display pending task ensures
        /// the last value wins.
        private func debouncedWrite(vcp: VCPCode, value: UInt16, for displayID: CGDirectDisplayID) {
            // Cancel any pending write for this display
            let writeKey = displayID
            pendingWrites[writeKey]?.cancel()

            pendingWrites[writeKey] = Task { [weak self] in
                // Wait for debounce period
                try? await Task.sleep(for: .seconds(self?.writeDebounceDelay ?? 0.1))
                guard !Task.isCancelled else { return }

                // Rate limit: ensure minimum interval since last write
                if let lastWrite = await self?.lastWriteTime[displayID] {
                    let elapsed = Date().timeIntervalSince(lastWrite)
                    let minInterval = self?.minimumWriteInterval ?? 0.05
                    if elapsed < minInterval {
                        let remaining = minInterval - elapsed
                        try? await Task.sleep(for: .seconds(remaining))
                        guard !Task.isCancelled else { return }
                    }
                }

                // Perform the write
                await self?.performWrite(vcp: vcp, value: value, for: displayID)
            }
        }

        /// Performs a single DDC write on the background queue.
        private func performWrite(vcp: VCPCode, value: UInt16, for displayID: CGDirectDisplayID) {
            lastWriteTime[displayID] = Date()

            Task.detached {
                if let writer = HardwareBrightnessManager.ddcWriter {
                    _ = writer(vcp, value, displayID)
                } else {
                    DDCController.write(vcp: vcp, value: value, for: displayID)
                }
            }
        }
    }

#endif // !APPSTORE

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

    // MARK: - DDC Interface Protocol

    /// Abstraction over DDC I/O for testability.
    ///
    /// Production code uses `DefaultDDCInterface` which delegates to `DDCController`.
    /// Tests inject a mock conformance to avoid real hardware interaction.
    ///
    /// All methods are `nonisolated` and synchronous — callers must dispatch to a
    /// background queue to avoid blocking the main thread.
    protocol DDCInterface: Sendable {
        /// Reads a VCP code from a display.
        func read(vcp: VCPCode, for displayID: CGDirectDisplayID) -> DDCReadResult?
        /// Writes a VCP code value to a display.
        func write(vcp: VCPCode, value: UInt16, for displayID: CGDirectDisplayID) -> Bool
        /// Probes a display for DDC capabilities.
        func probeCapabilities(for displayID: CGDirectDisplayID) -> HardwareDisplayCapability
    }

    /// Default DDC interface that delegates to the real DDCController.
    struct DefaultDDCInterface: DDCInterface {
        func read(vcp: VCPCode, for displayID: CGDirectDisplayID) -> DDCReadResult? {
            DDCController.read(vcp: vcp, for: displayID)
        }

        func write(vcp: VCPCode, value: UInt16, for displayID: CGDirectDisplayID) -> Bool {
            DDCController.write(vcp: vcp, value: value, for: displayID)
        }

        func probeCapabilities(for displayID: CGDirectDisplayID) -> HardwareDisplayCapability {
            HardwareDisplayCapability.probe(displayID: displayID)
        }
    }

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
    @Observable
    class HardwareBrightnessManager {
        static let shared = HardwareBrightnessManager()

        // MARK: - Published State

        /// Cached DDC capabilities per display (keyed by CGDirectDisplayID).
        /// Internal setter for @testable test access; set via probeAllDisplays() at runtime.
        var capabilities: [CGDirectDisplayID: HardwareDisplayCapability] = [:]

        /// Current hardware brightness values (0.0–1.0) per display.
        /// Updated from DDC reads and user writes.
        var hardwareBrightness: [CGDirectDisplayID: Double] = [:]

        /// Current hardware contrast values (0.0–1.0) per display.
        var hardwareContrast: [CGDirectDisplayID: Double] = [:]

        /// Current hardware volume values (0.0–1.0) per display.
        var hardwareVolume: [CGDirectDisplayID: Double] = [:]

        /// Current audio mute state per display (true = muted).
        var hardwareMute: [CGDirectDisplayID: Bool] = [:]

        /// Current input source per display.
        var activeInputSource: [CGDirectDisplayID: InputSource] = [:]

        /// Whether DDC hardware control is globally enabled.
        /// Controlled by AppSettings.ddcEnabled.
        var isEnabled: Bool = false

        /// The active control mode.
        var controlMode: DDCControlMode = .hardware

        // MARK: - Private State

        /// Serial queue for DDC I/O operations (prevents interleaved transactions).
        private let ddcQueue = DispatchQueue(label: "com.dimmerly.ddc", qos: .userInitiated)

        /// Queue-owned write timing state. Used from `ddcQueue` so the minimum interval
        /// is measured between actual hardware writes, not between enqueue times.
        private let writeTiming = DDCWriteTiming()

        /// Count of local user/app writes that have not yet completed on the hardware bus,
        /// per display+VCP code. A counter rather than a `Set` membership flag: if two writes
        /// to the same key overlap (e.g. two slider nudges close enough together that both
        /// escape debounce cancellation), the first write's completion must not clear the
        /// "pending" state while the second write is still in flight — that gap previously let
        /// a concurrent poll apply a stale hardware read and snap the UI back to the old value.
        private var pendingHardwareWrites: [WriteKey: Int] = [:]

        /// Timestamps of local user/app writes, used to ignore stale DDC poll results.
        private var lastLocalWriteTime: [WriteKey: Date] = [:]

        /// Consecutive DDC write failure count per display+VCP code.
        /// When a single code's count exceeds `maxWriteFailuresBeforeFallback`, only that
        /// code is dropped from the display's supported set — a flaky volume or input-source
        /// control no longer takes hardware brightness down with it.
        private var consecutiveWriteFailures: [WriteKey: Int] = [:]

        /// Number of consecutive DDC write failures (for a single VCP code) before
        /// auto-downgrading that code to software/no control.
        private let maxWriteFailuresBeforeFallback = 3

        /// Minimum interval between DDC writes to the same display.
        /// Updated from AppSettings.ddcWriteDelay via SettingsView's `.onChange`.
        var minimumWriteInterval: TimeInterval = 0.05 // 50ms

        /// Composite key for debouncing DDC writes per display+VCP code pair.
        /// Without the VCP code in the key, rapid changes to different controls
        /// (e.g., brightness then volume) on the same display would cancel each other.
        private struct WriteKey: Hashable {
            let displayID: CGDirectDisplayID
            let vcp: VCPCode
        }

        private final class DDCWriteTiming: @unchecked Sendable {
            private let lock = NSLock()
            private var lastWriteTime: [CGDirectDisplayID: Date] = [:]

            func waitUntilReady(for displayID: CGDirectDisplayID, minimumInterval: TimeInterval) {
                while true {
                    lock.lock()
                    let now = Date()
                    let remaining = lastWriteTime[displayID]
                        .map { minimumInterval - now.timeIntervalSince($0) } ?? 0

                    if remaining <= 0 {
                        lastWriteTime[displayID] = now
                        lock.unlock()
                        return
                    }

                    lock.unlock()
                    Thread.sleep(forTimeInterval: remaining)
                }
            }

            func removeDisplay(_ displayID: CGDirectDisplayID) {
                lock.lock()
                lastWriteTime.removeValue(forKey: displayID)
                lock.unlock()
            }
        }

        /// Pending write tasks per display+VCP code (for debouncing rapid slider changes).
        /// Entries are removed once their scheduled task's body finishes (see
        /// `clearPendingWriteSlotIfCurrent`) rather than left to sit as completed/cancelled
        /// `Task` objects until the next write to the same key happens to replace them.
        private var pendingWrites: [WriteKey: Task<Void, Never>] = [:]

        /// Monotonic per-key counter so a debounced write's own completion can tell whether
        /// it's still the current pending attempt for its key before clearing `pendingWrites`
        /// — a newer `debouncedWrite` call for the same key may have already taken the slot.
        private var pendingWriteGeneration: [WriteKey: Int] = [:]

        /// Background polling task for reading hardware values.
        private var pollingTask: Task<Void, Never>?

        /// Polling interval for DDC reads (seconds).
        var pollingInterval: TimeInterval = 5.0

        /// Write debounce delay (seconds).
        private let writeDebounceDelay: TimeInterval = 0.1

        // MARK: - DDC Interface

        /// The DDC I/O interface used for all hardware communication.
        /// Injected at init for testability; defaults to `DefaultDDCInterface`.
        let ddcInterface: DDCInterface

        // MARK: - Initialization

        init(ddcInterface: DDCInterface = DefaultDDCInterface()) {
            self.ddcInterface = ddcInterface
        }

        /// Test-only initializer that accepts a mock DDC interface.
        init(forTesting _: Bool, ddcInterface: DDCInterface = DefaultDDCInterface()) {
            self.ddcInterface = ddcInterface
        }

        // MARK: - Public API

        /// Returns the DDC capability record for a display, if available.
        func capability(for displayID: CGDirectDisplayID) -> HardwareDisplayCapability? {
            capabilities[displayID]
        }

        /// Returns whether a display supports DDC hardware control.
        func supportsDDC(for displayID: CGDirectDisplayID) -> Bool {
            capabilities[displayID]?.supportsDDC ?? false
        }

        /// Probes external displays for DDC capabilities.
        ///
        /// Called when:
        /// - DDC is enabled for the first time or toggled back on (`force: true`, the
        ///   default) — re-probes every connected external display, since capabilities
        ///   may have changed (e.g. DDC/CI toggled in the monitor's OSD).
        /// - A display-reconfiguration event reports displays that have never been
        ///   probed (`force: false`) — probes only the unprobed ones, so hot-plugged
        ///   monitors gain DDC support without waiting for a relaunch or Settings toggle.
        ///
        /// Probing is done on a background queue to avoid blocking the UI (~360ms per display).
        /// Results are merged into `capabilities` rather than replacing it wholesale, and
        /// any display that disconnected while the (multi-display) probe was in flight is
        /// dropped instead of being resurrected.
        func probeAllDisplays(force: Bool = true) {
            let connectedDisplayIDs = BrightnessManager.activeDisplayIDs().filter { CGDisplayIsBuiltin($0) == 0 }
            let idsToProbe = force ? connectedDisplayIDs : connectedDisplayIDs.filter { capabilities[$0] == nil }
            guard !idsToProbe.isEmpty else { return }

            let ddcIO = ddcInterface
            let ddcQueue = ddcQueue

            ddcQueue.async {
                var results: [CGDirectDisplayID: HardwareDisplayCapability] = [:]

                for displayID in idsToProbe {
                    let capability = ddcIO.probeCapabilities(for: displayID)
                    results[displayID] = capability
                }

                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let stillConnected = Set(BrightnessManager.activeDisplayIDs())
                    for (displayID, cap) in results where stillConnected.contains(displayID) {
                        capabilities[displayID] = cap
                        // A fresh probe gets a fresh failure budget — otherwise a display that
                        // previously hit the fallback threshold on some VCP code stays primed
                        // to re-downgrade after a single transient failure post-reprobe,
                        // instead of the full `maxWriteFailuresBeforeFallback` count.
                        consecutiveWriteFailures = consecutiveWriteFailures.filter { $0.key.displayID != displayID }
                    }
                    // Read initial values for DDC-capable displays
                    for (displayID, cap) in results where cap.supportsDDC && stillConnected.contains(displayID) {
                        self.readAllValues(for: displayID)
                    }
                    // Refresh BrightnessManager so display.supportsDDC flags
                    // reflect the newly-probed capabilities
                    BrightnessManager.shared.refreshDisplays()
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
            markLocalWrite(vcp: .brightness, for: displayID)
            hardwareBrightness[displayID] = clamped

            let rawValue = UInt16((clamped * Double(cap.maxBrightness)).rounded())
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
            markLocalWrite(vcp: .contrast, for: displayID)
            hardwareContrast[displayID] = clamped

            let rawValue = UInt16((clamped * Double(cap.maxContrast)).rounded())
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
            markLocalWrite(vcp: .volume, for: displayID)
            hardwareVolume[displayID] = clamped

            let rawValue = UInt16((clamped * Double(cap.maxVolume)).rounded())
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
            markLocalWrite(vcp: .audioMute, for: displayID)
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

            markLocalWrite(vcp: .inputSource, for: displayID)
            activeInputSource[displayID] = source
            debouncedWrite(vcp: .inputSource, value: source.rawValue, for: displayID)
        }

        /// Returns the available input sources for a display.
        ///
        /// Filters to common modern inputs (DisplayPort, HDMI, USB-C) that users are likely
        /// to encounter. Legacy sources (VGA, DVI, S-Video, composite, component, tuner) are
        /// excluded to keep the menu manageable. Monitors silently ignore sources they don't have.
        func availableInputSources(for displayID: CGDirectDisplayID) -> [InputSource] {
            guard supportsDDC(for: displayID),
                  capabilities[displayID]?.supportsInputSource == true
            else {
                return []
            }
            return [.displayPort1, .displayPort2, .hdmi1, .hdmi2, .usbC]
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
                    self?.pollAllDisplays()
                }
            }
        }

        /// Stops the background polling task.
        func stopPolling() {
            pollingTask?.cancel()
            pollingTask = nil
        }

        /// Applies settings that can change while the app is running.
        func applyRuntimeSettings(
            controlMode: DDCControlMode,
            pollingInterval: Int,
            writeDelayMilliseconds: Int
        ) {
            self.controlMode = controlMode
            self.pollingInterval = TimeInterval(pollingInterval)
            minimumWriteInterval = TimeInterval(writeDelayMilliseconds) / 1000.0
        }

        /// Cleans up state for disconnected displays.
        func removeDisplay(_ displayID: CGDirectDisplayID) {
            capabilities.removeValue(forKey: displayID)
            hardwareBrightness.removeValue(forKey: displayID)
            hardwareContrast.removeValue(forKey: displayID)
            hardwareVolume.removeValue(forKey: displayID)
            hardwareMute.removeValue(forKey: displayID)
            activeInputSource.removeValue(forKey: displayID)
            // Cancel and remove all pending writes for this display (any VCP code)
            for key in pendingWrites.keys where key.displayID == displayID {
                pendingWrites[key]?.cancel()
                pendingWrites.removeValue(forKey: key)
            }
            pendingWriteGeneration = pendingWriteGeneration.filter { $0.key.displayID != displayID }
            pendingHardwareWrites = pendingHardwareWrites.filter { $0.key.displayID != displayID }
            lastLocalWriteTime = lastLocalWriteTime.filter { $0.key.displayID != displayID }
            writeTiming.removeDisplay(displayID)
            consecutiveWriteFailures = consecutiveWriteFailures.filter { $0.key.displayID != displayID }
        }

        // MARK: - Private: DDC Read

        // swiftlint:disable cyclomatic_complexity

        /// Reads all supported VCP values for a display.
        ///
        /// Captures the DDC interface locally before the queued work to avoid
        /// accessing `self` from a non-isolated context for I/O operations.
        /// The queue work only hops back to MainActor for publishing results.
        private func readAllValues(for displayID: CGDirectDisplayID) {
            guard let cap = capabilities[displayID], cap.supportsDDC else { return }

            let ddcIO = ddcInterface
            let ddcQueue = ddcQueue
            ddcQueue.async {
                let readStartedAt = Date()
                var brightness: Double?
                var contrast: Double?
                var volume: Double?
                var muted: Bool?
                var inputSource: InputSource?

                if cap.supportsBrightness {
                    if let result = ddcIO.read(vcp: .brightness, for: displayID) {
                        brightness = Double(result.currentValue) / Double(result.maxValue)
                    }
                }

                if cap.supportsContrast {
                    if let result = ddcIO.read(vcp: .contrast, for: displayID) {
                        contrast = Double(result.currentValue) / Double(result.maxValue)
                    }
                }

                if cap.supportsVolume {
                    if let result = ddcIO.read(vcp: .volume, for: displayID) {
                        volume = Double(result.currentValue) / Double(result.maxValue)
                    }
                }

                if cap.supportsAudioMute {
                    if let result = ddcIO.read(vcp: .audioMute, for: displayID) {
                        // Non-continuous VCP: value in low byte only
                        muted = (result.currentValue & 0xFF) == 1
                    }
                }

                if cap.supportsInputSource {
                    if let result = ddcIO.read(vcp: .inputSource, for: displayID) {
                        // Non-continuous VCP codes return the value in the low byte only
                        inputSource = InputSource(rawValue: result.currentValue & 0xFF)
                    }
                }

                // Apply all read values on the main actor in a single hop
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if let brightness, shouldApplyRead(vcp: .brightness, for: displayID, readStartedAt: readStartedAt) {
                        hardwareBrightness[displayID] = brightness
                    }
                    if let contrast, shouldApplyRead(vcp: .contrast, for: displayID, readStartedAt: readStartedAt) {
                        hardwareContrast[displayID] = contrast
                    }
                    if let volume, shouldApplyRead(vcp: .volume, for: displayID, readStartedAt: readStartedAt) {
                        hardwareVolume[displayID] = volume
                    }
                    if let muted, shouldApplyRead(vcp: .audioMute, for: displayID, readStartedAt: readStartedAt) {
                        hardwareMute[displayID] = muted
                    }
                    if let inputSource,
                       shouldApplyRead(vcp: .inputSource, for: displayID, readStartedAt: readStartedAt)
                    {
                        activeInputSource[displayID] = inputSource
                    }
                }
            }
        }

        // swiftlint:enable cyclomatic_complexity

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
            // Cancel any pending write for this display+VCP pair
            let writeKey = WriteKey(displayID: displayID, vcp: vcp)
            pendingWrites[writeKey]?.cancel()

            let generation = (pendingWriteGeneration[writeKey] ?? 0) + 1
            pendingWriteGeneration[writeKey] = generation

            pendingWrites[writeKey] = Task { [weak self] in
                // Wait for debounce period
                try? await Task.sleep(for: .seconds(self?.writeDebounceDelay ?? 0.1))
                guard !Task.isCancelled else {
                    // This scheduled attempt was superseded before it ever reached the
                    // hardware — undo its `markLocalWrite` increment here, in the same task
                    // that observes the cancellation, rather than at the `.cancel()` call
                    // site. `Task.cancel()` is cooperative: if the previous task had already
                    // passed this checkpoint (i.e. is already inside `performWrite`), calling
                    // `.cancel()` on it is a no-op, and only `performWrite`'s own completion
                    // decrements — deciding it here, atomically with the cancellation check,
                    // is the only way to avoid double-decrementing that case.
                    self?.decrementPendingHardwareWrite(writeKey)
                    self?.clearPendingWriteSlotIfCurrent(writeKey, generation: generation)
                    return
                }

                // Perform the write
                self?.performWrite(vcp: vcp, value: value, for: displayID)
                self?.clearPendingWriteSlotIfCurrent(writeKey, generation: generation)
            }
        }

        /// Removes a finished debounce task from `pendingWrites` — but only if no newer
        /// `debouncedWrite` call for the same key has already taken the slot (tracked via
        /// `pendingWriteGeneration`), so this cleanup can never clobber a task that
        /// superseded the one finishing here.
        private func clearPendingWriteSlotIfCurrent(_ writeKey: WriteKey, generation: Int) {
            guard pendingWriteGeneration[writeKey] == generation else { return }
            pendingWrites.removeValue(forKey: writeKey)
            pendingWriteGeneration.removeValue(forKey: writeKey)
        }

        /// Decrements the pending-write count for a key, removing the entry once it reaches
        /// zero. Shared by a cancelled debounced write and a completed one — both represent
        /// one fewer write still "in flight" toward the hardware.
        private func decrementPendingHardwareWrite(_ writeKey: WriteKey) {
            guard let remaining = pendingHardwareWrites[writeKey] else { return }
            if remaining > 1 {
                pendingHardwareWrites[writeKey] = remaining - 1
            } else {
                pendingHardwareWrites.removeValue(forKey: writeKey)
            }
        }

        /// Performs a single DDC write using the injected DDC interface.
        ///
        /// Tracks consecutive write failures per display+VCP code. After
        /// `maxWriteFailuresBeforeFallback` consecutive failures for that code, only that
        /// code is dropped from the display's supported set (e.g. a flaky volume control
        /// stops being offered) rather than downgrading the whole display to `.notSupported`.
        /// If the failing code was brightness (or it was the last remaining supported code),
        /// this naturally falls back to software brightness for the same reason `.notSupported`
        /// used to — `usesHardwareBrightness` checks `supportsBrightness`, which is now `false`.
        private func performWrite(vcp: VCPCode, value: UInt16, for displayID: CGDirectDisplayID) {
            let ddcIO = ddcInterface
            let minInterval = minimumWriteInterval
            let threshold = maxWriteFailuresBeforeFallback
            let ddcQueue = ddcQueue
            let writeTiming = writeTiming
            let writeKey = WriteKey(displayID: displayID, vcp: vcp)
            ddcQueue.async {
                writeTiming.waitUntilReady(for: displayID, minimumInterval: minInterval)
                let success = ddcIO.write(vcp: vcp, value: value, for: displayID)

                Task { @MainActor [weak self] in
                    guard let self else { return }
                    decrementPendingHardwareWrite(writeKey)

                    if success {
                        consecutiveWriteFailures[writeKey] = 0
                    } else {
                        let count = (consecutiveWriteFailures[writeKey] ?? 0) + 1
                        consecutiveWriteFailures[writeKey] = count

                        if count >= threshold, let cap = capabilities[displayID] {
                            var remainingCodes = cap.supportedCodes
                            remainingCodes.remove(vcp)
                            capabilities[displayID] = HardwareDisplayCapability(
                                displayID: cap.displayID,
                                supportsDDC: !remainingCodes.isEmpty,
                                supportedCodes: remainingCodes,
                                maxBrightness: cap.maxBrightness,
                                maxContrast: cap.maxContrast,
                                maxVolume: cap.maxVolume
                            )
                            BrightnessManager.shared.applyCurrentBrightness(for: displayID)
                        }
                    }
                }
            }
        }

        private func markLocalWrite(vcp: VCPCode, for displayID: CGDirectDisplayID) {
            let writeKey = WriteKey(displayID: displayID, vcp: vcp)
            pendingHardwareWrites[writeKey, default: 0] += 1
            lastLocalWriteTime[writeKey] = Date()
        }

        private func shouldApplyRead(
            vcp: VCPCode,
            for displayID: CGDirectDisplayID,
            readStartedAt: Date
        ) -> Bool {
            let writeKey = WriteKey(displayID: displayID, vcp: vcp)
            guard (pendingHardwareWrites[writeKey] ?? 0) == 0 else { return false }
            guard let localWriteTime = lastLocalWriteTime[writeKey] else { return true }
            return localWriteTime <= readStartedAt
        }
    }

#endif // !APPSTORE

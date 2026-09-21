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
        private(set) var isEnabled: Bool = false

        /// True while an invalidated session is draining from the serial DDC queue.
        private(set) var isDisabling = false

        /// The active control mode.
        var controlMode: DDCControlMode = .hardware

        // MARK: - Private State

        /// Serial queue for DDC I/O operations (prevents interleaved transactions).
        private let ddcQueue = DispatchQueue(label: "com.dimmerly.ddc", qos: .userInitiated)

        /// Identifies the currently enabled DDC lifecycle. Queued work must carry a
        /// session and validate it immediately before I/O and again before publication.
        private let sessionGate = DDCSessionGate()

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

        /// Backoff window for restoring a VCP code after a temporary write-failure fallback.
        private let writeFailureRecoveryDelays: [Duration] = [.seconds(1), .seconds(5), .seconds(30)]

        /// Minimum interval between DDC writes to the same display.
        /// Updated from AppSettings.ddcWriteDelay via SettingsView's `.onChange`.
        var minimumWriteInterval: TimeInterval = 0.05 // 50ms

        /// Composite key for debouncing DDC writes per display+VCP code pair.
        /// Without the VCP code in the key, rapid changes to different controls
        /// (e.g., brightness then volume) on the same display would cancel each other.
        private struct WriteKey: Hashable {
            let displayID: CGDirectDisplayID
            let vcp: VCPCode
            let incarnation: UInt64

            init(vcp: VCPCode, connection: DDCDisplayConnectionToken) {
                displayID = connection.displayID
                self.vcp = vcp
                incarnation = connection.incarnation
            }

            /// The connection this key was minted against.
            var connection: DDCDisplayConnectionToken {
                DDCDisplayConnectionToken(displayID: displayID, incarnation: incarnation)
            }
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

            func reset() {
                lock.withLock {
                    lastWriteTime.removeAll()
                }
            }
        }

        /// Pending write tasks per display+VCP code (for debouncing rapid slider changes).
        /// Entries are removed once their scheduled task's body finishes (see
        /// `clearPendingWriteSlotIfCurrent`) rather than left to sit as completed/cancelled
        /// `Task` objects until the next write to the same key happens to replace them.
        private var pendingWrites: [WriteKey: Task<Void, Never>] = [:]

        /// Recovery probes scheduled after repeated write failures, keyed per display+VCP
        /// so multiple failures cannot create duplicate probes for the same control.
        private var recoveryProbeTasks: [WriteKey: Task<Void, Never>] = [:]

        /// Monotonic connection incarnation per display ID. A CoreGraphics display ID can be
        /// reused after a disconnect, so capability equality alone cannot identify the same
        /// physical connection.
        private let displayConnectionGate = DDCDisplayConnectionGate()

        /// Monotonic per-key counter so a debounced write's own completion can tell whether
        /// it's still the current pending attempt for its key before clearing `pendingWrites`
        /// — a newer `debouncedWrite` call for the same key may have already taken the slot.
        private var pendingWriteGeneration: [WriteKey: Int] = [:]

        /// Background polling task for reading hardware values.
        private var pollingTask: Task<Void, Never>?

        var pendingWorkCountForTesting: Int {
            pendingWrites.count + pendingHardwareWrites.values.reduce(0, +)
        }

        /// Test seam for waiting until an asynchronous read has attempted publication.
        var readPublicationHookForTesting: (() -> Void)?

        /// Polling interval for DDC reads (seconds).
        var pollingInterval: TimeInterval = 5.0

        /// Write debounce delay (seconds).
        private let writeDebounceDelay: TimeInterval = 0.1

        // MARK: - DDC Interface

        /// The DDC I/O interface used for all hardware communication.
        /// Injected at init for testability; defaults to `DefaultDDCInterface`.
        let ddcInterface: DDCInterface

        /// Supplies the currently connected external displays.
        /// Injected in tests so capability probing does not depend on live hardware.
        private let connectedExternalDisplayIDsProvider: () -> [CGDirectDisplayID]

        /// Refreshes display models after capability changes.
        /// Injected in tests to avoid touching live display gamma state.
        private let displayRefreshHandler: () -> Void

        /// Publishes an accepted external brightness read to the authoritative display model.
        /// Kept injectable so hardware-manager tests do not need the process-wide singleton.
        private let hardwareBrightnessReadHandler: @MainActor (CGDirectDisplayID, Double) -> Void

        /// Short retry window for a newly connected display whose DDC service is still starting.
        private let automaticProbeRetryDelays: [Duration] = [.milliseconds(250), .seconds(1)]

        // MARK: - Initialization

        init(
            ddcInterface: DDCInterface = DefaultDDCInterface(),
            connectedExternalDisplayIDsProvider: @escaping () -> [CGDirectDisplayID] = {
                BrightnessManager.activeDisplayIDs().filter { CGDisplayIsBuiltin($0) == 0 }
            },
            displayRefreshHandler: @escaping () -> Void = {
                BrightnessManager.shared.refreshDisplays()
            },
            hardwareBrightnessReadHandler: @escaping @MainActor (CGDirectDisplayID, Double) -> Void = {
                BrightnessManager.shared.synchronizeExternalHardwareBrightness(for: $0, to: $1)
            }
        ) {
            self.ddcInterface = ddcInterface
            self.connectedExternalDisplayIDsProvider = connectedExternalDisplayIDsProvider
            self.displayRefreshHandler = displayRefreshHandler
            self.hardwareBrightnessReadHandler = hardwareBrightnessReadHandler
        }

        /// Test-only initializer that accepts a mock DDC interface.
        init(
            forTesting _: Bool,
            ddcInterface: DDCInterface = DefaultDDCInterface(),
            connectedExternalDisplayIDsProvider: @escaping () -> [CGDirectDisplayID] = {
                BrightnessManager.activeDisplayIDs().filter { CGDisplayIsBuiltin($0) == 0 }
            },
            displayRefreshHandler: @escaping () -> Void = {
                BrightnessManager.shared.refreshDisplays()
            },
            hardwareBrightnessReadHandler: @escaping @MainActor (CGDirectDisplayID, Double) -> Void = {
                BrightnessManager.shared.synchronizeExternalHardwareBrightness(for: $0, to: $1)
            }
        ) {
            self.ddcInterface = ddcInterface
            self.connectedExternalDisplayIDsProvider = connectedExternalDisplayIDsProvider
            self.displayRefreshHandler = displayRefreshHandler
            self.hardwareBrightnessReadHandler = hardwareBrightnessReadHandler
        }

        // MARK: - Public API

        /// Starts a fresh DDC lifecycle. Work from an older lifecycle remains invalid.
        func enable() {
            guard !isEnabled || isDisabling || sessionGate.capture() == nil else { return }
            sessionGate.beginEnabledSession()
            isEnabled = true
            isDisabling = false
        }

        /// Invalidates the active lifecycle and returns only after all older queued I/O
        /// has drained. Re-enabling while this barrier drains creates an independent session.
        func disable() async {
            guard let session = sessionGate.capture() else {
                isEnabled = false
                isDisabling = false
                return
            }

            sessionGate.invalidate(session)
            isDisabling = true
            stopPolling()
            cancelPendingWrites()

            await withCheckedContinuation { continuation in
                ddcQueue.async {
                    continuation.resume()
                }
            }

            if sessionGate.capture() == nil {
                isEnabled = false
            }
            isDisabling = false
            writeTiming.reset()
        }

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
            guard let session = sessionGate.capture() else { return }
            let connectedDisplayIDs = connectedExternalDisplayIDsProvider()
            let idsToProbe = force ? connectedDisplayIDs : connectedDisplayIDs.filter { capabilities[$0] == nil }
            guard !idsToProbe.isEmpty else { return }

            probe(
                displayIDs: idsToProbe,
                session: session,
                retryDelays: force ? [] : automaticProbeRetryDelays
            )
        }

        private func probe(
            displayIDs: [CGDirectDisplayID],
            session: DDCSession,
            retryDelays: [Duration],
            recoveryWriteKey: WriteKey? = nil,
            remainingRecoveryDelays: [Duration] = []
        ) {
            let ddcIO = ddcInterface
            let ddcQueue = ddcQueue
            let connectionTokens = Dictionary(uniqueKeysWithValues: displayIDs.map {
                ($0, displayConnectionGate.current(for: $0))
            })

            ddcQueue.async { [weak self] in
                guard let self else { return }
                var results: [CGDirectDisplayID: HardwareDisplayCapability] = [:]

                for displayID in displayIDs {
                    guard let connectionToken = connectionTokens[displayID],
                          sessionGate.isCurrent(session),
                          displayConnectionGate.isCurrent(connectionToken)
                    else { return }
                    let capability = ddcIO.probeCapabilities(for: displayID)
                    results[displayID] = capability
                }

                Task { @MainActor [weak self] in
                    guard let self, sessionGate.isCurrent(session) else { return }
                    let stillConnected = Set(connectedExternalDisplayIDsProvider())
                    for (displayID, cap) in results where stillConnected.contains(displayID) {
                        guard let connectionToken = connectionTokens[displayID],
                              displayConnectionGate.isCurrent(connectionToken)
                        else { continue }
                        advanceDisplayConnection(for: displayID)
                        capabilities[displayID] = cap
                        cancelRecoveryProbes(for: displayID)
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
                    for (displayID, cap) in results where !cap.supportsDDC && stillConnected.contains(displayID) {
                        scheduleAutomaticProbeRetry(
                            for: displayID,
                            session: session,
                            retryDelays: retryDelays
                        )
                    }
                    if let recoveryWriteKey,
                       let capability = results[recoveryWriteKey.displayID],
                       stillConnected.contains(recoveryWriteKey.displayID),
                       !capability.supportedCodes.contains(recoveryWriteKey.vcp)
                    {
                        let currentRecoveryKey = WriteKey(
                            vcp: recoveryWriteKey.vcp,
                            connection: displayConnectionGate.current(for: recoveryWriteKey.displayID)
                        )
                        scheduleWriteFailureRecovery(
                            for: currentRecoveryKey,
                            session: session,
                            retryDelays: remainingRecoveryDelays
                        )
                    }
                    // Refresh BrightnessManager so display.supportsDDC flags
                    // reflect the newly-probed capabilities
                    displayRefreshHandler()
                }
            }
        }

        private func scheduleAutomaticProbeRetry(
            for displayID: CGDirectDisplayID,
            session: DDCSession,
            retryDelays: [Duration]
        ) {
            guard let delay = retryDelays.first else { return }

            Task { [weak self] in
                do {
                    try await Task.sleep(for: delay)
                } catch {
                    return
                }

                guard let self, sessionGate.isCurrent(session) else { return }
                guard connectedExternalDisplayIDsProvider().contains(displayID) else { return }
                guard capabilities[displayID]?.supportsDDC != true else { return }

                probe(
                    displayIDs: [displayID],
                    session: session,
                    retryDelays: Array(retryDelays.dropFirst())
                )
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
            guard sessionGate.capture() != nil else { return }
            guard let cap = capabilities[displayID], cap.supportsBrightness else { return }

            let clamped = min(max(value, 0.0), 1.0)
            let connection = displayConnectionGate.current(for: displayID)
            markLocalWrite(vcp: .brightness, connection: connection)
            hardwareBrightness[displayID] = clamped

            let rawValue = UInt16((clamped * Double(cap.maxBrightness)).rounded())
            debouncedWrite(vcp: .brightness, value: rawValue, for: displayID, connection: connection)
        }

        /// Sets the hardware contrast for a display via DDC/CI.
        ///
        /// - Parameters:
        ///   - displayID: CoreGraphics display identifier
        ///   - value: Contrast value (0.0–1.0)
        func setHardwareContrast(for displayID: CGDirectDisplayID, to value: Double) {
            guard sessionGate.capture() != nil else { return }
            guard let cap = capabilities[displayID], cap.supportsContrast else { return }

            let clamped = min(max(value, 0.0), 1.0)
            let connection = displayConnectionGate.current(for: displayID)
            markLocalWrite(vcp: .contrast, connection: connection)
            hardwareContrast[displayID] = clamped

            let rawValue = UInt16((clamped * Double(cap.maxContrast)).rounded())
            debouncedWrite(vcp: .contrast, value: rawValue, for: displayID, connection: connection)
        }

        /// Sets the hardware volume for a display via DDC/CI.
        ///
        /// - Parameters:
        ///   - displayID: CoreGraphics display identifier
        ///   - value: Volume value (0.0–1.0)
        func setHardwareVolume(for displayID: CGDirectDisplayID, to value: Double) {
            guard sessionGate.capture() != nil else { return }
            guard let cap = capabilities[displayID], cap.supportsVolume else { return }

            let clamped = min(max(value, 0.0), 1.0)
            let connection = displayConnectionGate.current(for: displayID)
            markLocalWrite(vcp: .volume, connection: connection)
            hardwareVolume[displayID] = clamped

            let rawValue = UInt16((clamped * Double(cap.maxVolume)).rounded())
            debouncedWrite(vcp: .volume, value: rawValue, for: displayID, connection: connection)
        }

        /// Toggles audio mute for a display via DDC/CI.
        ///
        /// DDC mute values: 1 = muted, 2 = unmuted (per MCCS v2.2a).
        ///
        /// - Parameter displayID: CoreGraphics display identifier
        func toggleMute(for displayID: CGDirectDisplayID) {
            guard sessionGate.capture() != nil else { return }
            guard let cap = capabilities[displayID], cap.supportsAudioMute else { return }

            let currentlyMuted = hardwareMute[displayID] ?? false
            let newMuted = !currentlyMuted
            let connection = displayConnectionGate.current(for: displayID)
            markLocalWrite(vcp: .audioMute, connection: connection)
            hardwareMute[displayID] = newMuted

            let rawValue: UInt16 = newMuted ? 1 : 2
            debouncedWrite(vcp: .audioMute, value: rawValue, for: displayID, connection: connection)
        }

        /// Sets the input source for a display via DDC/CI.
        ///
        /// - Parameters:
        ///   - displayID: CoreGraphics display identifier
        ///   - source: The input source to switch to
        func setInputSource(for displayID: CGDirectDisplayID, to source: InputSource) {
            guard sessionGate.capture() != nil else { return }
            guard let cap = capabilities[displayID], cap.supportsInputSource else { return }

            let connection = displayConnectionGate.current(for: displayID)
            markLocalWrite(vcp: .inputSource, connection: connection)
            activeInputSource[displayID] = source
            debouncedWrite(vcp: .inputSource, value: source.rawValue, for: displayID, connection: connection)
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
            guard sessionGate.capture() != nil else { return }
            stopPolling()
            // The two-step weak unwrap is deliberate, not redundant: the interval is read
            // through `self?` *before* the sleep, and `self` is only bound strongly *after*
            // it. A strong reference held across the `await` would keep this manager alive
            // for a full poll interval after its last real owner released it. Reading the
            // interval each iteration also lets `applyRuntimeSettings` retune the cadence.
            pollingTask = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    guard let pollingInterval = self?.pollingInterval else { return }
                    try? await Task.sleep(for: .seconds(pollingInterval))
                    guard !Task.isCancelled else { return }
                    guard let self, sessionGate.capture() != nil else { return }
                    pollAllDisplays()
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
            advanceDisplayConnection(for: displayID)
            capabilities.removeValue(forKey: displayID)
            hardwareBrightness.removeValue(forKey: displayID)
            hardwareContrast.removeValue(forKey: displayID)
            hardwareVolume.removeValue(forKey: displayID)
            hardwareMute.removeValue(forKey: displayID)
            activeInputSource.removeValue(forKey: displayID)
            writeTiming.removeDisplay(displayID)
            cancelRecoveryProbes(for: displayID)
        }

        private func cancelPendingWrites() {
            for task in pendingWrites.values {
                task.cancel()
            }
            pendingWrites.removeAll()
            pendingWriteGeneration.removeAll()
            pendingHardwareWrites.removeAll()
            lastLocalWriteTime.removeAll()
            consecutiveWriteFailures.removeAll()
            for task in recoveryProbeTasks.values {
                task.cancel()
            }
            recoveryProbeTasks.removeAll()
        }

        // MARK: - Private: DDC Read

        private struct HardwareReadValues {
            let brightness: Double?
            let contrast: Double?
            let volume: Double?
            let muted: Bool?
            let inputSource: InputSource?
        }

        // The helper carries the immutable gates and I/O seam needed by the background queue.
        // swiftlint:disable:next function_parameter_count
        private nonisolated static func readHardwareValues(
            for displayID: CGDirectDisplayID,
            capability: HardwareDisplayCapability,
            session: DDCSession,
            connection: DDCDisplayConnectionToken,
            ddcInterface: any DDCInterface,
            sessionGate: DDCSessionGate,
            displayConnectionGate: DDCDisplayConnectionGate
        ) -> HardwareReadValues? {
            // The display can be unplugged or DDC disabled mid-read; re-check before each
            // transaction so an abandoned poll never publishes values from a dead connection.
            let isLive = { sessionGate.isCurrent(session) && displayConnectionGate.isCurrent(connection) }
            var brightness: Double?
            var contrast: Double?
            var volume: Double?
            var muted: Bool?
            var inputSource: InputSource?

            if capability.supportsBrightness {
                guard isLive() else { return nil }
                if let result = ddcInterface.read(vcp: .brightness, for: displayID) {
                    brightness = Double(result.currentValue) / Double(result.maxValue)
                }
            }

            if capability.supportsContrast {
                guard isLive() else { return nil }
                if let result = ddcInterface.read(vcp: .contrast, for: displayID) {
                    contrast = Double(result.currentValue) / Double(result.maxValue)
                }
            }

            if capability.supportsVolume {
                guard isLive() else { return nil }
                if let result = ddcInterface.read(vcp: .volume, for: displayID) {
                    volume = Double(result.currentValue) / Double(result.maxValue)
                }
            }

            if capability.supportsAudioMute {
                guard isLive() else { return nil }
                if let result = ddcInterface.read(vcp: .audioMute, for: displayID) {
                    // Non-continuous VCP: value in low byte only
                    muted = (result.currentValue & 0xFF) == 1
                }
            }

            if capability.supportsInputSource {
                guard isLive() else { return nil }
                if let result = ddcInterface.read(vcp: .inputSource, for: displayID) {
                    // Non-continuous VCP codes return the value in the low byte only
                    inputSource = InputSource(rawValue: result.currentValue & 0xFF)
                }
            }

            return HardwareReadValues(
                brightness: brightness,
                contrast: contrast,
                volume: volume,
                muted: muted,
                inputSource: inputSource
            )
        }

        /// Reads all supported VCP values for a display.
        ///
        /// Captures the DDC interface locally before the queued work to avoid
        /// accessing `self` from a non-isolated context for I/O operations.
        /// The queue work only hops back to MainActor for publishing results.
        private func readAllValues(for displayID: CGDirectDisplayID) {
            guard let session = sessionGate.capture() else { return }
            guard let cap = capabilities[displayID], cap.supportsDDC else { return }
            let connection = displayConnectionGate.current(for: displayID)

            let ddcIO = ddcInterface
            let ddcQueue = ddcQueue
            ddcQueue.async { [weak self] in
                guard let self else { return }
                let readStartedAt = Date()
                guard let values = Self.readHardwareValues(
                    for: displayID,
                    capability: cap,
                    session: session,
                    connection: connection,
                    ddcInterface: ddcIO,
                    sessionGate: sessionGate,
                    displayConnectionGate: displayConnectionGate
                ) else { return }

                // Apply all read values on the main actor in a single hop
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    defer { readPublicationHookForTesting?() }
                    guard sessionGate.isCurrent(session),
                          displayConnectionGate.isCurrent(connection),
                          capabilities[displayID] == cap
                    else { return }
                    let canApply = { (vcp: VCPCode) in
                        self.shouldApplyRead(
                            vcp: vcp,
                            connection: connection,
                            readStartedAt: readStartedAt
                        )
                    }
                    if let brightness = values.brightness, canApply(.brightness) {
                        hardwareBrightness[displayID] = brightness
                        if controlMode == .hardware {
                            hardwareBrightnessReadHandler(displayID, brightness)
                        }
                    }
                    if let contrast = values.contrast, canApply(.contrast) {
                        hardwareContrast[displayID] = contrast
                    }
                    if let volume = values.volume, canApply(.volume) {
                        hardwareVolume[displayID] = volume
                    }
                    if let muted = values.muted, canApply(.audioMute) {
                        hardwareMute[displayID] = muted
                    }
                    if let inputSource = values.inputSource, canApply(.inputSource) {
                        activeInputSource[displayID] = inputSource
                    }
                }
            }
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
        private func debouncedWrite(
            vcp: VCPCode,
            value: UInt16,
            for displayID: CGDirectDisplayID,
            connection: DDCDisplayConnectionToken
        ) {
            guard let session = sessionGate.capture() else { return }
            guard displayConnectionGate.isCurrent(connection) else { return }
            // Cancel any pending write for this display+VCP pair
            let writeKey = WriteKey(vcp: vcp, connection: connection)
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

                guard let self,
                      sessionGate.isCurrent(session),
                      displayConnectionGate.isCurrent(connection)
                else {
                    self?.decrementPendingHardwareWrite(writeKey)
                    self?.clearPendingWriteSlotIfCurrent(writeKey, generation: generation)
                    return
                }

                // Perform the write
                performWrite(
                    vcp: vcp,
                    value: value,
                    for: displayID,
                    session: session,
                    connection: connection
                )
                clearPendingWriteSlotIfCurrent(writeKey, generation: generation)
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
        /// used to — `DisplayOutputPolicy` checks `supportsBrightness`, which is now `false`.
        private func performWrite(
            vcp: VCPCode,
            value: UInt16,
            for displayID: CGDirectDisplayID,
            session: DDCSession,
            connection: DDCDisplayConnectionToken
        ) {
            let ddcIO = ddcInterface
            let minInterval = minimumWriteInterval
            let threshold = maxWriteFailuresBeforeFallback
            let ddcQueue = ddcQueue
            let writeTiming = writeTiming
            let writeKey = WriteKey(vcp: vcp, connection: connection)
            ddcQueue.async { [weak self] in
                guard let self else { return }
                guard sessionGate.isCurrent(session), displayConnectionGate.isCurrent(connection) else { return }
                writeTiming.waitUntilReady(for: displayID, minimumInterval: minInterval)
                guard sessionGate.isCurrent(session), displayConnectionGate.isCurrent(connection) else { return }
                let success = ddcIO.write(vcp: vcp, value: value, for: displayID)

                Task { @MainActor [weak self] in
                    guard let self,
                          sessionGate.isCurrent(session),
                          displayConnectionGate.isCurrent(connection)
                    else { return }
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
                            scheduleWriteFailureRecovery(
                                for: writeKey,
                                session: session,
                                retryDelays: writeFailureRecoveryDelays
                            )
                            BrightnessManager.shared.applyCurrentBrightness(for: displayID)
                        }
                    }
                }
            }
        }

        private func scheduleWriteFailureRecovery(
            for writeKey: WriteKey,
            session: DDCSession,
            retryDelays: [Duration]
        ) {
            guard let delay = retryDelays.first else { return }
            guard recoveryProbeTasks[writeKey] == nil else { return }
            guard displayConnectionGate.isCurrent(writeKey.connection) else { return }

            recoveryProbeTasks[writeKey] = Task { [weak self] in
                do {
                    guard let self else { return }
                    try await Task.sleep(for: delay)
                    guard sessionGate.isCurrent(session) else { return }
                    guard connectedExternalDisplayIDsProvider().contains(writeKey.displayID) else { return }
                    guard displayConnectionGate.isCurrent(writeKey.connection) else { return }

                    recoveryProbeTasks.removeValue(forKey: writeKey)
                    probe(
                        displayIDs: [writeKey.displayID],
                        session: session,
                        retryDelays: [],
                        recoveryWriteKey: writeKey,
                        remainingRecoveryDelays: Array(retryDelays.dropFirst())
                    )
                } catch {
                    self?.recoveryProbeTasks.removeValue(forKey: writeKey)
                }
            }
        }

        private func cancelRecoveryProbes(for displayID: CGDirectDisplayID) {
            for key in recoveryProbeTasks.keys where key.displayID == displayID {
                recoveryProbeTasks[key]?.cancel()
                recoveryProbeTasks.removeValue(forKey: key)
            }
        }

        @discardableResult
        private func advanceDisplayConnection(for displayID: CGDirectDisplayID) -> DDCDisplayConnectionToken {
            for key in pendingWrites.keys where key.displayID == displayID {
                pendingWrites[key]?.cancel()
            }
            pendingWrites = pendingWrites.filter { $0.key.displayID != displayID }
            pendingWriteGeneration = pendingWriteGeneration.filter { $0.key.displayID != displayID }
            pendingHardwareWrites = pendingHardwareWrites.filter { $0.key.displayID != displayID }
            lastLocalWriteTime = lastLocalWriteTime.filter { $0.key.displayID != displayID }
            consecutiveWriteFailures = consecutiveWriteFailures.filter { $0.key.displayID != displayID }
            return displayConnectionGate.advance(for: displayID)
        }

        private func markLocalWrite(
            vcp: VCPCode,
            connection: DDCDisplayConnectionToken
        ) {
            let writeKey = WriteKey(vcp: vcp, connection: connection)
            pendingHardwareWrites[writeKey, default: 0] += 1
            lastLocalWriteTime[writeKey] = Date()
        }

        private func shouldApplyRead(
            vcp: VCPCode,
            connection: DDCDisplayConnectionToken,
            readStartedAt: Date
        ) -> Bool {
            let writeKey = WriteKey(vcp: vcp, connection: connection)
            guard (pendingHardwareWrites[writeKey] ?? 0) == 0 else { return false }
            guard let localWriteTime = lastLocalWriteTime[writeKey] else { return true }
            return localWriteTime <= readStartedAt
        }
    }

#endif // !APPSTORE

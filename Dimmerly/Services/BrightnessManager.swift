//
//  BrightnessManager.swift
//  Dimmerly
//
//  Per-display software brightness control for all displays (built-in and external).
//  Uses CoreGraphics gamma tables; direct builds can also drive native backlights and DDC.
//

import AppKit
import CoreGraphics

// Keep native output discovery beside the existing display policy and state machinery.
// swiftlint:disable file_length

// MARK: - Native Display Backlight (Private API)

#if !APPSTORE
    /// Dynamically loaded DisplayServices functions for controlling native display backlights.
    /// Uses dlopen/dlsym to avoid linking against
    /// a private framework, which keeps the build clean and fails gracefully at runtime
    /// if the framework is unavailable on a future macOS version.
    private enum DisplayServicesAPI {
        private nonisolated(unsafe) static let handle: UnsafeMutableRawPointer? = dlopen(
            "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices",
            RTLD_LAZY
        )

        private static let _setBrightness:
            (@convention(c) (CGDirectDisplayID, Float) -> Int32)? = {
                guard let handle, let sym = dlsym(handle, "DisplayServicesSetBrightness") else { return nil }
                return unsafeBitCast(sym, to: (@convention(c) (CGDirectDisplayID, Float) -> Int32).self)
            }()

        private static let _getBrightness:
            (@convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32)? = {
                guard let handle, let sym = dlsym(handle, "DisplayServicesGetBrightness") else { return nil }
                return unsafeBitCast(
                    sym,
                    to: (@convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32).self
                )
            }()

        static var isAvailable: Bool {
            _setBrightness != nil && _getBrightness != nil
        }

        static func setBrightness(_ display: CGDirectDisplayID, _ brightness: Float) -> Int32 {
            _setBrightness?(display, brightness) ?? -1
        }

        static func getBrightness(_ display: CGDirectDisplayID, _ brightness: UnsafeMutablePointer<Float>) -> Int32 {
            _getBrightness?(display, brightness) ?? -1
        }
    }
#endif

/// Represents a display with its current visual properties.
///
/// This model tracks per-display brightness, warmth (color temperature), and contrast
/// adjustments applied via CoreGraphics gamma tables.
struct ExternalDisplay: Identifiable {
    /// Contrast value representing a neutral, linear response curve.
    static let neutralContrast: Double = 0.5

    /// Core Graphics display identifier (unique hardware ID)
    let id: CGDirectDisplayID
    /// Human-readable display name (e.g., "LG UltraFine 5K" or "Built-in Retina Display")
    var name: String
    /// Current brightness level (0.0 = dimmest allowed, 1.0 = full brightness)
    var brightness: Double
    /// Color temperature shift (0.0 = neutral/6500K, 1.0 = warmest/1900K)
    var warmth: Double = 0.0
    /// Contrast curve steepness (0.0 = flat, 0.5 = neutral/linear, 1.0 = steep S-curve)
    var contrast: Double = Self.neutralContrast
    /// Whether this is the built-in (laptop) display
    var isBuiltIn: Bool = false
}

/// Manages software-based brightness, warmth, and contrast control for all displays.
///
/// This manager uses CoreGraphics gamma table APIs to adjust display output, which is:
/// - App Store safe in the App Store build (direct builds add DisplayServices and DDC paths)
/// - Per-display configurable (supports multiple monitors independently)
/// - Hardware-independent (works with all external displays)
///
/// The manager automatically:
/// - Detects display connection/disconnection events
/// - Restores gamma tables after system wake (macOS resets them)
/// - Persists settings to UserDefaults with debouncing
/// - Coordinates with ScreenBlanker for smooth fade transitions
///
/// Thread safety: All methods must be called from the main actor.
@MainActor
@Observable
class BrightnessManager { // swiftlint:disable:this type_body_length
    static let shared = BrightnessManager()

    /// Minimum allowed brightness to ensure displays remain visible.
    /// Prevents accidentally setting displays to pure black, which would require external controls to recover.
    static let minimumBrightness: Double = 0.10

    /// Product-level percentage range shared with App Intents and other input surfaces.
    static let brightnessPercentageRange = (minimumBrightness * 100) ... 100.0

    /// Currently connected displays (built-in and external) with their visual properties.
    /// Updated automatically when displays are connected/disconnected.
    var displays: [ExternalDisplay] = []

    /// Tolerance below which a display is treated as untouched. Applied identically to
    /// brightness, warmth and contrast, so the three cannot disagree about what neutral
    /// means. One percent covers both floating-point drift from slider input and
    /// adjustments too small to see, neither of which should light up the menu bar.
    private static let neutralTolerance: Double = 0.01

    /// True when Dimmerly is overlaying an adjustment on any connected display that would
    /// disappear if the app quit. Drives the menu bar active-state icon.
    ///
    /// Brightness is read through `resolvedGammaBrightness` rather than `display.brightness`,
    /// because the two mean different things per display. Where brightness is delivered by
    /// hardware - the built-in backlight, or an external panel over DDC - the app writes the
    /// display's own setting, which persists after the app quits and which the user can change
    /// just as directly with the keyboard keys or the monitor's buttons. Backlight polling then
    /// syncs those user-made changes back into `display.brightness`, so that value cannot tell
    /// an adjustment made here apart from one made outside. Treating it as one left the icon
    /// pinned to its active state on any laptop not running at exactly 100%.
    ///
    /// `resolvedGammaBrightness` is 1.0 on those hardware paths and carries the requested level
    /// only when the app is dimming in software, which is precisely the overlay case. Warmth and
    /// contrast are always gamma overlays, so they count on every display.
    ///
    /// Known consequence, deliberately left alone: the day temperature slider tops out at the
    /// 6500K default, and `GammaMath.warmthForKelvin` only returns zero at exactly 6500K. A user
    /// who moves it one notch to 6400K gets a standing warmth of about 0.022, so with automatic
    /// colour temperature enabled this reads as active all day. That is truthful - the app really
    /// is warming the panel the whole time - and suppressing it would mean treating a configured
    /// day temperature as the neutral point, which this property has no business knowing about.
    var isAffectingDisplays: Bool {
        displays.contains { display in
            resolvedGammaBrightness(for: display) < 1.0 - Self.neutralTolerance
                || display.warmth > Self.neutralTolerance
                || abs(display.contrast - ExternalDisplay.neutralContrast) > Self.neutralTolerance
        }
    }

    /// UserDefaults keys for persisting display settings
    private let persistenceKey = "dimmerlyDisplayBrightness"
    private let warmthPersistenceKey = "dimmerlyDisplayWarmth"
    private let contrastPersistenceKey = "dimmerlyDisplayContrast"

    /// The `UserDefaults` suite per-display values are persisted to. Defaults to `.standard`;
    /// tests inject an isolated suite so they neither read nor overwrite real user settings.
    private let defaults: UserDefaults

    /// Manages the CoreGraphics display reconfiguration callback registration
    private var reconfigurationToken: DisplayReconfigurationToken?

    /// Task for debounced persistence to UserDefaults (prevents excessive writes during slider drags)
    private var persistTask: Task<Void, Never>?

    /// Active preset transition animation task (cancelled when a new transition starts)
    /// Tracks only displays with explicit brightness targets so completion and cancellation
    /// never write backlight values that the preset left unchanged.
    private var activeTransition: (task: Task<Void, Never>, hardwareBrightnessDisplayIDs: Set<CGDirectDisplayID>)?

    /// Coalesces system and screen wake events before reapplying display output.
    private var wakeMonitor: WorkspaceWakeMonitor?

    #if !APPSTORE
        /// Polling task that reads the built-in display backlight to detect external changes
        /// (keyboard brightness keys, Control Center). Runs every ~1 second.
        private var backlightPollTask: Task<Void, Never>?

        /// Test seam for observing built-in backlight writes without invoking private APIs.
        var setBuiltInBacklightHook: ((CGDirectDisplayID, Double) -> Bool)?

        /// Test seam for simulating built-in backlight reads.
        var readBuiltInBrightnessHook: ((CGDirectDisplayID) -> Double?)?

        /// Test seam for simulating DisplayServices availability.
        var isBuiltInBacklightAPIAvailableHook: (() -> Bool)?

        /// Test seam for probing native brightness on external displays.
        var readExternalNativeBacklightHook: ((CGDirectDisplayID) -> Double?)?

        /// Test seam for setting native brightness on external displays.
        var setExternalNativeBacklightHook: ((CGDirectDisplayID, Double) -> Bool)?

        /// Test seam for observing external DDC brightness writes without hitting hardware.
        var setExternalHardwareBrightnessHook: ((CGDirectDisplayID, Double) -> Void)?

        /// Display IDs whose native backlight is unavailable or currently rejects writes. These
        /// displays use software gamma until the API becomes available or a later native write
        /// succeeds, while warmth and contrast continue to use their normal gamma path.
        private var softwareBacklightFallbackDisplayIDs: Set<CGDirectDisplayID> = []

        /// External display identities whose native brightness read succeeded. Keying by stable
        /// display identity prevents a reused CoreGraphics display ID from inheriting support.
        private var nativeBacklightDisplayIdentities: Set<String> = []

        /// External displays temporarily using gamma after a failed native brightness write,
        /// mapped to the identity that failed so a reused display ID does not inherit fallback.
        private var externalBacklightFallbackIdentities: [CGDirectDisplayID: String] = [:]

        /// Successful native reads collected before reconciling one refresh. A read is useful
        /// for discovery and initial state, but a failed/transient read must not erase the model.
        private var nativeBrightnessReadsThisRefresh: [CGDirectDisplayID: Double] = [:]

        /// External display identities whose brightness hasn't been set this session. A monitor
        /// keeps its own brightness, so DDC is never written from a default or saved value: the
        /// display adopts its hardware reads until a user, preset, or schedule change claims it.
        private var unclaimedExternalBrightnessIdentities: Set<String> = []

        /// Test initializer skips implicit private API probes; explicit hooks still exercise them.
        private let isTestingInstance: Bool

        private enum NativeBrightnessReadResult {
            case value(Double)
            case unavailable
            case failed
        }
    #endif

    /// Test seam for observing gamma applications without modifying the real display state.
    var applyGammaHook: ((CGDirectDisplayID, Double, Double, Double) -> Void)?

    /// Test seams for deterministic display-reconfiguration coverage.
    var activeDisplayIDsHook: (() -> [CGDirectDisplayID])?
    var isBuiltInDisplayHook: ((CGDirectDisplayID) -> Bool)?

    /// Test seam for forcing transition eligibility independent of process-wide accessibility state.
    var canAnimateTransitionsHook: (() -> Bool)?

    /// Test seam for simulating blanking without changing real display or input state.
    var isBlankingHook: (() -> Bool)?

    private var isBlanking: Bool {
        isBlankingHook?() ?? ScreenBlanker.shared.isBlanking
    }

    /// Test seam for the stable per-display persistence key. The real implementation reads EDID
    /// metadata through CoreGraphics, which unit tests can't synthesize.
    var displayIdentityHook: ((CGDirectDisplayID) -> String)?

    /// Standard initializer that sets up full hardware monitoring and system integration.
    /// Registers observers for display changes, wake events, and ScreenBlanker coordination.
    init() {
        defaults = .standard
        #if !APPSTORE
            isTestingInstance = false
        #endif
        setupHardwareMonitoring()
    }

    /// Test-only initializer that bypasses all hardware interaction.
    ///
    /// This initializer:
    /// - Skips display enumeration and gamma table modification
    /// - Does not register system observers (wake, reconfiguration)
    /// - Does not coordinate with ScreenBlanker
    ///
    /// Use this for unit tests that need to verify business logic without side effects.
    ///
    /// - Parameters:
    ///   - forTesting: Pass `true` to create an isolated test instance
    ///   - defaults: Suite to persist per-display values to. Defaults to a dedicated testing
    ///     suite — *not* `.standard` — because setters debounce a persist, so a test that merely
    ///     adjusts brightness would otherwise overwrite the developer's real display settings.
    init(forTesting _: Bool, defaults: UserDefaults? = nil) {
        self.defaults = defaults
            ?? UserDefaults(suiteName: Self.testingDefaultsSuiteName)
            ?? .standard
        #if !APPSTORE
            isTestingInstance = true
        #endif
        // Skip hardware setup — no gamma changes, no observers
    }

    /// Suite backing `init(forTesting:)` when no explicit one is given. Keeps test writes off the
    /// real settings domain without each test having to remember to inject a suite.
    static let testingDefaultsSuiteName = "rs.in.olujic.dimmerly.testing"

    /// Clears the shared testing suite. Call from test teardown to stop values leaking between
    /// tests through the default suite.
    static func resetTestingDefaults() {
        UserDefaults().removePersistentDomain(forName: testingDefaultsSuiteName)
    }

    private func setupHardwareMonitoring() {
        refreshDisplays()

        // macOS can reset gamma when either the Mac or only its displays wake.
        // Clear app-managed blanking immediately, then wait for display stabilization.
        // Two passes: one as soon as the displays are usable, then a settle pass. Display
        // re-enumeration can still be in flight at one second — macOS was observed wiping the
        // gamma table roughly eight seconds after a display came back, long after a single
        // early re-apply had run and left the screen unadjusted.
        let monitor = WorkspaceWakeMonitor(
            delay: .seconds(1),
            settleDelay: .seconds(9),
            onWakeDetected: {
                ScreenBlanker.shared.dismiss(force: true)
            },
            onWakeReady: { [weak self] in
                self?.reapplyAll()
            }
        )
        monitor.start()
        wakeMonitor = monitor

        // Detect display plug/unplug. Blanking reconciliation belongs here rather than in
        // `refreshDisplays()`: that also runs at startup and after every DDC capability probe,
        // neither of which is a topology change.
        reconfigurationToken = DisplayReconfigurationToken { [weak self] in
            Task { @MainActor in
                self?.refreshDisplays()
                ScreenBlanker.shared.displayTopologyDidChange()
            }
        }

        #if !APPSTORE
            // Poll the built-in display backlight to detect external brightness changes
            // (keyboard F1/F2, Control Center). Polling is simple and reliable — the
            // DisplayServicesGetBrightness call is very cheap (~0.1ms).
            startBacklightPolling()
        #endif

        coordinateBlanking(with: ScreenBlanker.shared)
    }

    /// Gives the blanker what it needs to fade from, and restore to, each display's output.
    func coordinateBlanking(with blanker: ScreenBlanker) {
        // Once blanking ends, bring back every display the blanker did not already restore.
        // `restoreDisplay` below has written full output for the ones it restored, so a second
        // pass over them would only repeat the same backlight and DDC writes.
        blanker.onDismiss = { [weak self] restoredDisplayIDs in
            self?.reapplyAll(except: restoredDisplayIDs)
        }

        // Provide per-display brightness to ScreenBlanker for fade animation.
        // Uses the resolved *gamma* brightness (matching `applyDisplayGamma`), not the raw
        // model brightness — for hardware-controlled displays gamma sits at 1.0 regardless
        // of the model value, so the fade must start from there to avoid a jump/flash.
        blanker.brightnessForDisplay = { [weak self] displayID in
            guard let self, let display = displays.first(where: { $0.id == displayID }) else { return 1.0 }
            return resolvedGammaBrightness(for: display)
        }

        // Provide per-display warmth to ScreenBlanker for fade animation
        blanker.warmthForDisplay = { [weak self] displayID in
            self?.warmth(for: displayID) ?? 0.0
        }

        // Provide per-display contrast to ScreenBlanker for fade animation
        blanker.contrastForDisplay = { [weak self] displayID in
            self?.contrast(for: displayID) ?? ExternalDisplay.neutralContrast
        }

        // Restores a display's full output: hardware brightness as well as its gamma table.
        blanker.restoreDisplay = { [weak self] displayID in
            guard let self, let display = displays.first(where: { $0.id == displayID }) else { return }
            applyDisplayOutput(display, allowDuringBlanking: true)
        }
    }

    /// Returns the current brightness for a given display ID
    func brightness(for displayID: CGDirectDisplayID) -> Double {
        displays.first(where: { $0.id == displayID })?.brightness ?? 1.0
    }

    /// Returns the current warmth for a given display ID
    func warmth(for displayID: CGDirectDisplayID) -> Double {
        displays.first(where: { $0.id == displayID })?.warmth ?? 0.0
    }

    /// Returns the current contrast for a given display ID
    func contrast(for displayID: CGDirectDisplayID) -> Double {
        displays.first(where: { $0.id == displayID })?.contrast ?? ExternalDisplay.neutralContrast
    }

    // MARK: - Built-in Display Backlight

    #if !APPSTORE
        private func isBuiltInBacklightAPIAvailable() -> Bool {
            isBuiltInBacklightAPIAvailableHook?() ?? DisplayServicesAPI.isAvailable
        }

        private func validNativeBrightness(_ brightness: Double, isBuiltIn: Bool) -> Bool {
            brightness.isFinite && (isBuiltIn || (0.0 ... 1.0).contains(brightness))
        }

        private func nativeBrightnessReadResult(
            for displayID: CGDirectDisplayID,
            isBuiltIn: Bool
        ) -> NativeBrightnessReadResult {
            if !isBuiltIn, !HardwareBrightnessManager.shared.isExternalNativeBrightnessActive {
                return .unavailable
            }
            let brightness: Double?
            if let hook = isBuiltIn ? readBuiltInBrightnessHook : readExternalNativeBacklightHook {
                brightness = hook(displayID)
            } else {
                guard !isTestingInstance else { return .unavailable }
                if isBuiltIn, !isBuiltInDisplay(displayID) {
                    return .failed
                }
                guard isBuiltInBacklightAPIAvailable() else { return .unavailable }
                var value: Float = 0
                brightness = DisplayServicesAPI.getBrightness(displayID, &value) == 0 ? Double(value) : nil
            }
            guard let brightness, validNativeBrightness(brightness, isBuiltIn: isBuiltIn) else {
                return isBuiltInBacklightAPIAvailable() ? .failed : .unavailable
            }
            if !isBuiltIn {
                let identity = displayIdentity(for: displayID)
                // Polling re-reads every second; only a new identity is a change views observe.
                if !nativeBacklightDisplayIdentities.contains(identity) {
                    nativeBacklightDisplayIdentities.insert(identity)
                }
                nativeBrightnessReadsThisRefresh[displayID] = brightness
            }
            return .value(brightness)
        }

        /// Sets the hardware backlight brightness of the built-in display.
        /// Returns true on success.
        @discardableResult
        func setBuiltInBacklight(for displayID: CGDirectDisplayID, to value: Double) -> Bool {
            if let setBuiltInBacklightHook {
                return setBuiltInBacklightHook(displayID, value)
            }
            guard CGDisplayIsBuiltin(displayID) != 0,
                  isBuiltInBacklightAPIAvailable() else { return false }
            let clamped = Float(clamp01(value))
            return DisplayServicesAPI.setBrightness(displayID, clamped) == 0
        }

        /// Whether native backlight control applies to an external display right now: the user
        /// opted in, hardware control is active, and the display's current identity has returned
        /// a valid native brightness read. This is the only source of truth for native external
        /// brightness; the identity set is filled by reads and pruned during display enumeration,
        /// and resolving the identity live keeps a reused display ID from inheriting support.
        func supportsNativeBacklight(for displayID: CGDirectDisplayID) -> Bool {
            HardwareBrightnessManager.shared.isExternalNativeBrightnessActive
                && nativeBacklightDisplayIdentities.contains(displayIdentity(for: displayID))
        }

        private func hasExternalBacklightFallback(for displayID: CGDirectDisplayID) -> Bool {
            externalBacklightFallbackIdentities[displayID] == displayIdentity(for: displayID)
        }

        /// Writes native brightness to an external Apple-managed display.
        @discardableResult
        private func setExternalNativeBacklight(for displayID: CGDirectDisplayID, to value: Double) -> Bool {
            guard HardwareBrightnessManager.shared.isExternalNativeBrightnessActive else { return false }
            if let setExternalNativeBacklightHook {
                return setExternalNativeBacklightHook(displayID, value)
            }
            guard !isTestingInstance, isBuiltInDisplay(displayID) == false,
                  isBuiltInBacklightAPIAvailable() else { return false }
            let clamped = Float(clamp01(value))
            return DisplayServicesAPI.setBrightness(displayID, clamped) == 0
        }

        /// Called periodically to detect external brightness changes (keyboard keys, Control Center).
        /// Updates our model to stay in sync.
        private func syncBuiltInBrightness() {
            for i in displays.indices where displays[i].isBuiltIn {
                let displayID = displays[i].id
                guard !softwareBacklightFallbackDisplayIDs.contains(displayID) else { continue }
                switch nativeBrightnessReadResult(for: displayID, isBuiltIn: true) {
                case let .value(hw):
                    // A panel can report a native level below the app's interactive gamma
                    // floor. Preserve that hardware value rather than brightening it during the
                    // next poll; the user can still recover through the native backlight path.
                    let clamped = clamp01(hw)
                    if abs(displays[i].brightness - clamped) > 0.005 {
                        displays[i].brightness = clamped
                        debouncePersist()
                    }
                case .unavailable:
                    softwareBacklightFallbackDisplayIDs.insert(displayID)
                    applyDisplayGamma(displays[i])
                case .failed:
                    break
                }
            }

            guard HardwareBrightnessManager.shared.isExternalNativeBrightnessActive else { return }
            for i in displays.indices where !displays[i].isBuiltIn {
                let displayID = displays[i].id
                guard supportsNativeBacklight(for: displayID),
                      !hasExternalBacklightFallback(for: displayID),
                      case let .value(brightness) = nativeBrightnessReadResult(for: displayID, isBuiltIn: false)
                else { continue }
                if abs(displays[i].brightness - brightness) > 0.005 {
                    displays[i].brightness = brightness
                    debouncePersist()
                }
            }
        }

        #if DEBUG
            /// Test-only entry point for the same read path used by backlight polling.
            func syncBuiltInBrightnessForTesting() {
                syncBuiltInBrightness()
            }
        #endif

        /// Starts polling the built-in display backlight every ~1 second.
        private func startBacklightPolling() {
            backlightPollTask?.cancel()
            // `guard let self` must stay *inside* the loop body, after the sleep: a strong
            // reference bound across the `await` would keep this manager alive for a full
            // poll interval after its last real owner released it. Binding per iteration
            // means the strong reference dies before the next suspension point.
            backlightPollTask = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    guard !Task.isCancelled, let self else { return }
                    syncBuiltInBrightness()
                }
            }
        }
    #endif

    /// Toggles blanking for a single display
    func toggleBlank(for displayID: CGDirectDisplayID) {
        if ScreenBlanker.shared.isDisplayBlanked(displayID) {
            ScreenBlanker.shared.unblankDisplay(displayID)
        } else {
            ScreenBlanker.shared.blankDisplay(displayID)
        }
        // No manual observation nudge needed: ScreenBlanker is @Observable, so views
        // reading its blanked-display state re-render on their own.
    }

    /// Returns current brightness values keyed by stable display identity.
    func currentBrightnessSnapshot() -> [String: Double] {
        currentSnapshot(for: \.brightness)
    }

    /// Sets all connected displays to the same brightness value
    func setAllBrightness(to value: Double) {
        for display in displays {
            setBrightness(for: display.id, to: value)
        }
    }

    /// Applies saved brightness values from a preset (skips missing displays)
    func applyBrightnessValues(_ values: [String: Double]) {
        applySavedValues(values, using: setBrightness)
    }

    /// Returns current warmth values keyed by stable display identity.
    func currentWarmthSnapshot() -> [String: Double] {
        currentSnapshot(for: \.warmth)
    }

    /// Sets all connected displays to the same warmth value
    func setAllWarmth(to value: Double) {
        for display in displays {
            setWarmth(for: display.id, to: value)
        }
    }

    /// Applies saved warmth values from a preset (skips missing displays)
    func applyWarmthValues(_ values: [String: Double]) {
        applySavedValues(values, using: setWarmth)
    }

    /// Returns current contrast values keyed by stable display identity.
    func currentContrastSnapshot() -> [String: Double] {
        currentSnapshot(for: \.contrast)
    }

    /// Sets all connected displays to the same contrast value
    func setAllContrast(to value: Double) {
        for display in displays {
            setContrast(for: display.id, to: value)
        }
    }

    /// Applies saved contrast values from a preset (skips missing displays)
    func applyContrastValues(_ values: [String: Double]) {
        applySavedValues(values, using: setContrast)
    }

    private func currentSnapshot(for keyPath: KeyPath<ExternalDisplay, Double>) -> [String: Double] {
        var snapshot: [String: Double] = [:]
        for display in displays {
            snapshot[displayIdentity(for: display.id)] = display[keyPath: keyPath]
        }
        return snapshot
    }

    private func applySavedValues(
        _ values: [String: Double],
        using setter: (CGDirectDisplayID, Double) -> Void
    ) {
        // Resolve stable identities per display, falling back to legacy display-ID keys.
        for display in displays {
            let identity = displayIdentity(for: display.id)
            guard let value = savedValue(values, for: display.id, identity: identity) else { continue }
            setter(display.id, value)
        }
    }

    /// Refreshes the list of connected displays and restores their saved settings.
    ///
    /// This method:
    /// 1. Enumerates all active displays via CoreGraphics, including the built-in display
    /// 2. Reads native backlight levels where the build and display support it
    /// 3. Loads persisted brightness/warmth/contrast from UserDefaults
    /// 4. Clamps all values to valid ranges with safety minimums
    /// 5. Reapplies gamma tables if not currently blanking
    ///
    /// Called automatically when:
    /// - Manager is initialized
    /// - Displays are connected/disconnected (via reconfiguration callback)
    ///
    /// - Note: If screen blanking is active, gamma reapplication is deferred to avoid flicker.
    func refreshDisplays() {
        let displayIDs = activeDisplayIDsHook?() ?? Self.activeDisplayIDs()

        #if !APPSTORE
            let builtInDisplayIDs = Set(displayIDs.filter { isBuiltInDisplay($0) })
            softwareBacklightFallbackDisplayIDs.formIntersection(builtInDisplayIDs)

            let externalDisplayIDs = Set(displayIDs.filter { !isBuiltInDisplay($0) })
            let connectedExternalIdentities = Set(externalDisplayIDs.map(displayIdentity(for:)))
            externalBacklightFallbackIdentities = externalBacklightFallbackIdentities.filter {
                externalDisplayIDs.contains($0.key) && $0.value == displayIdentity(for: $0.key)
            }
            nativeBacklightDisplayIdentities.formIntersection(connectedExternalIdentities)
            nativeBrightnessReadsThisRefresh.removeAll(keepingCapacity: true)

            // Check DisplayServices only after explicit opt-in. A successful read identifies
            // Apple-managed external backlights so DDC discovery can skip VCP 0x10.
            if HardwareBrightnessManager.shared.isExternalNativeBrightnessActive {
                for displayID in externalDisplayIDs {
                    _ = nativeBrightnessReadResult(for: displayID, isBuiltIn: false)
                }
            }

            // Clean up HardwareBrightnessManager state for displays that disappeared
            for cachedID in HardwareBrightnessManager.shared.capabilities.keys
                where !externalDisplayIDs.contains(cachedID)
            {
                HardwareBrightnessManager.shared.removeDisplay(cachedID)
            }

            // Probe newly appeared external displays (hot-plug, or a display re-enumerated
            // under a new CGDirectDisplayID after sleep/wake) so DDC hardware control
            // becomes available without requiring a relaunch or a Settings toggle.
            if HardwareBrightnessManager.shared.isEnabled {
                let unprobedDisplayIDs = externalDisplayIDs
                    .filter { HardwareBrightnessManager.shared.capability(for: $0) == nil }
                if !unprobedDisplayIDs.isEmpty {
                    HardwareBrightnessManager.shared.probeAllDisplays(force: false)
                }
            }
        #endif

        let baseline = RefreshBaseline(
            savedBrightness: loadPersistedValues(forKey: persistenceKey),
            savedWarmth: loadPersistedValues(forKey: warmthPersistenceKey),
            savedContrast: loadPersistedValues(forKey: contrastPersistenceKey),
            displaysByID: Dictionary(uniqueKeysWithValues: displays.map { ($0.id, $0) }),
            displaysByIdentity: displays.reduce(into: [String: ExternalDisplay]()) { result, display in
                result[displayIdentity(for: display.id)] = display
            }
        )
        var newDisplays: [ExternalDisplay] = []
        var displaysWithSuppressedBrightnessWrite: Set<CGDirectDisplayID> = []

        for displayID in displayIDs {
            let refreshed = refreshedDisplay(for: displayID, baseline: baseline)
            if refreshed.suppressHardwareBrightnessWrite {
                displaysWithSuppressedBrightnessWrite.insert(displayID)
            }
            newDisplays.append(refreshed.display)
        }

        // Disambiguate identical display names by appending an index (e.g., "DELL S2723HC (1)")
        var nameCounts: [String: Int] = [:]
        for display in newDisplays {
            nameCounts[display.name, default: 0] += 1
        }
        let duplicatedNames = Set(nameCounts.filter { $0.value > 1 }.keys)
        if !duplicatedNames.isEmpty {
            var nameIndex: [String: Int] = [:]
            for i in newDisplays.indices {
                let name = newDisplays[i].name
                guard duplicatedNames.contains(name) else { continue }
                let index = (nameIndex[name] ?? 0) + 1
                nameIndex[name] = index
                newDisplays[i].name = "\(name) (\(index))"
            }
        }

        displays = newDisplays
        reapplyAfterRefresh(suppressingHardwareBrightnessWriteFor: displaysWithSuppressedBrightnessWrite)
    }

    /// The state a refresh is reconciled against: persisted values plus the displays as they
    /// were before re-enumeration. Grouped so `refreshedDisplay` stays a two-argument call.
    private struct RefreshBaseline {
        let savedBrightness: [String: Double]
        let savedWarmth: [String: Double]
        let savedContrast: [String: Double]
        let displaysByID: [CGDirectDisplayID: ExternalDisplay]
        let displaysByIdentity: [String: ExternalDisplay]
    }

    private func refreshedDisplay(
        for displayID: CGDirectDisplayID,
        baseline: RefreshBaseline
    ) -> (display: ExternalDisplay, suppressHardwareBrightnessWrite: Bool) {
        let builtIn = isBuiltInDisplay(displayID)
        let name = DisplayNameResolver.name(for: displayID)
        let identity = displayIdentity(for: displayID)
        let previousDisplay = baseline.displaysByIdentity[identity]
            ?? baseline.displaysByID[displayID]
            ?? (builtIn ? displays.first(where: \.isBuiltIn) : nil)
        let refreshedBrightness = refreshedBrightness(
            for: displayID,
            isBuiltIn: builtIn,
            savedBrightness: savedValue(baseline.savedBrightness, for: displayID, identity: identity),
            previousBrightness: previousDisplay?.brightness
        )
        let warmth = min(
            max(
                previousDisplay?.warmth
                    ?? savedValue(baseline.savedWarmth, for: displayID, identity: identity)
                    ?? 0.0,
                0.0
            ),
            1.0
        )
        let contrast = min(
            max(
                previousDisplay?.contrast
                    ?? savedValue(baseline.savedContrast, for: displayID, identity: identity)
                    ?? ExternalDisplay.neutralContrast,
                0.0
            ),
            1.0
        )
        var display = ExternalDisplay(
            id: displayID,
            name: name,
            brightness: refreshedBrightness.value,
            warmth: warmth,
            contrast: contrast
        )
        display.isBuiltIn = builtIn

        return (display, refreshedBrightness.suppressHardwareBrightnessWrite)
    }

    private func reapplyAfterRefresh(suppressingHardwareBrightnessWriteFor displayIDs: Set<CGDirectDisplayID>) {
        guard !isBlanking else { return }
        for display in displays {
            applyDisplayOutput(display, suppressHardwareBrightnessWrite: displayIDs.contains(display.id))
        }
    }

    private func refreshedBrightness(
        for displayID: CGDirectDisplayID,
        isBuiltIn: Bool,
        savedBrightness: Double?,
        previousBrightness: Double?
    ) -> (value: Double, suppressHardwareBrightnessWrite: Bool) {
        #if !APPSTORE
            if isBuiltIn {
                let fallback = previousBrightness ?? clampedBrightness(savedBrightness ?? 1.0)
                let fallbackActive = softwareBacklightFallbackDisplayIDs.contains(displayID)
                switch nativeBrightnessReadResult(for: displayID, isBuiltIn: true) {
                case let .value(hardwareBrightness):
                    if fallbackActive {
                        // A successful read is only a retry opportunity after a write failure;
                        // preserve the requested target until a native write accepts it.
                        return (fallback, false)
                    }
                    // Keep a live read exact and do not echo it back during refresh. Writing a
                    // low native value can fail redundantly and activate software fallback,
                    // which would then double-dim the already-low native backlight.
                    return (hardwareBrightness, true)
                case .unavailable:
                    softwareBacklightFallbackDisplayIDs.insert(displayID)
                    // An unavailable API is confirmed software-only, so gamma must deliver the
                    // preserved model value while native writes remain suppressed.
                    return (fallback, true)
                case .failed:
                    // A transient read failure is not evidence that native control is gone.
                    // Preserve the model, keep native gamma policy, and suppress the uncertain
                    // refresh write.
                    return (fallback, true)
                }
            }

            if supportsNativeBacklight(for: displayID) {
                let fallback = previousBrightness ?? clampedBrightness(savedBrightness ?? 1.0)
                let fallbackActive = hasExternalBacklightFallback(for: displayID)
                if fallbackActive {
                    // Retry the requested level after a transient native write failure.
                    return (clampedBrightness(fallback), false)
                }
                if let nativeBrightness = nativeBrightnessReadsThisRefresh[displayID] {
                    return (nativeBrightness, true)
                }
                // A transient read failure does not revoke eligibility or echo a stale target.
                return (clampedBrightness(fallback), true)
            }
        #endif

        #if !APPSTORE
            // A monitor keeps its own brightness and may have been changed with its buttons
            // while Dimmerly wasn't running, so a saved value only seeds the slider until the
            // first hardware read. It is written again once the user, a preset, or a schedule
            // sets a brightness this session.
            if previousBrightness == nil {
                unclaimedExternalBrightnessIdentities.insert(displayIdentity(for: displayID))
            }
        #endif
        // Like the built-in path, keep a live value exact: it can only be below the slider
        // minimum when it came from a hardware read, and raising it would brighten the panel.
        return (previousBrightness ?? clampedBrightness(savedBrightness ?? 1.0), false)
    }

    private func clampedBrightness(_ value: Double) -> Double {
        min(max(value, Self.minimumBrightness), 1.0)
    }

    /// Sets the brightness for a specific display.
    ///
    /// The value is clamped to [minimumBrightness, 1.0] to ensure displays remain visible
    /// and prevent gamma table errors. Changes are debounced (500ms) before persisting to UserDefaults.
    ///
    /// - Parameters:
    ///   - displayID: Core Graphics display identifier
    ///   - value: Desired brightness level (0.0–1.0), will be clamped to safe range
    /// - Note: If screen blanking is active, gamma changes are deferred until unblanking
    func setBrightness(for displayID: CGDirectDisplayID, to value: Double) {
        let clamped = clampedBrightness(value)

        guard let index = displays.firstIndex(where: { $0.id == displayID }) else { return }
        displays[index].brightness = clamped
        #if !APPSTORE
            unclaimedExternalBrightnessIdentities.remove(displayIdentity(for: displayID))
        #endif

        cancelActiveTransition()
        debouncePersist()
        applyDisplayOutput(displays[index])
    }

    /// Sets the color temperature warmth for a specific display.
    ///
    /// Warmth shifts the color temperature by adjusting RGB channel multipliers:
    /// - 0.0 = neutral (6500K, no shift)
    /// - 1.0 = warmest (1900K, reduces blue/green channels)
    ///
    /// - Parameters:
    ///   - displayID: Core Graphics display identifier
    ///   - value: Warmth level (0.0–1.0), will be clamped to valid range
    func setWarmth(for displayID: CGDirectDisplayID, to value: Double) {
        let clamped = clamp01(value)

        guard let index = displays.firstIndex(where: { $0.id == displayID }) else { return }
        // The change check gates the *side effects* only — it still prevents SwiftUI onChange
        // bounce-back from being mistaken for a manual override. Gamma is re-asserted either
        // way, because macOS wipes the gamma table during display wake and re-enumeration,
        // often after this app's wake handling has already finished. Skipping the write when
        // the value matches left the model believing warmth was applied while the panel sat
        // neutral, with no path back: auto colour temperature re-requests the same value every
        // 60 seconds, so every one of those repair opportunities became a no-op.
        let isChange = displays[index].warmth != clamped
        displays[index].warmth = clamped

        if isChange {
            if !isAutoColorTempUpdate {
                ColorTemperatureManager.shared.notifyManualWarmthChange()
                // Only cancel running transitions when the user is driving the change.
                // Auto-warmth updates call this for every display inside their own
                // animation loop; cancelling here would kill that animation.
                cancelActiveTransition()
            }
            debouncePersist()
        }

        applyDisplayGamma(displays[index])
    }

    /// Sets the contrast curve steepness for a specific display.
    ///
    /// Contrast controls the S-curve power function applied to gamma:
    /// - 0.0 = flat (reduced dynamic range)
    /// - 0.5 = neutral (linear, no adjustment)
    /// - 1.0 = steep (enhanced shadows and highlights)
    ///
    /// - Parameters:
    ///   - displayID: Core Graphics display identifier
    ///   - value: Contrast level (0.0–1.0), will be clamped to valid range
    func setContrast(for displayID: CGDirectDisplayID, to value: Double) {
        let clamped = clamp01(value)

        guard let index = displays.firstIndex(where: { $0.id == displayID }) else { return }
        displays[index].contrast = clamped

        cancelActiveTransition()
        debouncePersist()

        applyDisplayGamma(displays[index])
    }

    /// Cancels any in-progress preset/warmth transition so direct user input wins.
    ///
    /// Without this, a slider drag during an animated preset application would keep
    /// fighting the animation loop (which writes gamma each step) until the animation
    /// finished, producing a visible snap-back.
    private func cancelActiveTransition() {
        guard let activeTransition else { return }
        activeTransition.task.cancel()
        #if !APPSTORE
            // A cancelled animation may already have moved the model part-way toward a
            // hardware-backed preset. Commit that intermediate value before the competing user
            // edit wins, otherwise the model and the panel diverge until a later refresh.
            // A transition that never intended to touch hardware is left alone.
            synchronizeHardwareBrightnessAfterAnimation(for: activeTransition.hardwareBrightnessDisplayIDs)
        #endif
        self.activeTransition = nil
    }

    /// Re-applies the current brightness via gamma for a specific display.
    ///
    /// Called by HardwareBrightnessManager when DDC writes fail repeatedly and the display
    /// is downgraded to software-only control. This ensures the user doesn't lose brightness
    /// control when DDC becomes unreliable at runtime.
    func applyCurrentBrightness(for displayID: CGDirectDisplayID) {
        guard let display = displays.first(where: { $0.id == displayID }) else { return }
        applyDisplayGamma(display)
    }

    /// Reapplies gamma tables to all connected displays using their current settings.
    ///
    /// Called when:
    /// - Displays are refreshed (new displays connected)
    /// - System wakes from sleep (macOS resets gamma tables)
    /// - Screen blanking ends (restores pre-blanking state)
    func reapplyAll(except skippedDisplayIDs: Set<CGDirectDisplayID> = []) {
        for display in displays where !skippedDisplayIDs.contains(display.id) {
            applyDisplayOutput(display)
        }
    }

    // MARK: - Preset Transition

    /// Snapshot of start/end values for a single display in a running transition.
    ///
    /// A nil end value leaves that axis untouched, including changes received from hardware
    /// while a warmth-only animation is running.
    private struct TransitionTarget {
        let displayID: CGDirectDisplayID
        let start: (brightness: Double, warmth: Double, contrast: Double)
        let end: (brightness: Double?, warmth: Double?, contrast: Double?)
    }

    private static let transitionSteps = 20
    private static let transitionStepDelay = Duration.milliseconds(15)

    /// Smoothly transitions all displays from their current settings to a preset's target values.
    ///
    /// Animates brightness, warmth, and contrast simultaneously over ~300ms (20 steps at ~15ms each)
    /// using gamma table interpolation. Cancels any in-progress transition when called.
    ///
    /// Skips animation (returns `false`) when:
    /// - Screen blanking is active (gamma tables are zeroed)
    /// - Reduce Motion accessibility preference is enabled
    ///
    /// During animation, display state is updated each step so UI sliders track the transition.
    /// Persistence is deferred to a single write after the final step.
    ///
    /// - Parameter preset: The target preset to transition to
    /// - Returns: `true` if animation was started, `false` if the caller should apply instantly
    @discardableResult
    func animateToPreset(_ preset: BrightnessPreset) -> Bool {
        let targets: [TransitionTarget] = displays.map { display in
            // Per-display preset values are keyed by stable identity, with a fallback to the
            // legacy display-ID key so presets saved by earlier versions still resolve.
            let identity = displayIdentity(for: display.id)
            // A universal value applies to every display and wins over its own saved value.
            let target = { (universal: Double?, perDisplay: [String: Double]?) -> Double? in
                universal ?? perDisplay.flatMap { self.savedValue($0, for: display.id, identity: identity) }
            }
            return TransitionTarget(
                displayID: display.id,
                start: (display.brightness, display.warmth, display.contrast),
                end: (
                    target(preset.universalBrightness, preset.displayBrightness).map(clampedBrightness),
                    target(preset.universalWarmth, preset.displayWarmth).map(clamp01),
                    target(preset.universalContrast, preset.displayContrast).map(clamp01)
                )
            )
        }

        return runTransition(targets: targets)
    }

    /// Smoothly transitions all displays' warmth to a uniform target value.
    ///
    /// Animates over ~300ms (20 steps at ~15ms each), same timing as preset transitions.
    /// Brightness and contrast are left unchanged. Cancels any in-progress preset transition.
    ///
    /// - Parameter targetWarmth: The warmth value to transition to (0.0–1.0)
    /// - Returns: `true` if animation was started, `false` if the caller should apply instantly
    @discardableResult
    func animateAllWarmth(to targetWarmth: Double) -> Bool {
        let endWarmth = clamp01(targetWarmth)
        let targets = displays.map { display in
            TransitionTarget(
                displayID: display.id,
                start: (display.brightness, display.warmth, display.contrast),
                end: (nil, endWarmth, nil)
            )
        }
        return runTransition(targets: targets)
    }

    /// Smoothly transitions each display's warmth to per-display target values.
    ///
    /// Same animation as `animateAllWarmth(to:)` but with individual targets per display.
    ///
    /// - Parameter targetValues: Warmth values keyed by stable display identity (legacy ID fallback)
    /// - Returns: `true` if animation was started, `false` if the caller should apply instantly
    @discardableResult
    func animateWarmthValues(_ targetValues: [String: Double]) -> Bool {
        let targets: [TransitionTarget] = displays.compactMap { display in
            let identity = displayIdentity(for: display.id)
            guard let raw = savedValue(targetValues, for: display.id, identity: identity) else { return nil }
            return TransitionTarget(
                displayID: display.id,
                start: (display.brightness, display.warmth, display.contrast),
                end: (nil, clamp01(raw), nil)
            )
        }
        return runTransition(targets: targets)
    }

    /// Drives a 20-step gamma interpolation for a pre-computed set of targets.
    ///
    /// Skips animation when blanking is active or Reduce Motion is enabled. At the end, state
    /// is persisted and hardware brightness is synchronized only for displays with explicit
    /// brightness targets.
    private func runTransition(targets: [TransitionTarget]) -> Bool {
        cancelActiveTransition()

        let canAnimate = !isBlanking && (
            canAnimateTransitionsHook?() ?? !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        )
        guard canAnimate else {
            return false
        }

        let hardwareBrightnessDisplayIDs = Set(targets.compactMap { target in
            target.end.brightness == nil ? nil : target.displayID
        })
        #if !APPSTORE
            for displayID in hardwareBrightnessDisplayIDs {
                unclaimedExternalBrightnessIdentities.remove(displayIdentity(for: displayID))
            }
        #endif

        let task = Task { @MainActor in
            let steps = Self.transitionSteps

            for step in 1 ... steps {
                guard !Task.isCancelled else { return }

                let progress = Double(step) / Double(steps)

                for target in targets {
                    guard let index = displays.firstIndex(where: { $0.id == target.displayID }) else { continue }

                    if let brightness = target.end.brightness {
                        displays[index].brightness = target.start.brightness
                            + (brightness - target.start.brightness) * progress
                    }
                    if let warmth = target.end.warmth {
                        displays[index].warmth = target.start.warmth
                            + (warmth - target.start.warmth) * progress
                    }
                    if let contrast = target.end.contrast {
                        displays[index].contrast = target.start.contrast
                            + (contrast - target.start.contrast) * progress
                    }

                    // Blanking can begin after scheduling or between animation frames. Keep
                    // advancing the model, but leave gamma to the blanking fade while active.
                    if !isBlanking {
                        // Hardware brightness stays neutral in gamma while software brightness
                        // follows the interpolated model.
                        applyGamma(
                            displayID: target.displayID,
                            brightness: resolvedGammaBrightness(for: displays[index]),
                            warmth: displays[index].warmth,
                            contrast: displays[index].contrast
                        )
                    }
                }

                if step < steps {
                    try? await Task.sleep(for: Self.transitionStepDelay)
                }
            }

            guard !Task.isCancelled else { return }
            #if !APPSTORE
                synchronizeHardwareBrightnessAfterAnimation(for: hardwareBrightnessDisplayIDs)
            #endif
            persistAll()
            activeTransition = nil
        }
        activeTransition = (task, hardwareBrightnessDisplayIDs)

        return true
    }

    /// Debounces persistence to UserDefaults to prevent excessive writes during rapid changes.
    ///
    /// Typical use case: User dragging a brightness slider. Without debouncing, each slider
    /// movement would trigger a UserDefaults write (expensive I/O). Instead, we wait 500ms
    /// after the last change before persisting.
    ///
    /// Thread safety: Cancels any previous pending persist task before scheduling a new one.
    private func debouncePersist() {
        persistTask?.cancel()
        persistTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self.persistAll()
        }
    }

    // MARK: - Gamma

    /// Whether the current warmth change originated from the auto color temperature system.
    /// Used to prevent manual-override notifications when ColorTemperatureManager is applying warmth.
    var isAutoColorTempUpdate = false

    /// Applies a complete gamma table to a display (brightness + warmth + contrast combined).
    ///
    /// This method:
    /// 1. Calculates RGB channel multipliers for the warmth setting
    /// 2. Builds separate 256-entry gamma tables for R, G, and B channels
    /// 3. Applies all three tables atomically via CoreGraphics
    ///
    /// The return value from CGSetDisplayTransferByTable is intentionally ignored because:
    /// - There's no user-recoverable action on failure
    /// - Failures are extremely rare (only if display is disconnected mid-call)
    /// - The next refresh/wake cycle will retry automatically
    ///
    /// - Parameters:
    ///   - displayID: Core Graphics display identifier
    ///   - brightness: Brightness level (0.0–1.0)
    ///   - warmth: Color temperature warmth (0.0–1.0)
    ///   - contrast: Contrast curve steepness (0.0–1.0)
    private func applyGamma(displayID: CGDirectDisplayID, brightness: Double, warmth: Double, contrast: Double) {
        if let applyGammaHook {
            applyGammaHook(displayID, brightness, warmth, contrast)
            return
        }

        GammaMath.setTransferTables(for: displayID, brightness: brightness, warmth: warmth, contrast: contrast)
    }

    // MARK: - Persistence

    private func displayIdentity(for displayID: CGDirectDisplayID) -> String {
        if let displayIdentityHook {
            return displayIdentityHook(displayID)
        }
        return Self.persistenceIdentity(
            vendor: CGDisplayVendorNumber(displayID),
            model: CGDisplayModelNumber(displayID),
            serial: CGDisplaySerialNumber(displayID),
            unitNumber: CGDisplayUnitNumber(displayID),
            displayID: displayID
        )
    }

    /// Reads a saved value for a display, preferring its stable identity and falling back to the
    /// legacy display-ID key so settings written by earlier versions still load once.
    private func savedValue(
        _ saved: [String: Double],
        for displayID: CGDirectDisplayID,
        identity: String
    ) -> Double? {
        saved[identity] ?? saved[String(displayID)]
    }

    /// Per-display values saved under `key` (brightness, warmth, or contrast).
    private func loadPersistedValues(forKey key: String) -> [String: Double] {
        defaults.dictionary(forKey: key) as? [String: Double] ?? [:]
    }

    func persistAll() {
        var brightnessDict = loadPersistedValues(forKey: persistenceKey)
        var warmthDict = loadPersistedValues(forKey: warmthPersistenceKey)
        var contrastDict = loadPersistedValues(forKey: contrastPersistenceKey)
        for display in displays {
            // Keyed by stable identity, so the values are still found after the display is
            // re-enumerated under a different CGDirectDisplayID.
            let key = displayIdentity(for: display.id)
            let legacyKey = String(display.id)
            #if !APPSTORE
                // A persisted default would be restored as a claimed value after relaunch.
                if !unclaimedExternalBrightnessIdentities.contains(key) {
                    brightnessDict[key] = display.brightness
                }
            #else
                brightnessDict[key] = display.brightness
            #endif
            warmthDict[key] = display.warmth
            contrastDict[key] = display.contrast
            if key != legacyKey {
                // Migrate this connected display away from the old ephemeral ID key. Keep
                // unrelated legacy entries so disconnected displays can recover their settings.
                brightnessDict.removeValue(forKey: legacyKey)
                warmthDict.removeValue(forKey: legacyKey)
                contrastDict.removeValue(forKey: legacyKey)
            }
        }
        defaults.set(brightnessDict, forKey: persistenceKey)
        defaults.set(warmthDict, forKey: warmthPersistenceKey)
        defaults.set(contrastDict, forKey: contrastPersistenceKey)
    }

    #if !APPSTORE
        private func displayOutputPolicy(for display: ExternalDisplay) -> DisplayOutputPolicy {
            let hardwareManager = HardwareBrightnessManager.shared
            return DisplayOutputPolicy.resolve(
                mode: hardwareManager.controlMode,
                isBuiltIn: display.isBuiltIn,
                isDDCEnabled: hardwareManager.isEnabled,
                supportsDDCBrightness: hardwareManager.capability(for: display.id)?.supportsBrightness ?? false,
                supportsNativeBacklight: supportsNativeBacklight(for: display.id),
                experimentalNativeBrightnessEnabled: hardwareManager.experimentalNativeBrightnessEnabled,
                requestedBrightness: display.brightness,
                builtInBacklightAvailable: !softwareBacklightFallbackDisplayIDs.contains(display.id),
                nativeBacklightAvailable: !hasExternalBacklightFallback(for: display.id)
            )
        }

        /// Applies an accepted external hardware read to the authoritative display model.
        /// This intentionally does not call `setBrightness`, so polling never echoes a DDC read
        /// back into a write.
        func synchronizeExternalHardwareBrightness(for displayID: CGDirectDisplayID, to value: Double) {
            guard let index = displays.firstIndex(where: { $0.id == displayID }),
                  !displays[index].isBuiltIn,
                  !supportsNativeBacklight(for: displayID)
            else { return }

            // Mirror the built-in path: a hardware level below the slider minimum is real state,
            // not a request to raise.
            let brightness = clamp01(value)
            guard abs(displays[index].brightness - brightness) > 0.005 else { return }
            displays[index].brightness = brightness
            debouncePersist()
        }

        private func setExternalHardwareBrightness(for displayID: CGDirectDisplayID, to value: Double) {
            if let setExternalHardwareBrightnessHook {
                setExternalHardwareBrightnessHook(displayID, value)
                return
            }

            HardwareBrightnessManager.shared.setHardwareBrightness(for: displayID, to: value)
        }
    #endif

    private func resolvedGammaBrightness(for display: ExternalDisplay) -> Double {
        resolvedOutputPolicy(for: display).gammaBrightness
    }

    /// The output policy for a display, resolved against whichever control paths this build has.
    private func resolvedOutputPolicy(for display: ExternalDisplay) -> DisplayOutputPolicy {
        #if !APPSTORE
            displayOutputPolicy(for: display)
        #else
            DisplayOutputPolicy.resolve(requestedBrightness: display.brightness)
        #endif
    }

    private func applyDisplayGamma(_ display: ExternalDisplay, allowDuringBlanking: Bool = false) {
        guard allowDuringBlanking || !isBlanking else { return }

        applyGamma(
            displayID: display.id,
            brightness: resolvedOutputPolicy(for: display).gammaBrightness,
            warmth: display.warmth,
            contrast: display.contrast
        )
    }

    private func applyDisplayOutput(
        _ display: ExternalDisplay,
        allowDuringBlanking: Bool = false,
        suppressHardwareBrightnessWrite: Bool = false
    ) {
        #if !APPSTORE
            let output = displayOutputPolicy(for: display).output
            if output.writesBuiltInBacklight, !suppressHardwareBrightnessWrite {
                if setBuiltInBacklight(for: display.id, to: display.brightness) {
                    softwareBacklightFallbackDisplayIDs.remove(display.id)
                } else {
                    softwareBacklightFallbackDisplayIDs.insert(display.id)
                }
            } else if output.writesExternalBacklight, !suppressHardwareBrightnessWrite {
                externalBacklightFallbackIdentities[display.id] =
                    setExternalNativeBacklight(for: display.id, to: display.brightness)
                        ? nil : displayIdentity(for: display.id)
            } else if output == .ddc, !suppressHardwareBrightnessWrite,
                      !unclaimedExternalBrightnessIdentities.contains(displayIdentity(for: display.id))
            {
                setExternalHardwareBrightness(for: display.id, to: display.brightness)
            }
        #endif

        applyDisplayGamma(display, allowDuringBlanking: allowDuringBlanking)
    }

    private func isBuiltInDisplay(_ displayID: CGDirectDisplayID) -> Bool {
        isBuiltInDisplayHook?(displayID) ?? (CGDisplayIsBuiltin(displayID) != 0)
    }

    #if !APPSTORE
        /// Synchronizes hardware-backed brightness controls after a gamma-based animation completes.
        ///
        /// Animated preset transitions use gamma interpolation for smooth visuals. Once the
        /// animation finishes, we must commit the final brightness to the real hardware path
        /// so built-in backlight and DDC-backed displays match the app's final state.
        private func synchronizeHardwareBrightnessAfterAnimation(for displayIDs: Set<CGDirectDisplayID>) {
            for display in displays where displayIDs.contains(display.id) {
                applyDisplayOutput(display)
            }
        }
    #endif
}

/// Clamps a normalized display value to 0...1 without a brightness floor.
/// Brightness entering the slider range uses `clampedBrightness` instead.
private func clamp01(_ value: Double) -> Double {
    min(max(value, 0.0), 1.0)
}

// MARK: - Display Reconfiguration Callback

/// RAII wrapper for CoreGraphics display reconfiguration callback registration.
///
/// This class manages the lifecycle of a CGDisplayRegisterReconfigurationCallback registration,
/// automatically unregistering the callback on deinit. It safely bridges Swift closures to
/// C callback functions using Unmanaged pointer techniques.
///
/// Memory safety:
/// - The token is stored as a strong reference in BrightnessManager.reconfigurationToken
/// - Using `passUnretained` is safe because the token outlives the callback registration
/// - The callback only fires while the registration is active (before deinit)
/// - deinit removes the callback before the token is deallocated
///
/// Sendability:
/// - Marked `@unchecked Sendable` because CoreGraphics callbacks may fire on arbitrary threads
/// - The handler closure is `@Sendable`, ensuring thread-safe captures
/// - All operations (register, callback, unregister) are concurrency-safe
private final class DisplayReconfigurationToken: @unchecked Sendable {
    private let handler: @Sendable () -> Void

    /// Registers a display reconfiguration callback and stores the handler.
    ///
    /// - Parameter handler: Closure to invoke when displays are added/removed
    init(handler: @escaping @Sendable () -> Void) {
        self.handler = handler
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        CGDisplayRegisterReconfigurationCallback(
            displayReconfigurationCallback, pointer
        )
    }

    /// Automatically unregisters the callback when the token is deallocated.
    deinit {
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        CGDisplayRemoveReconfigurationCallback(
            displayReconfigurationCallback, pointer
        )
    }

    /// Called by the C callback function to invoke the Swift handler.
    fileprivate func reconfigured() {
        handler()
    }
}

/// Global C callback function for display reconfiguration events.
///
/// CoreGraphics requires a C function pointer (not a closure), so we use this global function
/// to bridge to Swift. The userInfo parameter contains an Unmanaged pointer to the token.
///
/// - Parameters:
///   - display: The display that changed (not used, we refresh all displays)
///   - flags: Change flags — add/remove (connect/disconnect) and mode changes
///     (resolution/refresh-rate) all trigger a refresh; other flags are ignored.
///   - userInfo: Unmanaged pointer to the DisplayReconfigurationToken
private func displayReconfigurationCallback(
    _: CGDirectDisplayID,
    _ flags: CGDisplayChangeSummaryFlags,
    _ userInfo: UnsafeMutableRawPointer?
) {
    // Handle display connection/disconnection, and mode changes (resolution/refresh-rate),
    // since some GPU drivers reset the gamma LUT on a mode change — without reacting here,
    // dimming/warmth would silently revert to native until the next add/remove event or wake.
    guard flags.contains(.addFlag) || flags.contains(.removeFlag) || flags.contains(.setModeFlag),
          let userInfo else { return }
    let token = Unmanaged<DisplayReconfigurationToken>.fromOpaque(userInfo).takeUnretainedValue()
    token.reconfigured()
}

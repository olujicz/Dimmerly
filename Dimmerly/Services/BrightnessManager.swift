//
//  BrightnessManager.swift
//  Dimmerly
//
//  Per-display software brightness control for external monitors.
//  Uses CoreGraphics gamma table APIs (App Store safe).
//

import AppKit
import CoreGraphics
import IOKit

/// Represents an external display with its current visual properties.
///
/// This model tracks per-display brightness, warmth (color temperature), and contrast
/// adjustments applied via CoreGraphics gamma tables. The built-in display is excluded.
struct ExternalDisplay: Identifiable, Sendable {
    /// Core Graphics display identifier (unique hardware ID)
    let id: CGDirectDisplayID
    /// Human-readable display name (e.g., "LG UltraFine 5K")
    let name: String
    /// Current brightness level (0.0 = dimmest allowed, 1.0 = full brightness)
    var brightness: Double
    /// Color temperature shift (0.0 = neutral/6500K, 1.0 = warmest/1900K)
    var warmth: Double = 0.0
    /// Contrast curve steepness (0.0 = flat, 0.5 = neutral/linear, 1.0 = steep S-curve)
    var contrast: Double = 0.5

    #if !APPSTORE
        /// Whether this display supports DDC/CI hardware control.
        /// Set during display enumeration by probing via HardwareBrightnessManager.
        var supportsDDC: Bool = false
    #endif
}

/// Manages software-based brightness, warmth, and contrast control for external displays.
///
/// This manager uses CoreGraphics gamma table APIs to adjust display output, which is:
/// - App Store safe (no private APIs or command-line tools required)
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
class BrightnessManager: ObservableObject {
    static let shared = BrightnessManager()

    /// Minimum allowed brightness to ensure displays remain visible.
    /// Prevents accidentally setting displays to pure black, which would require external controls to recover.
    static let minimumBrightness: Double = 0.10

    /// Currently connected external displays with their visual properties.
    /// Updated automatically when displays are connected/disconnected.
    @Published var displays: [ExternalDisplay] = []

    /// UserDefaults keys for persisting display settings
    private let persistenceKey = "dimmerlyDisplayBrightness"
    private let warmthPersistenceKey = "dimmerlyDisplayWarmth"
    private let contrastPersistenceKey = "dimmerlyDisplayContrast"

    /// Manages the CoreGraphics display reconfiguration callback registration
    private var reconfigurationToken: DisplayReconfigurationToken?

    /// Task for delayed gamma reapplication after system wake (allows macOS to stabilize)
    private var wakeTask: Task<Void, Never>?

    /// Task for debounced persistence to UserDefaults (prevents excessive writes during slider drags)
    private var persistTask: Task<Void, Never>?

    /// Active preset transition animation task (cancelled when a new transition starts)
    private var transitionTask: Task<Void, Never>?

    /// Standard initializer that sets up full hardware monitoring and system integration.
    /// Registers observers for display changes, wake events, and ScreenBlanker coordination.
    init() {
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
    /// - Parameter forTesting: Pass `true` to create an isolated test instance
    init(forTesting _: Bool) {
        // Skip hardware setup — no gamma changes, no observers
    }

    private func setupHardwareMonitoring() {
        refreshDisplays()

        // Re-apply gamma after wake (macOS resets gamma during wake)
        NotificationCenter.default.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleWake()
            }
        }

        // Detect display plug/unplug
        reconfigurationToken = DisplayReconfigurationToken { [weak self] in
            Task { @MainActor in
                self?.refreshDisplays()
            }
        }

        // Coordinate with ScreenBlanker — re-apply brightness after blanking ends
        ScreenBlanker.shared.onDismiss = { [weak self] in
            self?.reapplyAll()
        }

        // Provide per-display brightness to ScreenBlanker for fade animation
        ScreenBlanker.shared.brightnessForDisplay = { [weak self] displayID in
            self?.brightness(for: displayID) ?? 1.0
        }

        // Provide per-display warmth to ScreenBlanker for fade animation
        ScreenBlanker.shared.warmthForDisplay = { [weak self] displayID in
            self?.warmth(for: displayID) ?? 0.0
        }

        // Provide per-display contrast to ScreenBlanker for fade animation
        ScreenBlanker.shared.contrastForDisplay = { [weak self] displayID in
            self?.contrast(for: displayID) ?? 0.5
        }

        // Provide restore callback so ScreenBlanker can restore the full gamma table
        ScreenBlanker.shared.restoreDisplay = { [weak self] displayID in
            guard let self else { return }
            guard let display = self.displays.first(where: { $0.id == displayID }) else { return }
            self.applyGamma(
                displayID: displayID, brightness: display.brightness,
                warmth: display.warmth, contrast: display.contrast
            )
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
        displays.first(where: { $0.id == displayID })?.contrast ?? 0.5
    }

    /// Toggles blanking for a single display
    func toggleBlank(for displayID: CGDirectDisplayID) {
        if ScreenBlanker.shared.isDisplayBlanked(displayID) {
            ScreenBlanker.shared.unblankDisplay(displayID)
        } else {
            ScreenBlanker.shared.blankDisplay(displayID)
        }
        objectWillChange.send()
    }

    /// Returns a snapshot of current brightness values keyed by display ID string
    func currentBrightnessSnapshot() -> [String: Double] {
        var snapshot: [String: Double] = [:]
        for display in displays {
            snapshot[String(display.id)] = display.brightness
        }
        return snapshot
    }

    /// Sets all connected displays to the same brightness value
    func setAllBrightness(to value: Double) {
        for display in displays {
            setBrightness(for: display.id, to: value)
        }
    }

    /// Applies saved brightness values from a preset (skips missing displays)
    func applyBrightnessValues(_ values: [String: Double]) {
        for (idString, brightness) in values {
            guard let displayID = CGDirectDisplayID(idString) else { continue }
            setBrightness(for: displayID, to: brightness)
        }
    }

    /// Returns a snapshot of current warmth values keyed by display ID string
    func currentWarmthSnapshot() -> [String: Double] {
        var snapshot: [String: Double] = [:]
        for display in displays {
            snapshot[String(display.id)] = display.warmth
        }
        return snapshot
    }

    /// Sets all connected displays to the same warmth value
    func setAllWarmth(to value: Double) {
        for display in displays {
            setWarmth(for: display.id, to: value)
        }
    }

    /// Applies saved warmth values from a preset (skips missing displays)
    func applyWarmthValues(_ values: [String: Double]) {
        for (idString, warmth) in values {
            guard let displayID = CGDirectDisplayID(idString) else { continue }
            setWarmth(for: displayID, to: warmth)
        }
    }

    /// Returns a snapshot of current contrast values keyed by display ID string
    func currentContrastSnapshot() -> [String: Double] {
        var snapshot: [String: Double] = [:]
        for display in displays {
            snapshot[String(display.id)] = display.contrast
        }
        return snapshot
    }

    /// Sets all connected displays to the same contrast value
    func setAllContrast(to value: Double) {
        for display in displays {
            setContrast(for: display.id, to: value)
        }
    }

    /// Applies saved contrast values from a preset (skips missing displays)
    func applyContrastValues(_ values: [String: Double]) {
        for (idString, contrast) in values {
            guard let displayID = CGDirectDisplayID(idString) else { continue }
            setContrast(for: displayID, to: contrast)
        }
    }

    /// Refreshes the list of connected external displays and restores their saved settings.
    ///
    /// This method:
    /// 1. Enumerates all active displays via CoreGraphics
    /// 2. Filters out the built-in display (laptop screen)
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
        let displayIDs = Self.activeDisplayIDs()

        let savedBrightness = loadPersistedBrightness()
        let savedWarmth = loadPersistedWarmth()
        let savedContrast = loadPersistedContrast()
        var newDisplays: [ExternalDisplay] = []

        for displayID in displayIDs {
            // Skip built-in display (laptop screen) — only manage external monitors
            guard CGDisplayIsBuiltin(displayID) == 0 else { continue }

            let name = displayName(for: displayID)
            // Ensure brightness meets minimum threshold for visibility
            let brightness = Swift.max(savedBrightness[String(displayID)] ?? 1.0, Self.minimumBrightness)
            // Clamp warmth and contrast to valid ranges
            let warmth = min(max(savedWarmth[String(displayID)] ?? 0.0, 0.0), 1.0)
            let contrast = min(max(savedContrast[String(displayID)] ?? 0.5, 0.0), 1.0)

            var display = ExternalDisplay(
                id: displayID, name: name, brightness: brightness,
                warmth: warmth, contrast: contrast
            )

            #if !APPSTORE
                // Check DDC capability from HardwareBrightnessManager's cached probes
                display.supportsDDC = HardwareBrightnessManager.shared.supportsDDC(for: displayID)
            #endif

            newDisplays.append(display)
        }

        displays = newDisplays
        // Don't reapply gamma if blanking is active (would cause visible flicker)
        if !ScreenBlanker.shared.isBlanking {
            reapplyAll()
        }
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
        let clamped = min(Swift.max(value, Self.minimumBrightness), 1)

        guard let index = displays.firstIndex(where: { $0.id == displayID }) else { return }
        displays[index].brightness = clamped

        debouncePersist()

        // Don't apply gamma during blanking (would cause visible flicker)
        if !ScreenBlanker.shared.isBlanking {
            applyGamma(
                displayID: displayID, brightness: clamped,
                warmth: displays[index].warmth, contrast: displays[index].contrast
            )
        }
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
        let clamped = min(max(value, 0.0), 1.0)

        guard let index = displays.firstIndex(where: { $0.id == displayID }) else { return }
        // Skip if value hasn't changed — prevents SwiftUI onChange bounce-back from
        // falsely triggering a manual override when auto color temp updates warmth.
        guard displays[index].warmth != clamped else { return }
        displays[index].warmth = clamped

        if !isAutoColorTempUpdate {
            ColorTemperatureManager.shared.notifyManualWarmthChange()
        }

        debouncePersist()

        if !ScreenBlanker.shared.isBlanking {
            applyGamma(
                displayID: displayID, brightness: displays[index].brightness,
                warmth: clamped, contrast: displays[index].contrast
            )
        }
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
        let clamped = min(max(value, 0.0), 1.0)

        guard let index = displays.firstIndex(where: { $0.id == displayID }) else { return }
        displays[index].contrast = clamped

        debouncePersist()

        if !ScreenBlanker.shared.isBlanking {
            applyGamma(
                displayID: displayID, brightness: displays[index].brightness,
                warmth: displays[index].warmth, contrast: clamped
            )
        }
    }

    /// Reapplies gamma tables to all connected displays using their current settings.
    ///
    /// Called when:
    /// - Displays are refreshed (new displays connected)
    /// - System wakes from sleep (macOS resets gamma tables)
    /// - Screen blanking ends (restores pre-blanking state)
    func reapplyAll() {
        for display in displays {
            applyGamma(
                displayID: display.id, brightness: display.brightness,
                warmth: display.warmth, contrast: display.contrast
            )
        }
    }

    // MARK: - Preset Transition

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
        transitionTask?.cancel()

        guard !ScreenBlanker.shared.isBlanking,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        else {
            return false
        }

        transitionTask = Task { @MainActor in
            let steps = 20
            let stepDelay = Duration.milliseconds(15)

            // Snapshot current values and resolve target values per display
            struct Target {
                let displayID: CGDirectDisplayID
                let startBrightness: Double
                let startWarmth: Double
                let startContrast: Double
                let endBrightness: Double
                let endWarmth: Double
                let endContrast: Double
            }

            var targets: [Target] = []

            for display in displays {
                let idString = String(display.id)

                let endBrightness: Double
                if let universal = preset.universalBrightness {
                    endBrightness = max(universal, Self.minimumBrightness)
                } else if let value = preset.displayBrightness[idString] {
                    endBrightness = max(value, Self.minimumBrightness)
                } else {
                    endBrightness = display.brightness
                }

                let endWarmth: Double
                if let universal = preset.universalWarmth {
                    endWarmth = min(max(universal, 0), 1)
                } else if let values = preset.displayWarmth, let value = values[idString] {
                    endWarmth = min(max(value, 0), 1)
                } else {
                    endWarmth = display.warmth
                }

                let endContrast: Double
                if let universal = preset.universalContrast {
                    endContrast = min(max(universal, 0), 1)
                } else if let values = preset.displayContrast, let value = values[idString] {
                    endContrast = min(max(value, 0), 1)
                } else {
                    endContrast = display.contrast
                }

                targets.append(Target(
                    displayID: display.id,
                    startBrightness: display.brightness,
                    startWarmth: display.warmth,
                    startContrast: display.contrast,
                    endBrightness: endBrightness,
                    endWarmth: endWarmth,
                    endContrast: endContrast
                ))
            }

            for step in 1 ... steps {
                guard !Task.isCancelled else { return }

                let progress = Double(step) / Double(steps)

                for target in targets {
                    guard let index = displays.firstIndex(where: { $0.id == target.displayID }) else { continue }

                    let brightness = target.startBrightness + (target.endBrightness - target.startBrightness) * progress
                    let warmth = target.startWarmth + (target.endWarmth - target.startWarmth) * progress
                    let contrast = target.startContrast + (target.endContrast - target.startContrast) * progress

                    displays[index].brightness = brightness
                    displays[index].warmth = warmth
                    displays[index].contrast = contrast

                    applyGamma(displayID: target.displayID, brightness: brightness, warmth: warmth, contrast: contrast)
                }

                if step < steps {
                    try? await Task.sleep(for: stepDelay)
                }
            }

            guard !Task.isCancelled else { return }
            persistAll()
        }

        return true
    }

    /// Smoothly transitions all displays' warmth to a uniform target value.
    ///
    /// Animates over ~300ms (20 steps at ~15ms each), same timing as preset transitions.
    /// Brightness and contrast are left unchanged. Cancels any in-progress preset transition.
    ///
    /// Skips animation (returns `false`) when:
    /// - Screen blanking is active
    /// - Reduce Motion accessibility preference is enabled
    ///
    /// - Parameter targetWarmth: The warmth value to transition to (0.0–1.0)
    /// - Returns: `true` if animation was started, `false` if the caller should apply instantly
    @discardableResult
    func animateAllWarmth(to targetWarmth: Double) -> Bool {
        transitionTask?.cancel()

        guard !ScreenBlanker.shared.isBlanking,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        else {
            return false
        }

        let endWarmth = min(max(targetWarmth, 0), 1)

        transitionTask = Task { @MainActor in
            let steps = 20
            let stepDelay = Duration.milliseconds(15)

            struct WarmthTarget {
                let displayID: CGDirectDisplayID
                let start: Double
                let end: Double
            }

            let targets = displays.map { display in
                WarmthTarget(displayID: display.id, start: display.warmth, end: endWarmth)
            }

            for step in 1 ... steps {
                guard !Task.isCancelled else { return }

                let progress = Double(step) / Double(steps)

                for target in targets {
                    guard let index = displays.firstIndex(where: { $0.id == target.displayID }) else { continue }

                    let warmth = target.start + (target.end - target.start) * progress
                    displays[index].warmth = warmth

                    applyGamma(
                        displayID: target.displayID,
                        brightness: displays[index].brightness,
                        warmth: warmth,
                        contrast: displays[index].contrast
                    )
                }

                if step < steps {
                    try? await Task.sleep(for: stepDelay)
                }
            }

            guard !Task.isCancelled else { return }
            persistAll()
        }

        return true
    }

    /// Smoothly transitions each display's warmth to per-display target values.
    ///
    /// Same animation as `animateAllWarmth(to:)` but with individual targets per display.
    ///
    /// - Parameter targetValues: Warmth values keyed by display ID string
    /// - Returns: `true` if animation was started, `false` if the caller should apply instantly
    @discardableResult
    func animateWarmthValues(_ targetValues: [String: Double]) -> Bool {
        transitionTask?.cancel()

        guard !ScreenBlanker.shared.isBlanking,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        else {
            return false
        }

        transitionTask = Task { @MainActor in
            let steps = 20
            let stepDelay = Duration.milliseconds(15)

            struct WarmthTarget {
                let displayID: CGDirectDisplayID
                let start: Double
                let end: Double
            }

            let targets = displays.compactMap { display -> WarmthTarget? in
                let idString = String(display.id)
                guard let endWarmth = targetValues[idString] else { return nil }
                return WarmthTarget(displayID: display.id, start: display.warmth, end: min(max(endWarmth, 0), 1))
            }

            for step in 1 ... steps {
                guard !Task.isCancelled else { return }

                let progress = Double(step) / Double(steps)

                for target in targets {
                    guard let index = displays.firstIndex(where: { $0.id == target.displayID }) else { continue }

                    let warmth = target.start + (target.end - target.start) * progress
                    displays[index].warmth = warmth

                    applyGamma(
                        displayID: target.displayID,
                        brightness: displays[index].brightness,
                        warmth: warmth,
                        contrast: displays[index].contrast
                    )
                }

                if step < steps {
                    try? await Task.sleep(for: stepDelay)
                }
            }

            guard !Task.isCancelled else { return }
            persistAll()
        }

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

    /// Handles system wake events by reapplying gamma tables after a stabilization delay.
    ///
    /// macOS resets display gamma tables during wake, so we must reapply our settings.
    /// The 1-second delay allows the system to complete its display reconfiguration
    /// before we make changes (prevents race conditions and flicker).
    ///
    /// Multiple wake events (rare but possible) are coalesced by canceling previous tasks.
    private func handleWake() {
        // Cancel any previous wake task to avoid stacking delayed reapplications
        wakeTask?.cancel()
        wakeTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            reapplyAll()
        }
    }

    // MARK: - Display Enumeration

    /// Returns all active display IDs. Shared helper for display enumeration.
    static func activeDisplayIDs() -> [CGDirectDisplayID] {
        var displayIDs = [CGDirectDisplayID](repeating: 0, count: 16)
        var displayCount: UInt32 = 0

        guard CGGetActiveDisplayList(UInt32(displayIDs.count), &displayIDs, &displayCount) == .success else {
            return []
        }

        return Array(displayIDs.prefix(Int(displayCount)))
    }

    // MARK: - Gamma

    /// Whether the current warmth change originated from the auto color temperature system.
    /// Used to prevent manual-override notifications when ColorTemperatureManager is applying warmth.
    var isAutoColorTempUpdate = false

    /// Calculates RGB values for a color temperature using Tanner Helland's blackbody approximation.
    ///
    /// Algorithm source: http://www.tannerhelland.com/4435/convert-temperature-rgb-algorithm-code/
    /// Based on blackbody radiation curves, approximated with piecewise polynomials.
    ///
    /// - Parameter kelvin: Color temperature in Kelvin (1000–40000, clamped internally)
    /// - Returns: RGB values normalized to 0.0–1.0
    static func rgbFromKelvin(_ kelvin: Double) -> (r: Double, g: Double, b: Double) {
        let temp = min(max(kelvin, 1000), 40000) / 100.0

        // Red
        let r: Double
        if temp <= 66 {
            r = 1.0
        } else {
            let x = temp - 60
            r = min(max(329.698727446 * pow(x, -0.1332047592) / 255.0, 0), 1)
        }

        // Green
        let g: Double
        if temp <= 66 {
            let x = temp
            g = min(max((99.4708025861 * log(x) - 161.1195681661) / 255.0, 0), 1)
        } else {
            let x = temp - 60
            g = min(max(288.1221695283 * pow(x, -0.0755148492) / 255.0, 0), 1)
        }

        // Blue
        let b: Double
        if temp >= 66 {
            b = 1.0
        } else if temp <= 19 {
            b = 0.0
        } else {
            let x = temp - 10
            b = min(max((138.5177312231 * log(x) - 305.0447927307) / 255.0, 0), 1)
        }

        return (r: r, g: g, b: b)
    }

    /// Maps a warmth value (0.0–1.0) to a color temperature in Kelvin.
    ///
    /// - 0.0 → 6500K (neutral daylight)
    /// - 1.0 → 1900K (very warm candlelight)
    ///
    /// - Parameter warmth: Warmth level (0.0 = neutral, 1.0 = warmest)
    /// - Returns: Color temperature in Kelvin
    static func kelvinForWarmth(_ warmth: Double) -> Double {
        6500.0 - warmth * (6500.0 - 1900.0)
    }

    /// Maps a color temperature in Kelvin to a warmth value (0.0–1.0).
    ///
    /// Inverse of `kelvinForWarmth(_:)`.
    ///
    /// - Parameter kelvin: Color temperature in Kelvin
    /// - Returns: Warmth level (0.0 = neutral/6500K, 1.0 = warmest/1900K)
    static func warmthForKelvin(_ kelvin: Double) -> Double {
        (6500.0 - kelvin) / (6500.0 - 1900.0)
    }

    /// Calculates RGB channel multipliers for a given warmth level using blackbody radiation.
    ///
    /// Uses the Helland algorithm to produce physically-based color temperature shifts,
    /// normalized against the 6500K reference point so that warmth=0 produces (1, 1, 1).
    ///
    /// - At warmth=0.0: (r=1.0, g=1.0, b=1.0) — neutral white, 6500K
    /// - At warmth=1.0: ~1900K warm candlelight
    ///
    /// - Parameter warmth: Warmth level (0.0 = neutral, 1.0 = warmest)
    /// - Returns: RGB channel multipliers as a tuple
    static func channelMultipliers(for warmth: Double) -> (r: Double, g: Double, b: Double) {
        guard warmth > 0 else { return (r: 1.0, g: 1.0, b: 1.0) }

        let kelvin = kelvinForWarmth(warmth)
        let target = rgbFromKelvin(kelvin)
        let reference = rgbFromKelvin(6500)

        return (
            r: min(target.r / reference.r, 1.0),
            g: min(target.g / reference.g, 1.0),
            b: min(target.b / reference.b, 1.0)
        )
    }

    /// Applies an S-curve contrast adjustment using a split power function.
    ///
    /// The curve creates symmetric enhancement that:
    /// - Darkens shadows and brightens highlights when contrast > 0.5 (steeper slopes)
    /// - Reduces dynamic range when contrast < 0.5 (gentler slopes, "flat" look)
    /// - Acts as identity (no change) when contrast = 0.5 (neutral/linear)
    ///
    /// Mathematical approach:
    /// - Exponent scales from 0.11 (flat) to 9.0 (steep) via `pow(3, (contrast-0.5)*2)`
    /// - Split at midpoint (0.5) for symmetric S-curve behavior
    /// - Power functions preserve smooth gradients (no banding artifacts)
    ///
    /// - Parameters:
    ///   - t: Normalized input value [0.0, 1.0]
    ///   - contrast: Contrast level (0.0=flat, 0.5=neutral, 1.0=steep)
    /// - Returns: Adjusted value [0.0, 1.0] after applying contrast curve
    static func applyContrast(_ t: Double, contrast: Double) -> Double {
        // Fast path: neutral contrast is identity function
        guard contrast != 0.5 else { return t }

        let exponent = pow(3.0, (contrast - 0.5) * 2.0)
        if t < 0.5 {
            // Lower half: compress/expand shadows
            return 0.5 * pow(2.0 * t, exponent)
        } else {
            // Upper half: compress/expand highlights (mirrored)
            return 1.0 - 0.5 * pow(2.0 * (1.0 - t), exponent)
        }
    }

    /// Builds a 256-entry gamma lookup table for a single color channel.
    ///
    /// The table is constructed by:
    /// 1. Generating normalized values [0.0, 1.0] for each entry (i/255)
    /// 2. Applying the contrast S-curve transformation
    /// 3. Scaling by brightness and channel multiplier (for warmth)
    ///
    /// CoreGraphics uses these tables to remap output values:
    /// `output = table[input_byte]` for each pixel channel.
    ///
    /// - Parameters:
    ///   - brightness: Overall brightness scale (0.0–1.0)
    ///   - channelMultiplier: RGB channel multiplier (from warmth calculation)
    ///   - contrast: Contrast level for S-curve transformation
    /// - Returns: 256-entry array of gamma values
    static func buildTable(brightness: Double, channelMultiplier: Double, contrast: Double) -> [CGGammaValue] {
        let scale = brightness * channelMultiplier
        return (0 ..< 256).map { i in
            let t = Double(i) / 255.0
            let curved = applyContrast(t, contrast: contrast)
            return CGGammaValue(curved * scale)
        }
    }

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
        let m = Self.channelMultipliers(for: warmth)
        var rTable = Self.buildTable(brightness: brightness, channelMultiplier: m.r, contrast: contrast)
        var gTable = Self.buildTable(brightness: brightness, channelMultiplier: m.g, contrast: contrast)
        var bTable = Self.buildTable(brightness: brightness, channelMultiplier: m.b, contrast: contrast)

        // Return value intentionally ignored — no recovery action if gamma set fails
        CGSetDisplayTransferByTable(displayID, 256, &rTable, &gTable, &bTable)
    }

    // MARK: - Display Name

    /// Determines the human-readable name for a display using a multi-stage fallback approach.
    ///
    /// Display naming is challenging because:
    /// - macOS only maintains display names for popular models in common locales
    /// - Unsupported locales receive generic "Unknown Display" fallbacks
    /// - EDID data is available but requires IOKit parsing
    /// - Different Mac architectures (Intel vs Apple Silicon) expose data differently
    ///
    /// Resolution strategy:
    /// 1. **NSScreen.localizedName** — Fast, localized, works for ~90% of displays
    /// 2. **Apple's display override plist** — English fallback for unsupported locales
    /// 3. **EDID binary parsing via IOKit** — Raw monitor data
    ///    (Intel: IODisplayConnect, Apple Silicon: IOPortTransportStateDisplayPort)
    /// 4. **Localized "Unknown Display"** — Last resort
    ///
    /// - Parameter displayID: Core Graphics display identifier
    /// - Returns: Best available human-readable display name
    private func displayName(for displayID: CGDirectDisplayID) -> String {
        // Stage 1: Try NSScreen.localizedName (works for most locales and displays)
        for screen in NSScreen.screens {
            let key = NSDeviceDescriptionKey("NSScreenNumber")
            if let screenNumber = screen.deviceDescription[key] as? CGDirectDisplayID,
               screenNumber == displayID
            {
                let name = screen.localizedName
                // Detect generic fallbacks (e.g., "Unknown Display" in various languages)
                // If we get a generic name, continue to stages 2-3 for a better result
                if !looksLikeGenericDisplayName(name) {
                    return name
                }
            }
        }

        // Stage 2: Read English name from Apple's display override database
        // (Better than generic fallback for unsupported locales like Serbian)
        if let name = displayNameFromOverrides(for: displayID) {
            return name
        }

        // Stage 3: Parse EDID binary data via IOKit (low-level hardware query)
        if let name = edidDisplayName(for: displayID) {
            return name
        }

        // Stage 4: Give up and return localized "Unknown Display"
        return NSLocalizedString("Unknown Display", comment: "Fallback name when macOS cannot identify the display")
    }

    /// Checks if a display name appears to be a generic fallback rather than a real model name.
    ///
    /// When macOS doesn't recognize a display model or locale, it returns generic strings like
    /// "Unknown Display" in various languages. We detect these patterns to trigger deeper
    /// fallback logic (override plist or EDID parsing).
    ///
    /// - Parameter name: Display name to check
    /// - Returns: `true` if the name looks generic (should try harder to resolve)
    private func looksLikeGenericDisplayName(_ name: String) -> Bool {
        let lowercased = name.lowercased()
        // Check for "unknown" patterns across multiple languages
        return lowercased.contains("unknown") ||
            lowercased.contains("unbekannt") || // German
            lowercased.contains("inconnu") || // French
            lowercased.contains("desconocid") || // Spanish
            lowercased.contains("sconosciut") || // Italian
            lowercased.contains("onbekend") || // Dutch
            lowercased.contains("desconhecid") || // Portuguese
            lowercased.contains("不明") || // Japanese
            lowercased.contains("未知") || // Chinese
            lowercased.contains("알 수 없") || // Korean
            lowercased.contains("nepoznat") // Serbian
    }

    /// Reads the display product name from Apple's display override plist database.
    ///
    /// macOS maintains a database of known displays at:
    /// `/System/Library/Displays/Contents/Resources/Overrides/DisplayVendorID-*/DisplayProductID-*`
    ///
    /// These plists contain English (and sometimes localized) display names that ship with macOS.
    /// This is a good fallback when NSScreen.localizedName returns a generic string.
    ///
    /// - Parameter displayID: Core Graphics display identifier
    /// - Returns: Display name from override plist, or `nil` if not found
    private func displayNameFromOverrides(for displayID: CGDirectDisplayID) -> String? {
        let vendorHex = String(format: "%x", CGDisplayVendorNumber(displayID))
        let productHex = String(format: "%x", CGDisplayModelNumber(displayID))
        let basePath = "/System/Library/Displays/Contents/Resources/Overrides"
        let path = "\(basePath)/DisplayVendorID-\(vendorHex)/DisplayProductID-\(productHex)"

        guard let dict = NSDictionary(contentsOfFile: path) as? [String: Any] else {
            return nil
        }

        // DisplayProductName can be either a plain string or a localized dictionary
        if let name = dict["DisplayProductName"] as? String, !name.isEmpty {
            return name
        }
        if let names = dict["DisplayProductName"] as? [String: String],
           let name = names.values.first, !name.isEmpty
        {
            return name
        }
        return nil
    }

    /// Extracts the display name from EDID data via IOKit (architecture-aware fallback).
    ///
    /// EDID (Extended Display Identification Data) is a binary blob that all monitors provide,
    /// containing the manufacturer-set display name. However, its location in the IOKit registry
    /// differs by Mac architecture:
    /// - **Apple Silicon**: IOPortTransportStateDisplayPort services
    /// - **Intel Macs**: IODisplayConnect services
    ///
    /// This method tries Apple Silicon first (more common for newer Macs), then falls back to Intel.
    ///
    /// - Parameter displayID: Core Graphics display identifier
    /// - Returns: Display name parsed from EDID, or `nil` if not found
    private func edidDisplayName(for displayID: CGDirectDisplayID) -> String? {
        let targetModel = Int(CGDisplayModelNumber(displayID))

        // Apple Silicon: display info lives under IOPortTransportStateDisplayPort
        if let name = displayNameFromTransportService(matchingProductID: targetModel) {
            return name
        }

        // Intel Macs: display info lives under IODisplayConnect
        let targetVendor = Int(CGDisplayVendorNumber(displayID))
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("IODisplayConnect"),
            &iterator
        ) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }

        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer {
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }

            var properties: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let dict = properties?.takeRetainedValue() as? [String: Any]
            else {
                continue
            }

            guard let vendorID = dict["DisplayVendorID"] as? Int,
                  let productID = dict["DisplayProductID"] as? Int,
                  targetVendor == vendorID, targetModel == productID
            else {
                continue
            }

            if let info = IODisplayCreateInfoDictionary(service, 0)?.takeRetainedValue() as? [String: Any],
               let names = info["DisplayProductName"] as? [String: String],
               let name = names.values.first, !name.isEmpty
            {
                return name
            }

            if let edidData = dict["IODisplayEDID"] as? Data,
               let name = parseEDIDName(edidData)
            {
                return name
            }
        }

        return nil
    }

    /// Reads display product name from IOPortTransportStateDisplayPort services (Apple Silicon).
    ///
    /// On Apple Silicon Macs, display information is exposed through port transport services
    /// in the IOKit registry. This method:
    /// 1. Enumerates all IOPortTransportStateDisplayPort services
    /// 2. Matches by ProductID (corresponds to CGDisplayModelNumber)
    /// 3. Extracts ProductName or EDID data from service properties
    ///
    /// - Parameter targetModel: Display model number from CoreGraphics
    /// - Returns: Display name if found, otherwise `nil`
    private func displayNameFromTransportService(matchingProductID targetModel: Int) -> String? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("IOPortTransportStateDisplayPort"),
            &iterator
        ) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }

        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer {
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }

            var properties: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let dict = properties?.takeRetainedValue() as? [String: Any]
            else {
                continue
            }

            // Match by ProductID (corresponds to CGDisplayModelNumber)
            guard let productID = dict["ProductID"] as? Int,
                  productID == targetModel
            else {
                continue
            }

            // Read ProductName directly from the service properties
            if let name = dict["ProductName"] as? String, !name.isEmpty {
                return name
            }

            // Fall back to EDID binary from the service or its Metadata
            if let edidData = dict["EDID"] as? Data,
               let name = parseEDIDName(edidData)
            {
                return name
            }
            if let metadata = dict["Metadata"] as? [String: Any],
               let edidData = metadata["EDID"] as? Data,
               let name = parseEDIDName(edidData)
            {
                return name
            }
        }

        return nil
    }

    /// Parses the monitor name from raw EDID binary data.
    ///
    /// EDID (Extended Display Identification Data) is a 128+ byte binary structure that
    /// monitors provide via DDC/EDID protocols. The standard defines 4 descriptor blocks
    /// at offset 54, each 18 bytes long.
    ///
    /// Display name format (descriptor tag 0xFC):
    /// - Bytes 0-2: Always 0x00 (marks as descriptor, not detailed timing)
    /// - Byte 3: Descriptor type tag (0xFC = display name)
    /// - Byte 4: Reserved (0x00)
    /// - Bytes 5-17: 13 ASCII characters (padded with spaces or 0x0A)
    ///
    /// Reference: VESA Enhanced Extended Display Identification Data Standard (E-EDID)
    ///
    /// - Parameter edid: Raw EDID binary data from IOKit
    /// - Returns: ASCII monitor name if found and valid, otherwise `nil`
    private func parseEDIDName(_ edid: Data) -> String? {
        guard edid.count >= 128 else { return nil }

        // EDID has 4 descriptor blocks of 18 bytes each, starting at byte 54
        for i in 0 ..< 4 {
            let offset = 54 + (i * 18)
            guard offset + 17 < edid.count else { continue }

            // Monitor descriptor signature: bytes 0-2 are 0x00, byte 3 is the tag
            // Tag 0xFC = Display Product Name descriptor
            if edid[offset] == 0, edid[offset + 1] == 0, edid[offset + 2] == 0, edid[offset + 3] == 0xFC {
                // Name is in bytes 5-17 (13 chars max), padded with 0x0A (newline) or spaces
                let nameBytes = edid[(offset + 5) ... (offset + 17)]
                if let name = String(bytes: nameBytes, encoding: .ascii)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\n\r\0")),
                    !name.isEmpty
                {
                    return name
                }
            }
        }

        return nil
    }

    // MARK: - Persistence

    private func loadPersistedBrightness() -> [String: Double] {
        UserDefaults.standard.dictionary(forKey: persistenceKey) as? [String: Double] ?? [:]
    }

    private func loadPersistedWarmth() -> [String: Double] {
        UserDefaults.standard.dictionary(forKey: warmthPersistenceKey) as? [String: Double] ?? [:]
    }

    private func loadPersistedContrast() -> [String: Double] {
        UserDefaults.standard.dictionary(forKey: contrastPersistenceKey) as? [String: Double] ?? [:]
    }

    private func persistAll() {
        var brightnessDict: [String: Double] = [:]
        var warmthDict: [String: Double] = [:]
        var contrastDict: [String: Double] = [:]
        for display in displays {
            brightnessDict[String(display.id)] = display.brightness
            warmthDict[String(display.id)] = display.warmth
            contrastDict[String(display.id)] = display.contrast
        }
        UserDefaults.standard.set(brightnessDict, forKey: persistenceKey)
        UserDefaults.standard.set(warmthDict, forKey: warmthPersistenceKey)
        UserDefaults.standard.set(contrastDict, forKey: contrastPersistenceKey)
    }
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
///   - flags: Change flags (we only care about add/remove, not mode changes)
///   - userInfo: Unmanaged pointer to the DisplayReconfigurationToken
private func displayReconfigurationCallback(
    _: CGDirectDisplayID,
    _ flags: CGDisplayChangeSummaryFlags,
    _ userInfo: UnsafeMutableRawPointer?
) {
    // Only handle display connection/disconnection (ignore resolution/rotation changes)
    guard flags.contains(.addFlag) || flags.contains(.removeFlag) else { return }
    guard let userInfo else { return }
    let token = Unmanaged<DisplayReconfigurationToken>.fromOpaque(userInfo).takeUnretainedValue()
    token.reconfigured()
}

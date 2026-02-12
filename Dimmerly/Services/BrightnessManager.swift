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

struct ExternalDisplay: Identifiable, Sendable {
    let id: CGDirectDisplayID
    let name: String
    var brightness: Double // 0.0–1.0
    var warmth: Double = 0.0 // 0.0 (neutral) – 1.0 (warmest)
    var contrast: Double = 0.5 // 0.0 (flat) – 1.0 (steep), 0.5 = neutral/linear
}

@MainActor
class BrightnessManager: ObservableObject {
    static let shared = BrightnessManager()
    static let minimumBrightness: Double = 0.10

    @Published var displays: [ExternalDisplay] = []

    private let persistenceKey = "dimmerlyDisplayBrightness"
    private let warmthPersistenceKey = "dimmerlyDisplayWarmth"
    private let contrastPersistenceKey = "dimmerlyDisplayContrast"
    private var reconfigurationToken: DisplayReconfigurationToken?
    private var wakeTask: Task<Void, Never>?
    private var persistTask: Task<Void, Never>?

    init() {
        setupHardwareMonitoring()
    }

    /// Creates a BrightnessManager without hardware interaction, for unit testing
    init(forTesting: Bool) {
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
            self.applyGamma(displayID: displayID, brightness: display.brightness, warmth: display.warmth, contrast: display.contrast)
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

    func refreshDisplays() {
        let displayIDs = Self.activeDisplayIDs()

        let savedBrightness = loadPersistedBrightness()
        let savedWarmth = loadPersistedWarmth()
        let savedContrast = loadPersistedContrast()
        var newDisplays: [ExternalDisplay] = []

        for displayID in displayIDs {
            guard CGDisplayIsBuiltin(displayID) == 0 else { continue }

            let name = displayName(for: displayID)
            let brightness = Swift.max(savedBrightness[String(displayID)] ?? 1.0, Self.minimumBrightness)
            let warmth = min(max(savedWarmth[String(displayID)] ?? 0.0, 0.0), 1.0)
            let contrast = min(max(savedContrast[String(displayID)] ?? 0.5, 0.0), 1.0)
            newDisplays.append(ExternalDisplay(id: displayID, name: name, brightness: brightness, warmth: warmth, contrast: contrast))
        }

        displays = newDisplays
        if !ScreenBlanker.shared.isBlanking {
            reapplyAll()
        }
    }

    func setBrightness(for displayID: CGDirectDisplayID, to value: Double) {
        let clamped = min(Swift.max(value, Self.minimumBrightness), 1)

        guard let index = displays.firstIndex(where: { $0.id == displayID }) else { return }
        displays[index].brightness = clamped

        debouncePersist()

        if !ScreenBlanker.shared.isBlanking {
            applyGamma(displayID: displayID, brightness: clamped, warmth: displays[index].warmth, contrast: displays[index].contrast)
        }
    }

    func setWarmth(for displayID: CGDirectDisplayID, to value: Double) {
        let clamped = min(max(value, 0.0), 1.0)

        guard let index = displays.firstIndex(where: { $0.id == displayID }) else { return }
        displays[index].warmth = clamped

        debouncePersist()

        if !ScreenBlanker.shared.isBlanking {
            applyGamma(displayID: displayID, brightness: displays[index].brightness, warmth: clamped, contrast: displays[index].contrast)
        }
    }

    func setContrast(for displayID: CGDirectDisplayID, to value: Double) {
        let clamped = min(max(value, 0.0), 1.0)

        guard let index = displays.firstIndex(where: { $0.id == displayID }) else { return }
        displays[index].contrast = clamped

        debouncePersist()

        if !ScreenBlanker.shared.isBlanking {
            applyGamma(displayID: displayID, brightness: displays[index].brightness, warmth: displays[index].warmth, contrast: clamped)
        }
    }

    func reapplyAll() {
        for display in displays {
            applyGamma(displayID: display.id, brightness: display.brightness, warmth: display.warmth, contrast: display.contrast)
        }
    }

    private func debouncePersist() {
        persistTask?.cancel()
        persistTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s
            guard !Task.isCancelled else { return }
            self.persistAll()
        }
    }

    private func handleWake() {
        // Cancel any previous wake task to avoid stacking
        wakeTask?.cancel()
        wakeTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second delay
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

    /// Channel multipliers for the given warmth value.
    /// At warmth=0: (1, 1, 1) — neutral.  At warmth=1: (1, 0.82, 0.56) — ~2700K.
    static func channelMultipliers(for warmth: Double) -> (r: Double, g: Double, b: Double) {
        (r: 1.0, g: 1.0 - warmth * 0.18, b: 1.0 - warmth * 0.44)
    }

    /// Applies an S-curve contrast adjustment to a normalized input value.
    /// contrast: 0.0 (lowest/flat) to 1.0 (highest/steep), 0.5 = neutral (linear).
    static func applyContrast(_ t: Double, contrast: Double) -> Double {
        guard contrast != 0.5 else { return t }
        let exponent = pow(3.0, (contrast - 0.5) * 2.0)
        if t < 0.5 {
            return 0.5 * pow(2.0 * t, exponent)
        } else {
            return 1.0 - 0.5 * pow(2.0 * (1.0 - t), exponent)
        }
    }

    /// Builds a 256-entry gamma lookup table for one channel.
    private static func buildTable(brightness: Double, channelMultiplier: Double, contrast: Double) -> [CGGammaValue] {
        let scale = brightness * channelMultiplier
        return (0..<256).map { i in
            let t = Double(i) / 255.0
            let curved = applyContrast(t, contrast: contrast)
            return CGGammaValue(curved * scale)
        }
    }

    private func applyGamma(displayID: CGDirectDisplayID, brightness: Double, warmth: Double, contrast: Double) {
        let m = Self.channelMultipliers(for: warmth)
        var rTable = Self.buildTable(brightness: brightness, channelMultiplier: m.r, contrast: contrast)
        var gTable = Self.buildTable(brightness: brightness, channelMultiplier: m.g, contrast: contrast)
        var bTable = Self.buildTable(brightness: brightness, channelMultiplier: m.b, contrast: contrast)

        // Return value intentionally ignored — no recovery action if gamma set fails
        CGSetDisplayTransferByTable(displayID, 256, &rTable, &gTable, &bTable)
    }

    // MARK: - Display Name

    private func displayName(for displayID: CGDirectDisplayID) -> String {
        // Try NSScreen.localizedName first (works for most locales)
        for screen in NSScreen.screens {
            if let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
               screenNumber == displayID {
                let name = screen.localizedName
                // localizedName works for locales in Apple's display database.
                // For unsupported locales (e.g. Serbian), it returns a generic fallback.
                // Detect this by checking if the name matches our own "Unknown Display" translation
                // or common system fallbacks, then try harder.
                if !looksLikeGenericDisplayName(name) {
                    return name
                }
            }
        }

        // For unsupported locales, read the English name from Apple's display override plist
        if let name = displayNameFromOverrides(for: displayID) {
            return name
        }

        // Try EDID binary data from IOKit
        if let name = edidDisplayName(for: displayID) {
            return name
        }

        return NSLocalizedString("Unknown Display", comment: "Fallback name when macOS cannot identify the display")
    }

    /// Checks if a display name is a generic fallback rather than the real model name.
    private func looksLikeGenericDisplayName(_ name: String) -> Bool {
        let lowercased = name.lowercased()
        // Common generic fallback patterns across locales
        return lowercased.contains("unknown") ||
               lowercased.contains("unbekannt") ||       // de
               lowercased.contains("inconnu") ||          // fr
               lowercased.contains("desconocid") ||       // es
               lowercased.contains("sconosciut") ||       // it
               lowercased.contains("onbekend") ||         // nl
               lowercased.contains("desconhecid") ||      // pt
               lowercased.contains("不明") ||              // ja
               lowercased.contains("未知") ||              // zh
               lowercased.contains("알 수 없") ||          // ko
               lowercased.contains("nepoznat")            // sr
    }

    /// Reads the display product name from Apple's display override plist.
    private func displayNameFromOverrides(for displayID: CGDirectDisplayID) -> String? {
        let vendorHex = String(format: "%x", CGDisplayVendorNumber(displayID))
        let productHex = String(format: "%x", CGDisplayModelNumber(displayID))
        let path = "/System/Library/Displays/Contents/Resources/Overrides/DisplayVendorID-\(vendorHex)/DisplayProductID-\(productHex)"

        guard let dict = NSDictionary(contentsOfFile: path) as? [String: Any] else {
            return nil
        }

        if let name = dict["DisplayProductName"] as? String, !name.isEmpty {
            return name
        }
        if let names = dict["DisplayProductName"] as? [String: String],
           let name = names.values.first, !name.isEmpty {
            return name
        }
        return nil
    }

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
                  let dict = properties?.takeRetainedValue() as? [String: Any] else {
                continue
            }

            guard let vendorID = dict["DisplayVendorID"] as? Int,
                  let productID = dict["DisplayProductID"] as? Int,
                  targetVendor == vendorID && targetModel == productID else {
                continue
            }

            if let info = IODisplayCreateInfoDictionary(service, 0)?.takeRetainedValue() as? [String: Any],
               let names = info["DisplayProductName"] as? [String: String],
               let name = names.values.first, !name.isEmpty {
                return name
            }

            if let edidData = dict["IODisplayEDID"] as? Data,
               let name = parseEDIDName(edidData) {
                return name
            }
        }

        return nil
    }

    /// Reads display product name from IOPortTransportStateDisplayPort services (Apple Silicon).
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
                  let dict = properties?.takeRetainedValue() as? [String: Any] else {
                continue
            }

            // Match by ProductID (corresponds to CGDisplayModelNumber)
            guard let productID = dict["ProductID"] as? Int,
                  productID == targetModel else {
                continue
            }

            // Read ProductName directly from the service properties
            if let name = dict["ProductName"] as? String, !name.isEmpty {
                return name
            }

            // Fall back to EDID binary from the service or its Metadata
            if let edidData = dict["EDID"] as? Data,
               let name = parseEDIDName(edidData) {
                return name
            }
            if let metadata = dict["Metadata"] as? [String: Any],
               let edidData = metadata["EDID"] as? Data,
               let name = parseEDIDName(edidData) {
                return name
            }
        }

        return nil
    }

    /// Parses the monitor name from raw EDID data (descriptor tag 0xFC).
    private func parseEDIDName(_ edid: Data) -> String? {
        guard edid.count >= 128 else { return nil }

        // EDID has 4 descriptor blocks of 18 bytes each, starting at byte 54
        for i in 0..<4 {
            let offset = 54 + (i * 18)
            guard offset + 17 < edid.count else { continue }

            // Monitor descriptor: bytes 0-2 are 0x00, byte 3 is the tag
            if edid[offset] == 0 && edid[offset + 1] == 0 && edid[offset + 2] == 0 && edid[offset + 3] == 0xFC {
                // Name is in bytes 5-17 (13 chars), padded with 0x0A (newline) or spaces
                let nameBytes = edid[(offset + 5)...(offset + 17)]
                if let name = String(bytes: nameBytes, encoding: .ascii)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\n\r\0")),
                   !name.isEmpty {
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

// Safety: The token is stored as a strong reference in BrightnessManager.reconfigurationToken,
// so passUnretained is safe — the pointer remains valid for the lifetime of the registration.
private final class DisplayReconfigurationToken: @unchecked Sendable {
    private let handler: @Sendable () -> Void

    init(handler: @escaping @Sendable () -> Void) {
        self.handler = handler
        CGDisplayRegisterReconfigurationCallback(displayReconfigurationCallback, Unmanaged.passUnretained(self).toOpaque())
    }

    deinit {
        CGDisplayRemoveReconfigurationCallback(displayReconfigurationCallback, Unmanaged.passUnretained(self).toOpaque())
    }

    fileprivate func reconfigured() {
        handler()
    }
}

private func displayReconfigurationCallback(
    _ display: CGDirectDisplayID,
    _ flags: CGDisplayChangeSummaryFlags,
    _ userInfo: UnsafeMutableRawPointer?
) {
    guard flags.contains(.addFlag) || flags.contains(.removeFlag) else { return }
    guard let userInfo else { return }
    let token = Unmanaged<DisplayReconfigurationToken>.fromOpaque(userInfo).takeUnretainedValue()
    token.reconfigured()
}

//
//  HiDPIModeManager.swift
//  Dimmerly
//
//  Turns HiDPI sizes on and off for external displays below 4K, and switches a display
//  to one of those sizes. Direct download only.
//

#if !APPSTORE

    import AppKit
    import CoreGraphics
    import Foundation
    import os

    /// Runs a shell command as root after the standard macOS administrator prompt.
    protocol PrivilegedCommandRunning: Sendable {
        /// Returns normally on success. Throws `HiDPIModeError.cancelled` when the user
        /// dismisses the prompt.
        func run(_ command: String, prompt: String) async throws
    }

    enum HiDPIModeError: LocalizedError, Equatable {
        case cancelled
        case commandFailed
        case modeSwitchFailed

        var errorDescription: String? {
            switch self {
            case .cancelled:
                nil
            case .commandFailed:
                String(
                    localized: """
                    The HiDPI change didn’t complete. \
                    Try again, and enter the password of an administrator account.
                    """,
                    comment: "HiDPI settings error shown under a display when installing or removing the override fails"
                )
            case .modeSwitchFailed:
                String(
                    localized: """
                    macOS didn’t switch to that size. \
                    Try another size, or choose one in System Settings > Displays.
                    """,
                    comment: "HiDPI settings error shown under a display when changing its size fails"
                )
            }
        }
    }

    /// Asks for the administrator password with AppleScript's `do shell script`, run through
    /// `osascript` so the app stays responsive while the prompt is open. The command and the
    /// prompt are passed as arguments, never spliced into the script source.
    struct AppleScriptPrivilegedRunner: PrivilegedCommandRunning {
        func run(_ command: String, prompt: String) async throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = [
                "-e", "on run argv",
                "-e", "do shell script (item 1 of argv) with prompt (item 2 of argv) with administrator privileges",
                "-e", "end run",
                command, prompt,
            ]
            let errorPipe = Pipe()
            process.standardError = errorPipe
            process.standardOutput = FileHandle.nullDevice

            // Error output is collected while the process runs, so a long message can never
            // fill the pipe and stall it.
            let reader = errorPipe.fileHandleForReading
            let collected = OSAllocatedUnfairLock(initialState: Data())
            reader.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty {
                    handle.readabilityHandler = nil
                } else {
                    collected.withLock { $0.append(chunk) }
                }
            }

            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                process.terminationHandler = { finished in
                    reader.readabilityHandler = nil
                    let rest = (try? reader.readToEnd()) ?? Data()
                    let output = String(data: collected.withLock { $0 } + rest, encoding: .utf8) ?? ""
                    if finished.terminationStatus == 0 {
                        continuation.resume()
                    } else if output.contains("-128") {
                        continuation.resume(throwing: HiDPIModeError.cancelled)
                    } else {
                        continuation.resume(throwing: HiDPIModeError.commandFailed)
                    }
                }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    reader.readabilityHandler = nil
                    continuation.resume(throwing: HiDPIModeError.commandFailed)
                }
            }
        }
    }

    /// One external display as Settings shows it.
    struct HiDPIDisplayState: Identifiable, Equatable {
        let id: CGDirectDisplayID
        let identity: HiDPIDisplayIdentity
        let status: HiDPIOverrideStatus
        /// HiDPI sizes macOS offers now, largest first.
        let availableSizes: [HiDPISize]
        /// The mode the display runs in now, or nil when macOS doesn't report one.
        let current: HiDPIModeChoice?
    }

    @MainActor
    @Observable
    final class HiDPIModeManager {
        private(set) var displays: [HiDPIDisplayState] = []
        /// Models with a change in progress, keyed by `modelKey`. Keyed by model rather than
        /// display ID, which changes when a monitor is unplugged and plugged back in.
        private(set) var busyModels: Set<String> = []
        /// The last failure per display, shown under its row until its next change succeeds.
        private(set) var errors: [CGDirectDisplayID: HiDPIModeError] = [:]

        @ObservationIgnored private let runner: PrivilegedCommandRunning
        @ObservationIgnored private let location: HiDPIOverride.SystemLocation
        @ObservationIgnored private let defaults: UserDefaults
        /// The display names Settings passed last, reused when a change refreshes the list.
        @ObservationIgnored private var names: [CGDirectDisplayID: String] = [:]

        /// Models whose Dimmerly file macOS had read at boot and Dimmerly then removed, keyed
        /// by `modelKey`, each with that boot's time. Kept in defaults so the state survives
        /// quitting Dimmerly before the restart.
        static let removalsKey = "HiDPILoadedOverridesRemovedThisBoot"
        /// SHA-256 of the file Dimmerly installed, per model. A file that no longer matches has
        /// been edited by someone else and is left alone.
        static let installedKey = "HiDPIInstalledOverrideDigests"

        /// Settings uses this one, so a change still waiting on the password prompt keeps its
        /// lock when the Settings window closes and opens again.
        static let shared = HiDPIModeManager()

        init(
            runner: PrivilegedCommandRunning = AppleScriptPrivilegedRunner(),
            location: HiDPIOverride.SystemLocation = .system,
            defaults: UserDefaults = .standard
        ) {
            self.runner = runner
            self.location = location
            self.defaults = defaults
        }

        func isBusy(_ display: HiDPIDisplayState) -> Bool {
            busyModels.contains(Self.modelKey(display.identity))
        }

        // MARK: Reading state

        func refresh(names: [CGDirectDisplayID: String]) {
            self.names = names
            refresh()
        }

        /// Assigns only when something changed, so screen events that don't concern HiDPI,
        /// such as rearranging displays, don't redraw the section.
        private func refresh() {
            let updated = BrightnessManager.activeDisplayIDs().compactMap { displayID in
                state(for: displayID, name: names[displayID])
            }
            if updated != displays {
                displays = updated
            }
        }

        private func state(for displayID: CGDirectDisplayID, name: String?) -> HiDPIDisplayState? {
            let vendorID = CGDisplayVendorNumber(displayID)
            let productID = CGDisplayModelNumber(displayID)
            let modes = Self.allModes(for: displayID)
            guard let native = Self.nativeSize(in: modes),
                  HiDPIOverride.isEligible(
                      isBuiltIn: CGDisplayIsBuiltin(displayID) != 0,
                      vendorID: vendorID,
                      productID: productID,
                      nativeWidth: native.width,
                      nativeHeight: native.height
                  )
            else {
                return nil
            }

            let identity = HiDPIDisplayIdentity(
                vendorID: vendorID,
                productID: productID,
                nativeWidth: native.width,
                nativeHeight: native.height,
                // Another tool's override may have renamed the display "<name> (HiDPI)".
                name: Self.withoutHiDPISuffix(name ?? DisplayNameResolver.name(for: displayID))
            )
            let fileURL = HiDPIOverride.fileURL(vendorID: vendorID, productID: productID, root: location.overridesRoot)
            let offered = Set(modes.filter(Self.isHiDPI).map { HiDPISize(width: $0.width, height: $0.height) })
            let expected = HiDPIOverride.scaledSizes(nativeWidth: native.width, nativeHeight: native.height)
            let status = HiDPIOverride.status(
                ownership: ownedOverride(at: fileURL, identity: identity).ownership,
                expectedSizes: expected,
                offeredHiDPISizes: offered,
                installedBeforeLastRestart: Self.predatesBoot(fileURL),
                loadedFileRemovedThisBoot: loadedFileWasRemovedThisBoot(identity)
            )
            let current = CGDisplayCopyDisplayMode(displayID).map { mode in
                HiDPIModeChoice(
                    width: mode.width,
                    height: mode.height,
                    pixelWidth: mode.pixelWidth,
                    pixelHeight: mode.pixelHeight,
                    nativeWidth: native.width,
                    nativeHeight: native.height
                )
            }
            return HiDPIDisplayState(
                id: displayID,
                identity: identity,
                status: status,
                availableSizes: offered.filter { expected.contains($0) }.sorted(by: >),
                current: current
            )
        }

        // MARK: Actions

        /// Installs Dimmerly's override file for the display. Never replaces a file that is
        /// already there: the row may be out of date, and the file may belong to someone else.
        func enable(_ display: HiDPIDisplayState) async {
            guard display.status.action == .turnOn else { return }
            await perform(on: display) {
                // The row may show a file read a while ago. Read it again; the refresh afterwards
                // shows whatever appeared since.
                guard Self.readOverride(at: self.fileURL(for: display)).ownership == .none else { return }

                let contents = try HiDPIOverride.plistData(for: display.identity)
                let command = try HiDPIOverride.installCommand(
                    for: display.identity, contents: contents, location: self.location
                )
                try await self.runner.run(command, prompt: String(
                    localized: "Dimmerly wants to add HiDPI sizes for \(display.identity.name).",
                    comment: "Administrator password prompt when turning on HiDPI; the placeholder is the display name"
                ))
                self.setInstalledDigest(HiDPIOverride.sha256Hex(contents), for: display.identity)
            }
        }

        /// Removes Dimmerly's override file. Files written by other tools are never removed.
        func disable(_ display: HiDPIDisplayState) async {
            guard display.status.action == .turnOff else { return }
            await perform(on: display) {
                let file = self.fileURL(for: display)
                let current = self.ownedOverride(at: file, identity: display.identity)
                guard current.ownership == .dimmerly, let data = current.data else { return }
                let wasLoaded = Self.predatesBoot(file)

                let command = HiDPIOverride.removeCommand(
                    vendorID: display.identity.vendorID,
                    productID: display.identity.productID,
                    expectedCurrent: data,
                    location: self.location
                )
                try await self.runner.run(command, prompt: String(
                    localized: "Dimmerly wants to remove HiDPI sizes for \(display.identity.name).",
                    comment: "Administrator password prompt when turning off HiDPI; the placeholder is the display name"
                ))
                self.setInstalledDigest(nil, for: display.identity)
                if wasLoaded {
                    self.recordLoadedFileRemoval(for: display.identity)
                }
            }
        }

        /// Switches the display to a HiDPI size or to its native 1x mode. The choice is saved,
        /// so it holds after a restart. The screen-parameters notification that follows a
        /// switch refreshes the list.
        func select(_ choice: HiDPIModeChoice, for display: HiDPIDisplayState) {
            guard display.status.allowsSizeChange, choice != display.current else { return }
            let modes = Self.allModes(for: display.id)
            let candidates: [CGDisplayMode]
            switch choice {
            case let .hiDPI(size):
                candidates = modes.filter {
                    Self.isHiDPI($0) && $0.width == size.width && $0.height == size.height
                }
            case .native:
                candidates = modes.filter {
                    !Self.isHiDPI($0) && $0.width == display.identity.nativeWidth
                        && $0.height == display.identity.nativeHeight
                }
            case .lowResolution:
                // The picker lists a low-resolution mode only while it is the current mode,
                // which the guard above already returns for.
                return
            }
            let switched = Self.apply(Self.bestMode(in: candidates), to: display.id)
            errors[display.id] = switched ? nil : .modeSwitchFailed
        }

        private static func apply(_ mode: CGDisplayMode?, to displayID: CGDirectDisplayID) -> Bool {
            guard let mode else { return false }
            var config: CGDisplayConfigRef?
            guard CGBeginDisplayConfiguration(&config) == .success else { return false }
            guard CGConfigureDisplayWithDisplayMode(config, displayID, mode, nil) == .success else {
                CGCancelDisplayConfiguration(config)
                return false
            }
            return CGCompleteDisplayConfiguration(config, .permanently) == .success
        }

        /// Runs one change at a time per model: identical monitors share one override file, so
        /// all of them show as busy until it finishes.
        private func perform(on display: HiDPIDisplayState, _ work: @escaping () async throws -> Void) async {
            let model = Self.modelKey(display.identity)
            guard busyModels.insert(model).inserted else { return }
            defer {
                busyModels.remove(model)
                refresh()
            }
            do {
                try await work()
                errors[display.id] = nil
            } catch HiDPIModeError.cancelled {
                // Dismissing the password prompt changes nothing and isn't an error.
            } catch {
                errors[display.id] = .commandFailed
            }
        }

        private func fileURL(for display: HiDPIDisplayState) -> URL {
            HiDPIOverride.fileURL(
                vendorID: display.identity.vendorID,
                productID: display.identity.productID,
                root: location.overridesRoot
            )
        }

        // MARK: Override files

        /// The file's contents and who wrote it. Anything that exists but isn't a readable
        /// regular file, such as a symbolic link or a folder, is treated as someone else's, so
        /// it is never overwritten or removed.
        private static func readOverride(at url: URL) -> (data: Data?, ownership: HiDPIOverrideOwnership) {
            // attributesOfItem doesn't follow symbolic links, so a link reports as a link.
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
                return (nil, .none)
            }
            guard attributes[.type] as? FileAttributeType == .typeRegular, let data = try? Data(contentsOf: url) else {
                return (nil, .other(hiDPIOnly: false))
            }
            return (data, HiDPIOverride.ownership(ofPlistData: data))
        }

        // MARK: Installed digests

        /// Like `readOverride`, but a file carrying Dimmerly's marker counts as Dimmerly's only
        /// while it is byte for byte what Dimmerly installed. Otherwise another tool edited it,
        /// and it is treated as that tool's.
        private func ownedOverride(
            at url: URL, identity: HiDPIDisplayIdentity
        ) -> (data: Data?, ownership: HiDPIOverrideOwnership) {
            let read = Self.readOverride(at: url)
            guard read.ownership == .dimmerly, let data = read.data else { return read }
            let digests = defaults.dictionary(forKey: Self.installedKey) as? [String: String] ?? [:]
            guard digests[Self.modelKey(identity)] == HiDPIOverride.sha256Hex(data) else {
                return (data, .other(hiDPIOnly: false))
            }
            return read
        }

        private func setInstalledDigest(_ digest: String?, for identity: HiDPIDisplayIdentity) {
            var digests = defaults.dictionary(forKey: Self.installedKey) as? [String: String] ?? [:]
            digests[Self.modelKey(identity)] = digest
            defaults.set(digests, forKey: Self.installedKey)
        }

        // MARK: Removals this boot

        static func modelKey(_ identity: HiDPIDisplayIdentity) -> String {
            "\(String(identity.vendorID, radix: 16))-\(String(identity.productID, radix: 16))"
        }

        private func loadedFileWasRemovedThisBoot(_ identity: HiDPIDisplayIdentity) -> Bool {
            guard let boot = Self.bootDate?.timeIntervalSince1970 else { return false }
            let removals = defaults.dictionary(forKey: Self.removalsKey) as? [String: Double] ?? [:]
            return removals[Self.modelKey(identity)] == boot
        }

        /// Entries from earlier boots are dropped on each write. Nothing clears an entry for the
        /// current boot: macOS keeps the removed file's sizes until the restart either way.
        private func recordLoadedFileRemoval(for identity: HiDPIDisplayIdentity) {
            guard let boot = Self.bootDate?.timeIntervalSince1970 else { return }
            var removals = (defaults.dictionary(forKey: Self.removalsKey) as? [String: Double] ?? [:])
                .filter { $0.value == boot }
            removals[Self.modelKey(identity)] = boot
            defaults.set(removals, forKey: Self.removalsKey)
        }

        // MARK: Display modes

        private static func allModes(for displayID: CGDirectDisplayID) -> [CGDisplayMode] {
            let options = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
            return (CGDisplayCopyAllDisplayModes(displayID, options) as? [CGDisplayMode] ?? [])
                .filter { $0.isUsableForDesktopGUI() }
        }

        private static func isHiDPI(_ mode: CGDisplayMode) -> Bool {
            HiDPIModeChoice.isHiDPI(
                width: mode.width, height: mode.height, pixelWidth: mode.pixelWidth, pixelHeight: mode.pixelHeight
            )
        }

        /// The panel's native size: the mode IOKit flags as native, else the largest 1x mode.
        private static func nativeSize(in modes: [CGDisplayMode]) -> HiDPISize? {
            let nativeFlag: UInt32 = 0x0200_0000 // kDisplayModeNativeFlag
            let oneX = modes.filter { $0.pixelWidth == $0.width }
            let mode = oneX.first { $0.ioFlags & nativeFlag != 0 }
                ?? oneX.max { $0.width * $0.height < $1.width * $1.height }
            return mode.map { HiDPISize(width: $0.width, height: $0.height) }
        }

        /// Prefers the highest refresh rate.
        private static func bestMode(in modes: [CGDisplayMode]) -> CGDisplayMode? {
            modes.max { $0.refreshRate < $1.refreshRate }
        }

        /// True when the file was last written before this boot.
        private static func predatesBoot(_ file: URL) -> Bool {
            guard let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate,
                let boot = bootDate
            else {
                return false
            }
            return modified < boot
        }

        private static let bootDate: Date? = {
            var bootTime = timeval()
            var size = MemoryLayout<timeval>.stride
            var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
            guard sysctl(&mib, 2, &bootTime, &size, nil, 0) == 0 else { return nil }
            return Date(timeIntervalSince1970: TimeInterval(bootTime.tv_sec))
        }()

        private static func withoutHiDPISuffix(_ name: String) -> String {
            let suffix = " (HiDPI)"
            return name.hasSuffix(suffix) ? String(name.dropLast(suffix.count)) : name
        }
    }

#endif

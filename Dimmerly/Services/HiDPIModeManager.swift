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
        private(set) var busyDisplayIDs: Set<CGDirectDisplayID> = []
        /// The last failure per display, shown under its row until its next change succeeds.
        private(set) var errors: [CGDirectDisplayID: HiDPIModeError] = [:]

        @ObservationIgnored private let runner: PrivilegedCommandRunning
        @ObservationIgnored private let overridesRoot: URL
        @ObservationIgnored private let defaults: UserDefaults

        /// Models whose override Dimmerly removed, keyed by `modelKey`, each with the boot time
        /// it was removed in. Kept in defaults so the restart note survives quitting Dimmerly.
        static let removalsKey = "HiDPIOverridesRemovedThisBoot"

        init(
            runner: PrivilegedCommandRunning = AppleScriptPrivilegedRunner(),
            overridesRoot: URL = HiDPIOverride.overridesRoot,
            defaults: UserDefaults = .standard
        ) {
            self.runner = runner
            self.overridesRoot = overridesRoot
            self.defaults = defaults
        }

        // MARK: Reading state

        func refresh(names: [CGDirectDisplayID: String] = [:]) {
            displays = BrightnessManager.activeDisplayIDs().compactMap { displayID in
                state(for: displayID, name: names[displayID])
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
                name: Self.withoutHiDPISuffix(name ?? Self.screenName(for: displayID) ?? String(displayID))
            )
            let fileURL = HiDPIOverride.fileURL(vendorID: vendorID, productID: productID, root: overridesRoot)
            let offered = Set(modes.filter(Self.isHiDPI).map { HiDPISize(width: $0.width, height: $0.height) })
            let expected = HiDPIOverride.scaledSizes(nativeWidth: native.width, nativeHeight: native.height)
            let status = HiDPIOverride.status(
                ownership: Self.readOverride(at: fileURL).ownership,
                expectedSizes: expected,
                offeredHiDPISizes: offered,
                installedBeforeLastRestart: Self.predatesBoot(fileURL),
                removedSinceLastRestart: wasRemovedThisBoot(identity)
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

        /// Installs Dimmerly's override file for the display, replacing a HiDPI-only file
        /// another tool left there.
        func enable(_ display: HiDPIDisplayState) async {
            guard [.off, .restartToRemove, .otherOverride(replaceable: true)].contains(display.status) else {
                return
            }
            await perform(on: display) {
                let destination = self.fileURL(for: display)
                // The row may show a file read a while ago. Read it again, so a file another app
                // wrote since then is never replaced; the refresh afterwards shows it.
                let current = Self.readOverride(at: destination)
                guard current.ownership != .other(replaceable: false) else { return }

                var staged: [URL] = []
                defer { staged.forEach { try? FileManager.default.removeItem(at: $0) } }
                let newFile = try Self.stage(HiDPIOverride.plistData(for: display.identity))
                staged.append(newFile)
                let snapshot = try current.data.map(Self.stage)
                if let snapshot {
                    staged.append(snapshot)
                }

                let command = HiDPIOverride.installCommand(
                    stagedFile: newFile,
                    destination: destination,
                    expectedCurrentFile: snapshot
                )
                try await self.runner.run(command, prompt: Self.installPrompt(for: display))
                self.setRemovedThisBoot(false, for: display.identity)
            }
        }

        /// Removes Dimmerly's override file. Files written by other tools are never removed.
        func disable(_ display: HiDPIDisplayState) async {
            guard [.on, .restartToEnable, .notAccepted].contains(display.status) else { return }
            await perform(on: display) {
                let file = self.fileURL(for: display)
                let current = Self.readOverride(at: file)
                guard current.ownership == .dimmerly, let data = current.data else { return }

                let snapshot = try Self.stage(data)
                defer { try? FileManager.default.removeItem(at: snapshot) }
                let command = HiDPIOverride.removeCommand(
                    file: file,
                    expectedCurrentFile: snapshot,
                    clearWindowServerFlag: !self.otherOverrideFilesExist(besides: file)
                )
                try await self.runner.run(command, prompt: Self.removePrompt(for: display))
                self.setRemovedThisBoot(true, for: display.identity)
            }
        }

        /// Switches the display to a HiDPI size or to its native 1x mode. The choice is saved,
        /// so it holds after a restart. A low-resolution mode is only ever shown, never chosen.
        func select(_ choice: HiDPIModeChoice, for display: HiDPIDisplayState) {
            guard choice != display.current else { return }
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
                return
            }
            let switched = Self.apply(Self.bestMode(in: candidates), to: display.id)
            errors[display.id] = switched ? nil : .modeSwitchFailed
            refresh(names: currentNames)
        }

        private static func apply(_ mode: CGDisplayMode?, to displayID: CGDirectDisplayID) -> Bool {
            guard let mode else { return false }
            var config: CGDisplayConfigRef?
            guard CGBeginDisplayConfiguration(&config) == .success else { return false }
            CGConfigureDisplayWithDisplayMode(config, displayID, mode, nil)
            return CGCompleteDisplayConfiguration(config, .permanently) == .success
        }

        private var currentNames: [CGDirectDisplayID: String] {
            Dictionary(displays.map { ($0.id, $0.identity.name) }, uniquingKeysWith: { first, _ in first })
        }

        /// Runs one change at a time per model: identical monitors share one override file, so
        /// all of them show as busy until it finishes.
        private func perform(on display: HiDPIDisplayState, _ work: @escaping () async throws -> Void) async {
            let ids = Set(displays.filter { Self.sameModel($0.identity, display.identity) }.map(\.id))
                .union([display.id])
            guard busyDisplayIDs.isDisjoint(with: ids) else { return }
            busyDisplayIDs.formUnion(ids)
            defer {
                busyDisplayIDs.subtract(ids)
                refresh(names: currentNames)
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
                root: overridesRoot
            )
        }

        /// True when any override file other than `file` exists, from Dimmerly or anyone else.
        /// Hidden files such as `.DS_Store` don't count.
        private func otherOverrideFilesExist(besides file: URL) -> Bool {
            guard let enumerator = FileManager.default.enumerator(
                at: overridesRoot,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else {
                return false
            }
            for case let url as URL in enumerator
                where url.standardizedFileURL != file.standardizedFileURL
                && (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            {
                return true
            }
            return false
        }

        // MARK: Override files

        /// The file's contents and who wrote it. A file that exists but can't be read is
        /// treated as someone else's, so it is never overwritten.
        private static func readOverride(at url: URL) -> (data: Data?, ownership: HiDPIOverrideOwnership) {
            let data = try? Data(contentsOf: url)
            if data == nil, FileManager.default.fileExists(atPath: url.path) {
                return (nil, .other(replaceable: false))
            }
            return (data, HiDPIOverride.ownership(ofPlistData: data))
        }

        /// Writes `data` to a new temporary file for the privileged command to read.
        private static func stage(_ data: Data) throws -> URL {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("dimmerly-hidpi-\(UUID().uuidString).plist")
            try data.write(to: url)
            return url
        }

        private static func sameModel(_ lhs: HiDPIDisplayIdentity, _ rhs: HiDPIDisplayIdentity) -> Bool {
            lhs.vendorID == rhs.vendorID && lhs.productID == rhs.productID
        }

        // MARK: Removals this boot

        private static func modelKey(_ identity: HiDPIDisplayIdentity) -> String {
            "\(String(identity.vendorID, radix: 16))-\(String(identity.productID, radix: 16))"
        }

        private func wasRemovedThisBoot(_ identity: HiDPIDisplayIdentity) -> Bool {
            guard let boot = Self.bootDate?.timeIntervalSince1970 else { return false }
            let removals = defaults.dictionary(forKey: Self.removalsKey) as? [String: Double] ?? [:]
            return removals[Self.modelKey(identity)] == boot
        }

        /// Records or forgets a removal. Entries from earlier boots are dropped on each write.
        private func setRemovedThisBoot(_ removed: Bool, for identity: HiDPIDisplayIdentity) {
            guard let boot = Self.bootDate?.timeIntervalSince1970 else { return }
            var removals = (defaults.dictionary(forKey: Self.removalsKey) as? [String: Double] ?? [:])
                .filter { $0.value == boot }
            removals[Self.modelKey(identity)] = removed ? boot : nil
            if removals.isEmpty {
                defaults.removeObject(forKey: Self.removalsKey)
            } else {
                defaults.set(removals, forKey: Self.removalsKey)
            }
        }

        // MARK: Prompts

        private static func installPrompt(for display: HiDPIDisplayState) -> String {
            String(
                localized: "Dimmerly wants to add HiDPI sizes for \(display.identity.name).",
                comment: "Administrator password prompt when turning on HiDPI; the placeholder is the display name"
            )
        }

        private static func removePrompt(for display: HiDPIDisplayState) -> String {
            String(
                localized: "Dimmerly wants to remove HiDPI sizes for \(display.identity.name).",
                comment: "Administrator password prompt when turning off HiDPI; the placeholder is the display name"
            )
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

        private static func screenName(for displayID: CGDirectDisplayID) -> String? {
            NSScreen.screens.first {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
            }?.localizedName
        }
    }

#endif

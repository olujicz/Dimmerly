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
    import Security

    /// Runs one helper request as root after the standard macOS administrator prompt.
    protocol PrivilegedCommandRunning: Sendable {
        /// Returns normally on success. Throws `HiDPIModeError.cancelled` when the user
        /// dismisses the prompt and `HiDPIModeError.held` when the helper left the original
        /// override aside because its path is taken.
        func run(_ request: HiDPIHelperCommand.Request, prompt: String) async throws
    }

    enum HiDPIModeError: LocalizedError, Equatable {
        case cancelled
        case commandFailed
        case modeSwitchFailed
        /// An earlier removal kept the original override at `path`, and another file is in its place.
        case held(path: String)

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
            case let .held(path):
                String(
                    localized: """
                    Dimmerly kept the original display override at \(path) because another file is in its place. \
                    Move or delete the file in the way, then try again.
                    """,
                    comment: """
                    HiDPI settings error: a removal was interrupted and the original override file \
                    is kept at the path in the placeholder
                    """
                )
            }
        }
    }

    /// Asks for the administrator password with AppleScript's `do shell script`, run through
    /// `osascript` so the app stays responsive while the prompt is open. The script copies the
    /// helper tool into a fresh folder only root can write, checks the copy against the digest
    /// and signing team of the one in the app, and runs that copy once. The script and the
    /// prompt are passed as arguments, never spliced into the script source.
    struct AppleScriptPrivilegedRunner: PrivilegedCommandRunning {
        func run(_ request: HiDPIHelperCommand.Request, prompt: String) async throws {
            let command = try HiDPIHelperInvocation.script(for: request)
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
                    } else if let path = HiDPIHelperInvocation.heldPath(in: output) {
                        continuation.resume(throwing: HiDPIModeError.held(path: path))
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

    /// What the helper must be: the tool this app was built with, signed under the release team.
    enum HiDPIHelperIdentity {
        /// The signing identifier of `DimmerlyHiDPIHelper` as Xcode embeds it.
        static let identifier = "DimmerlyHiDPIHelper"

        /// The code requirement the helper must satisfy. A release build also requires a
        /// Developer ID Application certificate; development builds accept any Apple-issued
        /// certificate of the team.
        static func requirement(team: String, developerID: Bool) -> String {
            var text = "identifier \"\(identifier)\" and anchor apple generic "
                + "and certificate leaf[subject.OU] = \"\(team)\""
            if developerID {
                text += " and certificate 1[field.1.2.840.113635.100.6.2.6] exists"
                    + " and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
            }
            return text
        }

        enum Trust: Equatable {
            /// The helper must satisfy this requirement, in the app and again as a private copy.
            case requirement(String)
            /// Development builds without a signing team: the digest alone.
            case digestOnly
        }

        /// How much to trust the helper. A build that isn't a development build and can't name its
        /// signing team gets nil: it must not ask for an administrator password.
        static func trust(team: String?, isDevelopmentBuild: Bool) -> Trust? {
            if let team {
                return .requirement(requirement(team: team, developerID: !isDevelopmentBuild))
            }
            return isDevelopmentBuild ? .digestOnly : nil
        }

        static var isDevelopmentBuild: Bool {
            #if DEBUG
                true
            #else
                false
            #endif
        }
    }

    /// Builds the root script that runs the helper tool from the app bundle.
    enum HiDPIHelperInvocation {
        static let helperName = HiDPIHelperIdentity.identifier

        static func helperURL(in bundle: Bundle = .main) -> URL {
            bundle.bundleURL.appendingPathComponent("Contents/MacOS/\(helperName)")
        }

        /// - Parameters:
        ///   - helper: The helper tool to run.
        ///   - trust: How to verify the helper; nil refuses to build a script.
        ///   - scratchRoot: Where root makes its private folder.
        static func script(
            for request: HiDPIHelperCommand.Request,
            helper: URL = helperURL(),
            trust: HiDPIHelperIdentity.Trust? = HiDPIHelperIdentity.trust(
                team: signingTeam(), isDevelopmentBuild: HiDPIHelperIdentity.isDevelopmentBuild
            ),
            scratchRoot: String = "/var/db"
        ) throws -> String {
            guard let trust, let data = try? Data(contentsOf: helper) else { throw HiDPIModeError.commandFailed }
            var requirement: String?
            if case let .requirement(text) = trust {
                guard isSigned(helper, requirement: text) else { throw HiDPIModeError.commandFailed }
                requirement = text
            }
            return scriptText(
                arguments: request.arguments, helper: helper, helperDigest: HiDPITransaction.sha256Hex(data),
                requirement: requirement, scratchRoot: scratchRoot
            )
        }

        static func scriptText(
            arguments: [String], helper: URL, helperDigest: String, requirement: String?, scratchRoot: String
        ) -> String {
            let quote = HiDPIOverride.shellQuoted
            var lines = [
                "D=$(/usr/bin/mktemp -d \(quote(scratchRoot + "/dimmerly-hidpi.XXXXXXXX"))) || exit 4",
                "fail() { /bin/rm -rf \"$D\"; echo 'Dimmerly: the helper failed verification' >&2; exit 4; }",
                "/bin/cp \(quote(helper.path)) \"$D/helper\" || fail",
                "/usr/sbin/chown \"$(/usr/bin/id -u):$(/usr/bin/id -g)\" \"$D/helper\" || fail",
                "/bin/chmod 755 \"$D/helper\" || fail",
                "[ \"$(/usr/bin/shasum -a 256 < \"$D/helper\" | /usr/bin/cut -d ' ' -f1)\" "
                    + "= \(quote(helperDigest)) ] || fail",
            ]
            if let requirement {
                lines.append("/usr/bin/codesign --verify --strict -R \(quote("=" + requirement)) \"$D/helper\" || fail")
            }
            lines += [
                "\"$D/helper\" " + arguments.map(quote).joined(separator: " "),
                "rc=$?",
                "/bin/rm -rf \"$D\"",
                "exit $rc",
            ]
            return lines.joined(separator: "\n")
        }

        /// The path after the helper's held-original marker in osascript's error text.
        static func heldPath(in output: String) -> String? {
            guard let range = output.range(of: HiDPIHelperCommand.heldMarker + " ") else { return nil }
            let path = output[range.upperBound...].prefix { !$0.isWhitespace && $0 != "\"" && $0 != "(" }
            return path.isEmpty ? nil : String(path)
        }

        /// The Team ID the running app is signed with, or nil for an unsigned or ad-hoc build, or
        /// when the signature can't be read.
        static func signingTeam() -> String? {
            var code: SecCode?
            var staticCode: SecStaticCode?
            var information: CFDictionary?
            guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
                  SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
                  SecCodeCopySigningInformation(
                      staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information
                  ) == errSecSuccess,
                  let info = information as? [String: Any]
            else {
                return nil
            }
            return info[kSecCodeInfoTeamIdentifier as String] as? String
        }

        static func isSigned(_ file: URL, requirement text: String) -> Bool {
            var staticCode: SecStaticCode?
            var requirement: SecRequirement?
            guard SecStaticCodeCreateWithPath(file as CFURL, [], &staticCode) == errSecSuccess, let staticCode,
                  SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess,
                  let requirement
            else {
                return false
            }
            return SecStaticCodeCheckValidity(staticCode, SecCSFlags(rawValue: kSecCSStrictValidate), requirement)
                == errSecSuccess
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
        /// A change to this model was interrupted, or its original override is held. The helper's
        /// record says so, and the only thing to do is let the helper finish or undo it.
        var recoveryPending = false

        enum PrimaryAction: Equatable {
            case turnOn
            case turnOff
            case finishPendingChange
        }

        /// What the row's button does: finishing a pending change comes before everything else,
        /// including rows that otherwise offer no action.
        var primaryAction: PrimaryAction? {
            if recoveryPending {
                return .finishPendingChange
            }
            switch status.action {
            case .turnOn: return .turnOn
            case .turnOff: return .turnOff
            case nil: return nil
            }
        }
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
        @ObservationIgnored private let overridesRoot: URL
        /// The helper's root-owned records, which Dimmerly only reads.
        @ObservationIgnored private let stateRoot: URL
        /// The display names Settings passed last, reused when a change refreshes the list.
        @ObservationIgnored private var names: [CGDirectDisplayID: String] = [:]

        /// Settings uses this one, so a change still waiting on the password prompt keeps its
        /// lock when the Settings window closes and opens again.
        static let shared = HiDPIModeManager()

        init(
            runner: PrivilegedCommandRunning = AppleScriptPrivilegedRunner(),
            overridesRoot: URL = HiDPIOverride.overridesRoot,
            stateRoot: URL = HiDPIOverride.stateRoot
        ) {
            self.runner = runner
            self.overridesRoot = overridesRoot
            self.stateRoot = stateRoot
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
            // A removal that was interrupted and can't put the original back stays on screen
            // until the user clears the way and the next change finishes it.
            for display in updated {
                if let path = heldOriginal(display.identity) {
                    errors[display.id] = .held(path: path)
                } else if case .held = errors[display.id] {
                    errors[display.id] = nil
                }
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
            let fileURL = HiDPIOverride.fileURL(vendorID: vendorID, productID: productID, root: overridesRoot)
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
                current: current,
                recoveryPending: isRecoveryPending(identity)
            )
        }

        // MARK: Actions

        /// Installs Dimmerly's override file for the display. Never replaces a file that is
        /// already there: the row may be out of date, and the file may belong to someone else.
        func enable(_ display: HiDPIDisplayState) async {
            guard display.primaryAction == .turnOn else { return }
            await perform(on: display) {
                // The row may show a file read a while ago. Read it again; the refresh afterwards
                // shows whatever appeared since.
                guard Self.readOverride(at: self.fileURL(for: display)).ownership == .none else { return }

                let request = try HiDPIHelperCommand.Request.install(
                    vendorID: display.identity.vendorID,
                    productID: display.identity.productID,
                    contents: HiDPIOverride.plistData(for: display.identity)
                )
                try await self.runner.run(request, prompt: String(
                    localized: "Dimmerly wants to add HiDPI sizes for \(display.identity.name).",
                    comment: "Administrator password prompt when turning on HiDPI; the placeholder is the display name"
                ))
            }
        }

        /// Removes Dimmerly's override file. Files written by other tools are never removed.
        func disable(_ display: HiDPIDisplayState) async {
            guard display.primaryAction == .turnOff else { return }
            await perform(on: display) {
                let current = self.ownedOverride(at: self.fileURL(for: display), identity: display.identity)
                guard current.ownership == .dimmerly, let data = current.data else { return }

                let request = HiDPIHelperCommand.Request.remove(
                    vendorID: display.identity.vendorID,
                    productID: display.identity.productID,
                    digest: HiDPIOverride.sha256Hex(data)
                )
                try await self.runner.run(request, prompt: String(
                    localized: "Dimmerly wants to remove HiDPI sizes for \(display.identity.name).",
                    comment: "Administrator password prompt when turning off HiDPI; the placeholder is the display name"
                ))
            }
        }

        /// Lets the helper finish or undo an interrupted change for the display's model. It works
        /// from any row, including ones that are otherwise stuck behind a file in the way.
        func recoverPendingChange(_ display: HiDPIDisplayState) async {
            guard display.primaryAction == .finishPendingChange else { return }
            await perform(on: display) {
                let request = HiDPIHelperCommand.Request.recover(
                    vendorID: display.identity.vendorID, productID: display.identity.productID
                )
                try await self.runner.run(request, prompt: String(
                    localized: "Dimmerly wants to finish a HiDPI change for \(display.identity.name).",
                    comment: """
                    Administrator password prompt when finishing an interrupted HiDPI change; \
                    the placeholder is the display name
                    """
                ))
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
            } catch let error as HiDPIModeError {
                errors[display.id] = error
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

        /// Identifies a model for the busy lock, the same way the helper keys its own records.
        static func modelKey(_ identity: HiDPIDisplayIdentity) -> String {
            HiDPITransaction.Model(vendorID: identity.vendorID, productID: identity.productID).key
        }

        // MARK: Helper records

        /// Like `readOverride`, but a file carrying Dimmerly's marker counts as Dimmerly's only
        /// while it is byte for byte what the helper installed, as its root-owned record says.
        /// Otherwise another tool edited it, or Dimmerly never installed it, and it is left alone.
        private func ownedOverride(
            at url: URL, identity: HiDPIDisplayIdentity
        ) -> (data: Data?, ownership: HiDPIOverrideOwnership) {
            let read = Self.readOverride(at: url)
            guard read.ownership == .dimmerly, let data = read.data else { return read }
            guard let installed = installedRecord(identity),
                  installed.digest == HiDPIOverride.sha256Hex(data),
                  installed.fileIdentity == Self.fileIdentity(of: url)
            else {
                return (data, .other(hiDPIOnly: false))
            }
            return read
        }

        private func stateFile(_ kind: String, _ identity: HiDPIDisplayIdentity) -> URL {
            HiDPIOverride.stateFile(
                kind, vendorID: identity.vendorID, productID: identity.productID, root: stateRoot
            )
        }

        /// What the helper recorded when it published the file: its digest and its identity on the
        /// volume. A byte-identical copy someone else made has a different identity.
        private func installedRecord(_ identity: HiDPIDisplayIdentity) -> (digest: String, fileIdentity: String)? {
            guard let text = try? String(contentsOf: stateFile("installed", identity), encoding: .utf8) else {
                return nil
            }
            let lines = text.split(separator: "\n").map(String.init)
            guard lines.count == 2, lines[1].hasPrefix("id=\(HiDPITransaction.identityPrefix)") else { return nil }
            return (lines[0], String(lines[1].dropFirst(3)))
        }

        /// The file's identity in the form the helper records (volume UUID and inode); nil when it
        /// can't be determined, which never matches a record.
        private static func fileIdentity(of url: URL) -> String? {
            HiDPITransaction.identity(ofPath: url.path)
        }

        /// The helper writes the boot time here when it removes a file macOS had read at boot.
        private func loadedFileWasRemovedThisBoot(_ identity: HiDPIDisplayIdentity) -> Bool {
            guard let boot = Self.bootDate?.timeIntervalSince1970,
                  let text = try? String(contentsOf: stateFile("removed", identity), encoding: .utf8),
                  let recorded = Int(text.trimmingCharacters(in: .whitespacesAndNewlines))
            else {
                return false
            }
            return recorded == Int(boot)
        }

        /// Whether the helper has an unfinished change for this model, from its record file.
        func isRecoveryPending(_ identity: HiDPIDisplayIdentity) -> Bool {
            FileManager.default.fileExists(atPath: stateFile("record", identity).path)
        }

        /// Where the helper keeps the original override of an interrupted removal, when another
        /// file has taken its path and the original is still there; nil otherwise. A record that
        /// still says "conflict" after the original was put back doesn't count.
        func heldOriginal(_ identity: HiDPIDisplayIdentity) -> String? {
            guard let data = try? Data(contentsOf: stateFile("record", identity)),
                  let record = HiDPITransaction.Record(data: data), record.conflict
            else {
                return nil
            }
            let model = HiDPITransaction.Model(vendorID: identity.vendorID, productID: identity.productID)
            let hold = overridesRoot.appendingPathComponent(model.vendorFolder)
                .appendingPathComponent(model.holdName).path
            return (try? FileManager.default.attributesOfItem(atPath: hold)) == nil ? nil : hold
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

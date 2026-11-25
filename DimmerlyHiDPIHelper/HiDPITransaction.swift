//
//  HiDPITransaction.swift
//  DimmerlyHiDPIHelper
//
//  The privileged half of the HiDPI feature: installs and removes one display override
//  file. Direct download only. The same file is built into the one-shot helper tool, which
//  runs as root for the length of one change and then exits, and into the app target so the
//  tests can drive it against a temporary folder.
//
//  Every path below the trusted base is reached through directory descriptors that were
//  checked as they were opened, and every change to a directory entry is an exclusive
//  rename (`renameatx_np` with `RENAME_EXCL`), which fails instead of replacing anything.
//  A small root-owned record per display model says what a change was about to do, so an
//  interrupted change can be finished or undone before the next one starts.
//

#if !APPSTORE

    import CryptoKit
    import Darwin
    import Foundation

    nonisolated enum HiDPITransaction {
        // MARK: Configuration

        /// What the helper changes. Production always uses `.system`; tests point it at a
        /// temporary folder owned by the current user and replace the preference with a stand-in.
        struct Configuration {
            /// Every folder from here down to the one that holds the files is checked.
            var trustedBase = "/Library"
            /// The override root and the state folder, below `trustedBase`.
            var overridesComponents = ["Displays", "Contents", "Resources", "Overrides"]
            var stateComponents = ["Application Support", "Dimmerly", "HiDPI"]
            var ownerUID: uid_t = 0
            var ownerGID: gid_t = 0
            /// Whether the process must be root (production) or may be anyone (tests).
            var requiresRoot = true
            var bootTime: () -> Date? = { HiDPITransaction.systemBootTime() }
            var preferenceIsEnabled: () throws -> Bool = { try SystemPreference.isEnabled() }
            var enablePreference: () throws -> Void = { try SystemPreference.enable() }
            /// Called as each step is reached; tests use it to change the filesystem at that
            /// moment or to stop dead, as a crash would.
            var checkpoint: (Step) throws -> Void = { _ in }

            static var system: Configuration {
                Configuration()
            }
        }

        enum Step: Equatable {
            case beforeInstallPublish
            case afterInstallRecord
            case afterInstallPreference
            case afterInstallPublish
            case beforeRemoveHold
            case afterRemoveRecord
            case afterRemoveHold
            case afterRemoveUnlink
            /// Each state-file write or delete and each directory sync, before it happens; tests
            /// throw here to stand in for a failing disk.
            case writeState(String)
            case deleteState(String)
            case syncDirectory
        }

        /// Thrown by a test checkpoint to stop without any cleanup, as a killed process would.
        struct Crash: Error {}

        enum Outcome: Equatable {
            case done
            /// Nothing was changed on purpose: a file was in the way, or the file wasn't Dimmerly's.
            case refused(String)
            /// An earlier removal left the original override here and its path is taken. It is
            /// untouched; the user decides what to do with it.
            case held(path: String)
        }

        enum Failure: Error, Equatable {
            case notRoot
            case invalidInput(String)
            case unsafe(String)
            case unsupported(String)
            case io(String)
        }

        // MARK: Identity and names

        struct Model {
            let vendorID: UInt32
            let productID: UInt32

            var vendorFolder: String {
                "DisplayVendorID-\(String(vendorID, radix: 16))"
            }

            var productFile: String {
                "DisplayProductID-\(String(productID, radix: 16))"
            }

            var holdName: String {
                ".dimmerly-hold.\(key)"
            }

            var stageName: String {
                ".dimmerly-stage.\(key)"
            }

            var key: String {
                "\(String(vendorID, radix: 16))-\(String(productID, radix: 16))"
            }

            var recordName: String {
                "\(key).txn"
            }

            var installedName: String {
                "\(key).installed"
            }

            var removedName: String {
                "\(key).removed"
            }

            var lockName: String {
                "vendor-\(String(vendorID, radix: 16)).lock"
            }
        }

        static let maximumFileSize = 64 * 1024
        static let renameExclusive: UInt32 = 0x0000_0004
        static let markerKey = "DimmerlyHiDPIOverride"
        static let allowedKeys: Set<String> = [
            "DisplayProductName", "DisplayVendorID", "DisplayProductID", "scale-resolutions", markerKey,
        ]

        static func sha256Hex(_ data: Data) -> String {
            SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }

        // MARK: Operations

        /// Installs `contents` as the override for `model`. Never replaces a file.
        static func install(model: Model, contents: Data, configuration: Configuration) throws -> Outcome {
            try requirePrivilege(configuration)
            try validate(contents: contents, for: model)
            let digest = sha256Hex(contents)

            let context = try Context(model: model, configuration: configuration, createFolders: true)
            defer { context.close() }
            if let held = try reconcile(context) {
                return held
            }

            switch try entryKind(context.vendorFD, model.productFile) {
            case .absent: break
            default: return .refused("an override file already exists for this display")
            }

            try context.writeRecord(Record(operation: .install, digest: digest, loaded: false, conflict: false))
            try configuration.checkpoint(.afterInstallRecord)

            var published = false
            do {
                try writeStage(context, contents: contents)
                if try !configuration.preferenceIsEnabled() {
                    try configuration.enablePreference()
                }
                try configuration.checkpoint(.afterInstallPreference)
                try configuration.checkpoint(.beforeInstallPublish)
                guard try exclusiveRename(
                    context.vendorFD, model.stageName, context.vendorFD, model.productFile
                ) else {
                    try cleanUpInstall(context)
                    return .refused("an override file appeared for this display")
                }
                published = true
                try configuration.checkpoint(.afterInstallPublish)
                try context.sync(context.vendorFD)
                try context.writeState(model.installedName, Data((digest + "\n").utf8))
                try context.deleteState(model.removedName)
                try context.deleteRecord()
                return .done
            } catch let crash as Crash {
                throw crash
            } catch {
                // Once the file is published the journal is all that says whose it is; it stays
                // until the outcome is recorded, and the next change finishes the job.
                if !published {
                    try? cleanUpInstall(context)
                }
                throw error
            }
        }

        /// Removes the override for `model` if it is exactly `expectedDigest`'s file.
        static func remove(model: Model, expectedDigest: String, configuration: Configuration) throws -> Outcome {
            try requirePrivilege(configuration)
            let context = try Context(model: model, configuration: configuration, createFolders: false)
            defer { context.close() }
            if let held = try reconcile(context) {
                return held
            }

            guard case .regular = try entryKind(context.vendorFD, model.productFile) else {
                return .refused("the override file is missing or isn't a regular file")
            }
            // Only a file this helper installed: its own root-owned record must name the digest.
            let installed = try readFile(context.stateFD, model.installedName, maximum: 128)
            guard installed.map({ (String(bytes: $0, encoding: .utf8) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines) }) == expectedDigest
            else {
                return .refused("the helper has no record of installing this file")
            }
            let loaded = try predatesBoot(context.vendorFD, model.productFile, configuration)
            try context.writeRecord(Record(operation: .remove, digest: expectedDigest, loaded: loaded, conflict: false))
            try configuration.checkpoint(.afterRemoveRecord)

            try configuration.checkpoint(.beforeRemoveHold)
            guard try exclusiveRename(context.vendorFD, model.productFile, context.vendorFD, model.holdName) else {
                try context.deleteRecord()
                return .refused("the override file changed while Dimmerly was removing it")
            }
            try configuration.checkpoint(.afterRemoveHold)
            return try finishRemoval(context, expectedDigest: expectedDigest, loaded: loaded)
        }

        /// Finishes or undoes an interrupted change for `model` and reports a conflict, if any.
        static func recover(model: Model, configuration: Configuration) throws -> Outcome {
            try requirePrivilege(configuration)
            let context = try Context(model: model, configuration: configuration, createFolders: false)
            defer { context.close() }
            return try reconcile(context) ?? .done
        }

        // MARK: Removal and recovery

        /// Decides what to do with the entry held aside: delete it if it is the expected file,
        /// otherwise put it back.
        private static func finishRemoval(_ context: Context, expectedDigest: String, loaded: Bool) throws -> Outcome {
            let model = context.model
            var isExpected = false
            if case .regular = try entryKind(context.vendorFD, model.holdName),
               let data = try readFile(context.vendorFD, model.holdName, maximum: maximumFileSize)
            {
                isExpected = sha256Hex(data) == expectedDigest
            }

            if isExpected {
                if loaded {
                    try context.writeState(model.removedName, Data("\(bootSeconds(context.configuration))\n".utf8))
                }
                guard unlinkat(context.vendorFD, model.holdName, 0) == 0 || errno == ENOENT else {
                    throw Failure.io("couldn't delete the removed override")
                }
                try context.configuration.checkpoint(.afterRemoveUnlink)
                try context.sync(context.vendorFD)
                try context.deleteState(model.installedName)
                try context.deleteRecord()
                _ = unlinkat(context.overridesFD, model.vendorFolder, AT_REMOVEDIR)
                return .done
            }

            if try exclusiveRename(context.vendorFD, model.holdName, context.vendorFD, model.productFile) {
                // The journal goes only after the restored entry is durable.
                try context.sync(context.vendorFD)
                try context.deleteRecord()
                return .refused("the override file isn't the one Dimmerly installed")
            }
            // Something took the path in the meantime: leave the original where it is.
            var record = try context.readRecord()
            record?.conflict = true
            if let record {
                try context.writeRecord(record)
            }
            return .held(path: context.holdPath)
        }

        /// Brings an interrupted change for the model to a stable state. Returns an outcome
        /// when the model can't proceed (a held original is waiting), else nil.
        private static func reconcile(_ context: Context) throws -> Outcome? {
            let model = context.model
            guard let record = try context.readRecord() else { return nil }

            switch record.operation {
            case .install:
                // Never published: remove what was staged. Published: record it as installed.
                _ = unlinkat(context.vendorFD, model.stageName, 0)
                if case .regular = try entryKind(context.vendorFD, model.productFile),
                   let data = try readFile(context.vendorFD, model.productFile, maximum: maximumFileSize),
                   sha256Hex(data) == record.digest
                {
                    try context.writeState(model.installedName, Data((record.digest + "\n").utf8))
                    try context.deleteState(model.removedName)
                }
                try context.deleteRecord()
                return nil

            case .remove:
                switch try entryKind(context.vendorFD, model.holdName) {
                case .absent:
                    // The entry was never held, or its removal finished.
                    if case .absent = try entryKind(context.vendorFD, model.productFile) {
                        try context.deleteState(model.installedName)
                    }
                    try context.deleteRecord()
                    return nil
                default:
                    let outcome = try finishRemoval(context, expectedDigest: record.digest, loaded: record.loaded)
                    if case .done = outcome {
                        return nil
                    }
                    if case .held = outcome {
                        return outcome
                    }
                    return nil
                }
            }
        }

        private static func cleanUpInstall(_ context: Context) throws {
            _ = unlinkat(context.vendorFD, context.model.stageName, 0)
            try context.deleteRecord()
        }

        // MARK: Files

        private enum EntryKind: Equatable {
            case absent
            case regular
            case other
        }

        private static func entryKind(_ directory: Int32, _ name: String) throws -> EntryKind {
            var info = stat()
            if fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) != 0 {
                if errno == ENOENT {
                    return .absent
                }
                throw Failure.io("couldn't look at \(name)")
            }
            return (info.st_mode & S_IFMT) == S_IFREG ? .regular : .other
        }

        /// Reads a regular file without following links. Returns nil when it can't be opened as one.
        private static func readFile(_ directory: Int32, _ name: String, maximum: Int) throws -> Data? {
            let fd = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { return nil }
            defer { close(fd) }
            var info = stat()
            guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, Int(info.st_size) <= maximum else {
                return nil
            }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 8192)
            while true {
                let count = read(fd, &buffer, buffer.count)
                if count < 0 {
                    throw Failure.io("couldn't read \(name)")
                }
                if count == 0 {
                    break
                }
                data.append(contentsOf: buffer[0 ..< count])
                if data.count > maximum {
                    return nil
                }
            }
            return data
        }

        private static func writeStage(_ context: Context, contents: Data) throws {
            let model = context.model
            // A stale stage belongs to an interrupted change that reconcile has already handled.
            _ = unlinkat(context.vendorFD, model.stageName, 0)
            let fd = openat(
                context.vendorFD, model.stageName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600
            )
            guard fd >= 0 else { throw Failure.io("couldn't create the staging file") }
            defer { close(fd) }
            guard fchown(fd, context.configuration.ownerUID, context.configuration.ownerGID) == 0,
                  fchmod(fd, 0o644) == 0
            else {
                throw Failure.io("couldn't set the staging file's owner")
            }
            try writeAll(fd, contents)
            guard fsync(fd) == 0 else { throw Failure.io("couldn't save the staging file") }
        }

        fileprivate static func writeAll(_ fd: Int32, _ data: Data) throws {
            try data.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let written = write(fd, raw.baseAddress! + offset, raw.count - offset)
                    if written < 0 {
                        throw Failure.io("couldn't write a file")
                    }
                    offset += written
                }
            }
        }

        /// Renames an entry only if nothing exists at the destination. False when something does.
        private static func exclusiveRename(
            _ fromDirectory: Int32, _ from: String, _ toDirectory: Int32, _ to: String
        ) throws -> Bool {
            if renameatx_np(fromDirectory, from, toDirectory, to, renameExclusive) == 0 {
                return true
            }
            switch errno {
            case EEXIST: return false
            case ENOENT: return false
            case ENOTSUP, EINVAL:
                throw Failure.unsupported("this volume can't do an exclusive rename")
            default: throw Failure.io("couldn't rename \(from)")
            }
        }

        private static func predatesBoot(
            _ directory: Int32, _ name: String, _ configuration: Configuration
        ) throws -> Bool {
            var info = stat()
            guard fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
                  let boot = configuration.bootTime()
            else {
                return false
            }
            return Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)) < boot
        }

        private static func bootSeconds(_ configuration: Configuration) -> Int {
            Int(configuration.bootTime()?.timeIntervalSince1970 ?? 0)
        }

        static func systemBootTime() -> Date? {
            var bootTime = timeval()
            var size = MemoryLayout<timeval>.stride
            var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
            guard sysctl(&mib, 2, &bootTime, &size, nil, 0) == 0 else { return nil }
            return Date(timeIntervalSince1970: TimeInterval(bootTime.tv_sec))
        }

        // MARK: Input validation

        private static func requirePrivilege(_ configuration: Configuration) throws {
            if configuration.requiresRoot, geteuid() != 0 {
                throw Failure.notRoot
            }
        }

        /// The file must be exactly what Dimmerly writes: a property list holding only the
        /// display's HiDPI settings and Dimmerly's marker, for this very model.
        static func validate(contents: Data, for model: Model) throws {
            guard !contents.isEmpty, contents.count <= maximumFileSize else {
                throw Failure.invalidInput("the override file is empty or too large")
            }
            guard let plist = try? PropertyListSerialization.propertyList(from: contents, format: nil)
                as? [String: Any]
            else {
                throw Failure.invalidInput("the override file isn't a property list dictionary")
            }
            guard Set(plist.keys).isSubset(of: allowedKeys), plist[markerKey] as? Bool == true else {
                throw Failure.invalidInput("the override file has unexpected keys or no Dimmerly marker")
            }
            guard (plist["DisplayVendorID"] as? Int) == Int(model.vendorID),
                  (plist["DisplayProductID"] as? Int) == Int(model.productID)
            else {
                throw Failure.invalidInput("the override file is for a different display")
            }
            if let name = plist["DisplayProductName"], (name as? String).map({ $0.count <= 256 }) != true {
                throw Failure.invalidInput("the display name is invalid")
            }
            guard let sizes = plist["scale-resolutions"] as? [Data], !sizes.isEmpty, sizes.count <= 256,
                  sizes.allSatisfy({ $0.count == 8 || $0.count == 16 })
            else {
                throw Failure.invalidInput("the size list is invalid")
            }
        }

        // MARK: Records

        enum RecordOperation: String { case install, remove }

        struct Record: Equatable {
            var operation: RecordOperation
            var digest: String
            var loaded: Bool
            var conflict: Bool

            var data: Data {
                let lines = [
                    "op=\(operation.rawValue)", "digest=\(digest)",
                    "loaded=\(loaded ? 1 : 0)", "conflict=\(conflict ? 1 : 0)",
                ]
                return Data((lines.joined(separator: "\n") + "\n").utf8)
            }

            init(operation: RecordOperation, digest: String, loaded: Bool, conflict: Bool) {
                self.operation = operation
                self.digest = digest
                self.loaded = loaded
                self.conflict = conflict
            }

            init?(data: Data) {
                var fields: [String: String] = [:]
                for line in (String(bytes: data, encoding: .utf8) ?? "").split(separator: "\n") {
                    let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
                    if parts.count == 2 {
                        fields[parts[0]] = parts[1]
                    }
                }
                guard let op = fields["op"].flatMap(RecordOperation.init(rawValue:)),
                      let digest = fields["digest"], digest.count == 64
                else {
                    return nil
                }
                self.init(
                    operation: op, digest: digest, loaded: fields["loaded"] == "1", conflict: fields["conflict"] == "1"
                )
            }
        }

        // MARK: Directory descriptors

        /// The descriptors for one change, opened and checked, plus the vendor-wide lock.
        private final class Context {
            let model: Model
            let configuration: Configuration
            let overridesFD: Int32
            let vendorFD: Int32
            let stateFD: Int32
            private let lockFD: Int32
            let holdPath: String

            init(model: Model, configuration: Configuration, createFolders: Bool) throws {
                self.model = model
                self.configuration = configuration
                let base = try HiDPITransaction.openTrusted(
                    path: configuration.trustedBase, configuration: configuration
                )
                defer { Darwin.close(base) }
                var opened: [Int32] = []
                func open(_ components: [String], create: Bool) throws -> Int32 {
                    var current = Darwin.dup(base)
                    for component in components {
                        let next: Int32
                        do {
                            next = try HiDPITransaction.openTrusted(
                                child: component, of: current, create: create, configuration: configuration
                            )
                        } catch {
                            Darwin.close(current)
                            throw error
                        }
                        Darwin.close(current)
                        current = next
                    }
                    opened.append(current)
                    return current
                }
                do {
                    let state = try open(configuration.stateComponents, create: true)
                    // Racing creators of the same file can see a spurious ENOENT from the file system,
                    // so a missing-file error from O_CREAT is retried briefly.
                    var lock = openat(state, model.lockName, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
                    var attempts = 0
                    while lock < 0, errno == ENOENT, attempts < 200 {
                        attempts += 1
                        usleep(1000)
                        lock = openat(state, model.lockName, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
                    }
                    guard lock >= 0 else { throw Failure.io("couldn't open the lock file (\(errno))") }
                    opened.append(lock)
                    var locked = flock(lock, LOCK_EX)
                    while locked != 0, errno == EINTR {
                        locked = flock(lock, LOCK_EX)
                    }
                    guard locked == 0 else { throw Failure.io("couldn't lock the display model (\(errno))") }
                    // Only under the lock: another change may be deleting the vendor folder, and a
                    // descriptor opened before the lock could point at a folder that is already gone.
                    let overrides = try open(configuration.overridesComponents, create: createFolders)
                    let vendor = try HiDPITransaction.openTrusted(
                        child: model.vendorFolder, of: overrides, create: createFolders, configuration: configuration
                    )
                    opened.append(vendor)
                    overridesFD = overrides
                    vendorFD = vendor
                    stateFD = state
                    lockFD = lock
                } catch {
                    opened.forEach { Darwin.close($0) }
                    throw error
                }
                let parts = [configuration.trustedBase] + configuration.overridesComponents
                    + [model.vendorFolder, model.holdName]
                holdPath = parts.joined(separator: "/")
            }

            func close() {
                Darwin.close(lockFD)
                Darwin.close(vendorFD)
                Darwin.close(overridesFD)
                Darwin.close(stateFD)
            }

            // State files live in a root-owned folder and are replaced atomically.

            /// Flushes a directory's entries to disk; a failure is an error, not something to ignore.
            func sync(_ directory: Int32) throws {
                try configuration.checkpoint(.syncDirectory)
                guard fsync(directory) == 0 else { throw Failure.io("couldn't save a folder to disk") }
            }

            func writeState(_ name: String, _ data: Data) throws {
                try configuration.checkpoint(.writeState(name))
                let temporary = ".\(name).tmp"
                _ = unlinkat(stateFD, temporary, 0)
                let fd = openat(stateFD, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
                guard fd >= 0 else { throw Failure.io("couldn't create a state file") }
                defer { Darwin.close(fd) }
                guard fchown(fd, configuration.ownerUID, configuration.ownerGID) == 0, fchmod(fd, 0o644) == 0 else {
                    throw Failure.io("couldn't set a state file's owner")
                }
                try HiDPITransaction.writeAll(fd, data)
                guard fsync(fd) == 0, renameat(stateFD, temporary, stateFD, name) == 0 else {
                    _ = unlinkat(stateFD, temporary, 0)
                    throw Failure.io("couldn't save a state file")
                }
                try sync(stateFD)
            }

            func deleteState(_ name: String) throws {
                try configuration.checkpoint(.deleteState(name))
                if unlinkat(stateFD, name, 0) != 0, errno != ENOENT {
                    throw Failure.io("couldn't delete a state file")
                }
                try sync(stateFD)
            }

            func writeRecord(_ record: Record) throws {
                try writeState(model.recordName, record.data)
            }

            func readRecord() throws -> Record? {
                guard let data = try HiDPITransaction.readFile(stateFD, model.recordName, maximum: 4096) else {
                    if try HiDPITransaction.entryKind(stateFD, model.recordName) == .absent {
                        return nil
                    }
                    throw Failure.unsafe("the change record can't be read")
                }
                guard let record = Record(data: data) else { throw Failure.unsafe("the change record is damaged") }
                return record
            }

            func deleteRecord() throws {
                try deleteState(model.recordName)
            }
        }

        /// Opens `path` as a trusted directory. The base itself is opened by path; it is the
        /// anchor the checks start from.
        fileprivate static func openTrusted(path: String, configuration: Configuration) throws -> Int32 {
            let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw Failure.unsafe("can't open \(path)") }
            do {
                try requireTrusted(fd, configuration)
            } catch {
                close(fd)
                throw error
            }
            return fd
        }

        fileprivate static func openTrusted(
            child name: String, of parent: Int32, create: Bool, configuration: Configuration
        ) throws -> Int32 {
            guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else {
                throw Failure.invalidInput("bad folder name")
            }
            var fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if fd < 0, errno == ENOENT, create {
                if mkdirat(parent, name, 0o755) != 0, errno != EEXIST {
                    throw Failure.io("couldn't create \(name)")
                }
                fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            guard fd >= 0 else { throw Failure.unsafe("can't open \(name) as a folder") }
            do {
                try requireTrusted(fd, configuration)
            } catch {
                close(fd)
                throw error
            }
            return fd
        }

        /// A trusted folder is a directory owned by the expected user, that group and others
        /// can't write to, with no ACL. Anything that can't be read to confirm that is rejected.
        fileprivate static func requireTrusted(_ fd: Int32, _ configuration: Configuration) throws {
            var info = stat()
            guard fstat(fd, &info) == 0 else { throw Failure.unsafe("can't read a folder's attributes") }
            guard (info.st_mode & S_IFMT) == S_IFDIR else { throw Failure.unsafe("not a folder") }
            guard info.st_uid == configuration.ownerUID else { throw Failure.unsafe("a folder has the wrong owner") }
            guard info.st_mode & 0o022 == 0 else { throw Failure.unsafe("a folder is writable by others") }
            if let acl = acl_get_fd_np(fd, ACL_TYPE_EXTENDED) {
                acl_free(UnsafeMutableRawPointer(acl))
                throw Failure.unsafe("a folder has an ACL")
            }
            guard errno == ENOENT else { throw Failure.unsafe("can't read a folder's ACL") }
        }

        // MARK: The shared preference

        /// `DisplayResolutionEnabled` in `/Library/Preferences/com.apple.windowserver`.
        enum SystemPreference {
            static var domain: CFString {
                "com.apple.windowserver" as CFString
            }

            static var key: CFString {
                "DisplayResolutionEnabled" as CFString
            }

            static func isEnabled() throws -> Bool {
                try checkFile()
                let value = CFPreferencesCopyValue(key, domain, kCFPreferencesAnyUser, kCFPreferencesAnyHost)
                return (value as? Bool) == true
            }

            static func enable() throws {
                try checkFile()
                CFPreferencesSetValue(key, kCFBooleanTrue, domain, kCFPreferencesAnyUser, kCFPreferencesAnyHost)
                guard CFPreferencesSynchronize(domain, kCFPreferencesAnyUser, kCFPreferencesAnyHost),
                      try isEnabled()
                else {
                    throw Failure.io("couldn't save the display preference")
                }
            }

            /// The preference's folder must be trusted, and an existing file must be a regular
            /// file owned by root that others can't write, with no ACL.
            private static func checkFile() throws {
                let configuration = Configuration.system
                let folder = try HiDPITransaction.openTrusted(
                    path: "/Library/Preferences", configuration: configuration
                )
                defer { close(folder) }
                try checkFile(named: "com.apple.windowserver.plist", in: folder, configuration: configuration)
            }

            static func checkFile(named name: String, in folder: Int32, configuration: Configuration) throws {
                let fd = openat(folder, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
                if fd < 0 {
                    if errno == ENOENT {
                        return
                    }
                    throw Failure.unsafe("can't read the display preference file")
                }
                defer { close(fd) }
                var info = stat()
                guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
                      info.st_uid == configuration.ownerUID, info.st_mode & 0o022 == 0
                else {
                    throw Failure.unsafe("the display preference file isn't safe to change")
                }
                if let acl = acl_get_fd_np(fd, ACL_TYPE_EXTENDED) {
                    acl_free(UnsafeMutableRawPointer(acl))
                    throw Failure.unsafe("the display preference file has an ACL")
                }
                guard errno == ENOENT else { throw Failure.unsafe("can't read the display preference file's ACL") }
            }
        }
    }

#endif

//
//  HiDPIModeManagerTests.swift
//  DimmerlyTests
//
//  Tests for the HiDPI helper's transaction logic and for the manager that drives it. The
//  transaction runs in this process against a temporary folder owned by the current user,
//  with a stand-in for the system preference and test checkpoints that change the filesystem
//  at chosen moments or stop dead like a crash. Nothing under /Library changes and no
//  password is asked for.
//

// swiftlint:disable file_length

#if !APPSTORE

    @testable import Dimmerly
    import XCTest

    /// A stand-in for `DisplayResolutionEnabled`.
    private final class FakePreference: @unchecked Sendable {
        private let lock = NSLock()
        private var enabled: Bool?
        private var writes = 0

        init(_ value: Bool?) {
            enabled = value
        }

        var value: Bool? {
            lock.withLock { enabled }
        }

        var writeCount: Int {
            lock.withLock { writes }
        }

        func isEnabled() -> Bool {
            lock.withLock { enabled == true }
        }

        func enable() {
            lock.withLock {
                enabled = true
                writes += 1
            }
        }
    }

    @MainActor
    class HiDPIFixtureTestCase: XCTestCase {
        let identity = HiDPIDisplayIdentity(
            vendorID: 0x4A8B, productID: 0x2555, nativeWidth: 1920, nativeHeight: 1080, name: "ANMITE"
        )
        fileprivate var base = URL(fileURLWithPath: "/")
        fileprivate var preference = FakePreference(nil)
        nonisolated(unsafe) var checkpoint: (HiDPITransaction.Step) throws -> Void = { _ in }
        nonisolated(unsafe) var stageHook: ((Int32, String) -> Int32)?

        override func setUpWithError() throws {
            base = try URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .resolvingSymlinksInPath()
                .appendingPathComponent("hidpi-tests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            preference = FakePreference(nil)
            checkpoint = { _ in }
            stageHook = nil
        }

        override func tearDownWithError() throws {
            try? FileManager.default.removeItem(at: base)
        }

        var overridesRoot: URL {
            base.appendingPathComponent("Overrides", isDirectory: true)
        }

        var stateRoot: URL {
            base.appendingPathComponent("State", isDirectory: true)
        }

        func model(_ product: UInt32? = nil) -> HiDPITransaction.Model {
            .init(vendorID: identity.vendorID, productID: product ?? identity.productID)
        }

        func file(_ product: UInt32? = nil) -> URL {
            HiDPIOverride.fileURL(
                vendorID: identity.vendorID, productID: product ?? identity.productID, root: overridesRoot
            )
        }

        var vendorFolder: URL {
            file().deletingLastPathComponent()
        }

        func contents(_ product: UInt32? = nil) throws -> Data {
            try HiDPIOverride.plistData(for: HiDPIDisplayIdentity(
                vendorID: identity.vendorID,
                productID: product ?? identity.productID,
                nativeWidth: identity.nativeWidth,
                nativeHeight: identity.nativeHeight,
                name: identity.name
            ))
        }

        var configuration: HiDPITransaction.Configuration {
            var configuration = HiDPITransaction.Configuration()
            configuration.trustedBase = base.path
            configuration.overridesComponents = ["Overrides"]
            configuration.stateComponents = ["State"]
            configuration.ownerUID = getuid()
            configuration.ownerGID = getgid()
            configuration.requiresRoot = false
            configuration.bootTime = { Date(timeIntervalSince1970: 2_000_000_000) }
            let preference = preference
            configuration.preferenceIsEnabled = { preference.isEnabled() }
            configuration.enablePreference = { preference.enable() }
            configuration.checkpoint = checkpoint
            if let stageHook {
                configuration.unlinkStage = stageHook
            }
            return configuration
        }

        func install(_ product: UInt32? = nil) throws -> HiDPITransaction.Outcome {
            try HiDPITransaction.install(
                model: model(product), contents: contents(product), configuration: configuration
            )
        }

        func remove(_ product: UInt32? = nil, digest: String? = nil) throws -> HiDPITransaction.Outcome {
            try HiDPITransaction.remove(
                model: model(product),
                expectedDigest: digest ?? HiDPIOverride.sha256Hex(contents(product)),
                configuration: configuration
            )
        }

        func recover(_ product: UInt32? = nil) throws -> HiDPITransaction.Outcome {
            try HiDPITransaction.recover(model: model(product), configuration: configuration)
        }

        func seed(_ data: Data, product: UInt32? = nil) throws {
            try FileManager.default.createDirectory(at: vendorFolder, withIntermediateDirectories: true)
            try data.write(to: file(product))
        }

        func state(_ name: String) -> String? {
            (try? String(contentsOf: stateRoot.appendingPathComponent(name), encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        func names(in folder: URL) -> [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
        }

        /// Runs `body` with a checkpoint that fires once, the first time `step` is reached.
        func at(_ step: HiDPITransaction.Step, _ body: @escaping () throws -> Void) {
            nonisolated(unsafe) var fired = false
            checkpoint = { reached in
                guard reached == step, !fired else { return }
                fired = true
                try body()
            }
        }

        func crash(at step: HiDPITransaction.Step) {
            at(step) { throw HiDPITransaction.Crash() }
        }
    }

    // MARK: - Install

    final class HiDPIInstallTests: HiDPIFixtureTestCase {
        func testInstallPublishesTheFileRecordsItAndSetsThePreference() throws {
            XCTAssertEqual(try install(), .done)

            let data = try contents()
            XCTAssertEqual(try Data(contentsOf: file()), data)
            XCTAssertEqual(state(model().installedName), HiDPIOverride.sha256Hex(data))
            XCTAssertNil(state(model().recordName))
            XCTAssertEqual(names(in: vendorFolder), [model().productFile])
            XCTAssertEqual(preference.value, true)
            let mode = try FileManager.default.attributesOfItem(atPath: file().path)[.posixPermissions] as? Int
            XCTAssertEqual(mode, 0o644)
        }

        func testInstallSetsTheSharedPreferenceOnlyWhenItIsNotAlreadyOn() throws {
            preference = FakePreference(true)
            XCTAssertEqual(try install(), .done)
            XCTAssertEqual(preference.writeCount, 0)
        }

        func testInstallRefusesAnythingAlreadyAtTheDestination() throws {
            try FileManager.default.createDirectory(at: vendorFolder, withIntermediateDirectories: true)
            let target = base.appendingPathComponent("target", isDirectory: true)
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)

            let occupants: [() throws -> Void] = [
                { try Data("theirs".utf8).write(to: self.file()) },
                { try FileManager.default.createDirectory(at: self.file(), withIntermediateDirectories: true) },
                { try FileManager.default.createSymbolicLink(at: self.file(), withDestinationURL: target) },
            ]
            for occupy in occupants {
                try? FileManager.default.removeItem(at: file())
                try occupy()
                guard case .refused = try install() else { return XCTFail("expected a refusal") }
                XCTAssertEqual(names(in: vendorFolder), [model().productFile])
                XCTAssertEqual(names(in: target), [])
                XCTAssertNil(state(model().recordName))
            }
            XCTAssertNil(preference.value)
        }

        func testAnOccupantThatAppearsJustBeforePublishingIsNeverReplacedOrLinkedInto() throws {
            let target = base.appendingPathComponent("target", isDirectory: true)
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)

            let occupants: [() throws -> Void] = [
                { try Data("theirs".utf8).write(to: self.file()) },
                { try FileManager.default.createDirectory(at: self.file(), withIntermediateDirectories: true) },
                { try FileManager.default.createSymbolicLink(at: self.file(), withDestinationURL: target) },
            ]
            for occupy in occupants {
                try? FileManager.default.removeItem(at: file())
                at(.beforeInstallPublish) { try occupy() }
                guard case .refused = try install() else { return XCTFail("expected a refusal") }

                // The occupant is untouched, nothing was linked inside it or its target, and
                // neither the staging file nor the change record is left.
                XCTAssertEqual(names(in: vendorFolder), [model().productFile])
                XCTAssertEqual(names(in: target), [])
                XCTAssertEqual(names(in: file()).filter { $0.hasPrefix(".dimmerly") }, [])
                XCTAssertNil(state(model().recordName))
                XCTAssertNil(state(model().installedName))
            }
        }

        func testACrashBeforePublishingLeavesNothingInstalledAndTheNextChangeCleansUp() throws {
            crash(at: .afterInstallPreference)
            XCTAssertThrowsError(try install()) { XCTAssertTrue($0 is HiDPITransaction.Crash) }
            XCTAssertNotNil(state(model().recordName))
            XCTAssertTrue(names(in: vendorFolder).contains(model().stageName))

            checkpoint = { _ in }
            XCTAssertEqual(try recover(), .done)
            XCTAssertEqual(names(in: vendorFolder), [])
            XCTAssertNil(state(model().recordName))
            XCTAssertNil(state(model().installedName))
        }

        func testACrashAfterPublishingIsRecognisedAsInstalledAndCanBeRemoved() throws {
            crash(at: .afterInstallPublish)
            XCTAssertThrowsError(try install())
            XCTAssertNil(state(model().installedName))

            checkpoint = { _ in }
            XCTAssertEqual(try recover(), .done)
            XCTAssertEqual(state(model().installedName), try HiDPIOverride.sha256Hex(contents()))
            XCTAssertNil(state(model().recordName))
            XCTAssertEqual(try remove(), .done)
            XCTAssertFalse(FileManager.default.fileExists(atPath: file().path))
        }

        func testACrashRightAfterWritingTheRecordIsCleanedUpBeforeTheNextInstall() throws {
            crash(at: .afterInstallRecord)
            XCTAssertThrowsError(try install())

            checkpoint = { _ in }
            XCTAssertEqual(try install(), .done)
            XCTAssertEqual(names(in: vendorFolder), [model().productFile])
        }

        func testAFailureSettingThePreferenceLeavesNoFileStageOrRecord() throws {
            var failing = configuration
            failing.enablePreference = { throw HiDPITransaction.Failure.io("no") }
            XCTAssertThrowsError(
                try HiDPITransaction.install(model: model(), contents: contents(), configuration: failing)
            )
            XCTAssertEqual(names(in: vendorFolder), [])
            XCTAssertNil(state(model().recordName))
        }

        func testInstallRejectsFoldersItCantTrust() throws {
            // Writable by others.
            try FileManager.default.createDirectory(at: vendorFolder, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: vendorFolder.path)
            XCTAssertThrowsError(try install())
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: vendorFolder.path)

            // An ACL entry.
            XCTAssertEqual(try Self.run("/bin/chmod", ["+a", "everyone allow add_file", vendorFolder.path]), 0)
            XCTAssertThrowsError(try install())
            XCTAssertEqual(names(in: vendorFolder), [])
        }

        func testInstallRejectsASymbolicLinkInTheFolderPath() throws {
            let elsewhere = base.appendingPathComponent("elsewhere", isDirectory: true)
            try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: overridesRoot, withDestinationURL: elsewhere)

            XCTAssertThrowsError(try install())
            XCTAssertEqual(names(in: elsewhere), [])
        }

        func testInstallRejectsAnUntrustedStateFolder() throws {
            try FileManager.default.createDirectory(at: stateRoot, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: stateRoot.path)
            XCTAssertThrowsError(try install())
            XCTAssertFalse(FileManager.default.fileExists(atPath: file().path))
        }

        func testInstallValidatesWhatItIsAskedToWrite() throws {
            let good = try XCTUnwrap(PropertyListSerialization.propertyList(
                from: contents(), format: nil
            ) as? [String: Any])

            func rejects(_ data: Data, line: UInt = #line) {
                XCTAssertThrowsError(
                    try HiDPITransaction.install(model: model(), contents: data, configuration: configuration),
                    line: line
                ) { error in
                    guard case HiDPITransaction.Failure.invalidInput = error else {
                        return XCTFail("expected invalidInput, got \(error)", line: line)
                    }
                }
            }
            func serialized(_ plist: [String: Any]) throws -> Data {
                try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            }

            rejects(Data())
            rejects(Data("not a plist".utf8))
            rejects(Data(count: HiDPITransaction.maximumFileSize + 1))
            var wrongVendor = good
            wrongVendor["DisplayVendorID"] = 7
            try rejects(serialized(wrongVendor))
            var extra = good
            extra["IODisplayEDID"] = Data([0, 1])
            try rejects(serialized(extra))
            var unmarked = good
            unmarked.removeValue(forKey: HiDPIOverride.ownershipKey)
            try rejects(serialized(unmarked))
            var badSizes = good
            badSizes["scale-resolutions"] = [Data([1, 2, 3])]
            try rejects(serialized(badSizes))
            XCTAssertEqual(names(in: vendorFolder), [])
        }

        func testTheExistingPreferenceFileMustBeSafeToChange() throws {
            let folder = base.appendingPathComponent("prefs", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let name = "com.apple.windowserver.plist"
            let path = folder.appendingPathComponent(name)
            let fd = open(folder.path, O_RDONLY | O_DIRECTORY)
            defer { close(fd) }
            func check() throws {
                try HiDPITransaction.SystemPreference.checkFile(named: name, in: fd, configuration: configuration)
            }

            XCTAssertNoThrow(try check()) // absent
            try Data("x".utf8).write(to: path)
            XCTAssertNoThrow(try check())

            try FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: path.path)
            XCTAssertThrowsError(try check())
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path.path)

            XCTAssertEqual(try Self.run("/bin/chmod", ["+a", "everyone allow write", path.path]), 0)
            XCTAssertThrowsError(try check())
            try FileManager.default.removeItem(at: path)

            let target = base.appendingPathComponent("target")
            try Data("x".utf8).write(to: target)
            try FileManager.default.createSymbolicLink(at: path, withDestinationURL: target)
            XCTAssertThrowsError(try check())
        }

        private static func run(_ tool: String, _ arguments: [String]) throws -> Int32 {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = arguments
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        }
    }

    // MARK: - Removal and recovery

    final class HiDPIRemovalTests: HiDPIFixtureTestCase {
        func testRemovalDeletesTheFileItsRecordAndTheEmptyFolderAndLeavesThePreference() throws {
            XCTAssertEqual(try install(), .done)
            let writes = preference.writeCount

            XCTAssertEqual(try remove(), .done)
            XCTAssertFalse(FileManager.default.fileExists(atPath: vendorFolder.path))
            XCTAssertNil(state(model().installedName))
            XCTAssertNil(state(model().recordName))
            XCTAssertEqual(preference.writeCount, writes)
            XCTAssertEqual(preference.value, true)
        }

        func testRemovalOfAFileMacOSAlreadyReadRecordsTheBootForTheRestartNote() throws {
            XCTAssertEqual(try install(), .done)
            // Older than the stand-in boot time, so macOS has had its chance to read it.
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: 1_000)], ofItemAtPath: file().path
            )
            XCTAssertEqual(try remove(), .done)
            XCTAssertEqual(state(model().removedName), "2000000000")
        }

        func testRemovalRestoresAFileThatIsNotWhatWasExpected() throws {
            XCTAssertEqual(try install(), .done)
            let edited = Data("edited by someone else".utf8)
            try edited.write(to: file())

            guard case .refused = try remove() else { return XCTFail("expected a refusal") }
            XCTAssertEqual(try Data(contentsOf: file()), edited)
            XCTAssertEqual(names(in: vendorFolder), [model().productFile])
            XCTAssertNil(state(model().recordName))
        }

        func testAFileSwappedInJustBeforeTheHoldIsRestoredNotDeleted() throws {
            XCTAssertEqual(try install(), .done)
            let replacement = Data("a replacement".utf8)
            at(.beforeRemoveHold) {
                try FileManager.default.removeItem(at: self.file())
                try replacement.write(to: self.file())
            }

            guard case .refused = try remove() else { return XCTFail("expected a refusal") }
            XCTAssertEqual(try Data(contentsOf: file()), replacement)
        }

        func testASymbolicLinkIsNeverRemovedOrFollowed() throws {
            let target = base.appendingPathComponent("target")
            try contents().write(to: target)
            try FileManager.default.createDirectory(at: vendorFolder, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: file(), withDestinationURL: target)

            guard case .refused = try remove() else { return XCTFail("expected a refusal") }
            XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
            XCTAssertNotNil(try? FileManager.default.destinationOfSymbolicLink(atPath: file().path))
        }

        func testASymbolicLinkSwappedInBeforeTheHoldIsPutBackAsTheLinkItWas() throws {
            XCTAssertEqual(try install(), .done)
            let target = base.appendingPathComponent("target")
            try Data("referent".utf8).write(to: target)
            at(.beforeRemoveHold) {
                try FileManager.default.removeItem(at: self.file())
                try FileManager.default.createSymbolicLink(at: self.file(), withDestinationURL: target)
            }

            guard case .refused = try remove() else { return XCTFail("expected a refusal") }
            // Still the original link, not a second hard link to what it pointed at.
            XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: file().path), target.path)
            XCTAssertEqual(try Data(contentsOf: target), Data("referent".utf8))
        }

        func testWhenSomethingTakesThePathTheOriginalStaysHeldAndItsLocationIsReported() throws {
            XCTAssertEqual(try install(), .done)
            let occupant = Data("occupant".utf8)
            let edited = Data("edited".utf8)
            let target = file()
            checkpoint = { step in
                if step == .beforeRemoveHold {
                    try edited.write(to: target)
                }
                if step == .afterRemoveHold {
                    try occupant.write(to: target)
                }
            }

            let held = try remove()
            let holdPath = vendorFolder.appendingPathComponent(model().holdName).path
            XCTAssertEqual(held, .held(path: holdPath))
            XCTAssertEqual(try Data(contentsOf: file()), occupant)
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: holdPath)), edited)

            // Every later change for the model reports the same place until the way is clear.
            checkpoint = { _ in }
            XCTAssertEqual(try install(), .held(path: holdPath))
            XCTAssertEqual(try recover(), .held(path: holdPath))
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: holdPath)), edited)

            try FileManager.default.removeItem(at: file())
            XCTAssertEqual(try recover(), .done)
            XCTAssertEqual(try Data(contentsOf: file()), edited)
            XCTAssertEqual(names(in: vendorFolder), [model().productFile])
            XCTAssertNil(state(model().recordName))
        }

        func testACrashAfterTheHoldIsFinishedByTheNextChange() throws {
            XCTAssertEqual(try install(), .done)
            crash(at: .afterRemoveHold)
            XCTAssertThrowsError(try remove())
            XCTAssertFalse(FileManager.default.fileExists(atPath: file().path))
            XCTAssertTrue(names(in: vendorFolder).contains(model().holdName))

            checkpoint = { _ in }
            XCTAssertEqual(try recover(), .done)
            XCTAssertFalse(FileManager.default.fileExists(atPath: vendorFolder.path))
            XCTAssertNil(state(model().installedName))
            XCTAssertNil(state(model().recordName))
        }

        func testACrashAfterTheHeldFileWasDeletedLeavesNoStaleRecords() throws {
            XCTAssertEqual(try install(), .done)
            crash(at: .afterRemoveUnlink)
            XCTAssertThrowsError(try remove())
            XCTAssertNotNil(state(model().recordName))

            checkpoint = { _ in }
            XCTAssertEqual(try recover(), .done)
            XCTAssertNil(state(model().installedName))
            XCTAssertNil(state(model().recordName))
        }

        func testACrashAfterTheHoldOfAFileThatWasNotTheExpectedOnePutsItBack() throws {
            XCTAssertEqual(try install(), .done)
            let foreign = Data("foreign".utf8)
            try foreign.write(to: file())
            crash(at: .afterRemoveHold)
            XCTAssertThrowsError(try remove())

            checkpoint = { _ in }
            XCTAssertEqual(try recover(), .done)
            XCTAssertEqual(try Data(contentsOf: file()), foreign)
        }

        func testRemovalRefusesAFileTheHelperHasNoRecordOfInstalling() throws {
            try seed(contents())
            guard case .refused = try remove() else { return XCTFail("expected a refusal") }
            XCTAssertEqual(try Data(contentsOf: file()), try contents())
            XCTAssertNil(state(model().recordName))
        }

        func testRemovalRefusesADigestThatIsNotTheInstalledOne() throws {
            XCTAssertEqual(try install(), .done)
            guard case .refused = try remove(digest: HiDPIOverride.sha256Hex(Data("other".utf8))) else {
                return XCTFail("expected a refusal")
            }
            XCTAssertEqual(try Data(contentsOf: file()), try contents())
        }

        // MARK: Different models

        func testModelsUnderOneVendorKeepTheirOwnHeldFilesAndRecords() throws {
            XCTAssertEqual(try install(0x2555), .done)
            XCTAssertEqual(try install(0x2556), .done)
            crash(at: .afterRemoveHold)
            XCTAssertThrowsError(try remove(0x2555))
            checkpoint = { _ in }

            // The other model's file and changes are unaffected by the stranded hold.
            XCTAssertEqual(try Data(contentsOf: file(0x2556)), try contents(0x2556))
            XCTAssertEqual(try remove(0x2556), .done)
            XCTAssertTrue(names(in: vendorFolder).contains(model(0x2555).holdName))
            XCTAssertFalse(names(in: vendorFolder).contains(model(0x2556).holdName))

            // Recovering one model never restores the other's file to the wrong path.
            XCTAssertEqual(try recover(0x2556), .done)
            XCTAssertFalse(FileManager.default.fileExists(atPath: file(0x2556).path))
            XCTAssertEqual(try recover(0x2555), .done)
            XCTAssertFalse(FileManager.default.fileExists(atPath: vendorFolder.path))
        }

        func testRemovingOneModelKeepsTheVendorFolderForTheOther() throws {
            XCTAssertEqual(try install(0x2555), .done)
            XCTAssertEqual(try install(0x2556), .done)
            XCTAssertEqual(try remove(0x2555), .done)
            XCTAssertEqual(names(in: vendorFolder), [model(0x2556).productFile])
        }

        func testChangesToSeveralModelsAtOnceAllLand() throws {
            let products: [UInt32] = [0x2501, 0x2502, 0x2503, 0x2504, 0x2505, 0x2506]
            let payloads = try products.map { try contents($0) }
            nonisolated(unsafe) let configuration = configuration
            let vendor = identity.vendorID
            let results = LockedList()
            DispatchQueue.concurrentPerform(iterations: products.count) { index in
                let target = HiDPITransaction.Model(vendorID: vendor, productID: products[index])
                do {
                    let outcome = try HiDPITransaction.install(
                        model: target, contents: payloads[index], configuration: configuration
                    )
                    results.append(outcome == .done ? "done" : "\(outcome)")
                } catch {
                    results.append("\(error)")
                }
            }
            XCTAssertEqual(results.values, Array(repeating: "done", count: products.count))
            XCTAssertEqual(names(in: vendorFolder).count, products.count)
        }

        // MARK: Failing disk

        private struct DiskFailure: Error {}

        /// Fails the first time `matches` accepts a step reached after `after` was seen.
        private func failDisk(
            after: HiDPITransaction.Step? = nil, at matches: @escaping (HiDPITransaction.Step) -> Bool
        ) {
            nonisolated(unsafe) var armed = after == nil
            nonisolated(unsafe) var fired = false
            checkpoint = { step in
                if step == after {
                    armed = true
                }
                guard armed, !fired, matches(step) else { return }
                fired = true
                throw DiskFailure()
            }
        }

        func testAFailureWritingTheInstalledRecordAfterPublishingKeepsTheJournal() throws {
            let installed = model().installedName
            failDisk { $0 == .writeState(installed) }
            XCTAssertThrowsError(try install())
            // Published, journal kept, no ownership record yet.
            XCTAssertEqual(try Data(contentsOf: file()), try contents())
            XCTAssertNotNil(state(model().recordName))
            XCTAssertNil(state(installed))

            checkpoint = { _ in }
            XCTAssertEqual(try recover(), .done)
            XCTAssertEqual(state(installed), try HiDPIOverride.sha256Hex(contents()))
            XCTAssertNil(state(model().recordName))
        }

        func testAFailedSyncAfterPublishingKeepsTheJournal() throws {
            failDisk(after: .afterInstallPublish) { $0 == .syncDirectory("vendor") }
            XCTAssertThrowsError(try install())
            XCTAssertNotNil(state(model().recordName))
            XCTAssertTrue(FileManager.default.fileExists(atPath: file().path))

            checkpoint = { _ in }
            XCTAssertEqual(try recover(), .done)
            XCTAssertNotNil(state(model().installedName))
            XCTAssertNil(state(model().recordName))
        }

        func testAFailureDeletingTheJournalAtTheEndOfAnInstallIsFinishedLater() throws {
            let record = model().recordName
            failDisk { $0 == .deleteState(record) }
            XCTAssertThrowsError(try install())
            XCTAssertNotNil(state(model().installedName))

            checkpoint = { _ in }
            XCTAssertEqual(try recover(), .done)
            XCTAssertNil(state(record))
            XCTAssertEqual(try remove(), .done)
        }

        func testAFailureWritingTheJournalBeforeAnythingChangesLeavesNothingBehind() throws {
            let record = model().recordName
            failDisk { $0 == .writeState(record) }
            XCTAssertThrowsError(try install())
            XCTAssertEqual(names(in: vendorFolder), [])
            XCTAssertNil(state(record))
        }

        func testAFailedSyncAfterRestoringAnOriginalKeepsTheJournalAndTheFile() throws {
            XCTAssertEqual(try install(), .done)
            let edited = Data("edited".utf8)
            try edited.write(to: file())
            failDisk(after: .afterRemoveHold) { $0 == .syncDirectory("vendor") }
            XCTAssertThrowsError(try remove())
            XCTAssertEqual(try Data(contentsOf: file()), edited)
            XCTAssertNotNil(state(model().recordName))

            checkpoint = { _ in }
            XCTAssertEqual(try recover(), .done)
            XCTAssertEqual(try Data(contentsOf: file()), edited)
            XCTAssertNil(state(model().recordName))
        }

        func testAFailureDeletingTheInstalledRecordAfterRemovalIsFinishedLater() throws {
            XCTAssertEqual(try install(), .done)
            let installed = model().installedName
            failDisk(after: .afterRemoveUnlink) { $0 == .deleteState(installed) }
            XCTAssertThrowsError(try remove())
            XCTAssertNotNil(state(model().recordName))

            checkpoint = { _ in }
            XCTAssertEqual(try recover(), .done)
            XCTAssertNil(state(installed))
            XCTAssertNil(state(model().recordName))
        }

        // MARK: Durability across recovery

        /// Records every step the transaction reaches.
        private func recordSteps() -> StepLog {
            let log = StepLog()
            checkpoint = { log.append($0) }
            return log
        }

        /// Throws a disk failure for the first `count` syncs of the folder `label` names (the vendor
        /// folder unless told otherwise). Syncs of other folders pass, so a test reaches the step
        /// it means to.
        private func failSyncs(_ count: Int, label: String = "vendor") {
            nonisolated(unsafe) var remaining = count
            checkpoint = { step in
                guard step == .syncDirectory(label), remaining > 0 else { return }
                remaining -= 1
                throw DiskFailure()
            }
        }

        func testRecoveryKeepsTheJournalThroughRepeatedSyncFailures() throws {
            crash(at: .afterInstallPublish)
            XCTAssertThrowsError(try install())

            failSyncs(2)
            XCTAssertThrowsError(try recover())
            XCTAssertNotNil(state(model().recordName))
            XCTAssertThrowsError(try recover())
            XCTAssertNotNil(state(model().recordName))
            XCTAssertNil(state(model().installedName), "nothing is recorded before the sync succeeds")

            XCTAssertEqual(try recover(), .done)
            XCTAssertNil(state(model().recordName))
            XCTAssertEqual(state(model().installedName), try HiDPIOverride.sha256Hex(contents()))
            XCTAssertEqual(try Data(contentsOf: file()), try contents())
        }

        func testRepeatedSyncFailuresAfterRestoringAnOriginalNeverLoseIt() throws {
            XCTAssertEqual(try install(), .done)
            let edited = Data("edited".utf8)
            try edited.write(to: file())
            failSyncs(3)
            XCTAssertThrowsError(try remove())
            XCTAssertThrowsError(try recover())
            XCTAssertThrowsError(try recover())
            XCTAssertNotNil(state(model().recordName))
            XCTAssertEqual(try Data(contentsOf: file()), edited)

            XCTAssertEqual(try recover(), .done)
            XCTAssertNil(state(model().recordName))
            XCTAssertEqual(try Data(contentsOf: file()), edited)
        }

        func testEveryRecoveryPathSyncsBeforeItDeletesTheJournal() throws {
            func assertSyncedBeforeJournalDelete(_ log: StepLog, file: StaticString = #filePath, line: UInt = #line) {
                let steps = log.steps
                guard let deleteIndex = steps.firstIndex(of: .deleteState(model().recordName)) else {
                    return XCTFail("the journal was never deleted", file: file, line: line)
                }
                XCTAssertTrue(
                    steps[..<deleteIndex].contains(.syncDirectory("vendor")),
                    "no directory sync before the journal was deleted: \(steps)", file: file, line: line
                )
            }

            // An install that was published.
            crash(at: .afterInstallPublish)
            XCTAssertThrowsError(try install())
            var log = recordSteps()
            XCTAssertEqual(try recover(), .done)
            assertSyncedBeforeJournalDelete(log)

            // A removal that deleted the held file.
            crash(at: .afterRemoveUnlink)
            XCTAssertThrowsError(try remove())
            log = recordSteps()
            XCTAssertEqual(try recover(), .done)
            assertSyncedBeforeJournalDelete(log)

            // An install that never published.
            crash(at: .afterInstallPreference)
            XCTAssertThrowsError(try install())
            log = recordSteps()
            XCTAssertEqual(try recover(), .done)
            assertSyncedBeforeJournalDelete(log)

            // A removal that put the original back.
            XCTAssertEqual(try install(), .done)
            try Data("edited".utf8).write(to: file())
            failSyncs(1)
            XCTAssertThrowsError(try remove())
            log = recordSteps()
            XCTAssertEqual(try recover(), .done)
            assertSyncedBeforeJournalDelete(log)
        }

        func testNewFoldersAreSyncedIntoTheirParentsBeforeTheJournalIsWritten() throws {
            let log = recordSteps()
            XCTAssertEqual(try install(), .done)
            let steps = log.steps
            let firstJournal = try XCTUnwrap(steps.firstIndex(of: .writeState(model().recordName)))
            // The state folder, the override root and the vendor folder were each synced, and so
            // was each one's parent, before the journal existed.
            let before = Array(steps[..<firstJournal])
            for name in ["State", "Overrides", model().vendorFolder] {
                XCTAssertTrue(before.contains(.syncDirectory("new folder:\(name)")), name)
                XCTAssertTrue(before.contains(.syncDirectory("parent of:\(name)")), name)
            }
        }

        func testAFailedSyncOfANewFolderStopsTheInstallBeforeAnythingIsRecorded() throws {
            failSyncs(1, label: "new folder:State")
            XCTAssertThrowsError(try install())
            XCTAssertNil(state(model().recordName))
            XCTAssertNil(state(model().installedName))

            checkpoint = { _ in }
            XCTAssertEqual(try install(), .done)
        }

        func testAFolderMadeByAnEarlierAttemptIsSyncedAgainOnEveryRetry() throws {
            let labels = [
                "parent of:State", "new folder:Overrides", "parent of:Overrides", "parent of:\(model().vendorFolder)",
            ]
            for label in labels {
                try? FileManager.default.removeItem(at: base.appendingPathComponent("Overrides"))
                try? FileManager.default.removeItem(at: stateRoot)

                // The folder is made, its sync fails; the retry finds the folder already there and
                // must still sync it, which this proves by failing that sync a second time too.
                failSyncs(2, label: label)
                XCTAssertThrowsError(try install(), label)
                XCTAssertThrowsError(try install(), "the second attempt skipped \(label)")
                XCTAssertNil(state(model().recordName), label)

                let log = recordSteps()
                XCTAssertEqual(try install(), .done, label)
                XCTAssertTrue(log.steps.contains(.syncDirectory(label)), "the third attempt skipped \(label)")
                XCTAssertEqual(try Data(contentsOf: file()), try contents())
            }
        }

        // MARK: Staging file removal

        private func failStageRemoval(with code: Int32) {
            stageHook = { _, _ in
                errno = code
                return -1
            }
        }

        func testAnInstallRecoveryThatCantRemoveTheStageKeepsTheJournal() throws {
            crash(at: .afterInstallPreference)
            XCTAssertThrowsError(try install())
            XCTAssertTrue(names(in: vendorFolder).contains(model().stageName))

            checkpoint = { _ in }
            failStageRemoval(with: EIO)
            XCTAssertThrowsError(try recover())
            XCTAssertNotNil(state(model().recordName))
            XCTAssertTrue(names(in: vendorFolder).contains(model().stageName))
            // The next change sees the pending journal rather than a clean slate.
            XCTAssertThrowsError(try install())
            XCTAssertNotNil(state(model().recordName))

            stageHook = nil
            XCTAssertEqual(try recover(), .done)
            XCTAssertEqual(names(in: vendorFolder), [])
            XCTAssertNil(state(model().recordName))
        }

        func testARefusedInstallThatCantRemoveItsStageKeepsTheJournal() throws {
            // The staging file is made normally; only its removal after the refusal fails.
            nonisolated(unsafe) var armed = false
            at(.beforeInstallPublish) {
                try Data("theirs".utf8).write(to: self.file())
                armed = true
            }
            stageHook = { directory, name in
                guard armed else { return unlinkat(directory, name, 0) }
                errno = EIO
                return -1
            }
            XCTAssertThrowsError(try install())
            XCTAssertNotNil(state(model().recordName))
            XCTAssertTrue(names(in: vendorFolder).contains(model().stageName))
            XCTAssertEqual(try Data(contentsOf: file()), Data("theirs".utf8))

            stageHook = nil
            checkpoint = { _ in }
            XCTAssertEqual(try recover(), .done)
            XCTAssertEqual(names(in: vendorFolder), [model().productFile])
            XCTAssertNil(state(model().recordName))
        }

        func testAStageThatIsAlreadyGoneIsNotAnError() throws {
            crash(at: .afterInstallPreference)
            XCTAssertThrowsError(try install())
            try FileManager.default.removeItem(at: vendorFolder.appendingPathComponent(model().stageName))

            checkpoint = { _ in }
            failStageRemoval(with: ENOENT)
            XCTAssertEqual(try recover(), .done)
            XCTAssertNil(state(model().recordName))
        }

        func testAStageThatVanishesBeforePublishingIsAnErrorNotAnInstall() throws {
            let stage = vendorFolder.appendingPathComponent(model().stageName)
            at(.beforeInstallPublish) { try FileManager.default.removeItem(at: stage) }
            XCTAssertThrowsError(try install())
            XCTAssertFalse(FileManager.default.fileExists(atPath: file().path))
            XCTAssertNil(state(model().installedName))
        }

        // MARK: A pending change when another model took the folder

        func testAnInterruptedRemovalStillRecoversAfterAnotherModelsLastRemovalDeletesTheFolder() throws {
            XCTAssertEqual(try install(0x2555), .done)
            XCTAssertEqual(try install(0x2556), .done)
            crash(at: .afterRemoveUnlink)
            XCTAssertThrowsError(try remove(0x2555))
            checkpoint = { _ in }

            // A's file is gone, B is the last one in the folder, and B's removal deletes it.
            // (B's own reconcile isn't involved: its journal is clean.)
            XCTAssertEqual(try remove(0x2556), .done)
            XCTAssertFalse(FileManager.default.fileExists(atPath: vendorFolder.path))
            XCTAssertNotNil(state(model(0x2555).recordName))

            XCTAssertEqual(try recover(0x2555), .done)
            XCTAssertNil(state(model(0x2555).recordName))
            XCTAssertNil(state(model(0x2555).installedName))
        }

        func testAnInterruptedInstallStillRecoversWhenItsFolderIsGone() throws {
            crash(at: .afterInstallRecord)
            XCTAssertThrowsError(try install())
            checkpoint = { _ in }
            try FileManager.default.removeItem(at: overridesRoot)

            XCTAssertEqual(try recover(), .done)
            XCTAssertNil(state(model().recordName))
        }

        func testRecoveryWithNothingPendingAndNoFolderIsANoOp() throws {
            XCTAssertEqual(try recover(), .done)
        }

        func testRemovalWithNoFolderIsRefused() throws {
            guard case .refused = try remove() else { return XCTFail("expected a refusal") }
        }

        // MARK: Last removal against another install

        func testTheLastRemovalInAVendorFolderNeverStrandsAnotherModelsInstall() throws {
            for round in 0 ..< 40 {
                try? FileManager.default.removeItem(at: base.appendingPathComponent("Overrides"))
                try? FileManager.default.removeItem(at: stateRoot)
                XCTAssertEqual(try install(0x2555), .done, "round \(round)")

                nonisolated(unsafe) let configuration = configuration
                let vendor = identity.vendorID
                let first = try contents(0x2555)
                let second = try contents(0x2556)
                let results = LockedList()
                DispatchQueue.concurrentPerform(iterations: 2) { index in
                    do {
                        let outcome = index == 0
                            ? try HiDPITransaction.remove(
                                model: .init(vendorID: vendor, productID: 0x2555),
                                expectedDigest: HiDPIOverride.sha256Hex(first),
                                configuration: configuration
                            )
                            : try HiDPITransaction.install(
                                model: .init(vendorID: vendor, productID: 0x2556),
                                contents: second,
                                configuration: configuration
                            )
                        results.append("\(index):\(outcome)")
                    } catch {
                        results.append("\(index):\(error)")
                    }
                }
                XCTAssertEqual(results.values.sorted(), ["0:done", "1:done"], "round \(round)")
                XCTAssertEqual(try Data(contentsOf: file(0x2556)), second, "round \(round)")
                XCTAssertFalse(FileManager.default.fileExists(atPath: file(0x2555).path))
            }
        }
    }

    private final class StepLog: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [HiDPITransaction.Step] = []

        var steps: [HiDPITransaction.Step] {
            lock.withLock { stored }
        }

        func append(_ step: HiDPITransaction.Step) {
            lock.withLock { stored.append(step) }
        }
    }

    private final class LockedList: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [String] = []

        var values: [String] {
            lock.withLock { stored }
        }

        func append(_ value: String) {
            lock.withLock { stored.append(value) }
        }
    }

    // MARK: - Command line and invocation

    final class HiDPIHelperCommandTests: HiDPIFixtureTestCase {
        func testParsingAcceptsOnlyTheThreeOperationsWithStrictArguments() throws {
            let plist = try contents()
            XCTAssertEqual(
                HiDPIHelperCommand.parse(["install", "19083", "9557", plist.base64EncodedString()]),
                .install(vendorID: 19083, productID: 9557, contents: plist)
            )
            let digest = HiDPIOverride.sha256Hex(plist)
            XCTAssertEqual(
                HiDPIHelperCommand.parse(["remove", "1", "2", digest]),
                .remove(vendorID: 1, productID: 2, digest: digest)
            )
            XCTAssertEqual(HiDPIHelperCommand.parse(["recover", "1", "2"]), .recover(vendorID: 1, productID: 2))

            let bad: [[String]] = [
                [], ["install"], ["recover", "1"], ["recover", "0", "2"], ["recover", "1", "4294967295"],
                ["recover", "-1", "2"], ["recover", "1", "2x"], ["recover", "1", "99999999999"],
                ["recover", "1", "2", "extra"], ["remove", "1", "2", "ABC"],
                ["remove", "1", "2", String(repeating: "g", count: 64)],
                ["install", "1", "2", "!!!"], ["install", "1", "2", ""], ["delete", "1", "2"],
                ["recover", "1", "../2"],
            ]
            for arguments in bad {
                XCTAssertNil(HiDPIHelperCommand.parse(arguments), "\(arguments)")
            }
        }

        func testRequestsRoundTripThroughTheirArguments() throws {
            let requests: [HiDPIHelperCommand.Request] = try [
                .install(vendorID: 7, productID: 8, contents: contents()),
                .remove(vendorID: 7, productID: 8, digest: HiDPIOverride.sha256Hex(contents())),
                .recover(vendorID: 7, productID: 8),
            ]
            for request in requests {
                XCTAssertEqual(HiDPIHelperCommand.parse(request.arguments), request)
            }
        }

        func testExitCodesTellTheAppWhatHappened() throws {
            nonisolated(unsafe) var messages: [String] = []
            func run(_ arguments: [String], _ configuration: HiDPITransaction.Configuration) -> Int32 {
                HiDPIHelperCommand.run(arguments, configuration: configuration) { messages.append($0) }
            }
            let request = try HiDPIHelperCommand.Request.install(
                vendorID: 0x4A8B, productID: 0x2555, contents: contents()
            )

            XCTAssertEqual(run(["nonsense"], configuration), HiDPIHelperCommand.ExitCode.invalidInput)
            XCTAssertEqual(run(request.arguments, configuration), HiDPIHelperCommand.ExitCode.done)
            XCTAssertEqual(run(request.arguments, configuration), HiDPIHelperCommand.ExitCode.refused)

            var needsRoot = configuration
            needsRoot.requiresRoot = true
            if geteuid() != 0 {
                XCTAssertEqual(run(["recover", "1", "2"], needsRoot), HiDPIHelperCommand.ExitCode.unsafe)
            }

            // A held original is reported with its location.
            let digest = try HiDPIOverride.sha256Hex(contents())
            var conflicted = configuration
            let occupant = Data("occupant".utf8)
            let target = file()
            conflicted.checkpoint = { step in
                if step == .beforeRemoveHold {
                    try Data("edited".utf8).write(to: target)
                }
                if step == .afterRemoveHold {
                    try occupant.write(to: target)
                }
            }
            messages = []
            XCTAssertEqual(
                run(["remove", "19083", "9557", digest], conflicted), HiDPIHelperCommand.ExitCode.held
            )
            XCTAssertEqual(
                HiDPIHelperInvocation.heldPath(in: messages.joined(separator: "\n")),
                vendorFolder.appendingPathComponent(model().holdName).path
            )
        }

        func testHeldPathIsReadFromOsascriptErrorText() {
            let text = "execution error: DIMMERLY-HELD /Library/Displays/x/.dimmerly-hold.a-b (3)\n"
            XCTAssertEqual(HiDPIHelperInvocation.heldPath(in: text), "/Library/Displays/x/.dimmerly-hold.a-b")
            XCTAssertNil(HiDPIHelperInvocation.heldPath(in: "execution error: failed (1)"))
        }

        // MARK: Who may be run as root

        func testAReleaseBuildThatCantNameItsTeamRefusesToBuildAScript() throws {
            XCTAssertNil(HiDPIHelperIdentity.trust(team: nil, isDevelopmentBuild: false))
            XCTAssertEqual(HiDPIHelperIdentity.trust(team: nil, isDevelopmentBuild: true), .digestOnly)
            XCTAssertThrowsError(try HiDPIHelperInvocation.script(
                for: .recover(vendorID: 1, productID: 2), trust: nil
            ))
        }

        func testTheReleaseRequirementNamesTheIdentifierTheTeamAndDeveloperID() {
            let release = HiDPIHelperIdentity.requirement(team: "ABCDE12345", developerID: true)
            XCTAssertTrue(release.contains("identifier \"DimmerlyHiDPIHelper\""))
            XCTAssertTrue(release.contains("certificate leaf[subject.OU] = \"ABCDE12345\""))
            XCTAssertTrue(release.contains("1.2.840.113635.100.6.2.6"))
            XCTAssertTrue(release.contains("1.2.840.113635.100.6.1.13"))
            XCTAssertEqual(
                HiDPIHelperIdentity.trust(team: "ABCDE12345", isDevelopmentBuild: false), .requirement(release)
            )
            let development = HiDPIHelperIdentity.requirement(team: "ABCDE12345", developerID: false)
            XCTAssertFalse(development.contains("1.2.840.113635.100.6.1.13"))
        }

        func testTheScriptChecksThePrivateCopyAgainstTheRequirementWhenThereIsOne() {
            let text = HiDPIHelperInvocation.scriptText(
                arguments: ["recover", "1", "2"],
                helper: URL(fileURLWithPath: "/tmp/h"),
                helperDigest: String(repeating: "a", count: 64),
                requirement: HiDPIHelperIdentity.requirement(team: "ABCDE12345", developerID: true),
                scratchRoot: "/var/db"
            )
            XCTAssertTrue(text.contains("/usr/bin/codesign --verify --strict -R '=identifier"))
            XCTAssertTrue(text.contains("\"$D/helper\" || fail"))
        }

        func testTheEmbeddedHelperMeetsTheDevelopmentRequirementAndNotAWrongOne() throws {
            guard let team = HiDPIHelperInvocation.signingTeam() else {
                throw XCTSkip("this build has no signing team")
            }
            let helper = HiDPIHelperInvocation.helperURL()
            XCTAssertTrue(HiDPIHelperInvocation.isSigned(
                helper, requirement: HiDPIHelperIdentity.requirement(team: team, developerID: false)
            ))
            XCTAssertFalse(HiDPIHelperInvocation.isSigned(
                helper, requirement: HiDPIHelperIdentity.requirement(team: "ZZZZZZZZZZ", developerID: false)
            ))
            XCTAssertFalse(HiDPIHelperInvocation.isSigned(
                helper, requirement: "identifier \"SomethingElse\" and anchor apple generic"
            ))
            // A development certificate isn't a Developer ID Application certificate.
            XCTAssertFalse(HiDPIHelperInvocation.isSigned(
                helper, requirement: HiDPIHelperIdentity.requirement(team: team, developerID: true)
            ))
        }

        // MARK: The root script around the helper

        private func runScript(helper: String, digest: String?, arguments: [String]) throws -> Int32 {
            let helperURL = URL(fileURLWithPath: helper)
            let data = try Data(contentsOf: helperURL)
            let script = HiDPIHelperInvocation.scriptText(
                arguments: arguments,
                helper: helperURL,
                helperDigest: digest ?? HiDPIOverride.sha256Hex(data),
                requirement: nil,
                scratchRoot: base.path
            )
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", script]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        }

        /// A stand-in helper that only exits with a chosen code.
        private func stubHelper(exitCode: Int) throws -> String {
            let url = base.appendingPathComponent("stub-\(exitCode)")
            try Data("#!/bin/sh\nexit \(exitCode)\n".utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            return url.path
        }

        func testTheScriptRunsAVerifiedCopyOnceAndPassesItsExitCodeBack() throws {
            let ok = try stubHelper(exitCode: 0)
            XCTAssertEqual(try runScript(helper: ok, digest: nil, arguments: ["recover", "1", "2"]), 0)
            let failing = try stubHelper(exitCode: 7)
            XCTAssertEqual(try runScript(helper: failing, digest: nil, arguments: ["recover", "1", "2"]), 7)
            // The private folder is removed afterwards.
            XCTAssertEqual(names(in: base).filter { $0.hasPrefix("dimmerly-hidpi.") }, [])
        }

        func testTheScriptRefusesAHelperThatDoesNotMatchTheDigestTheAppCalculated() throws {
            let wrong = HiDPIOverride.sha256Hex(Data("tampered".utf8))
            let stub = try stubHelper(exitCode: 0)
            XCTAssertEqual(try runScript(helper: stub, digest: wrong, arguments: ["recover", "1", "2"]), 4)
            XCTAssertEqual(names(in: base).filter { $0.hasPrefix("dimmerly-hidpi.") }, [])
        }

        func testTheBuiltHelperRefusesToRunWithoutAdministratorRights() throws {
            guard geteuid() != 0 else { return }
            let helper = HiDPIHelperInvocation.helperURL()
            guard FileManager.default.isExecutableFile(atPath: helper.path) else {
                return XCTFail("the helper isn't embedded in the app bundle at \(helper.path)")
            }
            // As an ordinary user the real helper exits before touching anything.
            XCTAssertEqual(
                try runScript(helper: helper.path, digest: nil, arguments: ["recover", "19083", "9557"]),
                HiDPIHelperCommand.ExitCode.unsafe
            )
        }
    }

    // MARK: - Manager

    final class HiDPIManagerTests: HiDPIFixtureTestCase {
        /// Runs requests through the real transaction in this process, as the helper would.
        private func makeManager(
            _ handler: (@Sendable (HiDPIHelperCommand.Request) async throws -> Void)? = nil
        ) -> HiDPIModeManager {
            nonisolated(unsafe) let configuration = configuration
            let executing: @Sendable (HiDPIHelperCommand.Request) async throws -> Void = { request in
                nonisolated(unsafe) var message = ""
                let code = HiDPIHelperCommand.run(request.arguments, configuration: configuration) { message += $0 }
                if code == HiDPIHelperCommand.ExitCode.held,
                   let path = HiDPIHelperInvocation.heldPath(in: message)
                {
                    throw HiDPIModeError.held(path: path)
                }
                guard code == 0 else { throw HiDPIModeError.commandFailed }
            }
            return HiDPIModeManager(
                runner: ClosureRunner(handler: handler ?? executing), overridesRoot: overridesRoot, stateRoot: stateRoot
            )
        }

        private func row(
            id: CGDirectDisplayID, status: HiDPIOverrideStatus, identity: HiDPIDisplayIdentity? = nil
        ) -> HiDPIDisplayState {
            HiDPIDisplayState(
                id: id, identity: identity ?? self.identity, status: status, availableSizes: [], current: nil
            )
        }

        // MARK: Recovery from Settings

        func testAPendingChangeComesBeforeEveryOtherActionEvenWhenTheRowOffersNone() {
            for status: HiDPIOverrideStatus in [.off, .on, .restartToEnable, .otherOverride(hiDPIOnly: false)] {
                var display = row(id: 1, status: status)
                display.recoveryPending = true
                XCTAssertEqual(display.primaryAction, .finishPendingChange, "\(status)")
            }
            XCTAssertEqual(row(id: 1, status: .off).primaryAction, .turnOn)
            XCTAssertEqual(row(id: 1, status: .on).primaryAction, .turnOff)
            XCTAssertNil(row(id: 1, status: .otherOverride(hiDPIOnly: true)).primaryAction)
        }

        func testALostInstallResultIsFinishedFromTheSettingsRecoveryAction() async {
            crash(at: .afterInstallPublish)
            let manager = makeManager()
            await manager.enable(row(id: 1, status: .off))
            XCTAssertEqual(manager.errors[1], .commandFailed)

            // Settings sees the file but no ownership record, plus the pending journal.
            var stuck = row(id: 1, status: .otherOverride(hiDPIOnly: false))
            stuck.recoveryPending = true
            checkpoint = { _ in }
            let recovering = makeManager()
            await recovering.enable(stuck)
            await recovering.disable(stuck)
            XCTAssertNotNil(state(model().recordName), "ordinary actions don't run on a pending row")

            await recovering.recoverPendingChange(stuck)
            XCTAssertNil(recovering.errors[1])
            XCTAssertNil(state(model().recordName))
            await recovering.disable(row(id: 1, status: .on))
            XCTAssertFalse(FileManager.default.fileExists(atPath: file().path))
        }

        func testAnInterruptedRemovalIsFinishedFromTheSettingsRecoveryAction() async throws {
            XCTAssertEqual(try install(), .done)
            crash(at: .afterRemoveHold)
            let manager = makeManager()
            await manager.disable(row(id: 1, status: .on))
            XCTAssertFalse(FileManager.default.fileExists(atPath: file().path))

            var pending = row(id: 1, status: .off)
            pending.recoveryPending = true
            checkpoint = { _ in }
            let recovering = makeManager()
            await recovering.recoverPendingChange(pending)
            XCTAssertNil(recovering.errors[1])
            XCTAssertFalse(FileManager.default.fileExists(atPath: vendorFolder.path))
        }

        func testAHeldOriginalShowsItsLocationAndIsRestoredOnceTheWayIsClear() async throws {
            XCTAssertEqual(try install(), .done)
            let edited = Data("edited".utf8)
            let occupant = Data("occupant".utf8)
            let target = file()
            checkpoint = { step in
                if step == .beforeRemoveHold {
                    try edited.write(to: target)
                }
                if step == .afterRemoveHold {
                    try occupant.write(to: target)
                }
            }
            let manager = makeManager()
            await manager.disable(row(id: 1, status: .on))
            let holdPath = vendorFolder.appendingPathComponent(model().holdName).path
            XCTAssertEqual(manager.errors[1], .held(path: holdPath))

            // The row is stuck behind the occupant, yet the recovery action is still there.
            var pending = row(id: 1, status: .otherOverride(hiDPIOnly: false))
            pending.recoveryPending = true
            checkpoint = { _ in }
            let recovering = makeManager()
            await recovering.recoverPendingChange(pending)
            XCTAssertEqual(recovering.errors[1], .held(path: holdPath))

            try FileManager.default.removeItem(at: file())
            await recovering.recoverPendingChange(pending)
            XCTAssertNil(recovering.errors[1])
            XCTAssertEqual(try Data(contentsOf: file()), edited)
        }

        func testRecoveryOnlyRunsForARowThatHasAPendingChange() async {
            let calls = CallCounter()
            let manager = makeManager { _ in calls.increment() }
            await manager.recoverPendingChange(row(id: 1, status: .off))
            XCTAssertEqual(calls.count, 0)
        }

        func testCancellingTheRecoveryPromptChangesNothing() async {
            crash(at: .afterInstallPublish)
            await makeManager().enable(row(id: 1, status: .off))
            var pending = row(id: 1, status: .otherOverride(hiDPIOnly: false))
            pending.recoveryPending = true
            let manager = makeManager { _ in throw HiDPIModeError.cancelled }
            await manager.recoverPendingChange(pending)
            XCTAssertTrue(manager.errors.isEmpty)
            XCTAssertNotNil(state(model().recordName))
        }

        // MARK: Pending-change discovery

        func testThePendingStateAndTheHeldWarningFollowTheHelpersRecords() throws {
            let manager = makeManager()
            XCTAssertFalse(manager.isRecoveryPending(identity))
            XCTAssertNil(manager.heldOriginal(identity))

            // An interrupted change is pending, with no conflict to warn about. The file was
            // edited by someone else, so recovery puts it back instead of deleting it.
            XCTAssertEqual(try install(), .done)
            try Data("edited".utf8).write(to: file())
            crash(at: .afterRemoveHold)
            XCTAssertThrowsError(try remove())
            XCTAssertTrue(manager.isRecoveryPending(identity))
            XCTAssertNil(manager.heldOriginal(identity))

            // Another file takes the path: the original is held and the warning names it.
            checkpoint = { _ in }
            try Data("occupant".utf8).write(to: file())
            let holdPath = vendorFolder.appendingPathComponent(model().holdName).path
            XCTAssertEqual(try recover(), .held(path: holdPath))
            XCTAssertEqual(manager.heldOriginal(identity), holdPath)

            // The way is cleared and the restore lands, but its sync fails: the journal still
            // says "conflict", yet the original is back, so the warning goes while the change
            // stays pending.
            try FileManager.default.removeItem(at: file())
            nonisolated(unsafe) var failed = false
            checkpoint = { step in
                guard step == .syncDirectory("vendor"), !failed else { return }
                failed = true
                throw HiDPITransaction.Failure.io("disk")
            }
            XCTAssertThrowsError(try recover())
            XCTAssertTrue(FileManager.default.fileExists(atPath: file().path))
            XCTAssertTrue(manager.isRecoveryPending(identity))
            XCTAssertNil(manager.heldOriginal(identity), "the original is back; the warning would be stale")

            checkpoint = { _ in }
            XCTAssertEqual(try recover(), .done)
            XCTAssertFalse(manager.isRecoveryPending(identity))
        }

        func testAnInterruptedRemovalIsFinishedFromSettingsAfterAnotherModelsLastRemoval() async throws {
            XCTAssertEqual(try install(0x2555), .done)
            XCTAssertEqual(try install(0x2556), .done)
            crash(at: .afterRemoveUnlink)
            XCTAssertThrowsError(try remove(0x2555))
            checkpoint = { _ in }
            XCTAssertEqual(try remove(0x2556), .done)

            let other = HiDPIDisplayIdentity(
                vendorID: identity.vendorID, productID: 0x2555, nativeWidth: 1920, nativeHeight: 1080, name: "A"
            )
            let manager = makeManager()
            XCTAssertTrue(manager.isRecoveryPending(other))
            var pending = row(id: 1, status: .off, identity: other)
            pending.recoveryPending = true
            await manager.recoverPendingChange(pending)
            XCTAssertNil(manager.errors[1])
            XCTAssertFalse(manager.isRecoveryPending(other))
        }

        func testCancellingThePasswordPromptChangesNothingAndShowsNoError() async {
            let manager = makeManager { _ in throw HiDPIModeError.cancelled }
            let display = row(id: 1, status: .off)
            await manager.enable(display)
            XCTAssertTrue(manager.errors.isEmpty)
            XCTAssertFalse(manager.isBusy(display))
            XCTAssertFalse(FileManager.default.fileExists(atPath: file().path))
        }

        func testAFailedCommandShowsAnErrorAndReleasesTheLock() async {
            let manager = makeManager { _ in throw HiDPIModeError.commandFailed }
            let display = row(id: 1, status: .off)
            await manager.enable(display)
            XCTAssertEqual(manager.errors[1], .commandFailed)
            XCTAssertFalse(manager.isBusy(display))
        }

        func testAHeldOriginalIsShownWithItsLocation() async throws {
            let manager = makeManager { _ in throw HiDPIModeError.held(path: "/somewhere/.dimmerly-hold.x") }
            await manager.enable(row(id: 1, status: .off))
            XCTAssertEqual(manager.errors[1], .held(path: "/somewhere/.dimmerly-hold.x"))
            XCTAssertTrue(try XCTUnwrap(manager.errors[1]?.errorDescription).contains("/somewhere/.dimmerly-hold.x"))
        }

        func testTurnOnAndTurnOffRunEndToEnd() async throws {
            let manager = makeManager()
            await manager.enable(row(id: 1, status: .off))
            XCTAssertEqual(try HiDPIOverride.ownership(ofPlistData: Data(contentsOf: file())), .dimmerly)
            XCTAssertNil(manager.errors[1])

            await manager.disable(row(id: 1, status: .on))
            XCTAssertFalse(FileManager.default.fileExists(atPath: file().path))
            XCTAssertEqual(preference.value, true)
            XCTAssertNil(manager.errors[1])
        }

        func testTurnOnNeverReplacesAFileThatAppearedAfterTheRowWasShown() async throws {
            let calls = CallCounter()
            let manager = makeManager { _ in calls.increment() }
            let foreign = try PropertyListSerialization.data(
                fromPropertyList: ["DisplayVendorID": 0x4A8B, "scale-resolutions": [Data([0, 0, 7, 0x40])]],
                format: .xml,
                options: 0
            )
            try seed(foreign)
            await manager.enable(row(id: 1, status: .off))
            XCTAssertEqual(calls.count, 0)
            XCTAssertEqual(try Data(contentsOf: file()), foreign)
        }

        func testTurnOffLeavesAFileThatAnotherToolEditedAfterDimmerlyInstalledIt() async throws {
            let installer = makeManager()
            await installer.enable(row(id: 1, status: .off))

            // Still carries Dimmerly's marker and only HiDPI keys, but the product name changed.
            var edited = try XCTUnwrap(PropertyListSerialization.propertyList(
                from: Data(contentsOf: file()), format: nil
            ) as? [String: Any])
            edited["DisplayProductName"] = "Renamed"
            let changed = try PropertyListSerialization.data(fromPropertyList: edited, format: .xml, options: 0)
            try changed.write(to: file())

            let calls = CallCounter()
            await makeManager { _ in calls.increment() }.disable(row(id: 1, status: .on))
            XCTAssertEqual(calls.count, 0)
            XCTAssertEqual(try Data(contentsOf: file()), changed)
        }

        func testTurnOffLeavesAMarkedFileDimmerlyHasNoRecordOfInstalling() async throws {
            let calls = CallCounter()
            let handBuilt = try contents()
            try seed(handBuilt)
            await makeManager { _ in calls.increment() }.disable(row(id: 1, status: .on))
            XCTAssertEqual(calls.count, 0)
            XCTAssertEqual(try Data(contentsOf: file()), handBuilt)
        }

        func testAnInstallWhoseResultWasLostIsStillRemovableAfterRecovery() async throws {
            crash(at: .afterInstallPublish)
            let flaky = makeManager()
            await flaky.enable(row(id: 1, status: .off))
            XCTAssertEqual(flaky.errors[1], .commandFailed)

            // The file landed but nothing recorded it; the next change finishes the record.
            checkpoint = { _ in }
            XCTAssertEqual(try recover(), .done)
            await makeManager().disable(row(id: 1, status: .on))
            XCTAssertFalse(FileManager.default.fileExists(atPath: file().path))
        }

        func testRowsThatOfferNoActionDoNothing() async {
            let calls = CallCounter()
            let manager = makeManager { _ in calls.increment() }
            await manager.enable(row(id: 1, status: .otherOverride(hiDPIOnly: true)))
            await manager.disable(row(id: 1, status: .otherOverride(hiDPIOnly: false)))
            XCTAssertEqual(calls.count, 0)
        }

        func testTheLockHoldsWhenTheSameModelReconnectsUnderANewID() async {
            let calls = CallCounter()
            let (entered, enteredSignal) = AsyncStream.makeStream(of: Void.self)
            let (release, releaseSignal) = AsyncStream.makeStream(of: Void.self)
            let manager = makeManager { _ in
                calls.increment()
                enteredSignal.yield()
                await Self.firstSignal(of: release)
            }
            let original = row(id: 1, status: .off)
            let reconnected = row(id: 77, status: .off)

            let first = Task { await manager.enable(original) }
            await Self.firstSignal(of: entered)
            XCTAssertTrue(manager.isBusy(reconnected))
            await manager.enable(reconnected)
            XCTAssertEqual(calls.count, 1)

            releaseSignal.yield()
            await first.value
            XCTAssertFalse(manager.isBusy(reconnected))
        }

        func testDifferentModelsDoNotBlockEachOther() async {
            let (entered, enteredSignal) = AsyncStream.makeStream(of: Void.self)
            let (release, releaseSignal) = AsyncStream.makeStream(of: Void.self)
            let manager = makeManager { _ in
                enteredSignal.yield()
                await Self.firstSignal(of: release)
            }
            let first = Task { await manager.enable(row(id: 1, status: .off)) }
            await Self.firstSignal(of: entered)

            let otherModel = HiDPIDisplayIdentity(
                vendorID: 0x1E6D, productID: 0x5B11, nativeWidth: 2560, nativeHeight: 1440, name: "Other"
            )
            XCTAssertFalse(manager.isBusy(row(id: 2, status: .off, identity: otherModel)))
            releaseSignal.yield()
            await first.value
        }

        private nonisolated static func firstSignal(of stream: AsyncStream<Void>) async {
            for await _ in stream {
                return
            }
        }
    }

    private struct ClosureRunner: PrivilegedCommandRunning {
        let handler: @Sendable (HiDPIHelperCommand.Request) async throws -> Void

        func run(_ request: HiDPIHelperCommand.Request, prompt _: String) async throws {
            try await handler(request)
        }
    }

    private final class CallCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0

        var count: Int {
            lock.withLock { value }
        }

        func increment() {
            lock.withLock { value += 1 }
        }
    }

#endif

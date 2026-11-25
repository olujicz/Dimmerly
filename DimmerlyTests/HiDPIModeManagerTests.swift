//
//  HiDPIModeManagerTests.swift
//  DimmerlyTests
//
//  Tests for the HiDPI privileged commands and the manager that runs them. Every file lives in
//  a temporary folder owned by the current user, and the commands run as that user against a
//  stand-in WindowServer preference file, so nothing under /Library changes and no password
//  is asked for.
//

#if !APPSTORE

    @testable import Dimmerly
    import XCTest

    @MainActor
    final class HiDPIModeManagerTests: XCTestCase {
        private let identity = HiDPIDisplayIdentity(
            vendorID: 0x4A8B, productID: 0x2555, nativeWidth: 1920, nativeHeight: 1080, name: "ANMITE"
        )
        private var base: URL = .init(fileURLWithPath: "/")
        private var location = HiDPIOverride.SystemLocation()
        private var suiteName = ""
        private var defaults = UserDefaults.standard

        override func setUpWithError() throws {
            base = try URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .resolvingSymlinksInPath()
                .appendingPathComponent("hidpi-tests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            location = HiDPIOverride.SystemLocation(
                overridesRoot: base.appendingPathComponent("Overrides", isDirectory: true),
                trustedBase: base,
                ownerUID: getuid(),
                ownerGID: getgid(),
                windowServerDomain: base.appendingPathComponent("windowserver").path
            )
            suiteName = "HiDPIModeManagerTests-\(UUID().uuidString)"
            defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        }

        override func tearDownWithError() throws {
            try? FileManager.default.removeItem(at: base)
            defaults.removePersistentDomain(forName: suiteName)
        }

        // MARK: Install command

        func testInstallWritesDimmerlysFileAndSetsTheFlagWhenAbsent() throws {
            XCTAssertEqual(try runInstall(), 0)

            let data = try Data(contentsOf: file)
            XCTAssertEqual(data, try HiDPIOverride.plistData(for: identity))
            XCTAssertEqual(HiDPIOverride.ownership(ofPlistData: data), .dimmerly)
            XCTAssertEqual(flag(), true)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: vendorFolder.path).count, 1)
        }

        func testInstallLeavesAnEnabledFlagAloneAndEnablesADisabledOne() throws {
            writeFlag(true)
            XCTAssertEqual(try runInstall(), 0)
            XCTAssertEqual(flag(), true)

            try FileManager.default.removeItem(at: vendorFolder)
            writeFlag(false)
            XCTAssertEqual(try runInstall(), 0)
            XCTAssertEqual(flag(), true)
        }

        func testInstallRefusesAnExistingFileAndKeepsItsBytes() throws {
            let foreign = Data("someone else's".utf8)
            try seed(foreign)
            XCTAssertNotEqual(try runInstall(), 0)
            XCTAssertEqual(try Data(contentsOf: file), foreign)
            XCTAssertNil(flag())
        }

        func testInstallRefusesASymbolicLinkAtTheDestination() throws {
            try FileManager.default.createDirectory(at: vendorFolder, withIntermediateDirectories: true)
            let target = base.appendingPathComponent("elsewhere")
            try Data("x".utf8).write(to: target)
            try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)

            XCTAssertNotEqual(try runInstall(), 0)
            XCTAssertEqual(try Data(contentsOf: target), Data("x".utf8))
        }

        func testInstallRefusesAFolderOthersCanWrite() throws {
            try FileManager.default.createDirectory(at: vendorFolder, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: vendorFolder.path)

            XCTAssertNotEqual(try runInstall(), 0)
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
            XCTAssertNil(flag())
        }

        func testInstallRefusesAFolderWithAnACLEntry() throws {
            try FileManager.default.createDirectory(at: vendorFolder, withIntermediateDirectories: true)
            XCTAssertEqual(try Self.run("/bin/chmod", ["+a", "everyone allow add_file", vendorFolder.path]), 0)

            XCTAssertNotEqual(try runInstall(), 0)
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        }

        func testInstallLeavesNoStagingFilesBehind() throws {
            XCTAssertEqual(try runInstall(), 0)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: vendorFolder.path).count, 1)
        }

        func testInstallThatCannotStageTouchesNeitherTheFileNorTheFlag() throws {
            writeFlag(false)
            try FileManager.default.createDirectory(at: vendorFolder, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: vendorFolder.path)
            defer {
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: vendorFolder.path)
            }

            XCTAssertNotEqual(try runInstall(), 0)
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
            XCTAssertEqual(flag(), false)
        }

        func testInstallRefusesASymbolicLinkInTheFolderPath() throws {
            let elsewhere = base.appendingPathComponent("elsewhere", isDirectory: true)
            try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: location.overridesRoot, withDestinationURL: elsewhere)

            XCTAssertNotEqual(try runInstall(), 0)
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: elsewhere.path).isEmpty)
        }

        func testInstallThatCannotSetTheFlagLeavesNoFileAndNoTemporaryCopy() throws {
            // A folder where the preference file belongs makes the write fail.
            try FileManager.default.createDirectory(
                at: URL(fileURLWithPath: location.windowServerDomain + ".plist"), withIntermediateDirectories: true
            )
            let broken = location

            XCTAssertNotEqual(try runShell(HiDPIOverride.installCommand(for: identity, location: broken)), 0)
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: vendorFolder.path).isEmpty)
        }

        func testInstallCarriesItsFileInsideTheCommand() throws {
            let command = try HiDPIOverride.installCommand(for: identity, location: location)
            let payload = try HiDPIOverride.plistData(for: identity).base64EncodedString()
            XCTAssertTrue(command.contains(payload))
            XCTAssertFalse(command.contains(NSTemporaryDirectory() + "dimmerly-hidpi"))
        }

        // MARK: Remove command

        func testRemoveDeletesTheFileAndItsEmptyFolderAndKeepsTheFlag() throws {
            XCTAssertEqual(try runInstall(), 0)
            let installed = try Data(contentsOf: file)

            XCTAssertEqual(try runRemove(expecting: installed), 0)
            XCTAssertFalse(FileManager.default.fileExists(atPath: vendorFolder.path))
            XCTAssertEqual(flag(), true)
        }

        func testRemoveNeverTouchesAFlagDimmerlyDidNotSet() throws {
            try seed(HiDPIOverride.plistData(for: identity))
            XCTAssertEqual(flag(), nil)
            XCTAssertEqual(try runRemove(expecting: Data(contentsOf: file)), 0)
            XCTAssertNil(flag())

            writeFlag(true)
            try seed(HiDPIOverride.plistData(for: identity))
            XCTAssertEqual(try runRemove(expecting: Data(contentsOf: file)), 0)
            XCTAssertEqual(flag(), true)
        }

        func testRemoveStopsWhenTheFileChangedAfterItWasRead() throws {
            let original = try HiDPIOverride.plistData(for: identity)
            try seed(original)
            var edited = try XCTUnwrap(PropertyListSerialization.propertyList(
                from: original, format: nil
            ) as? [String: Any])
            edited["default-resolution"] = Data([0, 0, 7, 0x80, 0, 0, 4, 0x38])
            let changed = try PropertyListSerialization.data(fromPropertyList: edited, format: .xml, options: 0)
            try changed.write(to: file)

            XCTAssertNotEqual(try runRemove(expecting: original), 0)
            XCTAssertEqual(try Data(contentsOf: file), changed)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: vendorFolder.path).count, 1)
        }

        func testRemoveKeepsAFolderThatHoldsOtherFiles() throws {
            let original = try HiDPIOverride.plistData(for: identity)
            try seed(original)
            let other = vendorFolder.appendingPathComponent("DisplayProductID-9999")
            try Data("other".utf8).write(to: other)

            XCTAssertEqual(try runRemove(expecting: original), 0)
            XCTAssertTrue(FileManager.default.fileExists(atPath: other.path))
        }

        func testRemoveRefusesASymbolicLink() throws {
            let target = base.appendingPathComponent("elsewhere")
            let original = try HiDPIOverride.plistData(for: identity)
            try original.write(to: target)
            try FileManager.default.createDirectory(at: vendorFolder, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)

            XCTAssertNotEqual(try runRemove(expecting: original), 0)
            XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
        }

        // MARK: Exact-path publishing, recovery and preference folder

        /// Runs `publish SRC DEST` from the command's own helpers.
        private func publish(_ source: URL, to destination: URL) throws -> Int32 {
            let lines = HiDPIOverride.preamble(ownerUID: getuid()) + [
                "publish \(HiDPIOverride.shellQuoted(source.path)) \(HiDPIOverride.shellQuoted(destination.path))",
            ]
            return try runShell(lines.joined(separator: "\n"))
        }

        func testPublishLinksTheExactPathAndRefusesToReplaceAFile() throws {
            let source = base.appendingPathComponent("source")
            let destination = base.appendingPathComponent("dest")
            try Data("new".utf8).write(to: source)
            XCTAssertEqual(try publish(source, to: destination), 0)
            XCTAssertEqual(try Data(contentsOf: destination), Data("new".utf8))

            let occupied = base.appendingPathComponent("occupied")
            try Data("theirs".utf8).write(to: occupied)
            XCTAssertNotEqual(try publish(source, to: occupied), 0)
            XCTAssertEqual(try Data(contentsOf: occupied), Data("theirs".utf8))
        }

        func testPublishFailsInsteadOfLinkingInsideADirectoryThatAppearedAtTheDestination() throws {
            let source = base.appendingPathComponent("source")
            try Data("new".utf8).write(to: source)
            let folder = base.appendingPathComponent("folder", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

            XCTAssertNotEqual(try publish(source, to: folder), 0)
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
            XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        }

        func testPublishFailsInsteadOfLinkingThroughASymbolicLinkToADirectory() throws {
            let source = base.appendingPathComponent("source")
            try Data("new".utf8).write(to: source)
            let target = base.appendingPathComponent("target", isDirectory: true)
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            let link = base.appendingPathComponent("link")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

            XCTAssertNotEqual(try publish(source, to: link), 0)
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty)
        }

        func testAFileStrandedInHoldingIsPutBackWhenItsPathIsFree() throws {
            let stranded = Data("foreign".utf8)
            try seedHold(stranded)

            // The install stops because a file turned up, and that file is the stranded one.
            XCTAssertNotEqual(try runInstall(), 0)
            XCTAssertEqual(try Data(contentsOf: file), stranded)
            XCTAssertEqual(holdFolders().count, 0)
        }

        func testAFileStrandedInHoldingStaysPutWhenItsPathIsTaken() throws {
            let stranded = Data("stranded".utf8)
            let occupant = Data("occupant".utf8)
            try seedHold(stranded)
            try occupant.write(to: file)

            XCTAssertNotEqual(try runRemove(expecting: Data("other".utf8)), 0)
            XCTAssertEqual(try Data(contentsOf: file), occupant)
            XCTAssertEqual(try Data(contentsOf: holdFolders()[0].appendingPathComponent("file")), stranded)
        }

        func testRemovalFinishesAnInterruptedRemovalOfDimmerlysOwnFile() throws {
            let own = try HiDPIOverride.plistData(for: identity)
            try seedHold(own)

            XCTAssertEqual(try runRemove(expecting: own), 0)
            XCTAssertFalse(FileManager.default.fileExists(atPath: vendorFolder.path))
        }

        func testInstallRefusesAnUntrustedPreferenceFolder() throws {
            let prefs = base.appendingPathComponent("prefs", isDirectory: true)
            try FileManager.default.createDirectory(at: prefs, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: prefs.path)
            var untrusted = location
            untrusted.windowServerDomain = prefs.appendingPathComponent("windowserver").path

            XCTAssertNotEqual(try runShell(HiDPIOverride.installCommand(for: identity, location: untrusted)), 0)
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
            XCTAssertNil(NSDictionary(contentsOf: URL(fileURLWithPath: untrusted.windowServerDomain + ".plist")))
        }

        func testAnInstallThatLandedButReportedFailureIsStillRecognisedAsDimmerlys() async {
            let flaky = makeManager { command in
                guard try Self.shell(command) == 0 else { throw HiDPIModeError.commandFailed }
                throw HiDPIModeError.commandFailed // the result was lost after the file landed
            }
            await flaky.enable(row(id: 1, status: .off))
            XCTAssertEqual(flaky.errors[1], .commandFailed)

            let remover = makeManager { command in
                guard try Self.shell(command) == 0 else { throw HiDPIModeError.commandFailed }
            }
            await remover.disable(row(id: 1, status: .on))
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        }

        func testAnInstallThatNeverLandedLeavesNoRecordBehind() async throws {
            let manager = makeManager { _ in throw HiDPIModeError.cancelled }
            await manager.enable(row(id: 1, status: .off))
            try HiDPIOverride.plistData(for: identity).write(to: { try seed(Data()); return file }())

            let calls = CallCounter()
            let remover = makeManager { _ in calls.increment() }
            await remover.disable(row(id: 1, status: .on))
            XCTAssertEqual(calls.count, 0)
        }

        // MARK: Manager

        func testCancellingThePasswordPromptChangesNothingAndShowsNoError() async {
            let manager = makeManager { _ in throw HiDPIModeError.cancelled }
            let display = row(id: 1, status: .off)

            await manager.enable(display)

            XCTAssertTrue(manager.errors.isEmpty)
            XCTAssertFalse(manager.isBusy(display))
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        }

        func testAFailedCommandShowsAnErrorAndReleasesTheLock() async {
            let manager = makeManager { _ in throw HiDPIModeError.commandFailed }
            let display = row(id: 1, status: .off)

            await manager.enable(display)

            XCTAssertEqual(manager.errors[1], .commandFailed)
            XCTAssertFalse(manager.isBusy(display))
        }

        func testTurnOnAndTurnOffRunTheCommandsEndToEnd() async throws {
            let manager = makeManager { command in
                guard try Self.shell(command) == 0 else { throw HiDPIModeError.commandFailed }
            }

            await manager.enable(row(id: 1, status: .off))
            XCTAssertEqual(try HiDPIOverride.ownership(ofPlistData: Data(contentsOf: file)), .dimmerly)
            XCTAssertNil(manager.errors[1])

            await manager.disable(row(id: 1, status: .on))
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
            XCTAssertEqual(flag(), true)
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
            XCTAssertEqual(try Data(contentsOf: file), foreign)
        }

        func testTurnOffNeverRemovesAFileDimmerlyNoLongerOwns() async throws {
            let calls = CallCounter()
            let manager = makeManager { _ in calls.increment() }
            var edited = try XCTUnwrap(PropertyListSerialization.propertyList(
                from: HiDPIOverride.plistData(for: identity), format: nil
            ) as? [String: Any])
            edited["IODisplayEDID"] = Data([0, 0xFF])
            let changed = try PropertyListSerialization.data(fromPropertyList: edited, format: .xml, options: 0)
            try seed(changed)

            await manager.disable(row(id: 1, status: .on))

            XCTAssertEqual(calls.count, 0)
            XCTAssertEqual(try Data(contentsOf: file), changed)
        }

        func testTurnOffLeavesAFileThatAnotherToolEditedAfterDimmerlyInstalledIt() async throws {
            let installer = makeManager { command in
                guard try Self.shell(command) == 0 else { throw HiDPIModeError.commandFailed }
            }
            await installer.enable(row(id: 1, status: .off))

            // Still carries Dimmerly's marker and only HiDPI keys, but the product name changed.
            var edited = try XCTUnwrap(PropertyListSerialization.propertyList(
                from: Data(contentsOf: file), format: nil
            ) as? [String: Any])
            edited["DisplayProductName"] = "Renamed"
            let changed = try PropertyListSerialization.data(fromPropertyList: edited, format: .xml, options: 0)
            try changed.write(to: file)

            let calls = CallCounter()
            let remover = makeManager { _ in calls.increment() }
            await remover.disable(row(id: 1, status: .on))

            XCTAssertEqual(calls.count, 0)
            XCTAssertEqual(try Data(contentsOf: file), changed)
        }

        func testTurnOffLeavesAMarkedFileDimmerlyHasNoRecordOfInstalling() async throws {
            let calls = CallCounter()
            let manager = makeManager { _ in calls.increment() }
            let handBuilt = try HiDPIOverride.plistData(for: identity)
            try seed(handBuilt)

            await manager.disable(row(id: 1, status: .on))

            XCTAssertEqual(calls.count, 0)
            XCTAssertEqual(try Data(contentsOf: file), handBuilt)
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

        // MARK: Helpers

        private var vendorFolder: URL {
            file.deletingLastPathComponent()
        }

        private var file: URL {
            HiDPIOverride.fileURL(
                vendorID: identity.vendorID, productID: identity.productID, root: location.overridesRoot
            )
        }

        private func row(
            id: CGDirectDisplayID,
            status: HiDPIOverrideStatus,
            identity: HiDPIDisplayIdentity? = nil
        ) -> HiDPIDisplayState {
            HiDPIDisplayState(
                id: id,
                identity: identity ?? self.identity,
                status: status,
                availableSizes: [],
                current: nil
            )
        }

        private func makeManager(
            _ handler: @escaping @Sendable (String) async throws -> Void
        ) -> HiDPIModeManager {
            HiDPIModeManager(runner: ClosureRunner(handler: handler), location: location, defaults: defaults)
        }

        private func seed(_ data: Data) throws {
            try FileManager.default.createDirectory(at: vendorFolder, withIntermediateDirectories: true)
            try data.write(to: file)
        }

        private func runInstall() throws -> Int32 {
            try runShell(HiDPIOverride.installCommand(for: identity, location: location))
        }

        private func runRemove(expecting data: Data) throws -> Int32 {
            try runShell(HiDPIOverride.removeCommand(
                vendorID: identity.vendorID,
                productID: identity.productID,
                expectedCurrent: data,
                location: location
            ))
        }

        private func seedHold(_ data: Data) throws {
            let hold = vendorFolder.appendingPathComponent(".dimmerly-hold.ABCD1234", isDirectory: true)
            try FileManager.default.createDirectory(at: hold, withIntermediateDirectories: true)
            try data.write(to: hold.appendingPathComponent("file"))
        }

        private func holdFolders() -> [URL] {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: vendorFolder.path)) ?? []
            return names.filter { $0.hasPrefix(".dimmerly-hold.") }
                .map { vendorFolder.appendingPathComponent($0, isDirectory: true) }
        }

        private func writeFlag(_ value: Bool) {
            let plist = [HiDPIOverride.windowServerKey: value]
            try? (plist as NSDictionary).write(to: URL(fileURLWithPath: location.windowServerDomain + ".plist"))
        }

        /// The stand-in preference's value, or nil when it isn't set.
        private func flag() -> Bool? {
            let url = URL(fileURLWithPath: location.windowServerDomain + ".plist")
            guard let plist = NSDictionary(contentsOf: url) else { return nil }
            return plist[HiDPIOverride.windowServerKey] as? Bool
        }

        private func runShell(_ command: String) throws -> Int32 {
            try Self.shell(command)
        }

        private nonisolated static func firstSignal(of stream: AsyncStream<Void>) async {
            for await _ in stream {
                return
            }
        }

        private nonisolated static func run(_ tool: String, _ arguments: [String]) throws -> Int32 {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = arguments
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        }

        private nonisolated static func shell(_ command: String) throws -> Int32 {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", command]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        }
    }

    private struct ClosureRunner: PrivilegedCommandRunning {
        let handler: @Sendable (String) async throws -> Void

        func run(_ command: String, prompt _: String) async throws {
            try await handler(command)
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

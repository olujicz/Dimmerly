//
//  HiDPIOverrideTests.swift
//  DimmerlyTests
//
//  Unit tests for HiDPI override sizes, file contents, ownership, status and commands.
//

#if !APPSTORE

    @testable import Dimmerly
    import XCTest

    final class HiDPIOverrideTests: XCTestCase {
        private let display = HiDPIDisplayIdentity(
            vendorID: 0x4A8B, productID: 0x2555, nativeWidth: 1920, nativeHeight: 1080, name: "ANMITE"
        )

        // MARK: Eligibility

        func testEligibilityAcceptsExternalDisplaysBelow4K() {
            XCTAssertTrue(HiDPIOverride.isEligible(
                isBuiltIn: false, vendorID: 0x4A8B, productID: 0x2555, nativeWidth: 1920, nativeHeight: 1080
            ))
            XCTAssertTrue(HiDPIOverride.isEligible(
                isBuiltIn: false, vendorID: 0x1E6D, productID: 0x5B11, nativeWidth: 2560, nativeHeight: 1440
            ))
        }

        func testEligibilityRejectsBuiltIn4KAndUnknownDisplays() {
            XCTAssertFalse(HiDPIOverride.isEligible(
                isBuiltIn: true, vendorID: 0x610, productID: 0xA045, nativeWidth: 1920, nativeHeight: 1080
            ))
            XCTAssertFalse(HiDPIOverride.isEligible(
                isBuiltIn: false, vendorID: 0x410C, productID: 0xC18F, nativeWidth: 3840, nativeHeight: 2160
            ))
            XCTAssertFalse(HiDPIOverride.isEligible(
                isBuiltIn: false, vendorID: 0, productID: 0x2555, nativeWidth: 1920, nativeHeight: 1080
            ))
            XCTAssertFalse(HiDPIOverride.isEligible(
                isBuiltIn: false, vendorID: 0x4A8B, productID: 0xFFFF_FFFF, nativeWidth: 1920, nativeHeight: 1080
            ))
            XCTAssertFalse(HiDPIOverride.isEligible(
                isBuiltIn: false, vendorID: 0x4A8B, productID: 0x2555, nativeWidth: 1024, nativeHeight: 768
            ))
        }

        // MARK: Sizes

        func testScaledSizesFor1080pStepDownFromJustBelowNative() {
            let sizes = HiDPIOverride.scaledSizes(nativeWidth: 1920, nativeHeight: 1080)
            XCTAssertEqual(sizes.map { "\($0.width)x\($0.height)" }, [
                "1856x1044", "1792x1008", "1728x972", "1664x936", "1600x900", "1536x864", "1472x828",
            ])
        }

        func testScaledSizesKeepEvenHeightsAndSkipNative() {
            let sizes = HiDPIOverride.scaledSizes(nativeWidth: 2560, nativeHeight: 1440)
            XCTAssertEqual(sizes.first, HiDPISize(width: 2496, height: 1404))
            XCTAssertFalse(sizes.contains(HiDPISize(width: 2560, height: 1440)))
            XCTAssertTrue(sizes.allSatisfy { $0.height % 2 == 0 && $0.width >= 1920 })
        }

        // MARK: File contents

        func testPlistMatchesTheVerifiedOverrideLayout() throws {
            let data = try HiDPIOverride.plistData(for: display)
            let plist = try XCTUnwrap(
                PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
            )
            XCTAssertEqual(plist["DisplayVendorID"] as? Int, 0x4A8B)
            XCTAssertEqual(plist["DisplayProductID"] as? Int, 0x2555)
            XCTAssertEqual(plist["DisplayProductName"] as? String, "ANMITE")
            XCTAssertEqual(plist[HiDPIOverride.ownershipKey] as? Bool, true)
            XCTAssertNil(plist["default-resolution"])

            let resolutions = try XCTUnwrap(plist["scale-resolutions"] as? [Data])
            XCTAssertEqual(resolutions.count, 7 * 3)
            // 1856x1044: 3712x2088 with HiDPI flags, 3712x2088, then 1856x1044.
            XCTAssertEqual(hex(resolutions[0]), "00000e80000008280000000900200000")
            XCTAssertEqual(hex(resolutions[1]), "00000e8000000828")
            XCTAssertEqual(hex(resolutions[2]), "0000074000000414")
        }

        func testFilePathUsesLowercaseUnpaddedHexIDs() {
            let url = HiDPIOverride.fileURL(vendorID: 0x4A8B, productID: 0x2555)
            XCTAssertEqual(
                url.path,
                "/Library/Displays/Contents/Resources/Overrides/DisplayVendorID-4a8b/DisplayProductID-2555"
            )
        }

        // MARK: Ownership

        func testOwnershipRecognisesDimmerlyFiles() throws {
            XCTAssertEqual(HiDPIOverride.ownership(ofPlistData: nil), .none)
            XCTAssertEqual(try HiDPIOverride.ownership(ofPlistData: HiDPIOverride.plistData(for: display)), .dimmerly)
        }

        func testForeignHiDPIOnlyFileIsReplaceable() throws {
            let data = try plist([
                "DisplayProductName": "ANMITE (HiDPI)",
                "DisplayVendorID": 0x4A8B,
                "DisplayProductID": 0x2555,
                "scale-resolutions": [Data([0, 0, 7, 0x40])],
            ])
            XCTAssertEqual(HiDPIOverride.ownership(ofPlistData: data), .other(replaceable: true))
        }

        func testForeignFileWithOtherKeysIsNotReplaceable() throws {
            let data = try plist([
                "DisplayVendorID": 0x4A8B,
                "DisplayProductID": 0x2555,
                "IODisplayEDID": Data([0, 0xFF]),
            ])
            XCTAssertEqual(HiDPIOverride.ownership(ofPlistData: data), .other(replaceable: false))
            XCTAssertEqual(HiDPIOverride.ownership(ofPlistData: Data("not a plist".utf8)), .other(replaceable: false))
        }

        // MARK: Status

        func testStatusFollowsFileAndOfferedSizes() {
            let expected = HiDPIOverride.scaledSizes(nativeWidth: 1920, nativeHeight: 1080)
            let offered = Set(expected)
            XCTAssertEqual(status(.none, expected, []), .off)
            XCTAssertEqual(status(.dimmerly, expected, []), .restartToEnable)
            XCTAssertEqual(status(.dimmerly, expected, offered, installedBeforeLastRestart: true), .on)
            XCTAssertEqual(status(.other(replaceable: true), expected, offered), .otherOverride(replaceable: true))
        }

        func testRestartToRemoveOnlyAfterDimmerlyRemovedALoadedFile() {
            let expected = HiDPIOverride.scaledSizes(nativeWidth: 1920, nativeHeight: 1080)
            XCTAssertEqual(status(.none, expected, Set(expected), loadedFileRemoved: true), .restartToRemove)
            // Sizes on offer with no file and no removal this boot aren't Dimmerly's doing.
            XCTAssertEqual(status(.none, expected, Set(expected)), .off)
        }

        func testTurningBackOnBeforeRestartingIsOnAtOnce() {
            let expected = HiDPIOverride.scaledSizes(nativeWidth: 1920, nativeHeight: 1080)
            XCTAssertEqual(status(.dimmerly, expected, Set(expected), loadedFileRemoved: true), .on)
        }

        func testReplacedForeignOverrideWaitsForARestart() {
            let expected = HiDPIOverride.scaledSizes(nativeWidth: 1920, nativeHeight: 1080)
            // macOS still offers the other app's sizes, which may overlap Dimmerly's.
            XCTAssertEqual(status(.dimmerly, expected, Set(expected)), .restartToEnable)
        }

        func testStatusReportsAnOverrideMacOSIgnoredAfterARestart() {
            let expected = HiDPIOverride.scaledSizes(nativeWidth: 1920, nativeHeight: 1080)
            XCTAssertEqual(
                HiDPIOverride.status(
                    ownership: .dimmerly, expectedSizes: expected, offeredHiDPISizes: [],
                    installedBeforeLastRestart: true
                ),
                .notAccepted
            )
            // Installed since the last boot: macOS hasn't read it yet.
            XCTAssertEqual(
                HiDPIOverride.status(
                    ownership: .dimmerly, expectedSizes: expected, offeredHiDPISizes: [],
                    installedBeforeLastRestart: false
                ),
                .restartToEnable
            )
            // Honoured: an older file whose sizes are offered is simply on.
            XCTAssertEqual(
                HiDPIOverride.status(
                    ownership: .dimmerly, expectedSizes: expected, offeredHiDPISizes: Set(expected),
                    installedBeforeLastRestart: true
                ),
                .on
            )
        }

        func testStatusCountsTheOverrideAsActiveWhenMacOSDropsSomeSizes() {
            let expected = HiDPIOverride.scaledSizes(nativeWidth: 3440, nativeHeight: 1440)
            let smallestOnly = Set(expected.suffix(2))
            XCTAssertEqual(status(.dimmerly, expected, smallestOnly, installedBeforeLastRestart: true), .on)
        }

        func testStatusIgnoresHiDPISizesMacOSOffersOnItsOwn() {
            let expected = HiDPIOverride.scaledSizes(nativeWidth: 1920, nativeHeight: 1080)
            let builtInOnly: Set = [HiDPISize(width: 1024, height: 576)]
            XCTAssertEqual(status(.none, expected, builtInOnly), .off)
            XCTAssertEqual(status(.dimmerly, expected, builtInOnly), .restartToEnable)
        }

        // MARK: Current mode

        func testModeChoiceTellsHiDPINativeAndLowResolutionApart() {
            XCTAssertEqual(choice(1600, 900, 3200, 1800), .hiDPI(HiDPISize(width: 1600, height: 900)))
            XCTAssertEqual(choice(1920, 1080, 1920, 1080), .native)
            // The 1x 1600 × 900 that System Settings lists beside the HiDPI one must not read
            // as native.
            XCTAssertEqual(choice(1600, 900, 1600, 900), .lowResolution(HiDPISize(width: 1600, height: 900)))
        }

        // MARK: Commands

        func testInstallCommandCopiesAsRootAndSetsTheWindowServerFlag() {
            let command = HiDPIOverride.installCommand(
                stagedFile: URL(fileURLWithPath: "/private/tmp/it's staged.plist"),
                destination: HiDPIOverride.fileURL(vendorID: 0x4A8B, productID: 0x2555),
                expectedCurrentFile: nil
            )
            XCTAssertEqual(
                command,
                "[ ! -e '/Library/Displays/Contents/Resources/Overrides/"
                    + "DisplayVendorID-4a8b/DisplayProductID-2555' ] && "
                    + "/bin/mkdir -p '/Library/Displays/Contents/Resources/Overrides/DisplayVendorID-4a8b' && "
                    + "/usr/bin/install -m 0644 -o root -g wheel '/private/tmp/it'\\''s staged.plist' "
                    + "'/Library/Displays/Contents/Resources/Overrides/DisplayVendorID-4a8b/DisplayProductID-2555' && "
                    + "/usr/bin/defaults write /Library/Preferences/com.apple.windowserver "
                    + "DisplayResolutionEnabled -bool YES"
            )
        }

        func testInstallCommandOnlyReplacesTheFileDimmerlyRead() {
            let destination = HiDPIOverride.fileURL(vendorID: 0x4A8B, productID: 0x2555)
            let command = HiDPIOverride.installCommand(
                stagedFile: URL(fileURLWithPath: "/private/tmp/new.plist"),
                destination: destination,
                expectedCurrentFile: URL(fileURLWithPath: "/private/tmp/old.plist")
            )
            XCTAssertTrue(command.hasPrefix("/usr/bin/cmp -s '/private/tmp/old.plist' '\(destination.path)' && "))
        }

        func testRemoveCommandKeepsTheFlagWhileOtherOverridesRemain() {
            let file = HiDPIOverride.fileURL(vendorID: 0x4A8B, productID: 0x2555)
            let snapshot = URL(fileURLWithPath: "/private/tmp/old.plist")
            let keep = HiDPIOverride.removeCommand(
                file: file, expectedCurrentFile: snapshot, clearWindowServerFlag: false
            )
            XCTAssertTrue(keep.hasPrefix(
                "/usr/bin/cmp -s '/private/tmp/old.plist' '\(file.path)' && "
                    + "/bin/rm -f '\(file.path)' && { /bin/rmdir "
            ))
            XCTAssertFalse(keep.contains("defaults delete"))

            let clear = HiDPIOverride.removeCommand(
                file: file, expectedCurrentFile: snapshot, clearWindowServerFlag: true
            )
            XCTAssertTrue(clear.hasSuffix(
                "{ /usr/bin/defaults delete /Library/Preferences/com.apple.windowserver "
                    + "DisplayResolutionEnabled 2>/dev/null || true; }"
            ))
        }

        // MARK: Helpers

        private func status(
            _ ownership: HiDPIOverrideOwnership,
            _ expected: [HiDPISize],
            _ offered: Set<HiDPISize>,
            installedBeforeLastRestart: Bool = false,
            loadedFileRemoved: Bool = false
        ) -> HiDPIOverrideStatus {
            HiDPIOverride.status(
                ownership: ownership,
                expectedSizes: expected,
                offeredHiDPISizes: offered,
                installedBeforeLastRestart: installedBeforeLastRestart,
                loadedFileRemovedThisBoot: loadedFileRemoved
            )
        }

        private func choice(_ width: Int, _ height: Int, _ pixelWidth: Int, _ pixelHeight: Int) -> HiDPIModeChoice {
            HiDPIModeChoice(
                width: width,
                height: height,
                pixelWidth: pixelWidth,
                pixelHeight: pixelHeight,
                nativeWidth: 1920,
                nativeHeight: 1080
            )
        }

        private func hex(_ data: Data) -> String {
            data.map { String(format: "%02x", $0) }.joined()
        }

        private func plist(_ dictionary: [String: Any]) throws -> Data {
            try PropertyListSerialization.data(fromPropertyList: dictionary, format: .xml, options: 0)
        }
    }

#endif

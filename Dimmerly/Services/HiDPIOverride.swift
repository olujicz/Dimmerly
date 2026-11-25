//
//  HiDPIOverride.swift
//  Dimmerly
//
//  Builds and recognises the display override files that make macOS offer HiDPI
//  ("looks like") sizes on external displays below 4K. Direct download only: the
//  files live in /Library and need an administrator password to write.
//

#if !APPSTORE

    import CryptoKit
    import Foundation

    /// One external display, described by the values its override file is keyed on.
    struct HiDPIDisplayIdentity: Equatable {
        let vendorID: UInt32
        let productID: UInt32
        /// Native panel size in pixels.
        let nativeWidth: Int
        let nativeHeight: Int
        let name: String

        /// Override files are keyed by maker and model, so identical monitors share one.
        func isSameModel(as other: HiDPIDisplayIdentity) -> Bool {
            vendorID == other.vendorID && productID == other.productID
        }
    }

    /// A logical ("looks like") size in points. Its HiDPI mode draws twice as many pixels.
    struct HiDPISize: Hashable, Comparable {
        let width: Int
        let height: Int

        static func < (lhs: HiDPISize, rhs: HiDPISize) -> Bool {
            (lhs.width, lhs.height) < (rhs.width, rhs.height)
        }
    }

    /// The mode a display runs in, as the size picker shows it.
    enum HiDPIModeChoice: Hashable {
        /// The panel's native size at 1x.
        case native
        /// A HiDPI ("looks like") size.
        case hiDPI(HiDPISize)
        /// A 1x size other than native, which looks blurry. Shown so the picker never
        /// claims "Native" for it.
        case lowResolution(HiDPISize)

        init(width: Int, height: Int, pixelWidth: Int, pixelHeight: Int, nativeWidth: Int, nativeHeight: Int) {
            let size = HiDPISize(width: width, height: height)
            if Self.isHiDPI(width: width, height: height, pixelWidth: pixelWidth, pixelHeight: pixelHeight) {
                self = .hiDPI(size)
            } else if width == nativeWidth, height == nativeHeight {
                self = .native
            } else {
                self = .lowResolution(size)
            }
        }

        /// A HiDPI mode draws twice as many pixels as its size in points, in both directions.
        static func isHiDPI(width: Int, height: Int, pixelWidth: Int, pixelHeight: Int) -> Bool {
            pixelWidth == width * 2 && pixelHeight == height * 2
        }
    }

    /// Who wrote the override file for a display, if one exists.
    enum HiDPIOverrideOwnership: Equatable {
        case none
        case dimmerly
        /// Written by someone else, or by Dimmerly and since extended with other settings.
        /// Dimmerly never replaces or removes it. `hiDPIOnly` is true when it holds nothing
        /// but HiDPI sizes, which only changes what Settings says about it.
        case other(hiDPIOnly: Bool)
    }

    /// What Settings shows for a display.
    enum HiDPIOverrideStatus: Equatable {
        /// No override and no extra HiDPI sizes.
        case off
        /// Dimmerly's file is installed; macOS reads it at the next restart.
        case restartToEnable
        /// Dimmerly's file is installed and macOS offers its sizes.
        case on
        /// Dimmerly's file was installed before the last restart, yet macOS offers none of
        /// its sizes. Some docks, adapters and capture devices never honour overrides.
        case notAccepted
        /// Dimmerly's file was removed; the sizes stay until the next restart.
        case restartToRemove
        /// Another tool's override file is installed.
        case otherOverride(hiDPIOnly: Bool)

        enum Action {
            case turnOn
            case turnOff
        }

        /// What the row's button does in this state, or nil when it has none. Settings and
        /// `HiDPIModeManager` both follow this, so they can't disagree.
        var action: Action? {
            switch self {
            // After Turn Off, the sizes stay until the restart; Turn On puts the file back,
            // so changing your mind before restarting needs no restart at all.
            case .off, .restartToRemove: .turnOn
            case .on, .restartToEnable, .notAccepted: .turnOff
            case .otherOverride: nil
            }
        }

        /// Once removed, the sizes stay offered until the restart, but picking one then would
        /// be a dead end.
        var allowsSizeChange: Bool {
            self != .restartToRemove
        }
    }

    enum HiDPIOverride {
        static let overridesRoot = URL(fileURLWithPath: "/Library/Displays/Contents/Resources/Overrides")
        static let windowServerDomain = "/Library/Preferences/com.apple.windowserver"
        static let windowServerKey = "DisplayResolutionEnabled"
        /// Marks a file as Dimmerly's, so Dimmerly only ever removes its own files.
        static let ownershipKey = "DimmerlyHiDPIOverride"

        /// Displays this wide or wider already get HiDPI sizes from macOS.
        static let maximumNativeWidth = 3840
        static let minimumNativeWidth = 1280

        /// Keys a pure HiDPI override holds. A file with other keys carries someone else's settings.
        static let hiDPIOnlyKeys: Set<String> = [
            "DisplayProductName", "DisplayVendorID", "DisplayProductID",
            "scale-resolutions", "default-resolution", ownershipKey,
        ]

        // MARK: Eligibility and sizes

        static func isEligible(
            isBuiltIn: Bool,
            vendorID: UInt32,
            productID: UInt32,
            nativeWidth: Int,
            nativeHeight: Int
        ) -> Bool {
            guard !isBuiltIn,
                  BrightnessManager.isUsableDisplayMetadata(vendorID),
                  BrightnessManager.isUsableDisplayMetadata(productID)
            else {
                return false
            }
            return nativeWidth >= minimumNativeWidth && nativeWidth < maximumNativeWidth && nativeHeight > 0
        }

        /// Sizes from just under native down to three quarters of it, in 64-point steps.
        /// macOS ignores a HiDPI size equal to the native size, so native itself is left out.
        /// Heights keep the panel's aspect ratio and are rounded to an even number.
        static func scaledSizes(nativeWidth: Int, nativeHeight: Int) -> [HiDPISize] {
            guard nativeWidth > 64, nativeHeight > 0 else { return [] }
            var sizes: [HiDPISize] = []
            var width = nativeWidth - 64
            while width >= nativeWidth * 3 / 4 {
                let height = (width * nativeHeight + nativeWidth) / (2 * nativeWidth) * 2
                sizes.append(HiDPISize(width: width, height: height))
                width -= 64
            }
            return sizes
        }

        // MARK: Files

        static func fileURL(vendorID: UInt32, productID: UInt32, root: URL = overridesRoot) -> URL {
            root.appendingPathComponent("DisplayVendorID-\(String(vendorID, radix: 16))", isDirectory: true)
                .appendingPathComponent("DisplayProductID-\(String(productID, radix: 16))")
        }

        /// The override file. Each size gets three `scale-resolutions` entries, as macOS
        /// expects: the doubled size with the HiDPI flags, the doubled size, and the size
        /// itself, each value a big-endian UInt32. No default size is set, so the display
        /// keeps starting at its native mode if macOS rejects the file.
        static func plistData(for display: HiDPIDisplayIdentity) throws -> Data {
            var resolutions: [Data] = []
            for size in scaledSizes(nativeWidth: display.nativeWidth, nativeHeight: display.nativeHeight) {
                resolutions.append(bigEndian([size.width * 2, size.height * 2, 0x9, 0x200000]))
                resolutions.append(bigEndian([size.width * 2, size.height * 2]))
                resolutions.append(bigEndian([size.width, size.height]))
            }
            let plist: [String: Any] = [
                "DisplayProductName": display.name,
                "DisplayVendorID": Int(display.vendorID),
                "DisplayProductID": Int(display.productID),
                "scale-resolutions": resolutions,
                ownershipKey: true,
            ]
            return try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        }

        static func ownership(ofPlistData data: Data?) -> HiDPIOverrideOwnership {
            guard let data else { return .none }
            guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any]
            else {
                return .other(hiDPIOnly: false)
            }
            // The marker alone doesn't make a file removable: once another tool adds settings
            // to it, removing the file would discard them.
            let isHiDPIOnly = Set(plist.keys).isSubset(of: hiDPIOnlyKeys) && plist["scale-resolutions"] != nil
            if plist[ownershipKey] as? Bool == true, isHiDPIOnly {
                return .dimmerly
            }
            return .other(hiDPIOnly: isHiDPIOnly)
        }

        // MARK: Status

        /// - Parameters:
        ///   - offeredHiDPISizes: logical sizes macOS currently offers as HiDPI modes. One
        ///     expected size is enough: macOS silently drops sizes whose doubled image is larger
        ///     than the GPU allows (6K on base M-series chips), which hits wide panels.
        ///   - installedBeforeLastRestart: whether the file predates the current boot, so macOS
        ///     has already had its chance to read it.
        ///   - loadedFileRemovedThisBoot: whether Dimmerly removed a file of its own that macOS
        ///     had read at the current boot. Its sizes stay on offer until the restart, and
        ///     this is the only way sizes on offer can be Dimmerly's while its current file, if
        ///     any, is unread.
        static func status(
            ownership: HiDPIOverrideOwnership,
            expectedSizes: [HiDPISize],
            offeredHiDPISizes: Set<HiDPISize>,
            installedBeforeLastRestart: Bool = false,
            loadedFileRemovedThisBoot: Bool = false
        ) -> HiDPIOverrideStatus {
            let sizesOffered = expectedSizes.contains { offeredHiDPISizes.contains($0) }
            switch ownership {
            case .dimmerly:
                if installedBeforeLastRestart {
                    return sizesOffered ? .on : .notAccepted
                }
                // macOS hasn't read the new file yet. Its sizes are on offer only when they
                // come from Dimmerly's earlier file, as after turning HiDPI off and on again
                // without restarting; sizes from another app's file it replaced don't count.
                return sizesOffered && loadedFileRemovedThisBoot ? .on : .restartToEnable
            case let .other(hiDPIOnly):
                return .otherOverride(hiDPIOnly: hiDPIOnly)
            case .none:
                return sizesOffered && loadedFileRemovedThisBoot ? .restartToRemove : .off
            }
        }

        // MARK: Privileged commands

        /// Where the privileged commands work, and who must own it. Tests point this at a
        /// temporary folder owned by the current user; the app always uses `.system`.
        struct SystemLocation {
            var overridesRoot: URL = HiDPIOverride.overridesRoot
            /// Every folder from here down to the vendor folder must be a real directory owned
            /// by `ownerUID` that nobody else can write to, or the command stops.
            var trustedBase = URL(fileURLWithPath: "/Library")
            var ownerUID: UInt32 = 0
            var ownerGID: UInt32 = 0
            var windowServerDomain = HiDPIOverride.windowServerDomain

            static let system = SystemLocation()
        }

        /// Adds the display's override file as root and lets WindowServer use the added sizes.
        ///
        /// Everything root needs travels inside the command: the file's contents, its digest
        /// and the paths. Nothing is read from a location the user, or an app running as the
        /// user, could change while the password prompt is open. Root checks that the folders
        /// are trustworthy, that the contents decode to what the digest says and to Dimmerly's
        /// own file for this display, and that no file exists yet.
        ///
        /// The file is prepared beside its destination and moved into place last, after the
        /// WindowServer flag is set. If the move fails, the flag goes back to its earlier value.
        static func installCommand(
            for display: HiDPIDisplayIdentity,
            location: SystemLocation = .system
        ) throws -> String {
            let contents = try plistData(for: display)
            let destination = fileURL(
                vendorID: display.vendorID, productID: display.productID, root: location.overridesRoot
            )
            let directory = destination.deletingLastPathComponent()
            guard let checks = folderChecks(for: directory, location: location, create: true) else {
                return "/usr/bin/false"
            }
            let digest = sha256Hex(contents)
            let flag = "\(shellQuoted(location.windowServerDomain)) \(shellQuoted(windowServerKey))"
            let owner = "\(location.ownerUID):\(location.ownerGID)"
            var lines = preamble(ownerUID: location.ownerUID) + checks + [
                "DEST=\(shellQuoted(destination.path))",
                "TMP=\(shellQuoted(directory.path))/.dimmerly-hidpi-$$",
                "abort() { /bin/rm -f \"$TMP\"; exit 1; }",
                "[ ! -e \"$DEST\" ] && [ ! -L \"$DEST\" ] || exit 1",
                "printf '%s' \(shellQuoted(contents.base64EncodedString())) | /usr/bin/base64 -D > \"$TMP\" || abort",
                "[ \"$(digest \"$TMP\")\" = \(shellQuoted(digest)) ] || abort",
            ]
            for (key, value) in [
                (ownershipKey, "true"),
                ("DisplayVendorID", String(display.vendorID)),
                ("DisplayProductID", String(display.productID)),
            ] {
                lines.append(
                    "[ \"$(/usr/bin/plutil -extract \(shellQuoted(key)) raw -o - \"$TMP\" 2>/dev/null)\" "
                        + "= \(shellQuoted(value)) ] || abort"
                )
            }
            lines += [
                "/usr/sbin/chown \(owner) \"$TMP\" || abort",
                "/bin/chmod 644 \"$TMP\" || abort",
                "CHANGED=0",
                "undo() {",
                "  [ \"$CHANGED\" = 1 ] || return 0",
                "  if [ \"$PRC\" -ne 0 ]; then /usr/bin/defaults delete \(flag); "
                    + "else /usr/bin/defaults write \(flag) -bool NO; fi",
                "}",
                "PRIOR=$(/usr/bin/defaults read \(flag) 2>/dev/null); PRC=$?",
                "if [ \"$PRC\" -eq 0 ] && [ \"$PRIOR\" = 1 ]; then :",
                "elif [ \"$PRC\" -ne 0 ] || [ \"$PRIOR\" = 0 ]; then",
                "  CHANGED=1",
                // `defaults write` can report success without writing, so read the value back.
                "  /usr/bin/defaults write \(flag) -bool YES || { undo; abort; }",
                "  [ \"$(/usr/bin/defaults read \(flag) 2>/dev/null)\" = 1 ] || { undo; abort; }",
                "else abort; fi",
                "/bin/mv -f \"$TMP\" \"$DEST\" || { undo; abort; }",
                "exit 0",
            ]
            return lines.joined(separator: "\n")
        }

        /// Removes the display's override file as root, only if it still holds exactly
        /// `expectedCurrent`, the bytes Dimmerly read and recognised as its own. Then removes
        /// the vendor folder if that left it empty.
        ///
        /// The WindowServer flag stays as it is: Dimmerly can't tell a flag it set from one the
        /// user or another tool did, and other overrides may rely on it.
        static func removeCommand(
            vendorID: UInt32,
            productID: UInt32,
            expectedCurrent: Data,
            location: SystemLocation = .system
        ) -> String {
            let destination = fileURL(vendorID: vendorID, productID: productID, root: location.overridesRoot)
            let directory = destination.deletingLastPathComponent()
            guard let checks = folderChecks(for: directory, location: location, create: false) else {
                return "/usr/bin/false"
            }
            let lines = preamble(ownerUID: location.ownerUID) + checks + [
                "DEST=\(shellQuoted(destination.path))",
                "[ -f \"$DEST\" ] && [ ! -L \"$DEST\" ] || exit 1",
                "[ \"$(digest \"$DEST\")\" = \(shellQuoted(sha256Hex(expectedCurrent))) ] || exit 1",
                "/bin/rm -f \"$DEST\" || exit 1",
                "/bin/rmdir \(shellQuoted(directory.path)) 2>/dev/null",
                "exit 0",
            ]
            return lines.joined(separator: "\n")
        }

        static func sha256Hex(_ data: Data) -> String {
            SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }

        /// Shell helpers: `trusted` accepts only a real directory owned by `ownerUID` that group
        /// and others can't write to, and `digest` prints a file's SHA-256.
        private static func preamble(ownerUID: UInt32) -> [String] {
            [
                "umask 022",
                "trusted() {",
                "  [ -d \"$1\" ] && [ ! -L \"$1\" ] || return 1",
                "  [ \"$(/usr/bin/stat -f %u \"$1\")\" = \(ownerUID) ] || return 1",
                "  [ $(( 0$(/usr/bin/stat -f %Lp \"$1\") & 022 )) -eq 0 ]",
                "}",
                "digest() { /usr/bin/shasum -a 256 < \"$1\" | /usr/bin/cut -d ' ' -f1; }",
            ]
        }

        /// One check per folder from the trusted base down to `directory`. When `create` is set,
        /// a missing folder is made; an existing one must pass `trusted`.
        private static func folderChecks(for directory: URL, location: SystemLocation, create: Bool) -> [String]? {
            let base = location.trustedBase.standardizedFileURL.pathComponents
            let target = directory.standardizedFileURL.pathComponents
            guard target.count > base.count, Array(target.prefix(base.count)) == base else { return nil }
            var checks: [String] = []
            for count in base.count ... target.count {
                let path = NSString.path(withComponents: Array(target.prefix(count)))
                let quoted = shellQuoted(path)
                if create, count > base.count {
                    checks.append(
                        "if [ -e \(quoted) ] || [ -L \(quoted) ]; then trusted \(quoted) || exit 1; "
                            + "else /bin/mkdir -m 755 \(quoted) || exit 1; fi"
                    )
                } else {
                    checks.append("trusted \(quoted) || exit 1")
                }
            }
            return checks
        }

        static func shellQuoted(_ value: String) -> String {
            "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }

        // MARK: Helpers

        private static func bigEndian(_ values: [Int]) -> Data {
            var data = Data(capacity: values.count * 4)
            for value in values {
                withUnsafeBytes(of: UInt32(truncatingIfNeeded: value).bigEndian) { data.append(contentsOf: $0) }
            }
            return data
        }
    }

#endif

//
//  HiDPIOverride.swift
//  Dimmerly
//
//  Builds and recognises the display override files that make macOS offer HiDPI
//  ("looks like") sizes on external displays below 4K. Direct download only: the
//  files live in /Library and need an administrator password to write.
//

#if !APPSTORE

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
        /// Written by someone else. `replaceable` is true when it holds nothing but HiDPI
        /// sizes, so replacing it with Dimmerly's file loses nothing.
        case other(replaceable: Bool)
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
        case otherOverride(replaceable: Bool)

        enum Action {
            case turnOn
            case turnOff
            /// Replaces another app's HiDPI-only file with Dimmerly's.
            case manage
        }

        /// What the row's button does in this state, or nil when it has none. Settings and
        /// `HiDPIModeManager` both follow this, so they can't disagree.
        var action: Action? {
            switch self {
            // After Turn Off, the sizes stay until the restart; Turn On puts the file back,
            // so changing your mind before restarting needs no restart at all.
            case .off, .restartToRemove: .turnOn
            case .on, .restartToEnable, .notAccepted: .turnOff
            case .otherOverride(replaceable: true): .manage
            case .otherOverride(replaceable: false): nil
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

        /// Keys a pure HiDPI override holds. A foreign file with only these is safe to replace.
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
                return .other(replaceable: false)
            }
            if plist[ownershipKey] as? Bool == true {
                return .dimmerly
            }
            let isHiDPIOnly = Set(plist.keys).isSubset(of: hiDPIOnlyKeys) && plist["scale-resolutions"] != nil
            return .other(replaceable: isHiDPIOnly)
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
            case let .other(replaceable):
                return .otherOverride(replaceable: replaceable)
            case .none:
                return sizesOffered && loadedFileRemovedThisBoot ? .restartToRemove : .off
            }
        }

        // MARK: Privileged commands

        /// Copies the prepared file into place as root and lets WindowServer use the added sizes.
        ///
        /// The password prompt can stay open for a while, so the command first checks that the
        /// destination still holds what Dimmerly read before asking: a copy of it at
        /// `expectedCurrentFile`, or nothing when that is nil. If another app changed it in the
        /// meantime, the command stops before touching anything.
        static func installCommand(stagedFile: URL, destination: URL, expectedCurrentFile: URL?) -> String {
            let unchanged = expectedCurrentFile.map {
                "/usr/bin/cmp -s \(shellQuoted($0.path)) \(shellQuoted(destination.path))"
            } ?? "[ ! -e \(shellQuoted(destination.path)) ]"
            return [
                unchanged,
                "/bin/mkdir -p \(shellQuoted(destination.deletingLastPathComponent().path))",
                "/usr/bin/install -m 0644 -o root -g wheel "
                    + "\(shellQuoted(stagedFile.path)) \(shellQuoted(destination.path))",
                "/usr/bin/defaults write \(windowServerDomain) \(windowServerKey) -bool YES",
            ].joined(separator: " && ")
        }

        /// Removes the file and its vendor folder if empty. Clears the WindowServer flag only
        /// when no override files remain, since other overrides may depend on it. Like
        /// `installCommand`, it stops if the file no longer matches `expectedCurrentFile`.
        static func removeCommand(file: URL, expectedCurrentFile: URL, clearWindowServerFlag: Bool) -> String {
            var steps = [
                "/usr/bin/cmp -s \(shellQuoted(expectedCurrentFile.path)) \(shellQuoted(file.path))",
                "/bin/rm -f \(shellQuoted(file.path))",
                "{ /bin/rmdir \(shellQuoted(file.deletingLastPathComponent().path)) 2>/dev/null || true; }",
            ]
            if clearWindowServerFlag {
                steps.append(
                    "{ /usr/bin/defaults delete \(windowServerDomain) \(windowServerKey) 2>/dev/null || true; }"
                )
            }
            return steps.joined(separator: " && ")
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

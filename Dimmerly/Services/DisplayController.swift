//
//  DisplayController.swift
//  Dimmerly
//
//  Controller for managing display sleep operations.
//

#if !APPSTORE
import Foundation
import IOKit

/// Controller responsible for putting displays to sleep
struct DisplayController {
    /// Puts all connected displays to sleep immediately.
    ///
    /// Uses macOS `pmset displaysleepnow` as the primary method (reliable on macOS 13+).
    /// Falls back to IOKit `IODisplayWrangler` if pmset is unavailable.
    static func sleepDisplays() -> Result<Void, DisplayError> {
        let pmsetResult = sleepWithPmset()
        if case .success = pmsetResult {
            return pmsetResult
        }
        return sleepWithIOKit()
    }

    /// Sleeps displays using the macOS `pmset` utility
    private static func sleepWithPmset() -> Result<Void, DisplayError> {
        let pmsetPath = "/usr/bin/pmset"
        guard FileManager.default.isExecutableFile(atPath: pmsetPath) else {
            return .failure(.pmsetNotFound)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: pmsetPath)
        process.arguments = ["displaysleepnow"]

        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                return .success(())
            } else {
                return .failure(.pmsetFailed(status: process.terminationStatus))
            }
        } catch {
            return .failure(.unknownError(error))
        }
    }

    /// Sleeps displays using IOKit (fallback for systems where pmset is unavailable)
    private static func sleepWithIOKit() -> Result<Void, DisplayError> {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("IODisplayWrangler")
        )
        guard service != IO_OBJECT_NULL else {
            return .failure(.displayWranglerNotFound)
        }
        defer { IOObjectRelease(service) }

        let result = IORegistryEntrySetCFProperty(
            service,
            "IORequestIdle" as CFString,
            kCFBooleanTrue
        )
        if result == KERN_SUCCESS {
            return .success(())
        } else {
            return .failure(.iokitError(code: result))
        }
    }
}
#endif

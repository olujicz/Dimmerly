//
//  DisplayController.swift
//  Dimmerly
//
//  Controller for managing display sleep operations.
//

#if !APPSTORE
import IOKit

/// Controller responsible for putting displays to sleep via IOKit
struct DisplayController {
    /// Puts all connected displays to sleep immediately using IOKit
    static func sleepDisplays() -> Result<Void, DisplayError> {
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

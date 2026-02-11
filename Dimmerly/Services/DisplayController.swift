//
//  DisplayController.swift
//  Dimmerly
//
//  Controller for managing display sleep operations.
//

#if !APPSTORE
import Foundation

/// Controller responsible for putting displays to sleep
struct DisplayController {
    /// Puts all connected displays to sleep asynchronously using `pmset displaysleepnow`.
    static func sleepDisplays() async -> Result<Void, DisplayError> {
        let pmsetPath = "/usr/bin/pmset"
        guard FileManager.default.isExecutableFile(atPath: pmsetPath) else {
            return .failure(.pmsetNotFound)
        }

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: pmsetPath)
                process.arguments = ["displaysleepnow"]

                do {
                    try process.run()
                    process.waitUntilExit()
                    if process.terminationStatus == 0 {
                        continuation.resume(returning: .success(()))
                    } else {
                        continuation.resume(returning: .failure(.pmsetFailed(status: process.terminationStatus)))
                    }
                } catch {
                    continuation.resume(returning: .failure(.unknownError(error.localizedDescription)))
                }
            }
        }
    }
}
#endif

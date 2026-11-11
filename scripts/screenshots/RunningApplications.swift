import AppKit
import Foundation

@MainActor
protocol ScreenshotApplication {
    var processIdentifier: pid_t { get }
    var bundleURL: URL? { get }
    var isTerminated: Bool { get }
    func terminate() -> Bool
}

extension NSRunningApplication: ScreenshotApplication {}

/// Temporarily closes the user's Dimmerly instances, preserving their exact app paths.
@MainActor
enum RunningApplications {
    struct SavedApplication: Codable {
        let processID: pid_t
        let path: String
    }

    struct LifecycleError: LocalizedError {
        let message: String
        var errorDescription: String? {
            message
        }
    }

    static func runningApplications() -> [any ScreenshotApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: "rs.in.olujic.dimmerly")
    }

    static func waitInterval() async throws {
        try await Task.sleep(for: .milliseconds(100))
    }

    static func openApplication(_ url: URL) async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }

    static func pause(
        manifest: URL, stagedApp: URL,
        applications suppliedApplications: [any ScreenshotApplication]? = nil,
        wait: @MainActor () async throws -> Void = waitInterval
    ) async throws {
        guard !FileManager.default.fileExists(atPath: manifest.path) else {
            throw LifecycleError(message: "A previous capture still has apps to restore: \(manifest.path)")
        }
        let applications = suppliedApplications ?? runningApplications()
        let saved = try applications.compactMap { application -> SavedApplication? in
            guard let url = application.bundleURL else {
                throw LifecycleError(message: "Cannot remember the running Dimmerly app's location.")
            }
            // A staged process left by a killed script must never reopen without its environment.
            guard url.standardizedFileURL.path != stagedApp.standardizedFileURL.path else { return nil }
            return SavedApplication(processID: application.processIdentifier, path: url.path)
        }
        try JSONEncoder().encode(saved).write(to: manifest, options: .atomic)
        for application in applications {
            guard application.terminate() else {
                // An explicit refusal leaves that original running; it needs no restoration.
                let remaining = saved.filter { $0.processID != application.processIdentifier }
                try JSONEncoder().encode(remaining).write(to: manifest, options: .atomic)
                throw LifecycleError(message:
                    "Dimmerly refused to quit. Close it, then retry. No process was force-quit.")
            }
        }
        for _ in 0 ..< 100 {
            if applications.allSatisfy(\.isTerminated) {
                return
            }
            try await wait()
        }
        throw LifecycleError(message: "Dimmerly did not finish quitting within 10 seconds. Capture was stopped.")
    }

    /// Returns warnings for original app locations that no longer exist.
    static func resume(
        manifest: URL, stagedApp: URL,
        applications: @MainActor () -> [any ScreenshotApplication] = runningApplications,
        openApplication: @MainActor (URL) async throws -> Void = openApplication,
        wait: @MainActor () async throws -> Void = waitInterval
    ) async throws -> [String] {
        let saved = try JSONDecoder().decode([SavedApplication].self, from: Data(contentsOf: manifest))
            .filter { URL(fileURLWithPath: $0.path).standardizedFileURL.path != stagedApp.standardizedFileURL.path }
        // A PID alone is insufficient: it may have been reused since a crashed capture.
        func isOriginalProcess(_ application: any ScreenshotApplication) -> Bool {
            let path = application.bundleURL?.standardizedFileURL.path
            return !application.isTerminated && saved.contains {
                $0.processID == application.processIdentifier &&
                    URL(fileURLWithPath: $0.path).standardizedFileURL.path == path
            }
        }
        for _ in 0 ..< 100 {
            if !applications().contains(where: isOriginalProcess) {
                break
            }
            try await wait()
        }
        guard !applications().contains(where: isOriginalProcess) else {
            // Don't discard recovery data while an accepted quit request may still complete.
            throw LifecycleError(message:
                "The original Dimmerly is still quitting. Finish closing it, then rerun launch; " +
                    "its saved app path is retained.")
        }
        var warnings: [String] = []
        for path in Set(saved.map(\.path)).sorted() {
            let url = URL(fileURLWithPath: path)
            let isRunning = applications().contains {
                !$0.isTerminated && $0.bundleURL?.standardizedFileURL.path == url.standardizedFileURL.path
            }
            if isRunning {
                continue
            }
            guard FileManager.default.fileExists(atPath: path) else {
                warnings.append("Skipped missing Dimmerly app: \(path). Open its new location manually.")
                continue
            }
            try await openApplication(url)
        }
        try FileManager.default.removeItem(at: manifest)
        return warnings
    }
}

import AppKit
import Foundation

@MainActor
final class TestApplication: ScreenshotApplication {
    let processIdentifier: pid_t
    let bundleURL: URL?
    var isTerminated = false
    var acceptsTermination = true
    var quitRequested = false
    init(_ pid: pid_t, _ path: URL) {
        processIdentifier = pid; bundleURL = path
    }

    func terminate() -> Bool {
        quitRequested = true; return acceptsTermination
    }
}

@main
struct RunningApplicationsTests {
    @MainActor
    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let manifest = directory.appendingPathComponent("running.json")
        let originalURL = directory.appendingPathComponent("Original.app")
        let stagedURL = directory.appendingPathComponent("Staged.app")
        try FileManager.default.createDirectory(at: originalURL, withIntermediateDirectories: true)
        let original = TestApplication(101, originalURL)
        let staged = TestApplication(102, stagedURL)
        let applications: [any ScreenshotApplication] = [original, staged]
        try await RunningApplications.pause(manifest: manifest, stagedApp: stagedURL, applications: applications) {
            original.isTerminated = true
            staged.isTerminated = true
        }
        let savedData = try Data(contentsOf: manifest)
        let saved = try JSONDecoder().decode([RunningApplications.SavedApplication].self, from: savedData)
        precondition(saved.map(\.path) == [originalURL.path], "Never restore the staged app as a real app")
        precondition(original.quitRequested && staged.quitRequested)

        // Resume must wait for an original that is still shutting down, then reopen exactly its path.
        original.isTerminated = false
        var waits = 0
        var opened: [URL] = []
        _ = try await RunningApplications.resume(
            manifest: manifest, stagedApp: stagedURL, applications: { applications },
            openApplication: { opened.append($0) }, wait: {
                waits += 1
                if waits == 3 {
                    original.isTerminated = true
                }
            }
        )
        precondition(waits == 3 && opened.map(\.path) == [originalURL.path])
        precondition(!FileManager.default.fileExists(atPath: manifest.path))

        // A shutdown timeout keeps recovery data; it must not treat a quitting app as restored.
        try JSONEncoder().encode(saved).write(to: manifest)
        original.isTerminated = false
        do {
            _ = try await RunningApplications.resume(
                manifest: manifest, stagedApp: stagedURL, applications: { applications },
                openApplication: { _ in fatalError("Must not reopen a still-quitting app") }, wait: {}
            )
            fatalError("Expected shutdown timeout")
        } catch {}
        precondition(FileManager.default.fileExists(atPath: manifest.path))

        // A missing old path is reported and removed from recovery, not a permanent blocker.
        original.isTerminated = true
        try FileManager.default.removeItem(at: originalURL)
        let warnings = try await RunningApplications.resume(
            manifest: manifest, stagedApp: stagedURL, applications: { applications },
            openApplication: { _ in fatalError("Must not open a missing app") }, wait: {}
        )
        precondition(warnings.count == 1 && warnings[0].contains(originalURL.path))
        precondition(!FileManager.default.fileExists(atPath: manifest.path))

        // An old manifest containing a staged path must not reopen it either.
        try JSONEncoder().encode([RunningApplications.SavedApplication(processID: 102, path: stagedURL.path)])
            .write(to: manifest)
        _ = try await RunningApplications.resume(
            manifest: manifest, stagedApp: stagedURL, applications: { applications },
            openApplication: { _ in fatalError("Must not reopen a staged app") }, wait: {}
        )

        // An explicit refusal stops capture; it never escalates to force-quit.
        let refusing = TestApplication(103, originalURL)
        refusing.acceptsTermination = false
        do {
            try await RunningApplications.pause(
                manifest: manifest, stagedApp: stagedURL, applications: [refusing], wait: {}
            )
            fatalError("Expected quit refusal")
        } catch {}
        precondition(refusing.quitRequested && !refusing.isTerminated)
        let refusedData = try Data(contentsOf: manifest)
        let afterRefusal = try JSONDecoder().decode([RunningApplications.SavedApplication].self, from: refusedData)
        precondition(afterRefusal.isEmpty, "An explicitly refusing app stays running and needs no reopening")
        print("Running application lifecycle checks passed")
    }
}

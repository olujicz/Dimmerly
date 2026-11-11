import AppKit
import CoreGraphics
import ScreenCaptureKit

/// Captures a visible window of an explicitly selected, already running Dimmerly process.
@main
enum CaptureWindows {
    private struct Options {
        let processID: pid_t
        let mode: String
        let outputURL: URL
        let statusURL: URL?
        let valuesURL: URL?
        let requiresBackdrop: Bool

        static let usage = "Expected --pid PID --mode menu|settings-region|settings --output PATH, " +
            "or --pid PID --mode record --values VALUES.jsonl --output DIR"

        init(arguments: [String]) throws {
            var values: [String: String] = [:]
            var index = 1
            while index < arguments.count {
                let key = arguments[index]
                guard ["--pid", "--mode", "--output", "--status", "--values", "--backdrop"].contains(key),
                      values[key] == nil, index + 1 < arguments.count
                else {
                    throw CaptureError(Self.usage)
                }
                values[key] = arguments[index + 1]
                index += 2
            }
            guard let pidText = values["--pid"], let processID = pid_t(pidText), processID > 0,
                  let mode = values["--mode"],
                  ["menu", "settings-region", "settings", "record", "menu-desktop", "settings-desktop"].contains(mode),
                  let outputPath = values["--output"], !outputPath.isEmpty,
                  (mode == "record") == (values["--values"] != nil),
                  [nil, "required"].contains(values["--backdrop"])
            else {
                throw CaptureError(Self.usage)
            }
            self.processID = processID
            self.mode = mode
            outputURL = URL(fileURLWithPath: outputPath)
            statusURL = values["--status"].map { URL(fileURLWithPath: $0) }
            valuesURL = values["--values"].map { URL(fileURLWithPath: $0) }
            requiresBackdrop = values["--backdrop"] == "required"
        }
    }

    private struct CaptureError: LocalizedError {
        let message: String
        init(_ message: String) {
            self.message = message
        }

        var errorDescription: String? {
            message
        }
    }

    @MainActor
    static func main() async {
        var statusURL: URL?
        let arguments = CommandLine.arguments
        if await handleLifecycle(arguments: arguments) {
            return
        }
        if arguments.count == 3, arguments[1] == "--preflight" {
            let status = preflightStatus()
            try? writeStatus(status, to: URL(fileURLWithPath: arguments[2]))
            exit(status == "ok" ? 0 : 1)
        }
        do {
            let options = try Options(arguments: arguments)
            statusURL = options.statusURL
            _ = NSApplication.shared
            // A just-launched app takes a moment to register, so a recording started right
            // after it waits briefly.
            var application = NSRunningApplication(processIdentifier: options.processID)
            for _ in 0 ..< 50 where application == nil && options.mode == "record" {
                try await Task.sleep(for: .milliseconds(100))
                application = NSRunningApplication(processIdentifier: options.processID)
            }
            guard let application,
                  !application.isTerminated,
                  application.bundleIdentifier == "rs.in.olujic.dimmerly"
            else {
                throw CaptureError("PID must identify an already running Dimmerly app.")
            }
            if options.mode == "record", let valuesURL = options.valuesURL {
                let summary = try await PanelRecorder.run(
                    processID: options.processID,
                    outputDirectory: options.outputURL,
                    valuesURL: valuesURL,
                    isPanelWindow: { isMenuPanel($0.frame.size) }
                )
                try writeStatus("ok", to: statusURL)
                FileHandle.standardError.write(Data("Recorded \(summary.capturedFrames) frames\n".utf8))
                return
            }
            if options.mode == "settings-region" || options.mode == "settings-desktop" {
                // Activation can be refused while another app is finishing its own, so retry.
                for _ in 0 ..< 5 where !application.isActive {
                    application.activate(options: [.activateAllWindows])
                    try await Task.sleep(for: .milliseconds(400))
                }
                guard application.isActive else {
                    throw CaptureError("Bring Dimmerly Settings to the front, then retry the capture.")
                }
            }

            let content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true
            )
            let candidates = content.windows.filter {
                guard $0.owningApplication?.processID == options.processID else { return false }
                let size = $0.frame.size
                if options.mode == "menu" || options.mode == "menu-desktop" {
                    return isMenuPanel(size)
                }
                // Settings has a title; the staged app's untitled backdrop window behind it doesn't.
                return size.width >= 400 && size.height >= 300 && $0.title?.isEmpty == false
            }
            guard candidates.count == 1, let window = candidates.first else {
                let candidateDescriptions = candidates.map {
                    "id=\($0.windowID) \(Int($0.frame.width))x\(Int($0.frame.height))"
                }.joined(separator: ", ")
                throw CaptureError(
                    "Found \(candidates.count) matching \(options.mode) windows for PID \(options.processID) " +
                        "(\(candidateDescriptions)). " +
                        "Show only the intended window and retry."
                )
            }

            let image = try await captureStill(of: window, options: options)
            let bitmap = NSBitmapImageRep(cgImage: image)
            guard let data = bitmap.representation(using: .png, properties: [:]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            try data.write(to: options.outputURL, options: .atomic)
            try writeStatus("ok", to: statusURL)
        } catch {
            let nsError = error as NSError
            let message = "\(error.localizedDescription) [\(nsError.domain) \(nsError.code)]"
            try? writeStatus(message, to: statusURL)
            FileHandle.standardError.write(Data((message + "\n").utf8))
            exit(1)
        }
    }

    @MainActor
    private static func handleLifecycle(arguments: [String]) async -> Bool {
        guard arguments.count == 7, ["--pause-apps", "--resume-apps"].contains(arguments[1]),
              arguments[3] == "--staged-app", arguments[5] == "--status"
        else { return false }
        let manifest = URL(fileURLWithPath: arguments[2])
        let stagedApp = URL(fileURLWithPath: arguments[4])
        let status = URL(fileURLWithPath: arguments[6])
        do {
            _ = NSApplication.shared
            if arguments[1] == "--pause-apps" {
                try await RunningApplications.pause(manifest: manifest, stagedApp: stagedApp)
                try writeStatus("ok", to: status)
            } else {
                let warnings = try await RunningApplications.resume(manifest: manifest, stagedApp: stagedApp)
                try writeStatus((["ok"] + warnings).joined(separator: "\n"), to: status)
            }
        } catch {
            try? writeStatus(error.localizedDescription, to: status)
            exit(1)
        }
        return true
    }

    /// Captures `window` the way its mode needs.
    private static func captureStill(of window: SCWindow, options: Options) async throws -> CGImage {
        switch options.mode {
        case "menu-desktop", "settings-desktop":
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { $0.frame.contains(window.frame) }) else {
                throw CaptureLayout.LayoutError()
            }
            // Capture the actual desktop, including the actual system menu bar. The stage's
            // plain backdrop covers ordinary windows; no menu bar or app UI is composited.
            let region = try CaptureLayout.desktopRegion(window: window.frame, display: display.frame)
            guard content.windows.contains(where: {
                $0.owningApplication?.processID == options.processID &&
                    $0.windowID != window.windowID && $0.frame.contains(region)
            }) else {
                throw CaptureError("The desktop backdrop isn't ready yet.")
            }
            // The stage has appeared, but SwiftUI and the preset transition still need to settle.
            try await Task.sleep(for: .milliseconds(500))
            return try await SCScreenshotManager.captureImage(in: region)
        case "menu":
            // See `PanelRegion`: a window-only capture of the popover is too small and its
            // material has nothing behind it.
            let region = try await PanelRegion(window: window, processID: options.processID)
            // The staged app adds its backdrop just after the panel appears; until then the
            // panel would capture as flat grey, so a scripted capture fails and retries.
            guard !options.requiresBackdrop || region.hasBackdrop else {
                throw CaptureError("The panel's backdrop window isn't showing yet.")
            }
            return try await region.captureImage()
        case "settings-region":
            // One-shot region capture preserves the real title bar without a sharing badge.
            // It includes anything covering the window; inspect the resulting PNG before use.
            return try await SCScreenshotManager.captureImage(in: window.frame)
        default:
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let configuration = SCStreamConfiguration()
            let scale = CGFloat(filter.pointPixelScale)
            configuration.width = Int((window.frame.width * scale).rounded())
            configuration.height = Int((window.frame.height * scale).rounded())
            configuration.showsCursor = false
            configuration.ignoreShadowsSingleWindow = true
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        }
    }

    /// The 300-point panel is hosted in a popover, whose window adds a margin that depends on
    /// the macOS release (326 points on macOS 27).
    static func isMenuPanel(_ size: CGSize) -> Bool {
        size.width >= 280 && size.width <= 340 && size.height >= 150 && size.height <= 700
    }

    /// Reports whether a capture can run: `ok`, `unavailable` while the screen is locked or the
    /// displays sleep (WindowServer can't take screenshots then), or `denied` without Screen
    /// Recording. Requesting access adds the helper to the list in System Settings.
    private static func preflightStatus() -> String {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        let isLocked = session?["CGSSessionScreenIsLocked"] as? Bool ?? false
        var activeDisplayCount: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &activeDisplayCount)
        if isLocked || activeDisplayCount == 0 {
            return "unavailable"
        }
        return CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() ? "ok" : "denied"
    }

    private static func writeStatus(_ value: String, to url: URL?) throws {
        if let url {
            try Data(value.utf8).write(to: url, options: .atomic)
        }
    }
}

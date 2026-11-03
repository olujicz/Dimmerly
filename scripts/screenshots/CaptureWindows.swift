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

        init(arguments: [String]) throws {
            var values: [String: String] = [:]
            var index = 1
            while index < arguments.count {
                let key = arguments[index]
                guard ["--pid", "--mode", "--output", "--status"].contains(key),
                      values[key] == nil, index + 1 < arguments.count
                else {
                    throw CaptureError("Expected --pid PID --mode menu|settings-region|settings --output PATH")
                }
                values[key] = arguments[index + 1]
                index += 2
            }
            guard let pidText = values["--pid"], let processID = pid_t(pidText), processID > 0,
                  let mode = values["--mode"], ["menu", "settings-region", "settings"].contains(mode),
                  let outputPath = values["--output"], !outputPath.isEmpty
            else {
                throw CaptureError("Expected --pid PID --mode menu|settings-region|settings --output PATH")
            }
            self.processID = processID
            self.mode = mode
            outputURL = URL(fileURLWithPath: outputPath)
            statusURL = values["--status"].map { URL(fileURLWithPath: $0) }
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
        if arguments.count == 3, arguments[1] == "--preflight" {
            let status = preflightStatus()
            try? writeStatus(status, to: URL(fileURLWithPath: arguments[2]))
            exit(status == "ok" ? 0 : 1)
        }
        do {
            let options = try Options(arguments: arguments)
            statusURL = options.statusURL
            _ = NSApplication.shared
            guard let application = NSRunningApplication(processIdentifier: options.processID),
                  !application.isTerminated,
                  application.bundleIdentifier == "rs.in.olujic.dimmerly"
            else {
                throw CaptureError("PID must identify an already running Dimmerly app.")
            }
            if options.mode == "settings-region" {
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
                if options.mode == "menu" {
                    // The 300-point panel is hosted in a popover, whose window adds a margin
                    // that depends on the macOS release (326 points on macOS 27).
                    return size.width >= 280 && size.width <= 340 && size.height >= 150 && size.height <= 700
                }
                return size.width >= 400 && size.height >= 300
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

            let image: CGImage
            if options.mode == "settings-region" {
                // One-shot region capture preserves the real title bar without a sharing badge.
                // It includes anything covering the window; inspect the resulting PNG before use.
                image = try await SCScreenshotManager.captureImage(in: window.frame)
            } else {
                let filter = SCContentFilter(desktopIndependentWindow: window)
                let configuration = SCStreamConfiguration()
                let scale = CGFloat(filter.pointPixelScale)
                configuration.width = Int((window.frame.width * scale).rounded())
                configuration.height = Int((window.frame.height * scale).rounded())
                configuration.showsCursor = false
                configuration.ignoreShadowsSingleWindow = true
                image = try await SCScreenshotManager.captureImage(
                    contentFilter: filter, configuration: configuration
                )
            }
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

import AppKit
import CoreMedia
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

/// Records Dimmerly's menu panel while a demo storyboard plays, then matches the recording to
/// the demo's frames.
///
/// Frames are the panel's screen region with only Dimmerly's windows, so the panel's material
/// blurs the demo's backdrop window as it would a desktop, cut out with the panel's shape.
///
/// The panel window only exists while the panel is open, so the recorder waits for it, streams
/// it until it closes, and repeats until the app quits. ScreenCaptureKit sends a frame only
/// when the window changes, so a frame stays current until the next one arrives.
///
/// Output, under the given directory:
/// - `raw/NNNNNN.png`: every captured frame, and `raw/frames.json` with each one's Unix time.
/// - `panel/NNNN.png`: one file per demo frame with the panel open, linked to the capture
///   that was on screen for it. Every open frame gets one, so the compositor never guesses.
/// - `shape.png`: the panel's outline, used as the mask for every frame.
/// - `record.json`: a summary, with the capture geometry.
enum PanelRecorder {
    struct Summary: Codable {
        let capturedFrames: Int
        let openFrames: Int
        let segments: Int
        let pixelWidth: Int
        let pixelHeight: Int
        let geometry: String
    }

    private struct ValuesHeader: Decodable {
        let fps: Int
        let frames: Int
        let startedAt: Double
    }

    private struct ValuesFrame: Decodable {
        let frame: Int
        let panelOpen: Bool
    }

    /// Gives up if the panel never appears, or the app never quits.
    private static let timeout: TimeInterval = 180

    @MainActor
    static func run(
        processID: pid_t,
        outputDirectory: URL,
        valuesURL: URL,
        isPanelWindow: @escaping (SCWindow) -> Bool
    ) async throws -> Summary {
        let fileManager = FileManager.default
        let rawDirectory = outputDirectory.appendingPathComponent("raw")
        let panelDirectory = outputDirectory.appendingPathComponent("panel")
        for directory in [rawDirectory, panelDirectory] {
            try? fileManager.removeItem(at: directory)
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        let writer = FrameWriter(directory: rawDirectory)
        let deadline = Date().addingTimeInterval(timeout)
        var segments = 0
        var pixelSize = (width: 0, height: 0)
        var seenWindows: Set<String> = []
        var geometry = ""

        while isRunning(processID) {
            guard Date() < deadline else {
                throw RecordError("The demo did not finish within \(Int(timeout)) seconds.")
            }
            guard let window = try await settledPanelWindow(processID: processID, matching: isPanelWindow) else {
                try await seenWindows.formUnion(windowDescriptions(processID: processID))
                try await Task.sleep(for: .milliseconds(30))
                continue
            }
            segments += 1
            // Taller than the panel, so content that grows while it's open (Auto Warmth's status
            // line) stays in this stream instead of stopping it for a gap with no frames.
            let region = try await PanelRegion(window: window, processID: processID, extraHeight: 60)
            writer.mask = region.mask
            try region.writeShape(to: outputDirectory.appendingPathComponent("shape.png"))
            let filter = region.filter
            let configuration = region.configuration
            geometry = region.geometry
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
            configuration.queueDepth = 8
            pixelSize = (region.width, region.height)

            let stream = SCStream(filter: filter, configuration: configuration, delegate: writer)
            try stream.addStreamOutput(writer, type: .screen, sampleHandlerQueue: writer.sampleQueue)
            writer.didStop = false
            try await stream.startCapture()

            // Stop when the panel closes, the stream fails, or the app quits. A panel that changes
            // size within the region keeps recording with a fresh outline; one that outgrows it
            // starts a new segment at its new size.
            var shapeSize = window.frame.size
            while isRunning(processID), !writer.didStop {
                try await Task.sleep(for: .milliseconds(50))
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let current = content.windows.first(where: { $0.windowID == window.windowID }),
                      region.contains(current.frame)
                else { break }
                if current.frame.size != shapeSize {
                    shapeSize = current.frame.size
                    let mask = try await region.currentMask()
                    writer.sampleQueue.sync { writer.mask = mask }
                }
            }
            if !writer.didStop {
                try? await stream.stopCapture()
            }
        }

        let frames = writer.finish()
        guard !frames.isEmpty else {
            let seen = seenWindows.isEmpty ? "none" : seenWindows.sorted().joined(separator: ", ")
            throw RecordError("The panel never appeared, so nothing was recorded. Windows seen: \(seen).")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(frames).write(to: rawDirectory.appendingPathComponent("frames.json"))

        let openFrames = try align(
            frames,
            valuesURL: valuesURL,
            rawDirectory: rawDirectory,
            panelDirectory: panelDirectory
        )
        let summary = Summary(
            capturedFrames: frames.count,
            openFrames: openFrames,
            segments: segments,
            pixelWidth: pixelSize.width,
            pixelHeight: pixelSize.height,
            geometry: geometry
        )
        try encoder.encode(summary).write(to: outputDirectory.appendingPathComponent("record.json"))
        return summary
    }

    /// The app's on-screen windows as `WIDTHxHEIGHT`, for explaining a missing panel.
    private static func windowDescriptions(processID: pid_t) async throws -> Set<String> {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        return Set(content.windows.filter { $0.owningApplication?.processID == processID }.map {
            "\(Int($0.frame.width))x\(Int($0.frame.height))"
        })
    }

    private static func isRunning(_ processID: pid_t) -> Bool {
        guard let application = NSRunningApplication(processIdentifier: processID) else { return false }
        return !application.isTerminated
    }

    /// A popover's window grows while it appears, and a stream keeps the size it starts with,
    /// so recording waits until the window has kept one size for 150 ms.
    private static func settledPanelWindow(
        processID: pid_t,
        matching isPanelWindow: (SCWindow) -> Bool
    ) async throws -> SCWindow? {
        guard var window = try await panelWindow(processID: processID, matching: isPanelWindow) else { return nil }
        var settledSince = Date()
        while Date().timeIntervalSince(settledSince) < 0.15 {
            try await Task.sleep(for: .milliseconds(50))
            guard let current = try await panelWindow(processID: processID, matching: isPanelWindow) else { return nil }
            if current.frame.size != window.frame.size || current.windowID != window.windowID {
                settledSince = Date()
            }
            window = current
        }
        return window
    }

    private static func panelWindow(
        processID: pid_t,
        matching isPanelWindow: (SCWindow) -> Bool
    ) async throws -> SCWindow? {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let candidates = content.windows.filter {
            $0.owningApplication?.processID == processID && isPanelWindow($0)
        }
        guard candidates.count <= 1 else {
            throw RecordError("Found \(candidates.count) panel-sized windows; show only the demo panel.")
        }
        return candidates.first
    }

    /// Links one capture to every demo frame that shows the panel. A demo frame is applied at
    /// `startedAt + frame / fps` and reaches the screen about a frame later, so it takes the last
    /// capture before the middle of the following frame. Open frames before the first capture
    /// (the window takes a moment to appear) use the first capture.
    private static func align(
        _ frames: [FrameWriter.Frame],
        valuesURL: URL,
        rawDirectory: URL,
        panelDirectory: URL
    ) throws -> Int {
        let text: String
        do {
            text = try String(contentsOf: valuesURL, encoding: .utf8)
        } catch {
            throw RecordError("Can't read the demo values at \(valuesURL.path).")
        }
        let lines = text.split(separator: "\n").map { Data($0.utf8) }
        let decoder = JSONDecoder()
        guard let headerLine = lines.first, let header = try? decoder.decode(ValuesHeader.self, from: headerLine) else {
            throw RecordError("\(valuesURL.lastPathComponent) has no header; did the demo start?")
        }
        let values = try lines.dropFirst().map { try decoder.decode(ValuesFrame.self, from: $0) }
        guard values.count == header.frames else {
            throw RecordError("The demo wrote \(values.count) of \(header.frames) frames; it did not finish.")
        }

        let fps = Double(header.fps)
        var openFrames = 0
        for value in values where value.panelOpen {
            let shownBy = header.startedAt + (Double(value.frame) + 1.5) / fps
            let capture = frames.last(where: { $0.time <= shownBy }) ?? frames[0]
            let destination = panelDirectory.appendingPathComponent(String(format: "%04d.png", value.frame))
            try FileManager.default.linkItem(at: rawDirectory.appendingPathComponent(capture.file), to: destination)
            openFrames += 1
        }
        return openFrames
    }
}

/// How to capture the menu panel so it looks as it does on screen.
///
/// The panel's material blurs whatever is behind it, which a window-only capture leaves out
/// (light mode comes out flat grey), and a window-only capture of a popover is also scaled
/// about 7% smaller than its frame. So the capture is the panel's screen region with only
/// Dimmerly's windows, where the staged app puts a backdrop window behind the panel
/// (`DIMMERLY_SCREENSHOT_BACKDROP`). The panel's shape, which never changes, comes from a
/// still of the same region without the backdrop, on a clear background and without shadows;
/// `apply(to:)` keeps only that shape.
struct PanelRegion {
    let filter: SCContentFilter
    let configuration: SCStreamConfiguration
    let width: Int
    let height: Int
    let mask: [UInt8]
    let shape: CGImage
    let geometry: String
    /// Whether a backdrop window was behind the panel; without one the material is flat grey.
    let hasBackdrop: Bool
    /// The recorded screen area, in global points.
    let frame: CGRect
    private let shapeFilter: SCContentFilter
    private let shapeConfiguration: SCStreamConfiguration

    /// `extraHeight` points below the panel are recorded too, so the panel can grow without a
    /// new stream; they stay transparent until it does.
    init(window: SCWindow, processID: pid_t, extraHeight: CGFloat = 0) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let application = window.owningApplication,
              let display = content.displays.first(where: { $0.frame.contains(window.frame.origin) })
        else {
            throw RecordError("Can't find the display showing the panel.")
        }
        // macOS keeps the backdrop below the menu bar, so it can miss the popover's top
        // point; any other Dimmerly window covering nearly all of the panel counts.
        let panelArea = window.frame.width * window.frame.height
        let backdrops = content.windows.filter {
            let overlap = $0.frame.intersection(window.frame)
            return $0.owningApplication?.processID == processID && $0.windowID != window.windowID
                && !overlap.isNull && overlap.width * overlap.height >= 0.9 * panelArea
        }
        hasBackdrop = !backdrops.isEmpty
        let scale = CGFloat(SCContentFilter(desktopIndependentWindow: window).pointPixelScale)
        frame = CGRect(x: window.frame.minX, y: window.frame.minY, width: window.frame.width,
                       height: window.frame.height + extraHeight)
        width = Int((frame.width * scale).rounded())
        height = Int((frame.height * scale).rounded())
        let sourceRect = frame.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)

        let shapeConfiguration = SCStreamConfiguration()
        shapeConfiguration.sourceRect = sourceRect
        shapeConfiguration.width = width
        shapeConfiguration.height = height
        shapeConfiguration.showsCursor = false
        shapeConfiguration.backgroundColor = .clear
        shapeConfiguration.ignoreShadowsDisplay = true
        shapeFilter = SCContentFilter(display: display, including: [application], exceptingWindows: backdrops)
        self.shapeConfiguration = shapeConfiguration
        shape = try await SCScreenshotManager.captureImage(
            contentFilter: shapeFilter,
            configuration: shapeConfiguration
        )
        mask = try Self.alphaMask(of: shape, width: width, height: height)

        filter = SCContentFilter(display: display, including: [application], exceptingWindows: [])
        configuration = SCStreamConfiguration()
        configuration.sourceRect = sourceRect
        configuration.width = width
        configuration.height = height
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.colorSpaceName = CGColorSpace.sRGB
        configuration.showsCursor = false
        geometry = "window \(window.frame) display \(display.frame) scale \(scale) backdrops \(backdrops.count)"
    }

    /// Whether a panel at `windowFrame` still fits in the recorded area.
    func contains(_ windowFrame: CGRect) -> Bool {
        frame.insetBy(dx: -0.5, dy: -0.5).contains(windowFrame)
    }

    /// The panel's outline now, after it changed size inside the recorded area.
    func currentMask() async throws -> [UInt8] {
        let shape = try await SCScreenshotManager.captureImage(
            contentFilter: shapeFilter,
            configuration: shapeConfiguration
        )
        return try Self.alphaMask(of: shape, width: width, height: height)
    }

    /// One still of the panel, cut out with its shape.
    func captureImage() async throws -> CGImage {
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        let bytesPerRow = width * 4
        var bytes = Data(count: bytesPerRow * height)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: bytesPerRow, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: Self.bitmapInfo.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn, let masked = Self.image(
            from: &bytes,
            width: width,
            height: height,
            bytesPerRow: bytesPerRow,
            mask: mask
        )
        else { throw RecordError("Can't cut the panel out of its capture.") }
        return masked
    }

    func writeShape(to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw RecordError("Can't write \(url.path).") }
        CGImageDestinationAddImage(destination, shape, nil)
        guard CGImageDestinationFinalize(destination) else { throw RecordError("Can't write \(url.path).") }
    }

    /// BGRA, premultiplied, as ScreenCaptureKit delivers frames.
    static let bitmapInfo = CGBitmapInfo(
        rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
    )

    /// Multiplies premultiplied BGRA pixels by the shape, so every channel scales together, and
    /// wraps them in an image.
    static func image(
        from bytes: inout Data, width: Int, height: Int, bytesPerRow: Int, mask: [UInt8]
    ) -> CGImage? {
        if mask.count == width * height {
            bytes.withUnsafeMutableBytes { buffer in
                let pixels = buffer.bindMemory(to: UInt8.self)
                for row in 0 ..< height {
                    for column in 0 ..< width {
                        let alpha = UInt16(mask[row * width + column])
                        guard alpha != 255 else { continue }
                        let offset = row * bytesPerRow + column * 4
                        for channel in 0 ..< 4 {
                            pixels[offset + channel] = UInt8(UInt16(pixels[offset + channel]) * alpha / 255)
                        }
                    }
                }
            }
        }
        guard let provider = CGDataProvider(data: bytes as CFData),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
        else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
            space: colorSpace, bitmapInfo: bitmapInfo, provider: provider, decode: nil,
            shouldInterpolate: false, intent: .defaultIntent
        )
    }

    /// An image's alpha, one byte per pixel, row by row.
    private static func alphaMask(of image: CGImage, width: Int, height: Int) throws -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { throw RecordError("Can't read the panel's shape.") }
        return stride(from: 3, to: pixels.count, by: 4).map { pixels[$0] }
    }
}

struct RecordError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? {
        message
    }
}

/// Receives stream frames and writes each complete one as a PNG with its Unix time.
private final class FrameWriter: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    struct Frame: Codable {
        let file: String
        let time: Double
    }

    let sampleQueue = DispatchQueue(label: "rs.in.olujic.dimmerly.record.samples")
    private let writeQueue = DispatchQueue(label: "rs.in.olujic.dimmerly.record.png")
    private let directory: URL
    private let lock = NSLock()
    private var frames: [Frame] = []
    private var sequence = 0
    private var stopped = false
    /// Set before each stream starts; frames are multiplied by it to keep only the panel.
    var mask: [UInt8] = []

    init(directory: URL) {
        self.directory = directory
    }

    var didStop: Bool {
        get { lock.withLock { stopped } }
        set { lock.withLock { stopped = newValue } }
    }

    /// Waits for pending PNG writes and returns the frames in capture order.
    func finish() -> [Frame] {
        sampleQueue.sync {}
        writeQueue.sync {}
        return lock.withLock { frames.sorted { $0.time < $1.time } }
    }

    func stream(_: SCStream, didStopWithError _: any Error) {
        didStop = true
    }

    func stream(_: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid, isComplete(sampleBuffer),
              let pixelBuffer = sampleBuffer.imageBuffer,
              let image = copyImage(pixelBuffer, mask: mask)
        else { return }
        // Presentation times use the host clock; convert to Unix time to match the demo values.
        let age = CMTimeSubtract(CMClockGetTime(CMClockGetHostTimeClock()), sampleBuffer.presentationTimeStamp)
        let time = Date().timeIntervalSince1970 - age.seconds
        sequence += 1
        let file = String(format: "%06d.png", sequence)
        let url = directory.appendingPathComponent(file)
        writeQueue.async { [self] in
            guard let destination = CGImageDestinationCreateWithURL(
                url as CFURL,
                UTType.png.identifier as CFString,
                1,
                nil
            )
            else { return }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { return }
            lock.withLock { frames.append(Frame(file: file, time: time)) }
        }
    }

    private func isComplete(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
            as? [[SCStreamFrameInfo: Any]],
            let rawStatus = attachments.first?[.status] as? Int
        else { return false }
        return SCFrameStatus(rawValue: rawStatus) == .complete
    }

    /// Copies the pixels out so the stream can reuse its buffer while the PNG is written, and
    /// cuts the panel out with its shape.
    private func copyImage(_ pixelBuffer: CVPixelBuffer, mask: [UInt8]) -> CGImage? {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        var bytes = Data(bytes: base, count: bytesPerRow * height)
        return PanelRegion.image(
            from: &bytes,
            width: CVPixelBufferGetWidth(pixelBuffer),
            height: height,
            bytesPerRow: bytesPerRow,
            mask: mask
        )
    }
}

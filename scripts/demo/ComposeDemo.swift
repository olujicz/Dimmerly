// Composes the demo loop: illustrated displays dimmed and warmed with the app's own
// GammaMath, the real captured menu panel, a scripted cursor and captions.
//
// Build together with the app's gamma math so the simulated screens use the exact
// per-channel transfer Dimmerly sends to a real display:
//
//   xcrun swiftc -O -parse-as-library scripts/demo/ComposeDemo.swift \
//       Dimmerly/Services/GammaMath.swift -o .build/demo-tools/ComposeDemo \
//       -framework AppKit -framework CoreGraphics -framework AVFoundation -framework CoreText
//
// One self-contained script, so it is compiled without a project around it.
// swiftlint:disable file_length

import AppKit
import AVFoundation
import CoreText
import ImageIO
import UniformTypeIdentifiers

enum DemoError: Error, CustomStringConvertible {
    case invalid(String)

    var description: String {
        switch self {
        case let .invalid(message): message
        }
    }
}

let usage = """
Usage: ComposeDemo --appearance light|dark --values FILE --panel-dir DIR --storyboard FILE
                   (--output FILE.mov | --frame N --png FILE [--still] [--clock TEXT] | --check)
       ComposeDemo --appearance light|dark --window FILE --window-mask FILE --caption TEXT
                   --png FILE [--clock TEXT]

--appearance  light or dark: the backdrop, menu bar, captions and shadows to match
           the website's colour scheme. Use panel captures from the same appearance.

--output   writes the master movie: ProRes 422 HQ, 2560x1600, at the values' fps.
--frame/--png  renders one frame to a PNG for review.
--still    with --frame: the App Store still layout. The caption is at the top and larger,
           the menu bar and panel are zoomed, the devices are smaller, there is no cursor,
           and the frame's caption shows in full.
--clock    the menu-bar clock text (default "Tue 9:41").
--window   an App Store still of a window instead of the scene: a region capture of the
           window, the same-sized window capture whose alpha outlines it (--window-mask),
           and its caption.
--check    renders frame 0, the last frame and three sample frames, and fails unless
           the loop is seamless (<1% mean difference) and the simulated screens match
           GammaMath applied to the wallpaper within 1 per channel.
"""

// MARK: - Inputs

struct DisplayValues: Decodable, Equatable {
    let name: String
    let builtIn: Bool
    let brightness: Double
    let warmth: Double
    let contrast: Double

    enum CodingKeys: String, CodingKey { case name, builtIn, brightness, warmth, contrast }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        builtIn = try c.decodeIfPresent(Bool.self, forKey: .builtIn) ?? false
        brightness = try c.decode(Double.self, forKey: .brightness)
        warmth = try c.decodeIfPresent(Double.self, forKey: .warmth) ?? 0
        contrast = try c.decodeIfPresent(Double.self, forKey: .contrast) ?? 0.5
    }
}

struct FrameValues: Decodable {
    let frame: Int
    let panelOpen: Bool
    let caption: String
    let displays: [DisplayValues]
}

struct ValuesHeader: Decodable {
    let fps: Int
    let frames: Int
}

/// A cursor keyframe. A point key has `x`/`y` in panel points: origin at the top-left of
/// the reference capture (capture pixels / 2); `y` may be negative. A drag key names a
/// `slider` from `cursorSliders` and keeps the hotspot on that slider's thumb from `time`
/// to `until`, with the thumb position derived from each frame's logged value.
struct CursorKey: Decodable {
    let time: Double
    let x: Double?
    let y: Double?
    let click: Bool?
    let until: Double?
    let slider: String?
}

/// A slider track measured from the capture: the thumb centre sits at `minX` for value
/// `min` and at `maxX` for value `max`, on row `y` (panel points).
struct CursorSlider: Decodable {
    let display: String
    let value: String
    let y: Double
    let minX: Double
    let maxX: Double
    let min: Double
    let max: Double
}

struct CursorTrack: Decodable {
    let cursor: [CursorKey]?
    let cursorSliders: [String: CursorSlider]?
}

func loadValues(_ path: String) throws -> (fps: Int, frames: [FrameValues]) {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
        throw DemoError.invalid("Cannot read values: \(path)")
    }
    let lines = text.split(whereSeparator: \.isNewline).filter { !$0.allSatisfy(\.isWhitespace) }
    guard let first = lines.first else { throw DemoError.invalid("Values file is empty: \(path)") }
    let decoder = JSONDecoder()
    let header: ValuesHeader
    do { header = try decoder.decode(ValuesHeader.self, from: Data(first.utf8)) } catch {
        throw DemoError.invalid("Bad values header: \(error)")
    }
    guard (1 ... 120).contains(header.fps), header.frames > 0 else {
        throw DemoError.invalid("Values header needs fps 1–120 and frames > 0")
    }
    var frames: [FrameValues] = []
    for (number, line) in lines.dropFirst().enumerated() {
        do { try frames.append(decoder.decode(FrameValues.self, from: Data(line.utf8))) } catch {
            throw DemoError.invalid("Bad values line \(number + 2): \(error)")
        }
    }
    guard frames.count == header.frames else {
        throw DemoError.invalid("Header says \(header.frames) frames, file has \(frames.count)")
    }
    for (index, frame) in frames.enumerated() where frame.frame != index {
        throw DemoError.invalid("Frame lines must be 0, 1, 2…; line \(index + 2) is frame \(frame.frame)")
    }
    return (header.fps, frames)
}

func loadCursor(_ path: String) throws -> CursorTrack {
    guard let data = FileManager.default.contents(atPath: path) else {
        throw DemoError.invalid("Cannot read storyboard: \(path)")
    }
    let track: CursorTrack
    do { track = try JSONDecoder().decode(CursorTrack.self, from: data) } catch {
        throw DemoError.invalid("Bad storyboard cursor track: \(error)")
    }
    let keys = track.cursor ?? []
    let sliders = track.cursorSliders ?? [:]
    for (name, slider) in sliders {
        guard ["brightness", "warmth", "contrast"].contains(slider.value), slider.max != slider.min else {
            throw DemoError.invalid("Cursor slider \(name) needs value brightness, warmth or contrast, and min != max")
        }
    }
    for key in keys {
        if let name = key.slider {
            guard sliders[name] != nil, let until = key.until, until >= key.time, key.x == nil, key.y == nil else {
                throw DemoError.invalid("Cursor drag at \(key.time) s needs a known slider, until >= time, and no x/y")
            }
        } else {
            guard key.x != nil, key.y != nil, key.until == nil else {
                throw DemoError.invalid("Cursor key at \(key.time) s needs x and y (or a slider and until)")
            }
        }
    }
    for (a, b) in zip(keys, keys.dropFirst()) where b.time < (a.until ?? a.time) {
        throw DemoError.invalid("Cursor keys must not overlap or go back in time (\(a.time) then \(b.time))")
    }
    return track
}

// MARK: - Images

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

struct Bitmap {
    let width: Int
    let height: Int
    var pixels: [UInt8] // RGBA, opaque, row 0 at the top
}

/// An sRGB RGBA context whose CTM is flipped so y grows downward and row 0 of the
/// backing memory is the top of the picture.
func makeContext(
    width: Int,
    height: Int,
    data: UnsafeMutableRawPointer? = nil,
    bytesPerRow: Int? = nil,
    bitmapInfo: UInt32 = CGImageAlphaInfo.premultipliedLast.rawValue
) throws -> CGContext {
    guard let context = CGContext(
        data: data, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: bytesPerRow ?? width * 4, space: sRGB, bitmapInfo: bitmapInfo
    ) else { throw DemoError.invalid("Cannot allocate a \(width)x\(height) canvas") }
    context.translateBy(x: 0, y: CGFloat(height))
    context.scaleBy(x: 1, y: -1)
    return context
}

/// Draws an image upright in a flipped context.
func drawImage(_ image: CGImage, in rect: CGRect, context: CGContext) {
    context.saveGState()
    context.translateBy(x: rect.minX, y: rect.maxY)
    context.scaleBy(x: 1, y: -1)
    context.draw(image, in: CGRect(origin: .zero, size: rect.size))
    context.restoreGState()
}

func loadImage(_ path: String) throws -> CGImage {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { throw DemoError.invalid("Cannot read image: \(path)") }
    return image
}

func writePNG(_ image: CGImage, to path: String) throws {
    let url = URL(fileURLWithPath: path)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { throw DemoError.invalid("Cannot create PNG: \(path)") }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw DemoError.invalid("Cannot finish PNG: \(path)") }
}

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func gradient(_ stops: [(CGFloat, CGColor)]) -> CGGradient {
    CGGradient(colorsSpace: sRGB, colors: stops.map(\.1) as CFArray, locations: stops.map(\.0))!
}

func smoothstep(_ u: Double) -> Double {
    let t = min(max(u, 0), 1)
    return t * t * (3 - 2 * t)
}

// MARK: - Wallpaper (generated, so there is nothing to license)

struct SplitMix64 {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func unit() -> Double {
        Double(next() >> 11) / Double(UInt64(1) << 53)
    }

    mutating func signed() -> Double {
        unit() * 2 - 1
    }
}

/// Adds static, per-pixel triangular noise of about ±`amplitude` levels to RGB, so smooth
/// gradients survive 8-bit and H.264 without banding. Seeded by pixel, never by frame.
func addGrain(_ bytes: UnsafeMutablePointer<UInt8>, width: Int, height: Int, amplitude: Double, seed: UInt64) {
    for index in 0 ..< width * height {
        var rng = SplitMix64(state: seed ^ (UInt64(index) &* 0xD129_0F4B_A1C3_5E97))
        let offset = Int(((rng.unit() - rng.unit()) * amplitude).rounded())
        guard offset != 0 else { continue }
        let o = index * 4
        for c in 0 ..< 3 {
            bytes[o + c] = UInt8(clamping: Int(bytes[o + c]) + offset)
        }
    }
}

/// A ridgeline by midpoint displacement: `count + 1` heights in -1...1.
func ridgeline(seed: UInt64, count: Int, roughness: Double) -> [Double] {
    var rng = SplitMix64(state: seed)
    var heights = [Double](repeating: 0, count: count + 1)
    heights[0] = rng.signed() * 0.6
    heights[count] = rng.signed() * 0.6
    var step = count, scale = 1.0
    while step > 1 {
        let half = step / 2
        for i in stride(from: half, to: count, by: step) {
            heights[i] = (heights[i - half] + heights[i + half]) / 2 + rng.signed() * scale
        }
        scale *= roughness
        step = half
    }
    let peak = max(heights.map(abs).max() ?? 1, 1e-9)
    return heights.map { $0 / peak }
}

func mix(_ a: UInt32, _ b: UInt32, _ t: CGFloat, alpha: CGFloat = 1) -> CGColor {
    func channel(_ v: UInt32, _ shift: UInt32) -> CGFloat {
        CGFloat((v >> shift) & 0xFF) / 255
    }
    func lerp(_ shift: UInt32) -> CGFloat {
        channel(a, shift) + (channel(b, shift) - channel(a, shift)) * t
    }
    return CGColor(srgbRed: lerp(16), green: lerp(8), blue: lerp(0), alpha: alpha)
}

/// A calm mountain landscape: a deep-blue sky easing to a warm haze, a soft sun glow low
/// on the horizon and five ridgelines that grow darker and more saturated as they come
/// closer. Plenty of blue and near-white, so dimming and warming read clearly.
func makeWallpaper(width: Int, height: Int) throws -> Bitmap {
    let context = try makeContext(width: width, height: height,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    let design = CGSize(width: 1600, height: 1000)
    let scale = max(CGFloat(width) / design.width, CGFloat(height) / design.height)
    context.translateBy(x: (CGFloat(width) - design.width * scale) / 2,
                        y: (CGFloat(height) - design.height * scale) / 2)
    context.scaleBy(x: scale, y: scale)
    let haze: UInt32 = 0xE9E6E4

    context.drawLinearGradient(
        gradient([
            (0, color(0x1E4794)),
            (0.3, color(0x3D6FBE)),
            (0.58, color(0x8FB2E0)),
            (0.8, color(0xD5DFEC)),
            (1, color(0xF3EDE6)),
        ]),
        start: .zero, end: CGPoint(x: 0, y: 600), options: [.drawsAfterEndLocation]
    )
    let sun = CGPoint(x: 1060, y: 555)
    context.drawRadialGradient(
        gradient([
            (0, color(0xFFFDF8, 1)),
            (0.05, color(0xFFF8EC, 0.92)),
            (0.16, color(0xFFF1DE, 0.55)),
            (0.42, color(0xF7EEE4, 0.2)),
            (1, color(0xF7EEE4, 0)),
        ]),
        startCenter: sun, startRadius: 0, endCenter: sun, endRadius: 700, options: []
    )

    // A table of ridge layers reads best as named tuples, one row per layer.
    // swiftlint:disable:next large_tuple
    let layers: [(seed: UInt64, base: CGFloat, amplitude: CGFloat, roughness: Double, tone: UInt32, mist: CGFloat)] = [
        (0x5EED_0011, 545, 120, 0.56, 0xA3B7D8, 0.35),
        (0x5EED_0023, 615, 92, 0.54, 0x7896C6, 0.4),
        (0x5EED_0037, 695, 78, 0.52, 0x4C73AA, 0.42),
        (0x5EED_0051, 790, 64, 0.5, 0x2A527F, 0.38),
        (0x5EED_0067, 895, 52, 0.47, 0x132E4E, 0.26),
    ]
    for (index, layer) in layers.enumerated() {
        let count = 512
        let heights = ridgeline(seed: layer.seed, count: count, roughness: layer.roughness)
        let path = CGMutablePath()
        let left: CGFloat = -20, span = design.width + 40
        path.move(to: CGPoint(x: left, y: design.height + 10))
        for i in 0 ... count {
            path.addLine(to: CGPoint(x: left + span * CGFloat(i) / CGFloat(count),
                                     y: layer.base - layer.amplitude * CGFloat(heights[i])))
        }
        path.addLine(to: CGPoint(x: left + span, y: design.height + 10))
        path.closeSubpath()
        context.saveGState()
        context.addPath(path)
        context.clip()
        // Mist settles in the valleys: each ridge fades towards the haze below its crest.
        context.drawLinearGradient(
            gradient([(0, color(layer.tone)), (1, mix(layer.tone, haze, layer.mist))]),
            start: CGPoint(x: 0, y: layer.base - layer.amplitude), end: CGPoint(
                x: 0,
                y: layer.base + layer.amplitude + 110
            ),
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
        )
        context.restoreGState()
        if index == 1 {
            context.drawLinearGradient(
                gradient([(0, color(0xFFFFFF, 0)), (0.5, color(0xF4F1EE, 0.28)), (1, color(0xFFFFFF, 0))]),
                start: CGPoint(x: 0, y: 550), end: CGPoint(x: 0, y: 690), options: []
            )
        }
    }

    guard let data = context.data else { throw DemoError.invalid("Wallpaper canvas has no memory") }
    let bytes = data.assumingMemoryBound(to: UInt8.self)
    addGrain(bytes, width: width, height: height, amplitude: 1.2, seed: 0xA11_CE5)
    return Bitmap(width: width, height: height,
                  pixels: Array(UnsafeBufferPointer(start: bytes, count: width * height * 4)))
}

// MARK: - GammaMath transfer

/// The three 8-bit channel lookups for a display, from the same calls the app makes
/// before `CGSetDisplayTransferByTable`.
func transferLUT(_ display: DisplayValues) -> [[UInt8]] {
    let multipliers = GammaMath.channelMultipliers(for: display.warmth)
    return [multipliers.r, multipliers.g, multipliers.b].map { multiplier in
        GammaMath.buildTable(brightness: display.brightness, channelMultiplier: multiplier, contrast: display.contrast)
            .map { UInt8((min(max(Double($0), 0), 1) * 255).rounded()) }
    }
}

func applyLUT(_ lut: [[UInt8]], to wallpaper: Bitmap) -> CGImage {
    let count = wallpaper.width * wallpaper.height
    var out = [UInt8](repeating: 255, count: count * 4)
    lut[0].withUnsafeBufferPointer { r in
        lut[1].withUnsafeBufferPointer { g in
            lut[2].withUnsafeBufferPointer { b in
                wallpaper.pixels.withUnsafeBufferPointer { src in
                    out.withUnsafeMutableBufferPointer { dst in
                        for i in 0 ..< count {
                            let o = i * 4
                            dst[o] = r[Int(src[o])]
                            dst[o + 1] = g[Int(src[o + 1])]
                            dst[o + 2] = b[Int(src[o + 2])]
                        }
                    }
                }
            }
        }
    }
    let provider = CGDataProvider(data: Data(out) as CFData)!
    return CGImage(
        width: wallpaper.width, height: wallpaper.height, bitsPerComponent: 8, bitsPerPixel: 32,
        bytesPerRow: wallpaper.width * 4, space: sRGB,
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
    )!
}

// MARK: - Layout (canvas pixels, y down; the canvas is a 2x rendering)

enum Layout {
    static let width = 2560
    static let height = 1600
    /// Left margin shared by the monitor and the captions.
    static let margin: CGFloat = 170
    /// A 24 pt menu bar across the top edge.
    static let menuBar = CGRect(x: 0, y: 0, width: 2560, height: 48)
    /// Far enough from the right edge that the 300 pt panel keeps a margin.
    static let iconCenter = CGPoint(x: 2210, y: 24)
    static let wifiX: CGFloat = 2294
    static let controlCenterX: CGFloat = 2374
    static let clockRight: CGFloat = 2530
    /// The popover's arrow tip, just under the Dimmerly icon as macOS places it.
    static let panelTip = CGPoint(x: iconCenter.x, y: menuBar.maxY + 6)

    static let monitorEdge: CGFloat = 3
    static let monitorBezel: CGFloat = 20
    static let monitorScreen = CGRect(x: margin + monitorEdge + monitorBezel, y: 300, width: 1120, height: 630) // 16:9
    static let laptopEdge: CGFloat = 3
    static let laptopBezel: CGFloat = 16
    static let laptopScreen = CGRect(x: 1150, y: 880, width: 640, height: 400) // 16:10

    static let captionTop: CGFloat = 1392

    /// Screen pixels the check samples: well inside the glass, clear of the notch.
    static func interior(_ screen: CGRect) -> CGRect {
        screen.insetBy(dx: screen.width * 0.08, dy: screen.height * 0.12)
    }

    /// The MacBook and its soft shadow cover the monitor's lower-right corner.
    static var laptopOccluder: CGRect {
        laptopScreen.insetBy(dx: -(laptopBezel + laptopEdge) - 130, dy: -(laptopBezel + laptopEdge) - 130)
    }
}

// MARK: - Drawing helpers

func symbol(_ name: String, pointSize: CGFloat, weight: NSFont.Weight = .regular, tint: NSColor = .white) -> NSImage? {
    let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
        .applying(NSImage.SymbolConfiguration(paletteColors: [tint]))
    return NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
}

func withAppKit(_ context: CGContext, _ body: () -> Void) {
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
    body()
    NSGraphicsContext.restoreGraphicsState()
}

func drawSymbol(_ image: NSImage, centeredAt center: CGPoint, alpha: CGFloat, context: CGContext) {
    let size = image.size
    let rect = CGRect(x: (center.x - size.width / 2).rounded(), y: (center.y - size.height / 2).rounded(),
                      width: size.width, height: size.height)
    withAppKit(context) {
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: alpha, respectFlipped: true, hints: nil)
    }
}

func roundedRect(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func roundedRect(_ r: CGRect, top: CGFloat, bottom: CGFloat) -> CGPath {
    let path = CGMutablePath()
    path.move(to: CGPoint(x: r.minX + top, y: r.minY))
    path.addArc(tangent1End: CGPoint(x: r.maxX, y: r.minY), tangent2End: CGPoint(x: r.maxX, y: r.maxY), radius: top)
    path.addArc(tangent1End: CGPoint(x: r.maxX, y: r.maxY), tangent2End: CGPoint(x: r.minX, y: r.maxY), radius: bottom)
    path.addArc(tangent1End: CGPoint(x: r.minX, y: r.maxY), tangent2End: CGPoint(x: r.minX, y: r.minY), radius: bottom)
    path.addArc(tangent1End: CGPoint(x: r.minX, y: r.minY), tangent2End: CGPoint(x: r.maxX, y: r.minY), radius: top)
    path.closeSubpath()
    return path
}

func fill(_ path: CGPath, vertical stops: [(CGFloat, CGColor)], context: CGContext) {
    let box = path.boundingBoxOfPath
    context.saveGState()
    context.addPath(path)
    context.clip()
    context.drawLinearGradient(
        gradient(stops),
        start: CGPoint(x: 0, y: box.minY),
        end: CGPoint(x: 0, y: box.maxY),
        options: []
    )
    context.restoreGState()
}

func fill(_ path: CGPath, horizontal stops: [(CGFloat, CGColor)], context: CGContext) {
    let box = path.boundingBoxOfPath
    context.saveGState()
    context.addPath(path)
    context.clip()
    context.drawLinearGradient(
        gradient(stops),
        start: CGPoint(x: box.minX, y: 0),
        end: CGPoint(x: box.maxX, y: 0),
        options: []
    )
    context.restoreGState()
}

/// Paints only the soft shadow of `path`, offset down and right (one light, top left).
func softShadow( // swiftlint:disable:this function_parameter_count
    _ path: CGPath,
    dx: CGFloat,
    dy: CGFloat,
    blur: CGFloat,
    alpha: CGFloat,
    theme: Theme,
    context: CGContext
) {
    let away: CGFloat = 10000
    // Shadow offsets and blur are in device pixels and ignore the transform, so scale them by
    // it to match a scaled scene (the stills' smaller devices).
    let scale = hypot(context.ctm.a, context.ctm.b)
    context.saveGState()
    // The shadow offset is in device space (y up); the shape itself is drawn off-canvas.
    context.setShadow(
        offset: CGSize(width: dx * scale, height: -(away + dy) * scale),
        blur: blur * scale,
        color: color(theme.shadowColor, min(alpha * theme.shadowStrength, 1))
    )
    context.translateBy(x: 0, y: -away)
    context.addPath(path)
    context.setFillColor(color(0x000000))
    context.fillPath()
    context.restoreGState()
}

func ellipse(_ rect: CGRect) -> CGPath {
    CGPath(ellipseIn: rect, transform: nil)
}

/// Anodised aluminium, lit from above.
let aluminium: [(CGFloat, CGColor)] = [(0, color(0xF0F1F3)), (0.45, color(0xD6D9DD)), (1, color(0xB4B8BE))]

/// A faint highlight along the top edge of a body.
func topHighlight(_ rect: CGRect, inset: CGFloat, context: CGContext) {
    context.saveGState()
    context.setStrokeColor(color(0xFFFFFF, 0.75))
    context.setLineWidth(1.5)
    context.move(to: CGPoint(x: rect.minX + inset, y: rect.minY + 1))
    context.addLine(to: CGPoint(x: rect.maxX - inset, y: rect.minY + 1))
    context.strokePath()
    context.restoreGState()
}

// MARK: - Appearance

enum Appearance: String {
    case light, dark
}

/// The video's layout, or the App Store still layout: a larger caption at the top, the menu bar
/// and panel zoomed about the canvas's top-right corner, and smaller devices.
struct Style {
    var isStill = false
    var clock = "Tue 9:41"
    var uiScale: CGFloat = 1
    var deviceScale: CGFloat = 1
    var deviceOffset = CGPoint.zero
    var captionSize: CGFloat = 62
    var captionTop: CGFloat = Layout.captionTop

    static func video(clock: String?) -> Style {
        Style(clock: clock ?? "Tue 9:41")
    }

    static func still(clock: String?) -> Style {
        Style(isStill: true, clock: clock ?? "Tue 9:41", uiScale: 1.25, deviceScale: 0.9,
              deviceOffset: CGPoint(x: -24, y: 171), captionSize: 104, captionTop: 128)
    }

    /// Scales the devices about the left margin at the top of the canvas, then moves them.
    var deviceTransform: CGAffineTransform {
        CGAffineTransform(translationX: Layout.margin + deviceOffset.x, y: deviceOffset.y)
            .scaledBy(x: deviceScale, y: deviceScale)
            .translatedBy(x: -Layout.margin, y: 0)
    }

    /// Zooms the menu bar, the icon and the panel about the canvas's top-right corner.
    var uiTransform: CGAffineTransform {
        CGAffineTransform(translationX: CGFloat(Layout.width), y: 0)
            .scaledBy(x: uiScale, y: uiScale)
            .translatedBy(x: -CGFloat(Layout.width), y: 0)
    }
}

/// Everything that differs between the light and dark renders. The devices, screens and
/// wallpaper are identical in both.
struct Theme {
    let appearance: Appearance
    let backdrop: [(CGFloat, CGColor)] // diagonal, top-left to bottom-right
    let vignette: CGColor
    let shadowColor: UInt32
    let shadowStrength: CGFloat
    let deviceOutline: CGColor? // a hairline so aluminium edges read on a light page
    let rimShade: CGColor? // tones the aluminium rims down so they don't read as a white stroke
    let menuBar: [(CGFloat, CGColor)]
    let menuBarHairline: CGColor
    let menuItem: NSColor
    let iconPill: CGColor
    let caption: NSColor
    let captionShadow: CGFloat
    let clickRing: (UInt32, CGFloat)
    let panelShadow: CGFloat
    let panelEdge: CGFloat

    static func make(_ appearance: Appearance) -> Theme {
        switch appearance {
        case .dark:
            // Deep, slightly cool charcoal-blue that settles into a #151613 page at the edges.
            Theme(appearance: .dark,
                  backdrop: [(0, color(0x2C3643)), (0.5, color(0x212933)), (1, color(0x171C23))],
                  vignette: color(0x0C0E11, 0.34), shadowColor: 0x000000, shadowStrength: 1.35, deviceOutline: nil,
                  rimShade: color(0x10141A, 0.32),
                  menuBar: [(0, color(0x10141A, 0.5)), (1, color(0x10141A, 0.38))],
                  menuBarHairline: color(0xFFFFFF, 0.08), menuItem: .white, iconPill: color(0xFFFFFF, 0.2),
                  caption: NSColor.white.withAlphaComponent(0.96), captionShadow: 0.22,
                  clickRing: (0xFFFFFF, 0.6), panelShadow: 0.45, panelEdge: 0.35)
        case .light:
            // Warm off-white to very light grey, close to the #f3f1ec page.
            Theme(appearance: .light,
                  backdrop: [(0, color(0xFAF9F6)), (0.55, color(0xF3F1EC)), (1, color(0xEAE8E3))],
                  vignette: color(0x4A4436, 0.06), shadowColor: 0x3B3528, shadowStrength: 0.55,
                  deviceOutline: color(0x000000, 0.16), rimShade: nil,
                  menuBar: [(0, color(0xFFFFFF, 0.62)), (1, color(0xFFFFFF, 0.5))],
                  menuBarHairline: color(0x000000, 0.1), menuItem: NSColor.black.withAlphaComponent(0.85),
                  iconPill: color(0x000000, 0.1),
                  caption: NSColor(srgbRed: 0x1D / 255, green: 0x1D / 255, blue: 0x1F / 255, alpha: 1),
                  captionShadow: 0,
                  clickRing: (0x000000, 0.35), panelShadow: 0.24, panelEdge: 0.16)
        }
    }
}

// MARK: - Static scene

func drawBackground(theme: Theme, context: CGContext) {
    let canvas = CGRect(x: 0, y: 0, width: Layout.width, height: Layout.height)
    context.drawLinearGradient(gradient(theme.backdrop), start: .zero,
                               end: CGPoint(x: canvas.maxX, y: canvas.maxY), options: [])
    // A gentle vignette on the backdrop only, so device and UI pixels stay untouched.
    let center = CGPoint(x: canvas.midX, y: canvas.midY)
    context.drawRadialGradient(gradient([(0, theme.vignette.copy(alpha: 0)!), (1, theme.vignette)]),
                               startCenter: center, startRadius: 620, endCenter: center,
                               endRadius: hypot(canvas.width, canvas.height) / 2, options: [.drawsAfterEndLocation])
}

/// Darkens an aluminium rim on a dark backdrop, where its full brightness reads as a white line.
func shadeRim(_ path: CGPath, theme: Theme, context: CGContext) {
    guard let shade = theme.rimShade else { return }
    context.addPath(path)
    context.setFillColor(shade)
    context.fillPath()
}

/// A hairline around an aluminium body so its edge reads against a light backdrop.
func outline(_ path: CGPath, theme: Theme, context: CGContext) {
    guard let line = theme.deviceOutline else { return }
    context.addPath(path)
    context.setStrokeColor(line)
    context.setLineWidth(1.5)
    context.strokePath()
}

func drawMonitor(theme: Theme, context: CGContext) {
    let glass = Layout.monitorScreen.insetBy(dx: -Layout.monitorBezel, dy: -Layout.monitorBezel)
    let body = glass.insetBy(dx: -Layout.monitorEdge, dy: -Layout.monitorEdge)
    let cx = body.midX
    let screenWidth = Layout.monitorScreen.width
    let neckTop = body.maxY - 40, neckBottom: CGFloat = 1084
    let neckTopHalf = screenWidth * 0.21 / 2, neckBottomHalf = screenWidth * 0.24 / 2
    let footHalf = screenWidth * 0.42 / 2
    let topFace = CGRect(x: cx - footHalf, y: 1068, width: 2 * footHalf, height: 36)
    let frontEdge = CGRect(x: cx - footHalf + 3, y: topFace.maxY - 12, width: 2 * footHalf - 6, height: 24)

    // Soft contact shadow directly under the foot, slightly wider than it.
    softShadow(ellipse(CGRect(x: cx - footHalf - 90, y: frontEdge.maxY - 30, width: 2 * footHalf + 180, height: 48)),
               dx: 10, dy: 8, blur: 46, alpha: 0.18, theme: theme, context: context)
    softShadow(ellipse(CGRect(x: cx - footHalf - 14, y: frontEdge.maxY - 14, width: 2 * footHalf + 28, height: 22)),
               dx: 4, dy: 3, blur: 14, alpha: 0.32, theme: theme, context: context)

    // The foot, seen slightly from above: a darker front edge under a lit top face.
    fill(
        roundedRect(frontEdge, top: 4, bottom: 10),
        vertical: [(0, color(0xB9BDC3)), (1, color(0x8A8F96))],
        context: context
    )
    outline(
        roundedRect(frontEdge.insetBy(dx: -0.75, dy: -0.75), top: 4.75, bottom: 10.75),
        theme: theme,
        context: context
    )
    fill(roundedRect(topFace, 17), vertical: [(0, color(0xDADDE1)), (0.5, color(0xE9EBEE)), (1, color(0xF3F4F6))],
         context: context)
    context.addPath(roundedRect(topFace.insetBy(dx: 0.75, dy: 0.75), 16.25))
    context.setStrokeColor(color(0xFFFFFF, 0.5))
    context.setLineWidth(1.5)
    context.strokePath()

    // The neck, tapering slightly towards the monitor and standing at the back of the foot.
    let neck = CGMutablePath()
    neck.move(to: CGPoint(x: cx - neckTopHalf, y: neckTop))
    neck.addLine(to: CGPoint(x: cx + neckTopHalf, y: neckTop))
    neck.addLine(to: CGPoint(x: cx + neckBottomHalf, y: neckBottom))
    neck.addLine(to: CGPoint(x: cx - neckBottomHalf, y: neckBottom))
    neck.closeSubpath()
    fill(neck, horizontal: [
        (0, color(0xA4A9AF)), (0.08, color(0xC4C7CC)), (0.35, color(0xDFE1E4)), (0.65, color(0xD4D7DB)), (
            0.92,
            color(0xB9BDC3)
        ),
        (1, color(0x9A9FA6)),
    ], context: context)
    context.saveGState()
    context.addPath(neck)
    context.clip()
    context.drawLinearGradient(gradient([(0, color(0x000000, 0.3)), (1, color(0x000000, 0))]),
                               start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.maxY + 50), options: [])
    context.drawLinearGradient(gradient([(0, color(0x000000, 0)), (1, color(0x000000, 0.1))]),
                               start: CGPoint(x: 0, y: neckBottom - 40), end: CGPoint(x: 0, y: neckBottom), options: [])
    context.restoreGState()
    // A faint contact shade on the top face just in front of the neck.
    context.saveGState()
    context.addPath(roundedRect(topFace, 17))
    context.clip()
    context.drawLinearGradient(gradient([(0, color(0x000000, 0.12)), (1, color(0x000000, 0))]),
                               start: CGPoint(x: 0, y: neckBottom), end: CGPoint(x: 0, y: neckBottom + 12), options: [])
    context.restoreGState()

    // The display: a soft drop shadow, a thin aluminium edge and uniform black glass.
    softShadow(roundedRect(body, 22), dx: 10, dy: 30, blur: 80, alpha: 0.24, theme: theme, context: context)
    fill(roundedRect(body, 22), vertical: aluminium, context: context)
    shadeRim(roundedRect(body, 22), theme: theme, context: context)
    outline(roundedRect(body.insetBy(dx: -0.75, dy: -0.75), 22.75), theme: theme, context: context)
    topHighlight(body, inset: 22, context: context)
    context.addPath(roundedRect(glass, 19))
    context.setFillColor(color(0x0A0A0C))
    context.fillPath()
    context.addPath(roundedRect(glass.insetBy(dx: 0.5, dy: 0.5), 18.5))
    context.setStrokeColor(color(0xFFFFFF, 0.07))
    context.setLineWidth(1)
    context.strokePath()
}

/// The MacBook body, drawn over the monitor's screen but under its own screen.
func drawLaptop(theme: Theme, context: CGContext) {
    let glass = Layout.laptopScreen.insetBy(dx: -Layout.laptopBezel, dy: -Layout.laptopBezel)
    let lid = glass.insetBy(dx: -Layout.laptopEdge, dy: -Layout.laptopEdge)
    let deck = CGRect(x: lid.minX - 60, y: lid.maxY + 3, width: lid.width + 120, height: 24)

    softShadow(ellipse(CGRect(x: deck.minX - 20, y: deck.maxY - 28, width: deck.width + 40, height: 46)), dx: 10, dy: 8,
               blur: 46, alpha: 0.2, theme: theme, context: context)
    softShadow(ellipse(CGRect(x: deck.minX + 30, y: deck.maxY - 12, width: deck.width - 60, height: 16)), dx: 4, dy: 3,
               blur: 12, alpha: 0.3, theme: theme, context: context)
    softShadow(
        roundedRect(lid, top: 20, bottom: 6),
        dx: 10,
        dy: 24,
        blur: 64,
        alpha: 0.26,
        theme: theme,
        context: context
    )

    // Hinge, then the deck seen almost edge-on: a lit top face and a shaded front lip.
    context.addPath(roundedRect(CGRect(x: lid.minX + 24, y: lid.maxY - 3, width: lid.width - 48, height: 9), 3))
    context.setFillColor(color(0x34363B))
    context.fillPath()
    let deckPath = CGMutablePath()
    deckPath.move(to: CGPoint(x: deck.minX + 4, y: deck.minY))
    deckPath.addLine(to: CGPoint(x: deck.maxX - 4, y: deck.minY))
    deckPath.addQuadCurve(to: CGPoint(x: deck.maxX, y: deck.minY + 5), control: CGPoint(x: deck.maxX, y: deck.minY))
    deckPath.addLine(to: CGPoint(x: deck.maxX - 8, y: deck.maxY - 8))
    deckPath.addQuadCurve(
        to: CGPoint(x: deck.maxX - 22, y: deck.maxY),
        control: CGPoint(x: deck.maxX - 11, y: deck.maxY)
    )
    deckPath.addLine(to: CGPoint(x: deck.minX + 22, y: deck.maxY))
    deckPath.addQuadCurve(
        to: CGPoint(x: deck.minX + 8, y: deck.maxY - 8),
        control: CGPoint(x: deck.minX + 11, y: deck.maxY)
    )
    deckPath.addLine(to: CGPoint(x: deck.minX, y: deck.minY + 5))
    deckPath.addQuadCurve(to: CGPoint(x: deck.minX + 4, y: deck.minY), control: CGPoint(x: deck.minX, y: deck.minY))
    deckPath.closeSubpath()
    fill(
        deckPath,
        vertical: [(0, color(0xF2F3F5)), (0.22, color(0xDEE0E4)), (0.3, color(0xC9CCD1)), (1, color(0x8F949B))],
        context: context
    )
    context.addPath(roundedRect(
        CGRect(x: deck.midX - 78, y: deck.minY + 5, width: 156, height: 7),
        top: 0.5,
        bottom: 3.5
    ))
    context.setFillColor(color(0x5A5F66, 0.35))
    context.fillPath()

    // The lid: thin aluminium edge, uniform black glass.
    fill(roundedRect(lid, top: 20, bottom: 6), vertical: aluminium, context: context)
    shadeRim(roundedRect(lid, top: 20, bottom: 6), theme: theme, context: context)
    outline(roundedRect(lid.insetBy(dx: -0.75, dy: -0.75), top: 20.75, bottom: 6.75), theme: theme, context: context)
    topHighlight(lid, inset: 20, context: context)
    context.addPath(roundedRect(glass, top: 17, bottom: 4))
    context.setFillColor(color(0x0A0A0C))
    context.fillPath()
    context.addPath(roundedRect(glass.insetBy(dx: 0.5, dy: 0.5), top: 16.5, bottom: 3.5))
    context.setStrokeColor(color(0xFFFFFF, 0.07))
    context.setLineWidth(1)
    context.strokePath()
}

let menuBarClockFont = NSFont.systemFont(ofSize: 26, weight: .medium)

/// How far a clock wider than "Tue 9:41" pushes the status items, the icon and the panel to the left.
func menuBarShift(clock: String) -> CGFloat {
    func width(_ text: String) -> CGFloat {
        NSAttributedString(string: text, attributes: [.font: menuBarClockFont]).size().width
    }
    return max(0, width(clock) - width("Tue 9:41")).rounded()
}

func drawMenuBar(theme: Theme, clock text: String, context: CGContext) {
    let shift = menuBarShift(clock: text)
    let bar = Layout.menuBar
    context.saveGState()
    context.clip(to: bar)
    context.drawLinearGradient(
        gradient(theme.menuBar),
        start: CGPoint(x: 0, y: bar.minY),
        end: CGPoint(x: 0, y: bar.maxY),
        options: []
    )
    context.restoreGState()
    context.setFillColor(theme.menuBarHairline)
    context.fill(CGRect(x: bar.minX, y: bar.maxY - 1, width: bar.width, height: 1))

    if let wifi = symbol("wifi", pointSize: 26, weight: .medium, tint: theme.menuItem) {
        drawSymbol(wifi, centeredAt: CGPoint(x: Layout.wifiX - shift, y: bar.midY), alpha: 1, context: context)
    }
    if let controls = symbol("switch.2", pointSize: 26, weight: .medium, tint: theme.menuItem) {
        drawSymbol(controls, centeredAt: CGPoint(x: Layout.controlCenterX - shift, y: bar.midY), alpha: 1,
                   context: context)
    }
    let clock = NSAttributedString(string: text, attributes: [
        .font: menuBarClockFont,
        .foregroundColor: theme.menuItem,
    ])
    let size = clock.size()
    withAppKit(context) { clock.draw(at: CGPoint(x: Layout.clockRight - size.width, y: bar.midY - size.height / 2)) }
}

// MARK: - Cursor

/// The macOS arrow, in points with the hotspot at the origin and y down.
let arrowPath: CGPath = {
    let path = CGMutablePath()
    path.addLines(between: [
        CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 16.2), CGPoint(x: 3.9, y: 12.6), CGPoint(x: 6.4, y: 18.4),
        CGPoint(x: 8.9, y: 17.3), CGPoint(x: 6.4, y: 11.7), CGPoint(x: 11.6, y: 11.7),
    ])
    path.closeSubpath()
    return path
}()

func drawCursor(at hotspot: CGPoint, scale press: CGFloat, context: CGContext) {
    let scale: CGFloat = 2 * 1.2 * press // 2x canvas, a little larger than life so it reads in a small video
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -2.5), blur: 6, color: color(0x000000, 0.35))
    context.beginTransparencyLayer(auxiliaryInfo: nil)
    context.translateBy(x: hotspot.x, y: hotspot.y)
    context.scaleBy(x: scale, y: scale)
    context.setLineJoin(.round)
    context.addPath(arrowPath)
    context.setStrokeColor(color(0xFFFFFF))
    context.setLineWidth(2.2)
    context.strokePath()
    context.addPath(arrowPath)
    context.setFillColor(color(0x000000))
    context.fillPath()
    context.endTransparencyLayer()
    context.restoreGState()
}

/// A small, quick ring that confirms a click.
func drawClickRing(at center: CGPoint, progress: Double, theme: Theme, context: CGContext) {
    let eased = CGFloat(1 - pow(1 - progress, 3))
    let radius = 9 + 21 * eased
    context.setStrokeColor(color(theme.clickRing.0, theme.clickRing.1 * CGFloat(1 - progress)))
    context.setLineWidth(2.5)
    context.strokeEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius))
}

// MARK: - Panel captures

struct PanelImage {
    let image: CGImage
    let tip: CGPoint // arrow tip in capture pixels
}

func loadPanel(_ path: String) throws -> PanelImage {
    let source = try loadImage(path)
    let width = source.width, height = source.height
    let context = try makeContext(width: width, height: height)
    drawImage(source, in: CGRect(x: 0, y: 0, width: width, height: height), context: context)
    guard let data = context.data, let image = context.makeImage() else {
        throw DemoError.invalid("Cannot decode panel capture: \(path)")
    }
    let bytes = data.assumingMemoryBound(to: UInt8.self)
    // The arrow tip is the first row with opaque pixels; its centre is the tip's x.
    for y in 0 ..< height {
        var first = -1, last = -1
        for x in 0 ..< width where bytes[(y * width + x) * 4 + 3] > 127 {
            if first < 0 {
                first = x
            }
            last = x
        }
        if first >= 0 {
            return PanelImage(image: image, tip: CGPoint(x: CGFloat(first + last + 1) / 2, y: CGFloat(y)))
        }
    }
    throw DemoError.invalid("Panel capture is fully transparent: \(path)")
}

// MARK: - Compositor

struct PanelState {
    let captureFrame: Int?
    let progress: Double // 0 hidden … 1 fully open
}

struct CaptionState {
    let leaving: String?
    let leavingAlpha: Double
    let entering: String?
    let enteringProgress: Double
}

/// A stretch of the cursor track: a point held at one instant, or a drag on a slider.
enum CursorAnchor {
    case point(time: Double, position: CGPoint, click: Bool)
    case drag(start: Double, end: Double, slider: CursorSlider)

    var start: Double {
        switch self {
        case let .point(time, _, _): time
        case let .drag(start, _, _): start
        }
    }

    var end: Double {
        switch self {
        case let .point(time, _, _): time
        case let .drag(_, end, _): end
        }
    }
}

func drawCaptionLine( // swiftlint:disable:this function_parameter_count
    _ text: String, font: NSFont, top: CGFloat, alpha: Double, theme: Theme, context: CGContext
) {
    guard alpha > 0.002 else { return }
    let shadow = NSShadow()
    shadow.shadowBlurRadius = 18
    shadow.shadowOffset = NSSize(width: 0, height: -2)
    shadow.shadowColor = NSColor.black.withAlphaComponent(theme.captionShadow * alpha)
    // Tracking tightens with size, as SF Pro Display's does.
    let string = NSAttributedString(string: text, attributes: [
        .font: font,
        .foregroundColor: theme.caption.withAlphaComponent(theme.caption.alphaComponent * alpha),
        .kern: -0.9 * font.pointSize / 62,
    ].merging(theme.captionShadow > 0 ? [.shadow: shadow] : [:]) { a, _ in a })
    withAppKit(context) { string.draw(at: CGPoint(x: Layout.margin, y: top)) }
}

final class Compositor {
    let fps: Int
    let frames: [FrameValues]
    let anchors: [CursorAnchor]
    let clicks: [(time: Double, position: CGPoint)]
    let panelDir: String
    let staticScene: CGImage
    let laptopLayer: CGImage
    let monitorWallpaper: Bitmap
    let laptopWallpaper: Bitmap
    let panelStates: [PanelState]
    let captionStates: [CaptionState]
    /// Canvas position of the reference capture's top-left; cursor points are relative to it.
    let panelOrigin: CGPoint
    let dimmerlyIcon: NSImage?
    let captionFont: NSFont
    let theme: Theme
    let style: Style

    private var cachedPanel: (frame: Int, panel: PanelImage)?
    private var cachedScreens: [String: (values: DisplayValues, image: CGImage)] = [:]

    static let panelFade = 0.15
    static let captionExit = 0.15
    static let captionEnterDelay = 0.1
    static let captionEnter = 0.32

    // Validates every input and prepares the static layers in one pass.
    // swiftlint:disable:next function_body_length
    init(
        fps: Int,
        frames: [FrameValues],
        cursor track: CursorTrack,
        panelDir: String,
        theme: Theme,
        style: Style = .video(clock: nil)
    ) throws {
        self.fps = fps
        self.theme = theme
        self.style = style
        captionFont = NSFont.systemFont(ofSize: style.captionSize, weight: .semibold)
        self.frames = frames
        self.panelDir = panelDir

        for (index, frame) in frames.enumerated() {
            guard frame.displays.contains(where: \.builtIn), frame.displays.contains(where: { !$0.builtIn }) else {
                throw DemoError.invalid("Frame \(index) needs one built-in and one external display")
            }
        }

        let sceneContext = try makeContext(width: Layout.width, height: Layout.height,
                                           bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        drawBackground(theme: theme, context: sceneContext)
        sceneContext.saveGState()
        sceneContext.concatenate(style.deviceTransform)
        drawMonitor(theme: theme, context: sceneContext)
        sceneContext.restoreGState()
        sceneContext.saveGState()
        sceneContext.concatenate(style.uiTransform)
        drawMenuBar(theme: theme, clock: style.clock, context: sceneContext)
        sceneContext.restoreGState()
        // Static grain over the backdrop, stand and menu bar. The screens are drawn over
        // this layer afterwards, so their pixels never carry it.
        addGrain(sceneContext.data!.assumingMemoryBound(to: UInt8.self), width: Layout.width, height: Layout.height,
                 amplitude: 1.6, seed: 0x6EA1_0F0D)
        let laptopContext = try makeContext(width: Layout.width, height: Layout.height)
        laptopContext.concatenate(style.deviceTransform)
        drawLaptop(theme: theme, context: laptopContext)
        guard let scene = sceneContext.makeImage(), let laptop = laptopContext.makeImage() else {
            throw DemoError.invalid("Cannot render the static scene")
        }
        staticScene = scene
        laptopLayer = laptop
        monitorWallpaper = try makeWallpaper(
            width: Int(Layout.monitorScreen.width),
            height: Int(Layout.monitorScreen.height)
        )
        laptopWallpaper = try makeWallpaper(
            width: Int(Layout.laptopScreen.width),
            height: Int(Layout.laptopScreen.height)
        )
        dimmerlyIcon = symbol("sun.max.fill", pointSize: 27, weight: .medium, tint: theme.menuItem)

        // Panel captures present on disk.
        let names = (try? FileManager.default.contentsOfDirectory(atPath: panelDir)) ?? []
        let available = names.compactMap { name -> Int? in
            guard name.count == 8, name.hasSuffix(".png"), let n = Int(name.prefix(4)) else { return nil }
            return n
        }.filter { $0 < frames.count }.sorted()
        let n = frames.count
        if frames.contains(where: \.panelOpen), available.isEmpty {
            throw DemoError.invalid("The panel opens, but \(panelDir) has no NNNN.png captures")
        }

        func capture(for frame: Int, runStart: Int) -> Int? {
            if let hit = available.last(where: { $0 <= frame && $0 >= runStart }) {
                return hit
            }
            if let next = available.first(where: { $0 >= runStart }) {
                return next
            }
            return available.last(where: { $0 <= frame })
        }
        let transitions = (0 ..< n).filter { frames[$0].panelOpen != frames[($0 + n - 1) % n].panelOpen }
        panelStates = (0 ..< n).map { f in
            let open = frames[f].panelOpen
            guard let transition = transitions.last(where: { $0 <= f }) ?? transitions.last.map({ $0 - n }) else {
                return PanelState(captureFrame: open ? capture(for: f, runStart: 0) : nil, progress: open ? 1 : 0)
            }
            let ramp = smoothstep(Double(f - transition) / Double(fps) / Compositor.panelFade)
            if open {
                return PanelState(captureFrame: capture(for: f, runStart: max(transition, 0)), progress: ramp)
            }
            guard ramp < 1 else { return PanelState(captureFrame: nil, progress: 0) }
            let lastOpen = (transition - 1 + n) % n
            let runStart = transitions.last(where: { $0 <= lastOpen }) ?? 0
            return PanelState(captureFrame: capture(for: lastOpen, runStart: runStart), progress: 1 - ramp)
        }

        // Cursor points are relative to the first capture; without captures, assume the
        // recorder's region capture (arrow tip at 326,5 in a 652x856 capture).
        let referenceTip = try available.first.map { try loadPanel(Compositor.path(panelDir, $0)).tip }
            ?? CGPoint(x: 326, y: 5)
        let origin = CGPoint(x: Layout.panelTip.x - referenceTip.x, y: Layout.panelTip.y - referenceTip.y)
        panelOrigin = origin
        func canvas(_ x: Double, _ y: Double) -> CGPoint {
            CGPoint(x: origin.x + CGFloat(x) * 2, y: origin.y + CGFloat(y) * 2)
        }

        let sliders = track.cursorSliders ?? [:]
        anchors = try (track.cursor ?? []).map { key in
            if let name = key.slider, let slider = sliders[name], let until = key.until {
                guard frames.allSatisfy({ frame in frame.displays.contains { $0.name == slider.display } }) else {
                    throw DemoError
                        .invalid("Cursor slider \(name) names display \(slider.display), which isn't in every frame")
                }
                return .drag(start: key.time, end: until, slider: slider)
            }
            return .point(time: key.time, position: canvas(key.x!, key.y!), click: key.click == true)
        }
        clicks = anchors.compactMap {
            if case let .point(time, position, true) = $0 {
                return (time, position)
            }
            return nil
        }

        // Captions: the old line fades out, then the new one fades in rising a few pixels.
        // Changes include the wrap from the last frame back to frame 0.
        let changes = (0 ..< n).filter { frames[$0].caption != frames[($0 + n - 1) % n].caption }
        captionStates = (0 ..< n).map { f in
            let current = frames[f].caption.isEmpty ? nil : frames[f].caption
            guard let change = changes.last(where: { $0 <= f }) ?? changes.last.map({ $0 - n }) else {
                return CaptionState(leaving: nil, leavingAlpha: 0, entering: current, enteringProgress: 1)
            }
            let previous = frames[(change - 1 + 2 * n) % n].caption
            let elapsed = Double(f - change) / Double(fps)
            let enter = min(max((elapsed - Compositor.captionEnterDelay) / Compositor.captionEnter, 0), 1)
            return CaptionState(leaving: previous.isEmpty ? nil : previous,
                                leavingAlpha: 1 - smoothstep(elapsed / Compositor.captionExit),
                                entering: current, enteringProgress: 1 - pow(1 - enter, 3))
        }
    }

    static func path(_ dir: String, _ frame: Int) -> String {
        URL(fileURLWithPath: dir).appendingPathComponent(String(format: "%04d.png", frame)).path
    }

    func canvasPoint(_ x: Double, _ y: Double) -> CGPoint {
        CGPoint(x: panelOrigin.x + CGFloat(x) * 2, y: panelOrigin.y + CGFloat(y) * 2)
    }

    /// The slider thumb's centre at a frame, from the logged value and the measured track.
    func thumb(_ slider: CursorSlider, frame: Int) -> CGPoint {
        let display = frames[frame].displays.first { $0.name == slider.display }!
        let value = switch slider.value {
        case "warmth": display.warmth
        case "contrast": display.contrast
        default: display.brightness
        }
        let u = (value - slider.min) / (slider.max - slider.min)
        return canvasPoint(slider.minX + (slider.maxX - slider.minX) * u, slider.y)
    }

    func frameIndex(_ time: Double) -> Int {
        min(max(Int((time * Double(fps)).rounded()), 0), frames.count - 1)
    }

    func position(of anchor: CursorAnchor, at time: Double) -> CGPoint {
        switch anchor {
        case let .point(_, position, _): position
        case let .drag(_, _, slider): thumb(slider, frame: frameIndex(time))
        }
    }

    /// Holds on anchors; between them, smoothstep timing along a gentle upward arc.
    func cursorPosition(at time: Double) -> CGPoint? {
        guard let first = anchors.first, let last = anchors.last else { return nil }
        if time <= first.start {
            return position(of: first, at: first.start)
        }
        for (i, anchor) in anchors.enumerated() {
            if time <= anchor.end {
                return position(of: anchor, at: time)
            }
            guard i + 1 < anchors.count else { break }
            let next = anchors[i + 1]
            if time < next.start {
                let a = position(of: anchor, at: anchor.end), b = position(of: next, at: next.start)
                let s = CGFloat(smoothstep((time - anchor.end) / (next.start - anchor.end)))
                let dx = b.x - a.x, dy = b.y - a.y, length = hypot(dx, dy)
                var point = CGPoint(x: a.x + dx * s, y: a.y + dy * s)
                if length > 1 {
                    var normal = CGPoint(x: -dy / length, y: dx / length)
                    if normal.y > 0 {
                        normal = CGPoint(x: -normal.x, y: -normal.y)
                    }
                    let bow = min(length * 0.08, 50) * sin(.pi * s)
                    point.x += normal.x * bow
                    point.y += normal.y * bow
                }
                return point
            }
        }
        return position(of: last, at: last.end)
    }

    /// A short press on each click: down to 0.92 for about 80 ms, then back.
    func pressScale(at time: Double) -> CGFloat {
        var scale: CGFloat = 1
        for click in clicks {
            let d = time - click.time
            if d >= 0, d < 0.08 {
                scale = min(scale, 0.92)
            }
            if d >= 0.08, d < 0.15 {
                scale = min(scale, 0.92 + 0.08 * CGFloat(smoothstep((d - 0.08) / 0.07)))
            }
        }
        return scale
    }

    func screenImage(_ key: String, values: DisplayValues, wallpaper: Bitmap) -> CGImage {
        if let cached = cachedScreens[key], cached.values == values {
            return cached.image
        }
        let image = applyLUT(transferLUT(values), to: wallpaper)
        cachedScreens[key] = (values, image)
        return image
    }

    func panel(for frame: Int) throws -> PanelImage {
        if let cachedPanel, cachedPanel.frame == frame {
            return cachedPanel.panel
        }
        let panel = try loadPanel(Compositor.path(panelDir, frame))
        cachedPanel = (frame, panel)
        return panel
    }

    /// Renders one frame into a flipped canvas context (see `makeContext`).
    func render(frame f: Int, into context: CGContext) throws {
        let values = frames[f]
        let time = Double(f) / Double(fps)
        let canvas = CGRect(x: 0, y: 0, width: Layout.width, height: Layout.height)
        drawImage(staticScene, in: canvas, context: context)

        // Simulated screens: pixel-exact, so the check can compare against GammaMath.
        func drawScreen(_ key: String, _ rect: CGRect, _ display: DisplayValues, _ wallpaper: Bitmap, _ path: CGPath) {
            context.saveGState()
            context.concatenate(style.deviceTransform)
            context.interpolationQuality = style.deviceScale == 1 ? .none : .high
            context.addPath(path)
            context.clip()
            drawImage(screenImage(key, values: display, wallpaper: wallpaper), in: rect, context: context)
            context.restoreGState()
        }
        drawScreen("monitor", Layout.monitorScreen, values.displays.first(where: { !$0.builtIn })!, monitorWallpaper,
                   roundedRect(Layout.monitorScreen, 3))
        drawImage(laptopLayer, in: canvas, context: context)
        drawScreen("laptop", Layout.laptopScreen, values.displays.first(where: \.builtIn)!, laptopWallpaper,
                   roundedRect(Layout.laptopScreen, top: 8, bottom: 2))
        // MacBook notch, over the screen's top edge (outside the sampled interior).
        let notch = CGRect(x: Layout.laptopScreen.midX - 38, y: Layout.laptopScreen.minY - 2, width: 76, height: 15)
        context.saveGState()
        context.concatenate(style.deviceTransform)
        context.addPath(roundedRect(notch, top: 0.5, bottom: 6))
        context.setFillColor(color(0x0A0A0C))
        context.fillPath()
        context.restoreGState()

        // The menu-bar icon and the panel share the menu bar's zoom, and move left for a wider clock.
        context.saveGState()
        context.concatenate(style.uiTransform)
        context.translateBy(x: -menuBarShift(clock: style.clock), y: 0)

        // Menu-bar icon, with the system's highlight while the panel is open.
        let panelState = panelStates[f]
        let icon = Layout.iconCenter
        if panelState.progress > 0 {
            context.addPath(roundedRect(CGRect(x: icon.x - 31, y: icon.y - 18, width: 62, height: 36), 18))
            context.setFillColor(theme.iconPill.copy(alpha: theme.iconPill.alpha * CGFloat(panelState.progress))!)
            context.fillPath()
        }
        if let dimmerlyIcon {
            drawSymbol(dimmerlyIcon, centeredAt: icon, alpha: 1, context: context)
        }

        // The real panel, anchored by its arrow tip, fading and scaling from the tip.
        if panelState.progress > 0, let captureFrame = panelState.captureFrame {
            let panel = try panel(for: captureFrame)
            let scale = 0.95 + 0.05 * CGFloat(panelState.progress)
            context.saveGState()
            context.translateBy(x: Layout.panelTip.x, y: Layout.panelTip.y)
            context.scaleBy(x: scale, y: scale)
            context.setAlpha(CGFloat(panelState.progress))
            // A broad soft shadow, plus a tight one that defines the glass edge, as macOS does.
            context.setShadow(
                offset: CGSize(width: 0, height: -16),
                blur: 48,
                color: color(0x07121F, theme.panelShadow)
            )
            context.beginTransparencyLayer(auxiliaryInfo: nil)
            context.setShadow(offset: CGSize(width: 0, height: -1), blur: 3, color: color(0x07121F, theme.panelEdge))
            context.interpolationQuality = scale == 1 && style.uiScale == 1 ? .none : .high
            drawImage(panel.image, in: CGRect(x: -panel.tip.x, y: -panel.tip.y,
                                              width: CGFloat(panel.image.width), height: CGFloat(panel.image.height)),
                      context: context)
            context.endTransparencyLayer()
            context.restoreGState()
        }
        context.restoreGState()

        if style.isStill {
            // A still shows its caption in full, whatever the fade would be on this frame.
            if !values.caption.isEmpty {
                drawCaptionText(values.caption, alpha: 1, rise: 0, context: context)
            }
            return
        }
        drawCaption(captionStates[f], context: context)

        if let hotspot = cursorPosition(at: time) {
            for click in clicks {
                let progress = (time - click.time) / 0.3
                if progress >= 0, progress < 1 {
                    drawClickRing(at: click.position, progress: progress, theme: theme, context: context)
                }
            }
            drawCursor(at: hotspot, scale: pressScale(at: time), context: context)
        }
    }

    func drawCaption(_ state: CaptionState, context: CGContext) {
        if let leaving = state.leaving {
            drawCaptionText(leaving, alpha: state.leavingAlpha, rise: 0, context: context)
        }
        if let entering = state.entering {
            drawCaptionText(entering, alpha: state.enteringProgress, rise: 10 * CGFloat(1 - state.enteringProgress),
                            context: context)
        }
    }

    func drawCaptionText(_ text: String, alpha: Double, rise: CGFloat, context: CGContext) {
        drawCaptionLine(text, font: captionFont, top: style.captionTop + rise, alpha: alpha, theme: theme,
                        context: context)
    }

    func renderImage(frame: Int) throws -> (CGImage, CGContext) {
        let context = try makeContext(width: Layout.width, height: Layout.height)
        try render(frame: frame, into: context)
        guard let image = context.makeImage() else { throw DemoError.invalid("Cannot render frame \(frame)") }
        return (image, context)
    }
}

/// The same picture without an alpha channel. The canvas is fully covered, so nothing changes.
func opaque(_ image: CGImage) throws -> CGImage {
    let context = try makeContext(width: image.width, height: image.height,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    drawImage(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height), context: context)
    guard let flat = context.makeImage() else { throw DemoError.invalid("Cannot flatten the image") }
    return flat
}

// MARK: - Window still

/// An App Store still of a window, such as Settings, in the still layout: the backdrop and the
/// zoomed menu bar, the window centred under the caption with a window shadow, and the caption.
/// `window` is an opaque region capture; `mask` is a same-sized capture whose alpha outlines it.
func renderWindowStill(
    window capture: CGImage,
    mask: CGImage,
    caption: String,
    theme: Theme,
    style: Style
) throws -> CGImage {
    // A region capture of a window at a fractional screen position can round a few pixels
    // larger than the window; keep its centre at the mask's size.
    let extraWidth = capture.width - mask.width, extraHeight = capture.height - mask.height
    guard (0 ... 4).contains(extraWidth), (0 ... 4).contains(extraHeight),
          [.premultipliedFirst, .premultipliedLast, .first, .last].contains(mask.alphaInfo),
          let window = capture.cropping(to: CGRect(x: extraWidth / 2, y: extraHeight / 2,
                                                   width: mask.width, height: mask.height))
    else { throw DemoError.invalid("The window mask must have alpha and match the window capture's size") }
    let context = try makeContext(width: Layout.width, height: Layout.height,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    drawBackground(theme: theme, context: context)
    context.saveGState()
    context.concatenate(style.uiTransform)
    drawMenuBar(theme: theme, clock: style.clock, context: context)
    if let icon = symbol("sun.max.fill", pointSize: 27, weight: .medium, tint: theme.menuItem) {
        let center = CGPoint(x: Layout.iconCenter.x - menuBarShift(clock: style.clock), y: Layout.iconCenter.y)
        drawSymbol(icon, centeredAt: center, alpha: 1, context: context)
    }
    context.restoreGState()
    addGrain(context.data!.assumingMemoryBound(to: UInt8.self), width: Layout.width, height: Layout.height,
             amplitude: 1.6, seed: 0x6EA1_0F0D)

    // Fit under the caption with a margin all round, at most at the panel's zoom.
    let font = NSFont.systemFont(ofSize: style.captionSize, weight: .semibold)
    let area = CGRect(x: Layout.margin, y: style.captionTop + font.pointSize * 1.2 + 90,
                      width: CGFloat(Layout.width) - 2 * Layout.margin, height: 0)
    let available = CGSize(width: area.width, height: CGFloat(Layout.height) - area.minY - 110)
    let scale = min(style.uiScale, available.width / CGFloat(window.width), available.height / CGFloat(window.height))
    let size = CGSize(width: (CGFloat(window.width) * scale).rounded(),
                      height: (CGFloat(window.height) * scale).rounded())
    let rect = CGRect(x: ((CGFloat(Layout.width) - size.width) / 2).rounded(),
                      y: (area.minY + (available.height - size.height) / 2).rounded(),
                      width: size.width, height: size.height)

    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -28), blur: 80, color: color(0x07121F, theme.panelShadow))
    context.beginTransparencyLayer(auxiliaryInfo: nil)
    context.setShadow(offset: CGSize(width: 0, height: -1), blur: 3, color: color(0x07121F, theme.panelEdge))
    context.beginTransparencyLayer(auxiliaryInfo: nil)
    context.translateBy(x: rect.minX, y: rect.maxY)
    context.scaleBy(x: 1, y: -1)
    context.clip(to: CGRect(origin: .zero, size: rect.size), mask: mask)
    context.interpolationQuality = .high
    context.draw(window, in: CGRect(origin: .zero, size: rect.size))
    context.endTransparencyLayer()
    context.endTransparencyLayer()
    context.restoreGState()

    drawCaptionLine(caption, font: font, top: style.captionTop, alpha: 1, theme: theme, context: context)
    guard let image = context.makeImage() else { throw DemoError.invalid("Cannot render the window still") }
    return image
}

// MARK: - Modes

func writeMovie(_ compositor: Compositor, to path: String) async throws {
    let url = URL(fileURLWithPath: path)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? FileManager.default.removeItem(at: url)
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.proRes422HQ,
        AVVideoWidthKey: Layout.width,
        AVVideoHeightKey: Layout.height,
        AVVideoColorPropertiesKey: [
            AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
            AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
            AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
        ],
    ])
    guard writer.canAdd(input) else { throw DemoError.invalid("Cannot add a ProRes track") }
    let attributes = CVPixelBufferCreationAttributes(
        pixelFormatType: CVPixelFormatType(rawValue: kCVPixelFormatType_32BGRA),
        size: CVImageSize(width: Layout.width, height: Layout.height)
    )
    let receiver = writer.inputPixelBufferReceiver(for: input, pixelBufferAttributes: attributes)
    try writer.start()
    writer.startSession(atSourceTime: .zero)
    let pool = try receiver.pixelBufferPool ?? CVMutablePixelBuffer.Pool(pixelBufferAttributes: attributes)

    let bgra = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
    for frame in 0 ..< compositor.frames.count {
        let buffer = try pool.makeMutablePixelBuffer()
        try buffer.withUnsafeBuffer { pixels in
            CVPixelBufferLockBaseAddress(pixels, [])
            defer { CVPixelBufferUnlockBaseAddress(pixels, []) }
            let context = try makeContext(width: Layout.width, height: Layout.height,
                                          data: CVPixelBufferGetBaseAddress(pixels),
                                          bytesPerRow: CVPixelBufferGetBytesPerRow(pixels), bitmapInfo: bgra)
            try compositor.render(frame: frame, into: context)
            CVBufferSetAttachment(
                pixels,
                kCVImageBufferColorPrimariesKey,
                kCVImageBufferColorPrimaries_ITU_R_709_2,
                .shouldPropagate
            )
            CVBufferSetAttachment(
                pixels,
                kCVImageBufferTransferFunctionKey,
                kCVImageBufferTransferFunction_ITU_R_709_2,
                .shouldPropagate
            )
            CVBufferSetAttachment(
                pixels,
                kCVImageBufferYCbCrMatrixKey,
                kCVImageBufferYCbCrMatrix_ITU_R_709_2,
                .shouldPropagate
            )
        }
        try await receiver.append(CVReadOnlyPixelBuffer(buffer),
                                  with: CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(compositor.fps)))
    }
    receiver.finish()
    await writer.finishWriting()
    guard writer.status == .completed else {
        throw DemoError.invalid("Movie writing failed: \(writer.error.map { "\($0)" } ?? "unknown error")")
    }
}

func runCheck(_ compositor: Compositor) throws -> Bool {
    let frames = compositor.frames
    let last = frames.count - 1
    var passed = true

    let (_, firstContext) = try compositor.renderImage(frame: 0)
    let (_, lastContext) = try compositor.renderImage(frame: last)
    let count = Layout.width * Layout.height
    let a = firstContext.data!.assumingMemoryBound(to: UInt8.self)
    let b = lastContext.data!.assumingMemoryBound(to: UInt8.self)
    var total = 0
    for i in 0 ..< count {
        for c in 0 ..< 3 {
            total += abs(Int(a[i * 4 + c]) - Int(b[i * 4 + c]))
        }
    }
    let loopDifference = Double(total) / Double(count * 3 * 255) * 100
    let loopOK = loopDifference < 1
    passed = passed && loopOK
    print(String(
        format: "%@ loop: frame 0 vs frame %d differ by %.3f%% (limit 1%%)",
        loopOK ? "PASS" : "FAIL",
        last,
        loopDifference
    ))

    // Three frames where the displays are furthest from neutral, spread over the loop.
    func effect(_ f: Int) -> Double {
        frames[f].displays.reduce(0) { $0 + (1 - $1.brightness) + $1.warmth + abs($1.contrast - 0.5) }
    }
    let thirds = [
        0 ..< frames.count / 3,
        frames.count / 3 ..< 2 * frames.count / 3,
        2 * frames.count / 3 ..< frames.count,
    ]
    var samples = thirds.compactMap { range in range.max(by: { effect($0) < effect($1) }) }
    if samples.allSatisfy({ effect($0) == 0 }) {
        samples = [frames.count / 4, frames.count / 2, 3 * frames.count / 4]
    }

    for frame in samples {
        let (_, context) = try compositor.renderImage(frame: frame)
        let data = context.data!.assumingMemoryBound(to: UInt8.self)
        let values = frames[frame]
        var worst = 0, checked = 0
        for (rect, display, wallpaper) in [
            (Layout.monitorScreen, values.displays.first(where: { !$0.builtIn })!, compositor.monitorWallpaper),
            (Layout.laptopScreen, values.displays.first(where: \.builtIn)!, compositor.laptopWallpaper),
        ] {
            let lut = transferLUT(display)
            let interior = Layout.interior(rect)
            for gy in 0 ..< 24 {
                for gx in 0 ..< 32 {
                    let x = Int(interior.minX + interior.width * CGFloat(gx) / 31)
                    let y = Int(interior.minY + interior.height * CGFloat(gy) / 23)
                    if rect == Layout.monitorScreen, Layout.laptopOccluder.contains(CGPoint(x: x, y: y)) {
                        continue
                    }
                    let wx = x - Int(rect.minX), wy = y - Int(rect.minY)
                    for c in 0 ..< 3 {
                        let expected = Int(lut[c][Int(wallpaper.pixels[(wy * wallpaper.width + wx) * 4 + c])])
                        let actual = Int(data[(y * Layout.width + x) * 4 + c])
                        worst = max(worst, abs(expected - actual))
                    }
                    checked += 1
                }
            }
        }
        let ok = worst <= 1
        passed = passed && ok
        let summary = values.displays.map {
            String(format: "%@ b=%.3f w=%.3f c=%.2f", $0.name, $0.brightness, $0.warmth, $0.contrast)
        }.joined(separator: "; ")
        print(
            "\(ok ? "PASS" : "FAIL") screens at frame \(frame): \(checked) pixels, " +
                "max channel error \(worst) (limit 1) [\(summary)]"
        )
    }
    return passed
}

@main
struct ComposeDemo {
    static func main() async {
        do {
            try await run(Array(CommandLine.arguments.dropFirst()))
        } catch {
            FileHandle.standardError.write(Data("Error: \(error)\n".utf8))
            exit(1)
        }
    }

    // swiftlint:disable:next function_body_length
    static func run(_ args: [String]) async throws {
        if args == ["--help"] || args == ["-h"] {
            print(usage)
            return
        }
        let valued: Set = [
            "--appearance",
            "--values",
            "--panel-dir",
            "--storyboard",
            "--background",
            "--output",
            "--frame",
            "--png",
            "--clock",
            "--window",
            "--window-mask",
            "--caption",
        ]
        var options: [String: String] = [:]
        var check = false
        var still = false
        var index = 0
        while index < args.count {
            let name = args[index]
            if name == "--check", !check {
                check = true
                index += 1
                continue
            }
            if name == "--still", !still {
                still = true
                index += 1
                continue
            }
            guard valued.contains(name), index + 1 < args.count, !args[index + 1].hasPrefix("--"), options[name] == nil
            else { throw DemoError.invalid("Invalid or duplicate option: \(name)\n\(usage)") }
            options[name] = args[index + 1]
            index += 2
        }
        func required(_ name: String) throws -> String {
            guard let value = options[name],
                  !value.isEmpty else { throw DemoError.invalid("Missing \(name)\n\(usage)") }
            return value
        }
        guard let appearance = try Appearance(rawValue: required("--appearance")) else {
            throw DemoError.invalid("--appearance must be light or dark\n\(usage)")
        }
        if let window = options["--window"] {
            let image = try renderWindowStill(
                window: loadImage(window), mask: loadImage(required("--window-mask")),
                caption: required("--caption"), theme: Theme.make(appearance),
                style: .still(clock: options["--clock"])
            )
            let png = try required("--png")
            try writePNG(image, to: png)
            print("Wrote \(png) (window still, \(Layout.width)x\(Layout.height))")
            return
        }
        guard options["--window-mask"] == nil, options["--caption"] == nil else {
            throw DemoError.invalid("--window-mask and --caption go with --window\n\(usage)")
        }

        let modes = [options["--output"] != nil, options["--frame"] != nil || options["--png"] != nil, check]
        guard modes.filter(\.self).count == 1 else {
            throw DemoError.invalid("Choose exactly one of --output, --frame with --png, or --check\n\(usage)")
        }
        guard !still || options["--frame"] != nil else {
            throw DemoError.invalid("--still goes with --frame and --png\n\(usage)")
        }
        if options["--background"] != nil {
            FileHandle.standardError
                .write(Data("Note: --background is ignored; the backdrop is drawn for --appearance.\n".utf8))
        }
        let started = Date()
        let (fps, frames) = try loadValues(required("--values"))
        let cursor = try loadCursor(required("--storyboard"))
        let style = still ? Style.still(clock: options["--clock"]) : Style.video(clock: options["--clock"])
        let compositor = try Compositor(fps: fps, frames: frames, cursor: cursor, panelDir: required("--panel-dir"),
                                        theme: Theme.make(appearance), style: style)

        if check {
            let passed = try runCheck(compositor)
            print(String(format: "Check %@ in %.1f s", passed ? "passed" : "failed", Date().timeIntervalSince(started)))
            if !passed {
                exit(1)
            }
        } else if let output = options["--output"] {
            try await writeMovie(compositor, to: output)
            print(String(
                format: "Wrote %@ (%d frames at %d fps, %dx%d ProRes 422 HQ) in %.1f s",
                output,
                frames.count,
                fps,
                Layout.width,
                Layout.height,
                Date().timeIntervalSince(started)
            ))
        } else {
            guard let frame = try Int(required("--frame")), frames.indices.contains(frame) else {
                throw DemoError.invalid("--frame must be between 0 and \(frames.count - 1)")
            }
            let png = try required("--png")
            let image = try compositor.renderImage(frame: frame).0
            // App Store Connect rejects screenshots with an alpha channel.
            try writePNG(still ? opaque(image) : image, to: png)
            print("Wrote \(png) (frame \(frame), \(Layout.width)x\(Layout.height))")
        }
    }
}

// Composes genuine window captures for App Store and GitHub screenshots.

import AppKit
import ImageIO
import UniformTypeIdentifiers

enum ScreenshotError: Error, CustomStringConvertible {
    case invalid(String)

    var description: String {
        switch self {
        case let .invalid(message): message
        }
    }
}

let usage = """
Usage: screenshots.sh compose --variant app-store|github --menu FILE --settings FILE \
    --output PATH [--settings-mask FILE] [--background FILE] [--width N --height N]

app-store: writes an opaque 16:10 PNG (default 2880x1800).
github: writes native-resolution image1.png and image2.png into PATH.
--settings-mask uses only the alpha outline of a same-sized window capture.
"""

func loadImage(_ path: String) throws -> CGImage {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { throw ScreenshotError.invalid("Cannot read image: \(path)") }
    return image
}

func makeContext(width: Int, height: Int, opaque: Bool) throws -> CGContext {
    let alpha = opaque ? CGImageAlphaInfo.noneSkipLast : .premultipliedLast
    guard let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: alpha.rawValue
    ) else { throw ScreenshotError.invalid("Cannot allocate image canvas") }
    return context
}

func draw(_ image: CGImage, in context: CGContext, rect: CGRect, mask: CGImage? = nil) {
    context.saveGState()
    if let mask {
        context.clip(to: rect, mask: mask)
    }
    context.draw(image, in: rect)
    context.restoreGState()
}

func writePNG(_ image: CGImage, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { throw ScreenshotError.invalid("Cannot create PNG: \(url.path)") }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw ScreenshotError.invalid("Cannot finish PNG: \(url.path)")
    }
    print("Wrote \(url.path) (\(image.width)x\(image.height))")
}

do {
    let args = Array(CommandLine.arguments.dropFirst())
    if args == ["--help"] || args == ["-h"] {
        print(usage)
        exit(0)
    }
    let allowed: Set = [
        "--variant",
        "--menu",
        "--settings",
        "--output",
        "--settings-mask",
        "--background",
        "--width",
        "--height",
    ]
    var options: [String: String] = [:]
    var index = 0
    while index < args.count {
        let name = args[index]
        guard allowed.contains(name), index + 1 < args.count, !args[index + 1].hasPrefix("--"),
              options[name] == nil
        else { throw ScreenshotError.invalid("Invalid or duplicate option: \(name)\n\(usage)") }
        options[name] = args[index + 1]
        index += 2
    }
    func required(_ name: String) throws -> String {
        guard let value = options[name], !value.isEmpty else {
            throw ScreenshotError.invalid("Missing \(name)\n\(usage)")
        }
        return value
    }
    let variant = try required("--variant")
    guard ["app-store", "github"].contains(variant) else {
        throw ScreenshotError.invalid("Variant must be app-store or github")
    }
    let menu = try loadImage(required("--menu"))
    let settings = try loadImage(required("--settings"))
    let output = try URL(fileURLWithPath: required("--output"))
    let mask = try options["--settings-mask"].map { try loadImage($0) }
    if let mask {
        guard mask.width == settings.width, mask.height == settings.height,
              [.premultipliedFirst, .premultipliedLast, .first, .last].contains(mask.alphaInfo)
        else { throw ScreenshotError.invalid("Settings mask must have alpha and match Settings dimensions") }
    }

    if variant == "github" {
        guard options["--width"] == nil, options["--height"] == nil, options["--background"] == nil else {
            throw ScreenshotError.invalid("Canvas options apply only to app-store output")
        }
        let context = try makeContext(width: settings.width, height: settings.height, opaque: false)
        let settingsRect = CGRect(x: 0, y: 0, width: settings.width, height: settings.height)
        draw(settings, in: context, rect: settingsRect, mask: mask)
        guard let settingsImage = context.makeImage() else { throw ScreenshotError.invalid("Cannot compose Settings") }
        try writePNG(menu, to: output.appendingPathComponent("image1.png"))
        try writePNG(settingsImage, to: output.appendingPathComponent("image2.png"))
    } else {
        guard let width = Int(options["--width"] ?? "2880"), let height = Int(options["--height"] ?? "1800"),
              [(1280, 800), (1440, 900), (2560, 1600), (2880, 1800)].contains(where: { $0 == width && $1 == height })
        else { throw ScreenshotError.invalid("Use an accepted canvas: 1280x800, 1440x900, 2560x1600 or 2880x1800") }
        let gap = width * 5 / 36
        let totalWidth = menu.width + gap + settings.width
        guard totalWidth <= width, menu.height <= height, settings.height <= height else {
            throw ScreenshotError.invalid(
                "Native captures do not fit this canvas. Resize the windows and recapture, or choose a larger canvas."
            )
        }
        let backgroundPath = options["--background"] ?? URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().appendingPathComponent("background.png").path
        let background = try loadImage(backgroundPath)
        let context = try makeContext(width: width, height: height, opaque: true)
        draw(background, in: context, rect: CGRect(x: 0, y: 0, width: width, height: height))
        let left = (width - totalWidth) / 2
        draw(menu, in: context, rect: CGRect(x: left, y: (height - menu.height) / 2,
                                             width: menu.width, height: menu.height))
        draw(settings, in: context, rect: CGRect(x: left + menu.width + gap, y: (height - settings.height) / 2,
                                                 width: settings.width, height: settings.height), mask: mask)
        guard let image = context.makeImage() else { throw ScreenshotError.invalid("Cannot compose screenshot") }
        try writePNG(image, to: output)
    }
} catch {
    FileHandle.standardError.write(Data("Error: \(error)\n".utf8))
    exit(1)
}

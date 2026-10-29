// Renders the DMG installer window background at 1x and 2x.
//
// Usage: swift packaging/dmg/make-background.swift packaging/dmg
//
// The layout constants must stay in sync with dmgbuild-settings.py. Finder draws
// icon labels in black over a background picture in both light and dark mode, so
// the band behind the labels must keep at least 4.5:1 contrast with black.

import AppKit

let windowSize = NSSize(width: 660, height: 400)
let appIconCenter = NSPoint(x: 165, y: 180)
let applicationsIconCenter = NSPoint(x: 495, y: 180)
let iconSize: CGFloat = 128
let hint = "Drag Dimmerly to Applications to install"

func color(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
    NSColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

func drawBackground() {
    // Slate (#687690) gives black labels about 4.5:1 and, being nearly neutral,
    // carries them better than saturated blue does. Hold it flat across the label
    // band and only vary the shade above and below it.
    let labelBandTop = (appIconCenter.y + iconSize / 2) / windowSize.height
    let labelBandBottom = (appIconCenter.y + iconSize / 2 + 40) / windowSize.height
    NSGradient(
        colors: [color(0x8994A6), color(0x687690), color(0x687690), color(0x3A4250)],
        atLocations: [0, labelBandTop, labelBandBottom, 1],
        colorSpace: .sRGB
    )?
        .draw(
            from: NSPoint(x: 0, y: 0),
            to: NSPoint(x: 0, y: windowSize.height),
            options: [.drawsBeforeStartingLocation, .drawsAfterEndingLocation]
        )

    NSGradient(colors: [color(0xFFFFFF, alpha: 0.10), color(0xFFFFFF, alpha: 0)])?
        .draw(
            fromCenter: NSPoint(x: windowSize.width / 2, y: 0),
            radius: 0,
            toCenter: NSPoint(x: windowSize.width / 2, y: 0),
            radius: appIconCenter.y + iconSize / 2,
            options: []
        )

    let arrowStart = appIconCenter.x + iconSize / 2 + 28
    let arrowEnd = applicationsIconCenter.x - iconSize / 2 - 28
    let arrowY = appIconCenter.y
    let headLength: CGFloat = 18

    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: arrowStart, y: arrowY))
    arrow.line(to: NSPoint(x: arrowEnd, y: arrowY))
    arrow.move(to: NSPoint(x: arrowEnd - headLength, y: arrowY - headLength))
    arrow.line(to: NSPoint(x: arrowEnd, y: arrowY))
    arrow.line(to: NSPoint(x: arrowEnd - headLength, y: arrowY + headLength))
    arrow.lineWidth = 7
    arrow.lineCapStyle = .round
    arrow.lineJoinStyle = .round
    // Light brand blue from the website's dark theme (--blue-dark).
    color(0x91C0FF).setStroke()
    arrow.stroke()

    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    let shadow = NSShadow()
    shadow.shadowColor = color(0x0B1726, alpha: 0.35)
    shadow.shadowOffset = NSSize(width: 0, height: -1)
    shadow.shadowBlurRadius = 3
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 17, weight: .semibold),
        .foregroundColor: NSColor.white,
        .paragraphStyle: paragraph,
        .shadow: shadow,
    ]
    let text = NSAttributedString(string: hint, attributes: attributes)
    let textHeight = text.size().height
    text.draw(in: NSRect(x: 0, y: 330 - textHeight / 2, width: windowSize.width, height: textHeight))
}

func render(scale: Int, to url: URL) throws {
    let width = Int(windowSize.width) * scale
    let height = Int(windowSize.height) * scale
    guard
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )
    else {
        throw CocoaError(.fileWriteUnknown)
    }

    // Finder positions icons from the top-left corner, so draw in the same space.
    context.translateBy(x: 0, y: CGFloat(height))
    context.scaleBy(x: CGFloat(scale), y: -CGFloat(scale))

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
    drawBackground()
    NSGraphicsContext.restoreGraphicsState()

    guard
        let image = context.makeImage(),
        let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)
    else {
        throw CocoaError(.fileWriteUnknown)
    }
    let dpi = 72 * scale
    let properties = [
        kCGImagePropertyDPIWidth: dpi,
        kCGImagePropertyDPIHeight: dpi,
    ] as CFDictionary
    CGImageDestinationAddImage(destination, image, properties)
    guard CGImageDestinationFinalize(destination) else {
        throw CocoaError(.fileWriteUnknown)
    }
}

let outputDirectory = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? ".")
try render(scale: 1, to: outputDirectory.appendingPathComponent("background.png"))
try render(scale: 2, to: outputDirectory.appendingPathComponent("background@2x.png"))

import CoreGraphics
import Foundation

enum CaptureLayout {
    struct LayoutError: LocalizedError {
        var errorDescription: String? {
            "The entire app window must fit on one display. Move it onto a larger display and retry."
        }
    }

    /// ScreenCaptureKit coordinates: top left origin, including displays left of or above main.
    static func desktopRegion(window: CGRect, display: CGRect) throws -> CGRect {
        guard !window.isEmpty, display.contains(window) else { throw LayoutError() }
        let padded = window.insetBy(dx: -32, dy: -32).intersection(display)
        return CGRect(
            x: padded.minX, y: display.minY,
            width: display.maxX - padded.minX, height: padded.maxY - display.minY
        )
    }
}

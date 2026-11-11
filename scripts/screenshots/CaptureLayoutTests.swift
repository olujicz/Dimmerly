import CoreGraphics
import Foundation

@main
enum CaptureLayoutTests {
    static func main() throws {
        let display = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let window = CGRect(x: 1500, y: 35, width: 326, height: 600)
        let region = try CaptureLayout.desktopRegion(window: window, display: display)
        precondition(region.minY == display.minY, "The real menu bar must be included")
        precondition(region.contains(window), "The entire panel must be visible")
        precondition(region.minX == window.minX - 32, "Keep the left crop close to the app")
        precondition(region.maxX == display.maxX, "Keep the clock and rightmost menu bar items whole")
        precondition(display.contains(region), "A crop must not leak onto another screen")

        let secondary = CGRect(x: -1440, y: -900, width: 1440, height: 900)
        let settings = CGRect(x: -1400, y: -820, width: 680, height: 650)
        let secondRegion = try CaptureLayout.desktopRegion(window: settings, display: secondary)
        precondition(secondRegion.minY == -900)
        precondition(secondRegion.contains(settings))
        precondition(secondary.contains(secondRegion))

        let edgeWindow = CGRect(x: 0, y: 30, width: 326, height: 600)
        let edgeRegion = try CaptureLayout.desktopRegion(window: edgeWindow, display: display)
        precondition(edgeRegion.minX == 0)
        precondition(edgeRegion.contains(edgeWindow))
        do {
            _ = try CaptureLayout.desktopRegion(
                window: CGRect(x: 100, y: 30, width: 500, height: 1200), display: display
            )
            fatalError("An oversized window must fail rather than produce a clipped screenshot")
        } catch {}
        print("Capture layout checks passed")
    }
}

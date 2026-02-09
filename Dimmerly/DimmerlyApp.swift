import SwiftUI
import AppKit

@main
struct DimmerlyApp: App {
    var body: some Scene {
        MenuBarExtra {
            Button("Turn Displays Off") {
                DisplayController.sleepDisplays()
            }
            Divider()
            Button("Quit Dimmerly") {
                NSApplication.shared.terminate(nil)
            }
        } label: {
            Image(systemName: "moon.stars")
        }
    }
}

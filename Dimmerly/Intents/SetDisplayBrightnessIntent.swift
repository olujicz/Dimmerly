//
//  SetDisplayBrightnessIntent.swift
//  Dimmerly
//
//  App Intent to set brightness for a specific display via Shortcuts.app.
//

import AppIntents
import CoreGraphics

struct SetDisplayBrightnessIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Display Brightness"
    static let description: IntentDescription = IntentDescription("Sets the brightness of a specific external display.")

    @Parameter(title: "Display")
    var display: DisplayEntity

    @Parameter(title: "Brightness", description: "Brightness percentage (5–100)", default: 100.0, controlStyle: .slider, inclusiveRange: (5.0, 100.0))
    var brightness: Double

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let displayID = CGDirectDisplayID(display.id) else {
            throw IntentError.invalidDisplay
        }
        let value = brightness / 100.0
        BrightnessManager.shared.setBrightness(for: displayID, to: value)
        return .result()
    }

    enum IntentError: Swift.Error, CustomLocalizedStringResourceConvertible {
        case invalidDisplay

        var localizedStringResource: LocalizedStringResource {
            switch self {
            case .invalidDisplay: return "The selected display is no longer connected."
            }
        }
    }
}

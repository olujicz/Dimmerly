//
//  SetDisplayWarmthIntent.swift
//  Dimmerly
//
//  App Intent to set warmth for a specific display via Shortcuts.app.
//

import AppIntents
import CoreGraphics

struct SetDisplayWarmthIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Display Warmth"
    static let description: IntentDescription = IntentDescription("Sets the color warmth of a specific external display.")

    @Parameter(title: "Display")
    var display: DisplayEntity

    @Parameter(title: "Warmth", description: "Warmth percentage (0–100)", default: 0.0, controlStyle: .slider, inclusiveRange: (0.0, 100.0))
    var warmth: Double

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let displayID = CGDirectDisplayID(display.id) else {
            throw IntentError.invalidDisplay
        }
        let value = warmth / 100.0
        BrightnessManager.shared.setWarmth(for: displayID, to: value)
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

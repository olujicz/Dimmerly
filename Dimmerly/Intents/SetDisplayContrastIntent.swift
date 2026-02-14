//
//  SetDisplayContrastIntent.swift
//  Dimmerly
//
//  App Intent to set contrast for a specific display via Shortcuts.app.
//

import AppIntents
import CoreGraphics

struct SetDisplayContrastIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Display Contrast"
    static let description: IntentDescription = .init("Sets the contrast of a specific external display.")

    @Parameter(title: "Display")
    var display: DisplayEntity

    @Parameter(
        title: "Contrast",
        description: "Contrast percentage (0–100, 50 = neutral)",
        default: 50.0,
        controlStyle: .slider,
        inclusiveRange: (0.0, 100.0)
    )
    var contrast: Double

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let displayID = CGDirectDisplayID(display.id) else {
            throw IntentError.invalidDisplay
        }
        let value = contrast / 100.0
        BrightnessManager.shared.setContrast(for: displayID, to: value)
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

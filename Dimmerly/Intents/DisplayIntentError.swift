//
//  DisplayIntentError.swift
//  Dimmerly
//
//  Shared error type for display-targeted App Intents.
//  Previously each intent declared its own nested `IntentError.invalidDisplay`;
//  consolidating avoids drift between identical error shapes.
//

import AppIntents

enum DisplayIntentError: Swift.Error, CustomLocalizedStringResourceConvertible {
    case invalidDisplay

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .invalidDisplay: return "The selected display is no longer connected."
        }
    }
}

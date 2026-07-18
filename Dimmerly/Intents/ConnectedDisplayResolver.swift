//
//  ConnectedDisplayResolver.swift
//  Dimmerly
//

import CoreGraphics

@MainActor
enum ConnectedDisplayResolver {
    static func resolve(
        _ entity: DisplayEntity,
        connectedIDs: () -> [CGDirectDisplayID]
    ) throws -> CGDirectDisplayID {
        guard let displayID = CGDirectDisplayID(entity.id),
              connectedIDs().contains(displayID)
        else {
            throw DisplayIntentError.invalidDisplay
        }
        return displayID
    }
}

@MainActor
protocol DisplayIntentCommanding: AnyObject {
    var connectedDisplayIDs: [CGDirectDisplayID] { get }
    func setBrightness(_ value: Double, for displayID: CGDirectDisplayID)
    func setWarmth(_ value: Double, for displayID: CGDirectDisplayID)
    func setContrast(_ value: Double, for displayID: CGDirectDisplayID)
    func toggleDim(for displayID: CGDirectDisplayID)
}

@MainActor
final class LiveDisplayIntentCommand: DisplayIntentCommanding {
    static let shared = LiveDisplayIntentCommand()

    private let manager: BrightnessManager

    private init(manager: BrightnessManager = .shared) {
        self.manager = manager
    }

    var connectedDisplayIDs: [CGDirectDisplayID] {
        manager.displays.map(\.id)
    }

    func setBrightness(_ value: Double, for displayID: CGDirectDisplayID) {
        manager.setBrightness(for: displayID, to: value)
    }

    func setWarmth(_ value: Double, for displayID: CGDirectDisplayID) {
        manager.setWarmth(for: displayID, to: value)
    }

    func setContrast(_ value: Double, for displayID: CGDirectDisplayID) {
        manager.setContrast(for: displayID, to: value)
    }

    func toggleDim(for displayID: CGDirectDisplayID) {
        manager.toggleBlank(for: displayID)
    }
}

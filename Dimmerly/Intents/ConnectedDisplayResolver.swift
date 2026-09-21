//
//  ConnectedDisplayResolver.swift
//  Dimmerly
//

import CoreGraphics

struct ConnectedDisplayDescriptor: Equatable, Sendable {
    let id: CGDirectDisplayID
    let stableIdentity: String
    let name: String
}

extension ConnectedDisplayDescriptor {
    /// Snapshot of the connected displays in the shape App Intents and entity queries consume.
    @MainActor
    static func connected(from manager: BrightnessManager = .shared) -> [ConnectedDisplayDescriptor] {
        manager.displays.map { display in
            ConnectedDisplayDescriptor(
                id: display.id,
                stableIdentity: BrightnessManager.stableDisplayIdentity(for: display.id),
                name: display.name
            )
        }
    }
}

@MainActor
enum ConnectedDisplayResolver {
    static func resolve(
        _ entity: DisplayEntity,
        connectedDescriptors: () -> [ConnectedDisplayDescriptor]
    ) throws -> CGDirectDisplayID {
        let matches = connectedDescriptors().filter { $0.stableIdentity == entity.id }
        guard DisplayEntityIdentifier.isSafelyPersistable(entity.id), matches.count == 1 else {
            throw DisplayIntentError.invalidDisplay
        }
        return matches[0].id
    }
}

@MainActor
protocol DisplayIntentCommanding: AnyObject {
    var connectedDisplayDescriptors: [ConnectedDisplayDescriptor] { get }
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

    var connectedDisplayDescriptors: [ConnectedDisplayDescriptor] {
        ConnectedDisplayDescriptor.connected(from: manager)
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

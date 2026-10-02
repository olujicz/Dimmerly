//
//  ControlCenterStatePublisher.swift
//  Dimmerly
//
//  Publishes app state for the Control Center toggles and applies their commands.
//

import Foundation
import WidgetKit

/// Shares the state the Control Center toggles show, and asks the system to redraw them.
///
/// Control values are read by the widget extension, which cannot see the app's managers. The app
/// writes each value to the app-group suite as it changes, then reloads the controls of that kind
/// so Control Center asks its value provider again.
@MainActor
struct ControlCenterStatePublisher {
    static let live = ControlCenterStatePublisher()

    let defaults: UserDefaults?
    let reloadControls: (String) -> Void

    init(
        defaults: UserDefaults? = SharedConstants.sharedDefaults,
        reloadControls: @escaping (String) -> Void = { ControlCenterStatePublisher.reloadSystemControls(ofKind: $0) }
    ) {
        self.defaults = defaults
        self.reloadControls = reloadControls
    }

    /// Publishes whether any display is blanked. Reloads the dim toggle only when the value changed.
    func publishDimState(_ isDimming: Bool) {
        publish(isDimming, forKey: SharedConstants.controlDimStateKey, kind: SharedConstants.dimToggleControlKind)
    }

    /// Publishes whether Auto Warmth is on. Reloads the Auto Warmth toggle only when the value changed.
    func publishAutoWarmthState(_ isEnabled: Bool) {
        publish(
            isEnabled,
            forKey: SharedConstants.controlAutoWarmthStateKey,
            kind: SharedConstants.autoWarmthControlKind
        )
    }

    /// Redraws the dim toggle after a command, even if the state did not change.
    ///
    /// Control Center flips a toggle as soon as it is tapped. When the action leaves nothing to
    /// report, such as real display sleep through `pmset`, the toggle has to be told to read the
    /// published value again or it would keep showing the state it guessed.
    func refreshDimToggle() {
        reloadControls(SharedConstants.dimToggleControlKind)
    }

    /// Redraws the Auto Warmth toggle after a command, even if the setting did not change.
    func refreshAutoWarmthToggle() {
        reloadControls(SharedConstants.autoWarmthControlKind)
    }

    /// Redraws configured preset controls after presets were renamed, reordered, or deleted.
    func refreshPresetControls() {
        reloadControls(SharedConstants.presetControlKind)
    }

    private func publish(_ isOn: Bool, forKey key: String, kind: String) {
        guard SharedConstants.publishControlState(isOn, forKey: key, in: defaults) else { return }
        reloadControls(kind)
    }

    static func reloadSystemControls(ofKind kind: String) {
        #if compiler(>=6.2)
            if #available(macOS 26.0, *) {
                ControlCenter.shared.reloadControls(ofKind: kind)
            }
        #endif
    }
}

/// Applies a pending dim toggle command written by the Control Center extension.
@MainActor
func handleWidgetDimStateCommand(
    settings: AppSettings,
    consumeCommand: () -> Bool? = { SharedConstants.consumeWidgetDimStateCommand() },
    setDimmed: (Bool, AppSettings) -> Void = { DisplayAction.setDimmed($0, settings: $1) },
    publisher: ControlCenterStatePublisher = .live
) {
    guard let isDimmed = consumeCommand() else { return }
    setDimmed(isDimmed, settings)
    publisher.refreshDimToggle()
}

/// Applies a pending Auto Warmth toggle command written by the Control Center extension.
///
/// Only the setting changes here. The scene's `.onChange` on `autoColorTempEnabled` starts or
/// stops the colour temperature manager, exactly as it does when the setting is changed in the
/// menu bar panel. The state is published straight away so the toggle does not wait for the
/// next view update to read it.
@MainActor
func handleWidgetAutoWarmthCommand(
    settings: AppSettings,
    consumeCommand: () -> Bool? = { SharedConstants.consumeWidgetAutoWarmthCommand() },
    publisher: ControlCenterStatePublisher = .live
) {
    guard let isEnabled = consumeCommand() else { return }
    settings.autoColorTempEnabled = isEnabled
    publisher.publishAutoWarmthState(settings.autoColorTempEnabled)
    publisher.refreshAutoWarmthToggle()
}

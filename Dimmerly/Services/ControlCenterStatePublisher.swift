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
    let reloadTimelines: () -> Void

    init(
        defaults: UserDefaults? = SharedConstants.sharedDefaults,
        reloadControls: @escaping (String) -> Void = { ControlCenterStatePublisher.reloadSystemControls(ofKind: $0) },
        reloadTimelines: @escaping () -> Void = { WidgetCenter.shared.reloadAllTimelines() }
    ) {
        self.defaults = defaults
        self.reloadControls = reloadControls
        self.reloadTimelines = reloadTimelines
    }

    /// Publishes what the dim button does, so the widgets and the Control Center button can say
    /// "Dim Displays" or "Turn Displays Off" to match. Redraws them only when the mode changed.
    func publishDisplayOffMode(_ mode: DisplayOffMode) {
        guard SharedConstants.publishDisplayOffMode(mode, in: defaults) else { return }
        reloadControls(SharedConstants.dimControlKind)
        reloadTimelines()
    }

    /// Publishes whether any display is blanked. Commands can also reload an unchanged value
    /// to reset Control Center's optimistic toggle state.
    func publishDimState(_ isDimming: Bool, forceReload: Bool = false) {
        publish(
            isDimming,
            forKey: SharedConstants.controlDimStateKey,
            kind: SharedConstants.dimToggleControlKind,
            forceReload: forceReload
        )
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

    private func publish(_ isOn: Bool, forKey key: String, kind: String, forceReload: Bool = false) {
        let didChange = SharedConstants.publishControlState(isOn, forKey: key, in: defaults)
        guard didChange || forceReload else { return }
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

@MainActor
extension WidgetActionCommand {
    /// Runs a widget or Control Center command inside the app process.
    ///
    /// Returns false when there was nothing to do it with: a preset that was deleted after the
    /// widget or control was set up, or an ID that is not a preset ID at all. The other commands
    /// publish whatever state they actually reached, so they report true.
    @discardableResult
    func performInApp(settings: AppSettings = .shared, presetManager: PresetManager = .shared) -> Bool {
        switch self {
        case .dimDisplays:
            DisplayAction.performSleep(settings: settings)
        case let .applyPreset(presetID):
            guard let uuid = UUID(uuidString: presetID), let preset = presetManager.preset(withID: uuid) else {
                return false
            }
            presetManager.applyPreset(preset, to: BrightnessManager.shared, animated: true)
        case let .setDimming(value):
            handleWidgetDimStateCommand(value, settings: settings)
        case let .setAutoWarmth(value):
            handleWidgetAutoWarmthCommand(value, settings: settings)
        }
        return true
    }

    /// Runs the command for an intent the app performs itself, throwing the error the extension
    /// would show for the same failure.
    func performForIntent(settings: AppSettings = .shared) throws {
        guard performInApp(settings: settings) else { throw WidgetActionExecution.failure(for: self) }
    }
}

/// Applies the Control Center dim toggle's requested state.
/// Publishes actual blanking state before reloading, even when the action leaves it unchanged.
@MainActor
func handleWidgetDimStateCommand(
    _ isDimmed: Bool,
    settings: AppSettings,
    setDimmed: (Bool, AppSettings) -> Void = { DisplayAction.setDimmed($0, settings: $1) },
    isBlankingAnyDisplay: () -> Bool = { ScreenBlanker.shared.isBlankingAnyDisplay },
    publisher: ControlCenterStatePublisher = .live
) {
    setDimmed(isDimmed, settings)
    publisher.publishDimState(isBlankingAnyDisplay(), forceReload: true)
}

/// Applies the Control Center Auto Warmth toggle's requested state.
///
/// Only the setting changes here. The scene's `.onChange` on `autoColorTempEnabled` starts or
/// stops the colour temperature manager, exactly as it does when the setting is changed in the
/// menu bar panel. The state is published straight away so the toggle does not wait for the
/// next view update to read it.
@MainActor
func handleWidgetAutoWarmthCommand(
    _ isEnabled: Bool,
    settings: AppSettings,
    publisher: ControlCenterStatePublisher = .live
) {
    settings.autoColorTempEnabled = isEnabled
    publisher.publishAutoWarmthState(settings.autoColorTempEnabled)
    publisher.refreshAutoWarmthToggle()
}

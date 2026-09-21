//
//  ScreenBlanker.swift
//  Dimmerly
//
//  Blanks displays using gamma output and screen-covering overlay windows.
//

import AppKit
import Observation

@MainActor
@Observable
final class ScreenBlanker {
    static let shared = ScreenBlanker()

    /// How far along a global blanking session is, if one is running at all.
    private enum GlobalBlankingPhase: Equatable {
        case none
        /// Fading to black. The set is what the fade targets.
        case fading(Set<CGDirectDisplayID>)
        /// Covered, windows up.
        case blanked(Set<CGDirectDisplayID>)
    }

    /// The whole blanking picture in one value, so the global session, the individually blanked
    /// displays, and the recovery arming can never disagree with one another.
    ///
    /// Global and per-display blanking are tracked side by side rather than as alternatives: a
    /// global blank can start on top of a partial per-display one, and the way out has to restore
    /// both.
    private struct BlankingState: Equatable {
        var global: GlobalBlankingPhase = .none
        /// Displays blanked one at a time, independent of any global session.
        var perDisplayCovered: Set<CGDirectDisplayID> = []
        /// True once every active display is covered per-display and the dismissal monitor is armed.
        var recoveryArmed = false

        var isGlobal: Bool {
            switch global {
            case .none: false
            case .fading, .blanked: true
            }
        }

        /// The displays the global session has put windows up for.
        var globalCovered: Set<CGDirectDisplayID> {
            switch global {
            case .none: []
            case let .fading(ids), let .blanked(ids): ids
            }
        }
    }

    private let inputMonitor: BlankingInputMonitoring
    private let windows: BlankingWindowControlling
    private let gamma: DisplayGammaControlling
    private let cursor: CursorVisibilityControlling
    private let clock: BlankingClock
    private let displays: ActiveDisplayProviding
    private let failurePresenter: @MainActor (BlankingInputMonitorError) -> Void
    private let gracePeriod: TimeInterval

    private var state = BlankingState()
    private var activationTime: TimeInterval = 0
    private var fadeTask: Task<Void, Never>?
    private var isCursorHidden = false

    /// True while a global blanking session is active. Per-display blanking deliberately does not
    /// count: it is dismissed differently and does not gate gamma writes the same way.
    var isBlanking: Bool {
        state.isGlobal
    }

    /// The displays blanked individually. A global session can start on top of these, so this is
    /// not necessarily empty while `isBlanking` is true.
    var blankedDisplayIDs: Set<CGDirectDisplayID> {
        state.perDisplayCovered
    }

    private var isPerDisplayFullBlanked: Bool {
        state.recoveryArmed
    }

    var onDismiss: (() -> Void)?
    var ignoreMouseMovement = false
    var useFadeTransition = false
    var requireEscapeToDismiss = false
    var brightnessForDisplay: ((CGDirectDisplayID) -> Double)?
    var warmthForDisplay: ((CGDirectDisplayID) -> Double)?
    var contrastForDisplay: ((CGDirectDisplayID) -> Double)?
    var restoreDisplay: ((CGDirectDisplayID) -> Void)?

    init(
        inputMonitor: BlankingInputMonitoring = SystemBlankingInputMonitor(),
        windows: BlankingWindowControlling = SystemBlankingWindowController(),
        gamma: DisplayGammaControlling = SystemDisplayGammaController(),
        cursor: CursorVisibilityControlling = SystemCursorVisibilityController(),
        clock: BlankingClock = SystemBlankingClock(),
        displays: ActiveDisplayProviding = SystemActiveDisplayProvider(),
        gracePeriod: TimeInterval = 0.5,
        failurePresenter: @escaping @MainActor (BlankingInputMonitorError) -> Void = { error in
            NSApp.activate()
            let alert = NSAlert()
            alert.messageText = NSLocalizedString(
                "Unable to Filter Wake Input",
                comment: "Blanking input error title"
            )
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            if error.settingsURL != nil {
                alert.addButton(withTitle: NSLocalizedString("Open Accessibility Settings", comment: "Open settings"))
                alert.addButton(withTitle: NSLocalizedString("Cancel", comment: "Cancel button"))
            } else {
                alert.addButton(withTitle: NSLocalizedString("OK", comment: "Alert dismiss button"))
            }
            let response = alert.runModal()
            if response == .alertFirstButtonReturn, let settingsURL = error.settingsURL {
                NSWorkspace.shared.open(settingsURL)
            }
        }
    ) {
        self.inputMonitor = inputMonitor
        self.windows = windows
        self.gamma = gamma
        self.cursor = cursor
        self.clock = clock
        self.displays = displays
        self.gracePeriod = gracePeriod
        self.failurePresenter = failurePresenter
    }

    func blank() {
        guard !isBlanking, !isPerDisplayFullBlanked else { return }
        let displayIDs = displays.activeDisplayIDs
        guard !displayIDs.isEmpty else { return }

        do {
            try startDismissMonitoring(action: { [weak self] in self?.dismiss() })
        } catch let error as BlankingInputMonitorError {
            failurePresenter(error)
            return
        } catch {
            failurePresenter(.unavailable)
            return
        }

        activationTime = clock.now
        let displaySet = Set(displayIDs)
        state.global = useFadeTransition ? .fading(displaySet) : .blanked(displaySet)
        hideCursorIfNeeded()

        if useFadeTransition {
            fadeToBlack(displayIDs)
        } else {
            guard showWindowsAndBlank(displayIDs) else {
                restoreAllAndFinish()
                failurePresenter(.unavailable)
                return
            }
            windows.beginBlankingSession()
        }
    }

    func dismiss(force: Bool = false) {
        if state.isGlobal {
            guard force || clock.now - activationTime >= gracePeriod else { return }
            restoreAllAndFinish()
            return
        }

        // Per-display blanking does not set `isBlanking` until every active display is covered.
        // A forced wake must still clear a partial or fully-covered per-display session.
        guard force, !state.perDisplayCovered.isEmpty else { return }
        forceUnblankAllDisplays()
        onDismiss?()
    }

    func blankDisplay(_ displayID: CGDirectDisplayID) {
        guard !state.isGlobal,
              !state.perDisplayCovered.contains(displayID),
              displays.activeDisplayIDs.contains(displayID),
              displays.hasScreen(for: displayID),
              windows.showWindow(for: displayID, showsEscapeHint: requireEscapeToDismiss)
        else {
            return
        }

        gamma.blank(displayID)
        state.perDisplayCovered.insert(displayID)

        guard Self.shouldEnablePerDisplayRecovery(
            blankedDisplayIDs: state.perDisplayCovered,
            activeDisplayIDs: displays.activeDisplayIDs
        ) else {
            return
        }

        startPerDisplayRecovery()
    }

    func unblankDisplay(_ displayID: CGDirectDisplayID) {
        guard state.perDisplayCovered.contains(displayID) else { return }

        stopPerDisplayRecovery()
        restore(displayID)
        windows.removeWindow(for: displayID)
        state.perDisplayCovered.remove(displayID)
    }

    func isDisplayBlanked(_ displayID: CGDirectDisplayID) -> Bool {
        state.perDisplayCovered.contains(displayID)
    }

    /// Reconciles blanking state after CoreGraphics reports a display topology change.
    ///
    /// A visible display can disappear while another display remains covered. In that case the
    /// remaining covered set may now include every active display and must become recoverable.
    /// Global blanking also needs to remove disconnected windows and cover newly-arrived displays
    /// while the session is still active.
    func displayTopologyDidChange() {
        guard state.isGlobal || !state.perDisplayCovered.isEmpty || state.recoveryArmed else { return }
        let activeDisplayIDs = Set(displays.activeDisplayIDs)

        if state.isGlobal {
            reconcileGlobalBlanking(for: activeDisplayIDs)
            return
        }

        reconcilePerDisplayBlanking(for: activeDisplayIDs)
    }

    private func reconcileGlobalBlanking(for activeDisplayIDs: Set<CGDirectDisplayID>) {
        for displayID in state.globalCovered.subtracting(activeDisplayIDs) {
            windows.removeWindow(for: displayID)
        }

        guard !activeDisplayIDs.isEmpty else {
            restoreAllAndFinish()
            return
        }

        switch state.global {
        case .fading:
            // The fade task owns a snapshot of the old topology. Finish the transition
            // synchronously so a newly-arrived display cannot remain visible during it.
            fadeTask?.cancel()
            fadeTask = nil
            guard showWindowsAndBlank(activeDisplayIDs.sorted()) else {
                restoreAllAndFinish()
                failurePresenter(.unavailable)
                return
            }
            windows.beginBlankingSession()
            state.global = .blanked(activeDisplayIDs)
        case let .blanked(currentlyBlanked):
            let missingDisplayIDs = activeDisplayIDs.subtracting(currentlyBlanked)
            guard missingDisplayIDs.isEmpty || showWindowsAndBlank(missingDisplayIDs.sorted()) else {
                restoreAllAndFinish()
                failurePresenter(.unavailable)
                return
            }
            state.global = .blanked(activeDisplayIDs)
        case .none:
            break
        }
    }

    private func reconcilePerDisplayBlanking(for activeDisplayIDs: Set<CGDirectDisplayID>) {
        let disconnectedDisplayIDs = state.perDisplayCovered.subtracting(activeDisplayIDs)
        for displayID in disconnectedDisplayIDs {
            windows.removeWindow(for: displayID)
        }
        state.perDisplayCovered.subtract(disconnectedDisplayIDs)

        guard !state.perDisplayCovered.isEmpty else {
            stopPerDisplayRecovery()
            return
        }

        let shouldRecover = Self.shouldEnablePerDisplayRecovery(
            blankedDisplayIDs: state.perDisplayCovered,
            activeDisplayIDs: Array(activeDisplayIDs)
        )
        if shouldRecover {
            guard !state.recoveryArmed else { return }
            startPerDisplayRecovery()
        } else {
            stopPerDisplayRecovery()
        }
    }

    static func shouldEnablePerDisplayRecovery(
        blankedDisplayIDs: Set<CGDirectDisplayID>,
        activeDisplayIDs: [CGDirectDisplayID]
    ) -> Bool {
        !activeDisplayIDs.isEmpty && activeDisplayIDs.allSatisfy { blankedDisplayIDs.contains($0) }
    }

    private func startDismissMonitoring(action: @escaping @MainActor () -> Void) throws {
        let policy: BlankingInputPolicy = requireEscapeToDismiss
            ? .escapeOnly
            : .anyInput(ignorePointerMovement: ignoreMouseMovement)

        try inputMonitor.start(
            policy: policy,
            onWake: action,
            onFailure: { [weak self] error in
                self?.handleMonitorFailure(error)
            }
        )
    }

    private func handleMonitorFailure(_ error: BlankingInputMonitorError) {
        if isBlanking {
            restoreAllAndFinish()
        } else if isPerDisplayFullBlanked {
            forceUnblankAllDisplays()
        }
        failurePresenter(error)
    }

    private func showWindowsAndBlank(_ displayIDs: [CGDirectDisplayID]) -> Bool {
        for displayID in displayIDs {
            guard windows.showWindow(
                for: displayID,
                showsEscapeHint: requireEscapeToDismiss
            ) else {
                return false
            }
            gamma.blank(displayID)
        }
        return true
    }

    private func fadeToBlack(_ displayIDs: [CGDirectDisplayID]) {
        fadeTask?.cancel()
        fadeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let steps = 30
            let stepDelay = Duration.milliseconds(500 / steps)

            for step in 1 ... steps {
                guard !Task.isCancelled else { return }
                let progress = Double(step) / Double(steps)

                for displayID in displayIDs {
                    let startBrightness = brightnessForDisplay?(displayID) ?? 1
                    gamma.apply(
                        brightness: startBrightness * (1 - progress),
                        warmth: warmthForDisplay?(displayID) ?? 0,
                        contrast: contrastForDisplay?(displayID) ?? 0.5,
                        to: displayID
                    )
                }

                do {
                    try await clock.sleep(for: stepDelay)
                } catch {
                    return
                }
            }

            guard !Task.isCancelled, state.isGlobal else { return }
            guard showWindowsAndBlank(displayIDs) else {
                restoreAllAndFinish()
                failurePresenter(.unavailable)
                return
            }
            windows.beginBlankingSession()
            state.global = .blanked(Set(displayIDs))
            fadeTask = nil
        }
    }

    private func restoreAllAndFinish() {
        guard state.isGlobal else { return }
        fadeTask?.cancel()
        fadeTask = nil
        inputMonitor.stop()

        // A global session can sit on top of displays that were already blanked individually,
        // so both sets have to be restored. This runs before the state is cleared: `restore`
        // calls out to `restoreDisplay`, which reads `isBlanking` to decide how to re-apply.
        let idsToRestore = Set(displays.activeDisplayIDs).union(state.perDisplayCovered)
        for displayID in idsToRestore.sorted() {
            restore(displayID)
        }

        windows.removeAllWindows()
        windows.endBlankingSession()
        unhideCursorIfNeeded()
        state = BlankingState()
        onDismiss?()
    }

    private func unblankAllDisplays() {
        guard state.recoveryArmed, clock.now - activationTime >= gracePeriod else { return }

        forceUnblankAllDisplays()
        onDismiss?()
    }

    private func forceUnblankAllDisplays() {
        // Only a session that was actually armed has a window session and hidden cursor to undo;
        // a partial per-display session has neither. This cannot delegate to
        // `stopPerDisplayRecovery()`, which would end the window session before the windows come
        // down rather than after.
        let hadArmedSession = state.recoveryArmed
        if hadArmedSession {
            inputMonitor.stop()
        }
        for displayID in state.perDisplayCovered.sorted() {
            restore(displayID)
            windows.removeWindow(for: displayID)
        }
        if hadArmedSession {
            windows.endBlankingSession()
            unhideCursorIfNeeded()
        }
        state = BlankingState()
    }

    /// Mirror of `stopPerDisplayRecovery()`. Arms the dismissal monitor once every active display
    /// is covered, tearing the whole session down if the monitor cannot start.
    private func startPerDisplayRecovery() {
        do {
            try startDismissMonitoring(action: { [weak self] in self?.unblankAllDisplays() })
        } catch let error as BlankingInputMonitorError {
            forceUnblankAllDisplays()
            failurePresenter(error)
            return
        } catch {
            forceUnblankAllDisplays()
            failurePresenter(.unavailable)
            return
        }

        state.recoveryArmed = true
        activationTime = clock.now
        windows.beginBlankingSession()
        hideCursorIfNeeded()
    }

    private func stopPerDisplayRecovery() {
        guard state.recoveryArmed else { return }
        inputMonitor.stop()
        windows.endBlankingSession()
        unhideCursorIfNeeded()
        state.recoveryArmed = false
    }

    private func restore(_ displayID: CGDirectDisplayID) {
        if let restoreDisplay {
            restoreDisplay(displayID)
        } else if brightnessForDisplay != nil || warmthForDisplay != nil || contrastForDisplay != nil {
            gamma.apply(
                brightness: brightnessForDisplay?(displayID) ?? 1,
                warmth: warmthForDisplay?(displayID) ?? 0,
                contrast: contrastForDisplay?(displayID) ?? 0.5,
                to: displayID
            )
        } else {
            gamma.restore(displayID)
        }
    }

    private func hideCursorIfNeeded() {
        guard !isCursorHidden else { return }
        cursor.hide()
        isCursorHidden = true
    }

    private func unhideCursorIfNeeded() {
        guard isCursorHidden else { return }
        cursor.unhide()
        isCursorHidden = false
    }
}

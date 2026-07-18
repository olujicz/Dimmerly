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

    private enum State: Equatable {
        case idle
        case fading(Set<CGDirectDisplayID>)
        case blanked(Set<CGDirectDisplayID>)
        case restoring
    }

    private let inputMonitor: BlankingInputMonitoring
    private let windows: BlankingWindowControlling
    private let gamma: DisplayGammaControlling
    private let cursor: CursorVisibilityControlling
    private let clock: BlankingClock
    private let displays: ActiveDisplayProviding
    private let failurePresenter: @MainActor (BlankingInputMonitorError) -> Void
    private let gracePeriod: TimeInterval

    private var state: State = .idle
    private var activationTime: TimeInterval = 0
    private var fadeTask: Task<Void, Never>?
    private var isCursorHidden = false
    private var isPerDisplayFullBlanked = false

    private(set) var isBlanking = false
    private(set) var blankedDisplayIDs: Set<CGDirectDisplayID> = []

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
        isBlanking = true
        windows.beginBlankingSession()
        hideCursorIfNeeded()

        let displaySet = Set(displayIDs)
        if useFadeTransition {
            state = .fading(displaySet)
            fadeToBlack(displayIDs)
        } else {
            state = .blanked(displaySet)
            guard showWindowsAndBlank(displayIDs) else {
                restoreAllAndFinish()
                failurePresenter(.unavailable)
                return
            }
        }
    }

    func dismiss(force: Bool = false) {
        guard isBlanking else { return }
        guard force || clock.now - activationTime >= gracePeriod else { return }
        restoreAllAndFinish()
    }

    func blankDisplay(_ displayID: CGDirectDisplayID) {
        guard !blankedDisplayIDs.contains(displayID),
              displays.activeDisplayIDs.contains(displayID),
              displays.hasScreen(for: displayID),
              windows.showWindow(for: displayID, showsEscapeHint: requireEscapeToDismiss)
        else {
            return
        }

        gamma.blank(displayID)
        blankedDisplayIDs.insert(displayID)

        guard Self.shouldEnablePerDisplayRecovery(
            blankedDisplayIDs: blankedDisplayIDs,
            activeDisplayIDs: displays.activeDisplayIDs
        ) else {
            return
        }

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

        isPerDisplayFullBlanked = true
        activationTime = clock.now
        windows.beginBlankingSession()
        hideCursorIfNeeded()
    }

    func unblankDisplay(_ displayID: CGDirectDisplayID) {
        guard blankedDisplayIDs.contains(displayID) else { return }

        if isPerDisplayFullBlanked {
            inputMonitor.stop()
            windows.endBlankingSession()
            unhideCursorIfNeeded()
            isPerDisplayFullBlanked = false
        }

        restore(displayID)
        windows.removeWindow(for: displayID)
        blankedDisplayIDs.remove(displayID)
    }

    func isDisplayBlanked(_ displayID: CGDirectDisplayID) -> Bool {
        blankedDisplayIDs.contains(displayID)
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

            guard !Task.isCancelled, isBlanking else { return }
            guard showWindowsAndBlank(displayIDs) else {
                restoreAllAndFinish()
                failurePresenter(.unavailable)
                return
            }
            state = .blanked(Set(displayIDs))
            fadeTask = nil
        }
    }

    private func restoreAllAndFinish() {
        guard isBlanking else { return }
        state = .restoring
        fadeTask?.cancel()
        fadeTask = nil
        inputMonitor.stop()

        let idsToRestore = Set(displays.activeDisplayIDs).union(blankedDisplayIDs)
        for displayID in idsToRestore.sorted() {
            restore(displayID)
        }

        windows.removeAllWindows()
        blankedDisplayIDs.removeAll()
        windows.endBlankingSession()
        unhideCursorIfNeeded()
        isPerDisplayFullBlanked = false
        isBlanking = false
        state = .idle
        onDismiss?()
    }

    private func unblankAllDisplays() {
        guard isPerDisplayFullBlanked,
              clock.now - activationTime >= gracePeriod
        else {
            return
        }

        forceUnblankAllDisplays()
        onDismiss?()
    }

    private func forceUnblankAllDisplays() {
        inputMonitor.stop()
        let idsToUnblank = blankedDisplayIDs.sorted()
        for displayID in idsToUnblank {
            restore(displayID)
            windows.removeWindow(for: displayID)
        }
        blankedDisplayIDs.removeAll()
        windows.endBlankingSession()
        unhideCursorIfNeeded()
        isPerDisplayFullBlanked = false
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

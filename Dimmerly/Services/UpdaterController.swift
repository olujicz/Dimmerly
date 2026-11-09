//
//  UpdaterController.swift
//  Dimmerly
//
//  Update state for the direct-download build: what Settings, the quick actions menu and
//  the menu bar panel show about Sparkle. Sparkle itself sits behind `SoftwareUpdating`
//  (see `SparkleUpdaterBridge`), so this type is tested without Sparkle or the network.
//
//  Sparkle keeps its settings in UserDefaults. This type only mirrors them for SwiftUI
//  and writes them when the user changes a toggle, never at launch.
//

#if !APPSTORE
    import AppKit
    import Foundation
    import Observation
    import OSLog

    private let updaterLogger = Logger(
        subsystem: "rs.in.olujic.dimmerly",
        category: "Updates"
    )

    /// The part of Sparkle's updater that the app uses.
    @MainActor
    protocol SoftwareUpdating: AnyObject {
        var canCheckForUpdates: Bool { get }
        var automaticallyChecksForUpdates: Bool { get set }
        var automaticallyDownloadsUpdates: Bool { get set }
        var lastUpdateCheckDate: Date? { get }
        func startUpdater() throws
        func checkForUpdates()
    }

    @MainActor
    @Observable
    final class UpdaterController {
        private let updater: SoftwareUpdating
        private let activateApp: @MainActor () -> Void

        private(set) var isStarted = false
        private(set) var canCheckForUpdates = false
        private(set) var automaticallyChecksForUpdates = false
        private(set) var automaticallyDownloadsUpdates = false
        private(set) var lastUpdateCheckDate: Date?
        /// A background check found an update that Sparkle didn't show in a window, so the
        /// panel shows a gentle reminder instead of interrupting what the user is doing.
        private(set) var isUpdateReminderPending = false

        init(updater: SoftwareUpdating, activateApp: @escaping @MainActor () -> Void = { NSApp.activate() }) {
            self.updater = updater
            self.activateApp = activateApp
            refresh()
        }

        /// Starts Sparkle's scheduler. Later calls do nothing.
        func start() {
            guard !isStarted else { return }
            do {
                try updater.startUpdater()
                isStarted = true
                refresh()
            } catch {
                updaterLogger.error("Could not start the updater: \(error.localizedDescription, privacy: .public)")
            }
        }

        /// Re-reads Sparkle's state. Never writes to the updater.
        func refresh() {
            canCheckForUpdates = updater.canCheckForUpdates
            automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates
            automaticallyDownloadsUpdates = updater.automaticallyDownloadsUpdates
            lastUpdateCheckDate = updater.lastUpdateCheckDate
        }

        func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
            updater.automaticallyChecksForUpdates = enabled
            automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates
        }

        func setAutomaticallyDownloadsUpdates(_ enabled: Bool) {
            updater.automaticallyDownloadsUpdates = enabled
            automaticallyDownloadsUpdates = updater.automaticallyDownloadsUpdates
        }

        /// A check the user asked for. Dimmerly is usually not the active app, so it's
        /// activated first; otherwise Sparkle's window could open behind other windows.
        func checkForUpdates() {
            activateApp()
            isUpdateReminderPending = false
            updater.checkForUpdates()
        }

        // MARK: - Gentle reminders

        func scheduledUpdateWillShow(userInitiated: Bool, shownBySparkle: Bool) {
            isUpdateReminderPending = !userInitiated && !shownBySparkle
        }

        func userAttendedToUpdate() {
            isUpdateReminderPending = false
        }

        func updateSessionDidFinish() {
            isUpdateReminderPending = false
            refresh()
        }
    }
#endif

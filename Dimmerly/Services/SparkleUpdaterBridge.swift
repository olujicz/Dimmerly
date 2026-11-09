//
//  SparkleUpdaterBridge.swift
//  Dimmerly
//
//  Connects Sparkle's standard updater to `UpdaterController`. This is the only file that
//  imports Sparkle; the App Store build contains neither this file nor the framework.
//
//  Dimmerly is a menu bar app without a Dock icon, so it uses Sparkle's gentle scheduled
//  update reminders: an update found in the background is shown as a row in the menu bar
//  panel instead of a window that could open behind, or over, what the user is doing.
//  https://sparkle-project.org/documentation/gentle-reminders/
//

#if !APPSTORE
    import AppKit
    import Sparkle

    @MainActor
    final class SparkleUpdaterBridge: NSObject, SoftwareUpdating {
        /// Receives Sparkle's events. Weak: the controller owns this bridge.
        weak var controller: UpdaterController?

        // Implicitly unwrapped because the controller needs `self` as its delegates.
        private var standardController: SPUStandardUpdaterController!
        private var observations: [NSKeyValueObservation] = []

        private var updater: SPUUpdater {
            standardController.updater
        }

        override init() {
            super.init()
            standardController = SPUStandardUpdaterController(
                startingUpdater: false,
                updaterDelegate: self,
                userDriverDelegate: self
            )
            // `canCheckForUpdates` changes during a check, and Sparkle changes its two settings
            // itself, e.g. from the "Check for updates automatically?" prompt on the second
            // launch. These are the properties Sparkle documents as KVO-compliant;
            // `lastUpdateCheckDate` isn't, so it's re-read when a session ends and when
            // Settings appears.
            let notify: @Sendable (SPUUpdater, Any) -> Void = { [weak self] _, _ in
                MainActor.assumeIsolated { self?.controller?.refresh() }
            }
            observations = [
                updater.observe(\.canCheckForUpdates, options: [.new], changeHandler: notify),
                updater.observe(\.automaticallyChecksForUpdates, options: [.new], changeHandler: notify),
                updater.observe(\.automaticallyDownloadsUpdates, options: [.new], changeHandler: notify),
            ]
        }

        // MARK: - SoftwareUpdating

        var canCheckForUpdates: Bool {
            updater.canCheckForUpdates
        }

        var automaticallyChecksForUpdates: Bool {
            get { updater.automaticallyChecksForUpdates }
            set { updater.automaticallyChecksForUpdates = newValue }
        }

        var automaticallyDownloadsUpdates: Bool {
            get { updater.automaticallyDownloadsUpdates }
            set { updater.automaticallyDownloadsUpdates = newValue }
        }

        var lastUpdateCheckDate: Date? {
            updater.lastUpdateCheckDate
        }

        func startUpdater() throws {
            try updater.start()
        }

        func checkForUpdates() {
            updater.checkForUpdates()
        }
    }

    // MARK: - SPUUpdaterDelegate

    extension SparkleUpdaterBridge: SPUUpdaterDelegate {
        #if DEBUG
            /// Debug builds can test against a local feed: DIMMERLY_UPDATE_FEED_URL. Release
            /// builds always use SUFeedURL from the Info.plist.
            func feedURLString(for _: SPUUpdater) -> String? {
                ProcessInfo.processInfo.environment["DIMMERLY_UPDATE_FEED_URL"]
            }
        #endif
    }

    // MARK: - SPUStandardUserDriverDelegate

    /// Sparkle calls its standard user driver's delegate on the main thread, but the
    /// protocol isn't annotated for Swift concurrency.
    extension SparkleUpdaterBridge: SPUStandardUserDriverDelegate {
        nonisolated var supportsGentleScheduledUpdateReminders: Bool {
            true
        }

        /// Sparkle only shows a scheduled update right away when it would be in focus anyway,
        /// e.g. just after launch. Otherwise the panel shows a reminder.
        nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(
            _: SUAppcastItem,
            andInImmediateFocus immediateFocus: Bool
        ) -> Bool {
            immediateFocus
        }

        nonisolated func standardUserDriverWillHandleShowingUpdate(
            _ handleShowingUpdate: Bool,
            forUpdate _: SUAppcastItem,
            state: SPUUserUpdateState
        ) {
            let userInitiated = state.userInitiated
            MainActor.assumeIsolated {
                controller?.scheduledUpdateWillShow(userInitiated: userInitiated, shownBySparkle: handleShowingUpdate)
            }
        }

        nonisolated func standardUserDriverDidReceiveUserAttention(forUpdate _: SUAppcastItem) {
            MainActor.assumeIsolated { controller?.userAttendedToUpdate() }
        }

        nonisolated func standardUserDriverWillFinishUpdateSession() {
            MainActor.assumeIsolated { controller?.updateSessionDidFinish() }
        }
    }

    // MARK: - Shared instance

    extension UpdaterController {
        /// The app's updater. Created without starting Sparkle; `AppServices` starts it
        /// during launch setup, which doesn't run while the app hosts unit tests.
        static let shared: UpdaterController = {
            let bridge = SparkleUpdaterBridge()
            let controller = UpdaterController(updater: bridge)
            bridge.controller = controller
            return controller
        }()
    }
#endif

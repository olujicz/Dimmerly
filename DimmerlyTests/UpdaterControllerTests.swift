//
//  UpdaterControllerTests.swift
//  DimmerlyTests
//
//  Tests the update state shown in Settings, the quick actions menu and the panel,
//  against a fake updater so no test touches Sparkle or the network.
//

#if !APPSTORE
    @testable import Dimmerly
    import XCTest

    @MainActor
    final class UpdaterControllerTests: XCTestCase {
        func testInitReadsStateWithoutWritingToTheUpdater() {
            let checked = Date(timeIntervalSince1970: 1_800_000_000)
            let updater = FakeUpdater(
                canCheckForUpdates: true,
                automaticallyChecksForUpdates: true,
                automaticallyDownloadsUpdates: false,
                lastUpdateCheckDate: checked
            )

            let controller = UpdaterController(updater: updater, activateApp: {})

            XCTAssertTrue(controller.canCheckForUpdates)
            XCTAssertTrue(controller.automaticallyChecksForUpdates)
            XCTAssertFalse(controller.automaticallyDownloadsUpdates)
            XCTAssertEqual(controller.lastUpdateCheckDate, checked)
            XCTAssertFalse(controller.isUpdateReminderPending)
            XCTAssertFalse(controller.isStarted)
            XCTAssertEqual(updater.writeCount, 0)
        }

        func testRefreshNeverWritesToTheUpdater() {
            let updater = FakeUpdater()
            let controller = UpdaterController(updater: updater, activateApp: {})

            updater.canCheckForUpdates = false
            updater.storedAutomaticallyChecks = true
            updater.storedAutomaticallyDownloads = true
            updater.lastUpdateCheckDate = Date(timeIntervalSince1970: 1_800_000_000)
            controller.refresh()

            XCTAssertFalse(controller.canCheckForUpdates)
            XCTAssertTrue(controller.automaticallyChecksForUpdates)
            XCTAssertTrue(controller.automaticallyDownloadsUpdates)
            XCTAssertEqual(controller.lastUpdateCheckDate, Date(timeIntervalSince1970: 1_800_000_000))
            XCTAssertEqual(updater.writeCount, 0)
        }

        func testTogglesWriteThroughOnlyWhenSet() {
            let updater = FakeUpdater()
            let controller = UpdaterController(updater: updater, activateApp: {})

            controller.setAutomaticallyChecksForUpdates(true)

            XCTAssertEqual(updater.writeCount, 1)
            XCTAssertTrue(updater.automaticallyChecksForUpdates)
            XCTAssertTrue(controller.automaticallyChecksForUpdates)

            controller.setAutomaticallyDownloadsUpdates(true)

            XCTAssertEqual(updater.writeCount, 2)
            XCTAssertTrue(updater.automaticallyDownloadsUpdates)
            XCTAssertTrue(controller.automaticallyDownloadsUpdates)
        }

        func testStartIsIdempotent() {
            let updater = FakeUpdater()
            let controller = UpdaterController(updater: updater, activateApp: {})

            controller.start()
            controller.start()

            XCTAssertEqual(updater.startCount, 1)
            XCTAssertTrue(controller.isStarted)
        }

        func testStartFailureLeavesControllerStopped() {
            let updater = FakeUpdater()
            updater.startError = FakeUpdater.StartError()
            let controller = UpdaterController(updater: updater, activateApp: {})

            controller.start()

            XCTAssertFalse(controller.isStarted)
        }

        func testCheckForUpdatesActivatesTheAppFirst() {
            var events: [String] = []
            let updater = FakeUpdater()
            updater.onCheck = { events.append("check") }
            let controller = UpdaterController(updater: updater, activateApp: { events.append("activate") })

            controller.checkForUpdates()

            XCTAssertEqual(events, ["activate", "check"])
        }

        func testBackgroundUpdateNotShownBySparkleSetsReminder() {
            let controller = UpdaterController(updater: FakeUpdater(), activateApp: {})

            controller.scheduledUpdateWillShow(userInitiated: false, shownBySparkle: false)

            XCTAssertTrue(controller.isUpdateReminderPending)
        }

        func testUserInitiatedUpdateNeverSetsReminder() {
            let controller = UpdaterController(updater: FakeUpdater(), activateApp: {})

            controller.scheduledUpdateWillShow(userInitiated: true, shownBySparkle: false)

            XCTAssertFalse(controller.isUpdateReminderPending)
        }

        func testUpdateShownBySparkleNeverSetsReminder() {
            let controller = UpdaterController(updater: FakeUpdater(), activateApp: {})

            controller.scheduledUpdateWillShow(userInitiated: false, shownBySparkle: true)

            XCTAssertFalse(controller.isUpdateReminderPending)
        }

        func testReminderClearsWhenUserAttends() {
            let controller = UpdaterController(updater: FakeUpdater(), activateApp: {})
            controller.scheduledUpdateWillShow(userInitiated: false, shownBySparkle: false)

            controller.userAttendedToUpdate()

            XCTAssertFalse(controller.isUpdateReminderPending)
        }

        func testReminderClearsWhenSessionFinishes() {
            let updater = FakeUpdater()
            let controller = UpdaterController(updater: updater, activateApp: {})
            controller.scheduledUpdateWillShow(userInitiated: false, shownBySparkle: false)
            updater.lastUpdateCheckDate = Date(timeIntervalSince1970: 1_800_000_000)

            controller.updateSessionDidFinish()

            XCTAssertFalse(controller.isUpdateReminderPending)
            XCTAssertEqual(controller.lastUpdateCheckDate, Date(timeIntervalSince1970: 1_800_000_000))
        }

        func testPanelShowsTheUpdateRowOnlyWhileAReminderIsPending() {
            let controller = UpdaterController(updater: FakeUpdater(), activateApp: {})

            XCTAssertFalse(MenuBarUpdateRow.isVisible(for: nil))
            XCTAssertFalse(MenuBarUpdateRow.isVisible(for: controller))

            controller.scheduledUpdateWillShow(userInitiated: false, shownBySparkle: false)
            XCTAssertTrue(MenuBarUpdateRow.isVisible(for: controller))

            controller.updateSessionDidFinish()
            XCTAssertFalse(MenuBarUpdateRow.isVisible(for: controller))
        }

        func testCheckForUpdatesClearsReminder() {
            let controller = UpdaterController(updater: FakeUpdater(), activateApp: {})
            controller.scheduledUpdateWillShow(userInitiated: false, shownBySparkle: false)

            controller.checkForUpdates()

            XCTAssertFalse(controller.isUpdateReminderPending)
        }
    }

    @MainActor
    private final class FakeUpdater: SoftwareUpdating {
        struct StartError: Error {}

        var canCheckForUpdates: Bool
        var storedAutomaticallyChecks: Bool
        var storedAutomaticallyDownloads: Bool
        var lastUpdateCheckDate: Date?
        var startError: StartError?
        var onCheck: () -> Void = {}
        private(set) var writeCount = 0
        private(set) var startCount = 0

        init(
            canCheckForUpdates: Bool = true,
            automaticallyChecksForUpdates: Bool = false,
            automaticallyDownloadsUpdates: Bool = false,
            lastUpdateCheckDate: Date? = nil
        ) {
            self.canCheckForUpdates = canCheckForUpdates
            storedAutomaticallyChecks = automaticallyChecksForUpdates
            storedAutomaticallyDownloads = automaticallyDownloadsUpdates
            self.lastUpdateCheckDate = lastUpdateCheckDate
        }

        var automaticallyChecksForUpdates: Bool {
            get { storedAutomaticallyChecks }
            set {
                writeCount += 1
                storedAutomaticallyChecks = newValue
            }
        }

        var automaticallyDownloadsUpdates: Bool {
            get { storedAutomaticallyDownloads }
            set {
                writeCount += 1
                storedAutomaticallyDownloads = newValue
            }
        }

        func startUpdater() throws {
            startCount += 1
            if let startError {
                throw startError
            }
        }

        func checkForUpdates() {
            onCheck()
        }
    }
#endif

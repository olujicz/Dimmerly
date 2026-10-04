@testable import Dimmerly
import XCTest

#if APPSTORE
    @MainActor
    final class AppStoreShortcutManagerTests: XCTestCase {
        private final class Token {}
        private final class RegistrationState {
            var shouldFail = true
        }

        func testMainShortcutRegistersReplacesAndStopsWithoutDeliveringStaleActions() throws {
            var installed: [GlobalShortcut] = []
            var callbacks: [@MainActor () -> Void] = []
            var removals = 0
            let monitor = CarbonShortcutMonitor(
                coordinator: ShortcutRecordingCoordinator(),
                installer: { shortcut, callback in
                    installed.append(shortcut)
                    callbacks.append(callback)
                    return Token()
                },
                remover: { _ in removals += 1 }
            )
            let manager = KeyboardShortcutManager(monitor: monitor)
            let replacement = GlobalShortcut(key: "k", modifiers: [.command, .option, .shift])
            var triggers = 0
            manager.startMonitoring { triggers += 1 }
            XCTAssertEqual(installed, [.default])
            try XCTUnwrap(callbacks.first)()
            XCTAssertEqual(triggers, 1)

            manager.updateShortcut(replacement)
            XCTAssertEqual(manager.currentShortcut, replacement)
            XCTAssertEqual(installed, [.default, replacement])
            callbacks[0]()
            XCTAssertEqual(triggers, 1)
            callbacks[1]()
            XCTAssertEqual(triggers, 2)

            manager.stopMonitoring()
            callbacks[1]()
            XCTAssertEqual(triggers, 2)
            XCTAssertEqual(removals, 2)
        }

        func testMainShortcutReportsFailureAndRetriesConfiguredBinding() {
            let state = RegistrationState()
            var installs = 0
            let monitor = CarbonShortcutMonitor(
                coordinator: ShortcutRecordingCoordinator(),
                installer: { _, _ in
                    installs += 1
                    return state.shouldFail ? nil : Token()
                },
                remover: { _ in }
            )
            let manager = KeyboardShortcutManager(monitor: monitor)
            manager.startMonitoring {}
            XCTAssertTrue(manager.hasRegistrationFailure)
            let previousInstalls = installs
            state.shouldFail = false
            manager.retryFailedRegistrations()
            XCTAssertFalse(manager.hasRegistrationFailure)
            XCTAssertEqual(installs, previousInstalls + 1)
            manager.stopMonitoring()
        }

        func testPresetShortcutDeliversPresetIDAndRemovesDeletedBinding() throws {
            var callbacks: [@MainActor () -> Void] = []
            var removals = 0
            let monitor = CarbonShortcutMonitor(
                coordinator: ShortcutRecordingCoordinator(),
                installer: { _, callback in
                    callbacks.append(callback)
                    return Token()
                },
                remover: { _ in removals += 1 }
            )
            let manager = PresetShortcutManager(monitor: monitor)
            let preset = BrightnessPreset(
                name: "Night",
                shortcut: GlobalShortcut(key: "1", modifiers: [.command, .option, .shift])
            )
            var triggeredIDs: [UUID] = []
            manager.onPresetTriggered = { triggeredIDs.append($0) }
            manager.updateShortcuts(from: [preset, BrightnessPreset(name: "Unassigned")])
            XCTAssertEqual(callbacks.count, 1)
            try XCTUnwrap(callbacks.first)()
            XCTAssertEqual(triggeredIDs, [preset.id])

            var renamed = preset
            renamed.name = "Evening"
            manager.updateShortcuts(from: [renamed])
            XCTAssertEqual(callbacks.count, 1)
            manager.updateShortcuts(from: [])
            callbacks[0]()
            XCTAssertEqual(triggeredIDs, [preset.id])
            XCTAssertEqual(removals, 1)
        }

        func testPresetShortcutReportsFailureAndRetriesWithoutReplacingSuccessfulBinding() {
            let firstShortcut = GlobalShortcut(key: "1", modifiers: [.command, .option, .shift])
            let secondShortcut = GlobalShortcut(key: "2", modifiers: [.command, .option, .shift])
            let state = RegistrationState()
            var installs: [GlobalShortcut] = []
            let monitor = CarbonShortcutMonitor(
                coordinator: ShortcutRecordingCoordinator(),
                installer: { shortcut, _ in
                    installs.append(shortcut)
                    return shortcut == secondShortcut && state.shouldFail ? nil : Token()
                },
                remover: { _ in }
            )
            let manager = PresetShortcutManager(monitor: monitor)
            manager.updateShortcuts(from: [
                BrightnessPreset(name: "Night", shortcut: firstShortcut),
                BrightnessPreset(name: "Day", shortcut: secondShortcut),
            ])
            XCTAssertTrue(manager.hasRegistrationFailure)
            XCTAssertEqual(installs, [firstShortcut, secondShortcut])
            state.shouldFail = false
            manager.retryFailedRegistrations()
            XCTAssertFalse(manager.hasRegistrationFailure)
            XCTAssertEqual(installs, [firstShortcut, secondShortcut, secondShortcut])
            manager.updateShortcuts(from: [])
        }

        func testBothManagersReleaseRegistrationsWhileRecordingAndRestoreLatestBindings() {
            let coordinator = ShortcutRecordingCoordinator()
            var callbacks: [@MainActor () -> Void] = []
            var installed: [GlobalShortcut] = []
            var removals = 0
            func makeMonitor() -> CarbonShortcutMonitor {
                CarbonShortcutMonitor(
                    coordinator: coordinator,
                    installer: { shortcut, callback in
                        installed.append(shortcut)
                        callbacks.append(callback)
                        return Token()
                    },
                    remover: { _ in removals += 1 }
                )
            }
            let mainManager = KeyboardShortcutManager(monitor: makeMonitor())
            let presetManager = PresetShortcutManager(monitor: makeMonitor())
            let preset = BrightnessPreset(
                name: "Night",
                shortcut: GlobalShortcut(key: "1", modifiers: [.command, .option, .shift])
            )
            var mainTriggers = 0
            var presetTriggers = 0
            mainManager.startMonitoring { mainTriggers += 1 }
            presetManager.onPresetTriggered = { _ in presetTriggers += 1 }
            presetManager.updateShortcuts(from: [preset])
            let oldCallbacks = callbacks
            let recorderID = UUID()
            coordinator.setRecording(true, for: recorderID)
            oldCallbacks.forEach { $0() }
            XCTAssertEqual(mainTriggers, 0)
            XCTAssertEqual(presetTriggers, 0)
            XCTAssertEqual(removals, 2)

            let updated = GlobalShortcut(key: "k", modifiers: [.command, .option, .shift])
            mainManager.updateShortcut(updated)
            XCTAssertEqual(callbacks.count, 2)
            coordinator.setRecording(false, for: recorderID)
            XCTAssertEqual(callbacks.count, 4)
            let restored = Array(installed.suffix(2))
            XCTAssertTrue(restored.contains(updated))
            XCTAssertTrue(restored.contains(GlobalShortcut(key: "1", modifiers: [.command, .option, .shift])))
            oldCallbacks.forEach { $0() }
            callbacks.suffix(2).forEach { $0() }
            XCTAssertEqual(mainTriggers, 1)
            XCTAssertEqual(presetTriggers, 1)
            mainManager.stopMonitoring()
            presetManager.updateShortcuts(from: [])
        }

        func testBothManagersRejectUnsafePersistedBindingsAndRecoverAfterEditing() {
            var installed: [GlobalShortcut] = []
            func makeMonitor() -> CarbonShortcutMonitor {
                CarbonShortcutMonitor(
                    coordinator: ShortcutRecordingCoordinator(),
                    installer: { shortcut, _ in
                        installed.append(shortcut)
                        return Token()
                    },
                    remover: { _ in }
                )
            }
            let mainManager = KeyboardShortcutManager(
                shortcut: GlobalShortcut(key: "1", modifiers: [.command]),
                monitor: makeMonitor()
            )
            let presetManager = PresetShortcutManager(monitor: makeMonitor())
            var preset = BrightnessPreset(
                name: "Night",
                shortcut: GlobalShortcut(key: "2", modifiers: [.option])
            )
            mainManager.startMonitoring {}
            presetManager.updateShortcuts(from: [preset])
            mainManager.retryFailedRegistrations()
            presetManager.retryFailedRegistrations()
            XCTAssertTrue(installed.isEmpty)
            XCTAssertTrue(mainManager.hasInvalidShortcuts)
            XCTAssertTrue(presetManager.hasInvalidShortcuts)
            XCTAssertTrue(mainManager.hasRegistrationFailure)
            XCTAssertTrue(presetManager.hasRegistrationFailure)

            let mainShortcut = GlobalShortcut(key: "d", modifiers: [.command, .option, .shift])
            let presetShortcut = GlobalShortcut(key: "2", modifiers: [.command, .option, .shift])
            mainManager.updateShortcut(mainShortcut)
            preset.shortcut = presetShortcut
            presetManager.updateShortcuts(from: [preset])
            XCTAssertEqual(installed, [mainShortcut, presetShortcut])
            XCTAssertFalse(mainManager.hasInvalidShortcuts)
            XCTAssertFalse(presetManager.hasInvalidShortcuts)
            mainManager.stopMonitoring()
            presetManager.updateShortcuts(from: [])
        }
    }
#endif

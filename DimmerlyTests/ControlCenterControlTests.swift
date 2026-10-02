//
//  ControlCenterControlTests.swift
//  DimmerlyTests
//
//  Unit tests for the state the app shares with its Control Center controls, and for the
//  commands those controls send back.
//

@testable import Dimmerly
import XCTest

@MainActor
final class ControlCenterControlTests: XCTestCase {
    private var sharedSuiteName: String!
    private var sharedDefaults: UserDefaults!
    private var settingsSuiteName: String!
    private var settingsDefaults: UserDefaults!
    private var reloadedKinds: [String] = []

    override func setUp() async throws {
        sharedSuiteName = "ControlCenterControlTests-shared-\(UUID().uuidString)"
        sharedDefaults = UserDefaults(suiteName: sharedSuiteName)
        sharedDefaults.removePersistentDomain(forName: sharedSuiteName)
        settingsSuiteName = "ControlCenterControlTests-settings-\(UUID().uuidString)"
        settingsDefaults = UserDefaults(suiteName: settingsSuiteName)
        settingsDefaults.removePersistentDomain(forName: settingsSuiteName)
        reloadedKinds = []
    }

    override func tearDown() async throws {
        sharedDefaults.removePersistentDomain(forName: sharedSuiteName)
        settingsDefaults.removePersistentDomain(forName: settingsSuiteName)
        sharedDefaults = nil
        settingsDefaults = nil
    }

    private func makePublisher() -> ControlCenterStatePublisher {
        ControlCenterStatePublisher(defaults: sharedDefaults) { [weak self] kind in
            self?.reloadedKinds.append(kind)
        }
    }

    // MARK: - Control kinds

    func testControlKindsAreDistinctAndKeepTheShippedDimButtonKind() {
        let kinds = [
            SharedConstants.dimControlKind,
            SharedConstants.dimToggleControlKind,
            SharedConstants.autoWarmthControlKind,
            SharedConstants.presetControlKind,
        ]

        XCTAssertEqual(Set(kinds).count, kinds.count)
        // Changing an existing kind would silently remove the control users already placed.
        XCTAssertEqual(SharedConstants.dimControlKind, "rs.in.olujic.dimmerly.DimControl")
    }

    // MARK: - Published state

    func testPublishedStateReadsAsOffBeforeTheAppPublishesAnything() {
        XCTAssertFalse(SharedConstants.publishedDimState(in: sharedDefaults))
        XCTAssertFalse(SharedConstants.publishedAutoWarmthState(in: sharedDefaults))
        XCTAssertFalse(SharedConstants.publishedDimState(in: nil))
        XCTAssertFalse(SharedConstants.publishedAutoWarmthState(in: nil))
    }

    func testPublishingDimStateStoresValueAndReloadsOnlyOnChange() {
        let publisher = makePublisher()

        publisher.publishDimState(true)
        XCTAssertTrue(SharedConstants.publishedDimState(in: sharedDefaults))
        XCTAssertEqual(reloadedKinds, [SharedConstants.dimToggleControlKind])

        publisher.publishDimState(true)
        XCTAssertEqual(reloadedKinds.count, 1, "An unchanged value should not redraw the control")

        publisher.publishDimState(false)
        XCTAssertFalse(SharedConstants.publishedDimState(in: sharedDefaults))
        XCTAssertEqual(reloadedKinds, [SharedConstants.dimToggleControlKind, SharedConstants.dimToggleControlKind])
    }

    /// The first publish after launch must write even an "off" value, replacing whatever a
    /// previous session that ended abruptly left behind.
    func testFirstPublishOfOffStillReloadsToClearStaleState() {
        sharedDefaults.set(true, forKey: SharedConstants.controlDimStateKey)

        makePublisher().publishDimState(false)

        XCTAssertFalse(SharedConstants.publishedDimState(in: sharedDefaults))
        XCTAssertEqual(reloadedKinds, [SharedConstants.dimToggleControlKind])
    }

    func testPublishingAutoWarmthStateReloadsItsOwnKind() {
        makePublisher().publishAutoWarmthState(true)

        XCTAssertTrue(SharedConstants.publishedAutoWarmthState(in: sharedDefaults))
        XCTAssertFalse(SharedConstants.publishedDimState(in: sharedDefaults))
        XCTAssertEqual(reloadedKinds, [SharedConstants.autoWarmthControlKind])
    }

    func testPublishingWithoutSharedDefaultsIsANoOp() {
        let publisher = ControlCenterStatePublisher(defaults: nil) { [weak self] kind in
            self?.reloadedKinds.append(kind)
        }

        publisher.publishDimState(true)
        publisher.publishAutoWarmthState(true)

        XCTAssertTrue(reloadedKinds.isEmpty)
    }

    // MARK: - Toggle commands

    func testDimStateCommandIsConsumedOnceWithItsValue() {
        SharedConstants.storeWidgetDimStateCommand(false, in: sharedDefaults)

        XCTAssertEqual(SharedConstants.consumeWidgetDimStateCommand(from: sharedDefaults), false)
        XCTAssertNil(SharedConstants.consumeWidgetDimStateCommand(from: sharedDefaults))
    }

    func testAutoWarmthCommandIsConsumedOnceWithItsValue() {
        SharedConstants.storeWidgetAutoWarmthCommand(true, in: sharedDefaults)

        XCTAssertEqual(SharedConstants.consumeWidgetAutoWarmthCommand(from: sharedDefaults), true)
        XCTAssertNil(SharedConstants.consumeWidgetAutoWarmthCommand(from: sharedDefaults))
    }

    func testMalformedToggleCommandIsClearedAndIgnored() {
        sharedDefaults.set("yes", forKey: SharedConstants.widgetDimStateCommandKey)

        XCTAssertNil(SharedConstants.consumeWidgetDimStateCommand(from: sharedDefaults))
        XCTAssertNil(sharedDefaults.object(forKey: SharedConstants.widgetDimStateCommandKey))
    }

    func testToggleCommandHelpersDegradeToNoOpWithoutSharedDefaults() {
        SharedConstants.storeWidgetDimStateCommand(true, in: nil)
        SharedConstants.storeWidgetAutoWarmthCommand(true, in: nil)

        XCTAssertNil(SharedConstants.consumeWidgetDimStateCommand(from: nil))
        XCTAssertNil(SharedConstants.consumeWidgetAutoWarmthCommand(from: nil))
    }

    func testDimStateCommandAppliesRequestedStateAndAlwaysRedrawsToggle() {
        let settings = AppSettings(defaults: settingsDefaults)
        var requested: [Bool] = []

        handleWidgetDimStateCommand(
            settings: settings,
            consumeCommand: { true },
            setDimmed: { isDimmed, _ in requested.append(isDimmed) },
            publisher: makePublisher()
        )

        XCTAssertEqual(requested, [true])
        // Real display sleep leaves the published state unchanged, so the redraw cannot wait
        // for a state change or the toggle would stay on.
        XCTAssertEqual(reloadedKinds, [SharedConstants.dimToggleControlKind])
    }

    func testDimStateCommandIgnoresMissingCommand() {
        var requested: [Bool] = []

        handleWidgetDimStateCommand(
            settings: AppSettings(defaults: settingsDefaults),
            consumeCommand: { nil },
            setDimmed: { isDimmed, _ in requested.append(isDimmed) },
            publisher: makePublisher()
        )

        XCTAssertTrue(requested.isEmpty)
        XCTAssertTrue(reloadedKinds.isEmpty)
    }

    func testAutoWarmthCommandUpdatesSettingAndPublishesIt() {
        let settings = AppSettings(defaults: settingsDefaults)
        settings.autoColorTempEnabled = false

        handleWidgetAutoWarmthCommand(settings: settings, consumeCommand: { true }, publisher: makePublisher())

        XCTAssertTrue(settings.autoColorTempEnabled)
        XCTAssertTrue(settingsDefaults.bool(forKey: AppSettings.autoColorTempEnabledKey))
        XCTAssertTrue(SharedConstants.publishedAutoWarmthState(in: sharedDefaults))
        XCTAssertEqual(reloadedKinds.last, SharedConstants.autoWarmthControlKind)
    }

    func testAutoWarmthCommandIgnoresMissingCommand() {
        let settings = AppSettings(defaults: settingsDefaults)
        settings.autoColorTempEnabled = true

        handleWidgetAutoWarmthCommand(settings: settings, consumeCommand: { nil }, publisher: makePublisher())

        XCTAssertTrue(settings.autoColorTempEnabled)
        XCTAssertTrue(reloadedKinds.isEmpty)
    }

    // MARK: - Toggle intents

    func testToggleIntentsCarryTheirRequestedValue() {
        XCTAssertTrue(SetDimmingWidgetIntent(value: true).value)
        XCTAssertFalse(SetAutoWarmthWidgetIntent(value: false).value)
        XCTAssertFalse(SetDimmingWidgetIntent.isDiscoverable)
        XCTAssertFalse(SetAutoWarmthWidgetIntent.isDiscoverable)
    }

    // MARK: - Preset control

    private func storeWidgetPresets(_ presets: [WidgetPresetInfo]) throws {
        try sharedDefaults.set(JSONEncoder().encode(presets), forKey: SharedConstants.widgetPresetsKey)
    }

    func testWidgetPresetsDecodeInSharedOrder() throws {
        let presets = [
            WidgetPresetInfo(id: UUID().uuidString, name: "Work"),
            WidgetPresetInfo(id: UUID().uuidString, name: "Movie Night"),
        ]
        try storeWidgetPresets(presets)

        XCTAssertEqual(SharedConstants.widgetPresets(in: sharedDefaults), presets)
    }

    func testWidgetPresetsReadAsEmptyWhenMissingOrCorrupt() {
        XCTAssertTrue(SharedConstants.widgetPresets(in: sharedDefaults).isEmpty)
        XCTAssertTrue(SharedConstants.widgetPresets(in: nil).isEmpty)

        sharedDefaults.set(Data("not json".utf8), forKey: SharedConstants.widgetPresetsKey)
        XCTAssertTrue(SharedConstants.widgetPresets(in: sharedDefaults).isEmpty)
    }

    func testChosenPresetResolvesAgainstTheCurrentList() throws {
        let id = UUID().uuidString
        try storeWidgetPresets([WidgetPresetInfo(id: id, name: "Work")])
        XCTAssertEqual(SharedConstants.widgetPreset(withID: id, in: sharedDefaults)?.name, "Work")

        // A rename in the app shows up without reconfiguring the control.
        try storeWidgetPresets([WidgetPresetInfo(id: id, name: "Focus")])
        XCTAssertEqual(SharedConstants.widgetPreset(withID: id, in: sharedDefaults)?.name, "Focus")
    }

    func testUnchosenOrDeletedPresetResolvesToNil() throws {
        try storeWidgetPresets([WidgetPresetInfo(id: UUID().uuidString, name: "Work")])

        XCTAssertNil(SharedConstants.widgetPreset(withID: nil, in: sharedDefaults))
        XCTAssertNil(SharedConstants.widgetPreset(withID: UUID().uuidString, in: sharedDefaults))
    }

    func testPresetControlRefreshReloadsPresetKind() {
        makePublisher().refreshPresetControls()

        XCTAssertEqual(reloadedKinds, [SharedConstants.presetControlKind])
    }
}

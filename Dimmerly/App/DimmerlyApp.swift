//
//  DimmerlyApp.swift
//  Dimmerly
//
//  Main application entry point.
//  Provides menu bar interface and settings window.
//

import AppKit
import MenuBarExtraAccess
import SwiftUI

/// How long after a request's deadline its acknowledgement may still be read. The extension
/// checks once more right after its deadline passes, then removes its keys and stops reading.
let widgetActionAcknowledgementGrace: TimeInterval = 5

/// An acknowledgement follows the action and its state publication, never just receipt.
/// `performCommand` returns whether it did the action; the acknowledgement carries that result.
///
/// The extension removes the acknowledgement when it stops waiting. One written after that
/// (an action that outlasted the deadline, or an extension that was cancelled) would stay until
/// the next launch, so the app removes it itself once the extension can no longer be reading it.
/// `scheduleRemoval` runs the removal at the given date.
@MainActor
func handleWidgetActionRequest(
    _ id: UUID,
    defaults: UserDefaults? = SharedConstants.sharedDefaults,
    now: Date = Date(),
    scheduleRemoval: (Date, @escaping @MainActor () -> Void) -> Void = runOnMainActor(at:_:),
    performCommand: (WidgetActionCommand) -> Bool
) {
    guard let defaults,
          let request = SharedConstants.consumeWidgetActionRequest(id, from: defaults, now: now)
    else { return }
    let succeeded = performCommand(request.command)
    SharedConstants.acknowledgeWidgetAction(id, succeeded: succeeded, in: defaults)
    scheduleRemoval(request.expiresAt.addingTimeInterval(widgetActionAcknowledgementGrace)) {
        SharedConstants.removeWidgetActionAcknowledgement(id, from: defaults)
    }
}

/// Runs `work` on the main actor at `date`, or right away if `date` has passed.
func runOnMainActor(at date: Date, _ work: @escaping @MainActor () -> Void) {
    Task { @MainActor in
        try? await Task.sleep(for: .seconds(max(0, date.timeIntervalSinceNow)))
        work()
    }
}

@main
struct DimmerlyApp: App {
    /// Handles `dimmerly://` URLs from the widget and runs launch setup.
    @NSApplicationDelegateAdaptor(DimmerlyAppDelegate.self) private var appDelegate

    /// Managers and observers that must exist whether or not any view appears.
    private var services: AppServices {
        appDelegate.services
    }

    /// Application settings shared across all views
    @State private var settings = AppSettings.shared

    /// Manager for external display brightness
    @State private var brightnessManager = BrightnessManager.shared

    /// Manager for brightness presets
    @State private var presetManager = PresetManager.shared

    /// Provider for location data (solar calculations)
    @State private var locationProvider = LocationProvider.shared

    /// Manager for automatic color temperature adjustment
    @State private var colorTempManager = ColorTemperatureManager.shared

    #if !APPSTORE
        /// Manager for DDC/CI hardware display control (direct distribution only)
        @State private var hardwareManager = HardwareBrightnessManager.shared

        /// Sparkle update state (direct distribution only; the App Store updates the App Store edition)
        @State private var updaterController = UpdaterController.shared
    #endif

    /// Coordinates programmatic menu panel presentation, including Spotlight preset selection.
    @State private var menuBarPanelCoordinator = MenuBarPanelCoordinator.shared

    /// Handles the right-click quick actions menu on the status bar icon.
    @State private var statusItemQuickActions = StatusItemQuickActions()

    /// Reports on the status item whether Dimmerly is currently adjusting the displays.
    @State private var statusItemAccessibility = StatusItemAccessibility()

    @Environment(\.openSettings) private var openSettings

    /// Blanking state, observed so the Control Center dim toggle can follow it.
    @State private var screenBlanker = ScreenBlanker.shared

    var body: some Scene {
        @Bindable var menuBarPanelCoordinator = menuBarPanelCoordinator

        // Menu bar extra (the main interface) — window style preserves slider controls.
        MenuBarExtra {
            menuBarPanel(selectedPresetID: menuBarPanelCoordinator.requestedPresetID)
        } label: {
            MenuBarStatusLabel(
                settings: settings,
                brightnessManager: brightnessManager,
                statusItemAccessibility: statusItemAccessibility
            )
            // Launch setup, including the initial sync of these managers, runs once in
            // `AppServices.configure()` from `applicationDidFinishLaunching`. These
            // handlers only follow later edits to the settings.
            .onChange(of: menuBarPanelCoordinator.isPresented) { _, isPresented in
                if !isPresented {
                    menuBarPanelCoordinator.requestedPresetID = nil
                }
            }
            .onChange(of: settings.idleTimerEnabled) { _, _ in
                services.idleTimerManager.apply(
                    enabled: settings.idleTimerEnabled,
                    thresholdMinutes: settings.idleTimerMinutes
                )
            }
            .onChange(of: settings.idleTimerMinutes) { _, _ in
                services.idleTimerManager.apply(
                    enabled: settings.idleTimerEnabled,
                    thresholdMinutes: settings.idleTimerMinutes
                )
            }
            .onChange(of: settings.scheduleEnabled) { _, _ in
                services.scheduleManager.apply(enabled: settings.scheduleEnabled)
            }
            .onChange(of: settings.autoColorTempEnabled) { _, _ in
                colorTempManager.apply(enabled: settings.autoColorTempEnabled)
                ControlCenterStatePublisher.live.publishAutoWarmthState(settings.autoColorTempEnabled)
            }
            .onChange(of: settings.preventScreenLock) { _, _ in
                ControlCenterStatePublisher.live.publishDisplayOffMode(DisplayAction.offMode(settings: settings))
            }
            .onChange(of: screenBlanker.isBlankingAnyDisplay) { _, isBlanking in
                ControlCenterStatePublisher.live.publishDimState(isBlanking)
            }
            .onChange(of: presetManager.presets) { _, newValue in
                services.presetShortcutManager.updateShortcuts(from: newValue)
                AppEntityIndexingService.shared.reindexPresets(newValue)
            }
        }
        .menuBarExtraAccess(isPresented: $menuBarPanelCoordinator.isPresented) { statusItem in
            let panelPresenter = MenuBarPanelPresenter.shared
            panelPresenter.configure(
                statusItem: statusItem,
                contentBuilder: { selectedPresetID in
                    MenuBarPanelPresenter.hostingController(for: menuBarPanel(selectedPresetID: selectedPresetID))
                },
                didDismiss: {
                    menuBarPanelCoordinator.externalPresentationDidDismiss()
                }
            )
            menuBarPanelCoordinator.configureExternalPresentation(
                present: { presetID in
                    panelPresenter.present(selectedPresetID: presetID)
                },
                dismiss: {
                    panelPresenter.dismiss()
                }
            )
            menuBarPanelCoordinator.configureSystemPanelSession { [weak statusItem] in
                #if compiler(>=6.4)
                    if #available(macOS 27.0, *), let session = statusItem?.expandedInterfaceSession {
                        session.cancel()
                        return true
                    }
                #endif
                return false
            }
            menuBarPanelCoordinator.configureHiddenStatusItemFallback(
                isStatusItemReachable: { [weak statusItem] in StatusItemReachability.isReachable(statusItem) },
                openSettings: openSettingsWindow
            )
            statusItemQuickActions.configure(
                statusItem: statusItem,
                settings: settings,
                performSleep: { DisplayAction.performSleep(settings: settings) },
                openSettings: openSettingsWindow
            )
            #if !APPSTORE
                statusItemQuickActions.configureUpdates(
                    checkForUpdates: { updaterController.checkForUpdates() },
                    canCheckForUpdates: { updaterController.canCheckForUpdates }
                )
            #endif
            statusItemAccessibility.attach(to: statusItem)
            #if DEBUG
                ScreenshotStage.statusItemDidAttach(openSettings: openSettingsWindow)
            #endif
        }
        .menuBarExtraStyle(.window)

        // Settings window
        Settings {
            SettingsView()
                .environment(settings)
                .environment(services.shortcutManager)
                .environment(services.presetShortcutManager)
                .environment(presetManager)
                .environment(brightnessManager)
                .environment(services.scheduleManager)
                .environment(locationProvider)
                .environment(colorTempManager)
            #if !APPSTORE
                .environment(hardwareManager)
                .environment(updaterController)
            #endif
        }
    }

    /// The menu bar panel with its environment, shared by the MenuBarExtra and the
    /// externally presented panel.
    private func menuBarPanel(selectedPresetID: UUID?) -> some View {
        MenuBarPanel(selectedPresetID: selectedPresetID, openSettingsAction: openSettingsWindow)
            .environment(settings)
            .environment(brightnessManager)
            .environment(presetManager)
            .environment(colorTempManager)
        #if !APPSTORE
            .environment(hardwareManager)
            .environment(updaterController)
        #endif
            .environment(\.closeMenuBarPanel) { menuBarPanelCoordinator.dismiss() }
    }

    private func openSettingsWindow() {
        openSettings()
        NSApp.activate()
    }
}

/// Menu bar icon view that adapts to the user's selected icon style, and to
/// whether Dimmerly is currently affecting the displays.
///
/// Displays either a system SF Symbol or one of Dimmerly's custom symbols from the asset
/// catalog. Custom styles that define an active variant switch to it while displays are
/// being adjusted.
///
/// The label is handed to AppKit as a flat status item image, so it cannot carry an
/// accessibility value or a symbol content transition: SwiftUI forwards only the
/// accessibility label, and swaps the image in a single step. The value is set on the
/// status item itself by `StatusItemAccessibility`.
///
/// This is a separate view rather than part of the scene body because
/// `isAffectingDisplays` is derived from every display's brightness, warmth and contrast.
/// Reading it in `DimmerlyApp.body` would re-evaluate the whole scene on each slider tick.
struct MenuBarStatusLabel: View {
    let settings: AppSettings
    let brightnessManager: BrightnessManager
    let statusItemAccessibility: StatusItemAccessibility

    var body: some View {
        icon
            .onChange(of: brightnessManager.isAffectingDisplays, initial: true) { _, isAffecting in
                statusItemAccessibility.update(isAffectingDisplays: isAffecting)
            }
    }

    @ViewBuilder
    private var icon: some View {
        if let systemImage = settings.menuBarIcon.systemImageName {
            Image(systemName: systemImage)
                .accessibilityLabel("Dimmerly")
        } else {
            Image(settings.menuBarIcon
                .resolvedAssetName(isActive: brightnessManager.isAffectingDisplays) ?? "MenuBarIcon")
                .accessibilityLabel("Dimmerly")
        }
    }
}

/// The `dimmerly://` URLs the app responds to.
enum DimmerlyURL {
    /// Sent by a tap on the widget outside its buttons.
    static let openPanel = URL(string: "dimmerly://open")!

    static func opensPanel(_ url: URL) -> Bool {
        url.scheme?.lowercased() == openPanel.scheme && url.host()?.lowercased() == openPanel.host()
    }
}

/// Owns the app-lifetime managers and runs launch setup once, from
/// `applicationDidFinishLaunching`, so none of it depends on a view appearing.
/// The scenes read the managers from here and pass them on through `.environment(_:)`.
@MainActor
final class AppServices {
    let shortcutManager = KeyboardShortcutManager()
    let presetShortcutManager = PresetShortcutManager()
    #if DEBUG
        /// Screenshot runs (`DIMMERLY_SCREENSHOT`) get staged schedules; see `ScreenshotStage`.
        let scheduleManager = ScreenshotStage.isActive ? ScreenshotStage.makeScheduleManager() : ScheduleManager()
    #else
        let scheduleManager = ScheduleManager()
    #endif
    /// Not @Observable: held for its lifecycle only.
    let idleTimerManager = IdleTimerManager()

    private let settings = AppSettings.shared
    private let presetManager = PresetManager.shared
    private let brightnessManager = BrightnessManager.shared
    private let colorTempManager = ColorTemperatureManager.shared
    #if !APPSTORE
        private let hardwareManager = HardwareBrightnessManager.shared
    #endif

    /// Replaces the launch setup in tests, which must not touch hotkeys or displays.
    private let launchSetupOverride: (() -> Void)?

    private(set) var isConfigured = false

    init(launchSetupOverride: (() -> Void)? = nil) {
        self.launchSetupOverride = launchSetupOverride
    }

    /// Runs launch setup. Later calls do nothing, so observers are registered once.
    func configure() {
        guard !isConfigured else { return }
        isConfigured = true
        if let launchSetupOverride {
            launchSetupOverride()
        } else {
            performLaunchSetup()
        }
    }

    private func performLaunchSetup() {
        // Load saved shortcut before starting monitoring
        shortcutManager.updateShortcut(settings.keyboardShortcut)
        startGlobalShortcutMonitoring()
        configureIdleTimer()
        configurePresetShortcuts()
        configureScheduleManager()
        observeWidgetActionRequests()
        observeTermination()
        SharedConstants.discardLegacyWidgetCommands()
        SharedConstants.discardStaleWidgetActionKeys()
        AppEntityIndexingService.shared.reindexPresets(presetManager.presets)
        // Initial sync for settings-driven managers. `.onChange` in the scene body
        // keeps them current for subsequent edits without needing each
        // manager to observe UserDefaults directly.
        syncManagerStateFromSettings()
        #if !APPSTORE
            configureHardwareControl()
            UpdaterController.shared.start()
        #endif
    }

    /// Configures the global keyboard shortcut monitor to trigger display sleep.
    ///
    /// The shortcut is loaded from settings before monitoring starts.
    /// App Store builds register Carbon hotkeys without requiring special permissions.
    private func startGlobalShortcutMonitoring() {
        shortcutManager.startMonitoring { [settings] in
            DisplayAction.performSleep(settings: settings)
        }
    }

    /// Wires the idle-timer callback. Actual start/stop is driven by `.onChange(of:)`
    /// on `settings.idleTimerEnabled` / `.idleTimerMinutes` in the app's scene body, plus
    /// a one-time `syncManagerStateFromSettings()` at launch.
    private func configureIdleTimer() {
        idleTimerManager.onIdleThresholdReached = { [settings] in
            DisplayAction.performSleep(settings: settings)
        }
    }

    /// Observes action requests from the widget and Control Center extension.
    ///
    /// The extension runs in a separate process. It enqueues a `WidgetActionRequest` in the shared
    /// UserDefaults container and posts a distributed notification carrying the request ID; the app
    /// performs the request and writes an acknowledgement the extension waits for.
    ///
    /// The notification center keeps this observer alive for the lifetime of the app.
    private func observeWidgetActionRequests() {
        _ = DistributedNotificationCenter.default().addObserver(
            forName: SharedConstants.widgetActionNotification,
            object: nil, queue: .main
        ) { [settings] notification in
            guard let idString = notification.object as? String, let id = UUID(uuidString: idString) else { return }
            MainActor.assumeIsolated {
                handleWidgetActionRequest(id) { $0.performInApp(settings: settings) }
            }
        }
    }

    /// Blanking cannot outlive the app, so the dim toggle must not keep showing it as on.
    /// Display values changed in the last moments before quitting are saved right away.
    private func observeTermination() {
        _ = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil, queue: .main
        ) { [brightnessManager] _ in
            MainActor.assumeIsolated {
                brightnessManager.flushPendingPersistence()
                ControlCenterStatePublisher.live.publishDimState(false)
            }
        }
    }

    /// Wires the schedule-triggered callback. `.onChange` on `settings.scheduleEnabled`
    /// handles start/stop; the one-time sync in `syncManagerStateFromSettings` handles launch.
    private func configureScheduleManager() {
        scheduleManager.onScheduleTriggered = { [presetManager, brightnessManager] presetID in
            presetManager.applyPreset(id: presetID, to: brightnessManager, animated: true)
        }
    }

    /// Wires the preset-shortcut-triggered callback. `.onChange` on `presetManager.presets`
    /// handles re-registration whenever presets/shortcuts change.
    private func configurePresetShortcuts() {
        presetShortcutManager.onPresetTriggered = { [presetManager, brightnessManager] presetID in
            presetManager.applyPreset(id: presetID, to: brightnessManager, animated: true)
        }
    }

    /// One-time sync of settings-driven managers at app launch.
    ///
    /// `.onChange` modifiers only fire when a value changes, so we need this initial pass
    /// to pick up whatever state was persisted from the previous session.
    private func syncManagerStateFromSettings() {
        idleTimerManager.apply(
            enabled: settings.idleTimerEnabled,
            thresholdMinutes: settings.idleTimerMinutes
        )
        scheduleManager.apply(enabled: settings.scheduleEnabled)
        colorTempManager.apply(enabled: settings.autoColorTempEnabled)
        ControlCenterStatePublisher.live.publishAutoWarmthState(settings.autoColorTempEnabled)
        ControlCenterStatePublisher.live.publishDisplayOffMode(DisplayAction.offMode(settings: settings))
        // The dim toggle's later changes are published from the scene's `.onChange`.
        ControlCenterStatePublisher.live.publishDimState(ScreenBlanker.shared.isBlankingAnyDisplay)
        presetShortcutManager.updateShortcuts(from: presetManager.presets)
    }

    // MARK: - Hardware Control (DDC/CI)

    #if !APPSTORE
        /// Configures DDC/CI hardware display control for the direct distribution build.
        ///
        /// Sets up:
        /// 1. Initial DDC probe if hardware control was previously enabled
        /// 2. Syncs control mode and polling interval from settings
        /// 3. Starts background polling for OSD-initiated hardware changes
        ///
        /// DDC requires IOKit access incompatible with the App Sandbox, so this
        /// method is only compiled in direct distribution builds.
        private func configureHardwareControl() {
            guard settings.ddcEnabled else { return }
            hardwareManager.enable()
            hardwareManager.applyRuntimeSettings(
                controlMode: settings.ddcControlMode,
                pollingInterval: settings.ddcPollingInterval,
                writeDelayMilliseconds: settings.ddcWriteDelay,
                experimentalNativeBrightnessEnabled: settings.experimentalNativeBrightnessEnabled
            )
            // Nothing has been probed yet, so this refresh probes every external display
            // (with the automatic retries a still-starting DDC service needs).
            BrightnessManager.shared.refreshDisplays()
            hardwareManager.startPolling()
        }
    #endif
}

/// Receives `dimmerly://` URLs. Dimmerly has no window scene for `onOpenURL`, so the
/// app delegate is the one place that sees them, including the URL that launches the app.
///
/// It also owns `AppServices`, created once with the delegate, and configures it when
/// launching finishes.
@MainActor
final class DimmerlyAppDelegate: NSObject, NSApplicationDelegate {
    let services: AppServices
    /// When the app only hosts the unit tests, launch setup is skipped so a test run doesn't
    /// apply schedules, color temperature, or hardware control to the developer's displays.
    private let isHostingUnitTests: Bool

    init(
        services: AppServices,
        isHostingUnitTests: Bool = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    ) {
        self.services = services
        self.isHostingUnitTests = isHostingUnitTests
        super.init()
    }

    override convenience init() {
        self.init(services: AppServices())
    }

    func applicationDidFinishLaunching(_: Notification) {
        guard !isHostingUnitTests else { return }
        #if DEBUG
            // A screenshot run shows staged windows only; it must not register shortcuts,
            // run schedules, answer widget requests, or publish Control Center state.
            guard !ScreenshotStage.isActive else { return }
        #endif
        services.configure()
    }

    func application(_: NSApplication, open urls: [URL]) {
        guard urls.contains(where: DimmerlyURL.opensPanel) else { return }
        MenuBarPanelCoordinator.shared.openPanel()
    }

    /// Opening Dimmerly again from Finder, Spotlight or Launchpad shows the panel, or Settings
    /// while the status item is hidden, so the app can always be reached.
    func applicationShouldHandleReopen(_: NSApplication, hasVisibleWindows _: Bool) -> Bool {
        MenuBarPanelCoordinator.shared.openPanel()
        return false
    }
}

/// Tells VoiceOver whether Dimmerly is currently adjusting the displays, as the
/// accessibility value of the status item ("Dimmerly, Adjusting displays").
///
/// Only the default icon style shows this state, so the value carries it whatever icon
/// is chosen. `MenuBarExtra` drops an `.accessibilityValue` set on its label, so the
/// value goes straight onto the status item's button, which SwiftUI leaves alone when
/// it redraws the label.
@MainActor
final class StatusItemAccessibility {
    private var button: () -> NSButton? = { nil }
    private var isAffectingDisplays = false

    /// Starts reporting on `statusItem`. The button is looked up on each update rather
    /// than captured, in case `MenuBarExtraAccess` ever hands over a recreated one.
    func attach(to statusItem: NSStatusItem) {
        attach(button: { [weak statusItem] in statusItem?.button })
    }

    func attach(button: @escaping () -> NSButton?) {
        self.button = button
        apply()
    }

    func update(isAffectingDisplays: Bool) {
        self.isAffectingDisplays = isAffectingDisplays
        apply()
    }

    static func value(isAffectingDisplays: Bool) -> String {
        isAffectingDisplays
            ? String(
                localized: "Adjusting displays",
                comment: "Menu bar item accessibility value while Dimmerly is dimming, warming, or changing contrast"
            )
            : String(
                localized: "Not adjusting displays",
                comment: "Menu bar item accessibility value while Dimmerly leaves every display untouched"
            )
    }

    private func apply() {
        button()?.setAccessibilityValue(Self.value(isAffectingDisplays: isAffectingDisplays))
    }
}

/// Selects the menu presentation path supported by the current macOS release.
enum StatusItemQuickActionsPresentation: Equatable {
    case contextMenu
    case statusItemMenu

    static var current: Self {
        if #available(macOS 27.0, *) {
            .contextMenu
        } else {
            .statusItemMenu
        }
    }
}

/// Attaches a right-click quick-actions menu to the status bar icon, using the
/// `NSStatusItem` exposed by `MenuBarExtraAccess`. A local event monitor detects
/// right-clicks on the button specifically so left-clicks keep opening the panel
/// exactly as `MenuBarExtra` already handles it.
@MainActor
final class StatusItemQuickActions: NSObject {
    private var statusItem: NSStatusItem?
    private var rightClickMonitor: Any?
    private var settings: AppSettings?
    private var performSleep: (() -> Void)?
    private var openSettings: (() -> Void)?
    private var checkForUpdates: (@MainActor () -> Void)?
    private var canCheckForUpdates: (@MainActor () -> Bool)?

    func configure(
        statusItem: NSStatusItem,
        settings: AppSettings,
        performSleep: @escaping () -> Void,
        openSettings: @escaping () -> Void
    ) {
        self.statusItem = statusItem
        self.settings = settings
        self.performSleep = performSleep
        self.openSettings = openSettings

        guard rightClickMonitor == nil, statusItem.button != nil else { return }

        // Resolve the button from `self.statusItem` (updated every `configure()` call)
        // inside the closure, rather than capturing today's button in a local — if
        // MenuBarExtraAccess ever hands over a recreated NSStatusItem/button, the
        // `rightClickMonitor == nil` guard above skips re-registering the monitor, so a
        // captured button would go stale and right-click quick actions would silently
        // stop matching the real (new) button's window.
        //
        // Also matches Control-click (a `.leftMouseDown` with the `.control` modifier) —
        // the canonical secondary-click alternative on macOS, and the only option for
        // users with right-click/secondary-click disabled. A plain left-click (no
        // Control) passes through unmodified so the normal panel toggle still runs.
        rightClickMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.rightMouseDown, .leftMouseDown]
        ) { [weak self] event in
            guard let self, let currentButton = self.statusItem?.button, event.window === currentButton.window
            else { return event }

            let isControlClick = event.type == .leftMouseDown && event.modifierFlags.contains(.control)
            guard event.type == .rightMouseDown || isControlClick else { return event }

            showQuickActionsMenu(for: event, in: currentButton)
            return nil
        }
    }

    /// Wires "Check for Updates…" (direct-download build only). Separate from `configure()`
    /// so the item can be tested without a live `NSStatusItem`.
    func configureUpdates(
        checkForUpdates: @escaping @MainActor () -> Void,
        canCheckForUpdates: @escaping @MainActor () -> Bool
    ) {
        self.checkForUpdates = checkForUpdates
        self.canCheckForUpdates = canCheckForUpdates
    }

    private func showQuickActionsMenu(for event: NSEvent, in button: NSStatusBarButton) {
        guard let statusItem, let settings else { return }

        let menu = makeQuickActionsMenu(turnOffTitle: Self.turnOffTitle(settings: settings))

        switch StatusItemQuickActionsPresentation.current {
        case .contextMenu:
            // macOS 27 no longer routes window-based MenuBarExtra clicks through
            // the status item's target/action. Pop up this independent menu
            // directly so quick actions do not depend on that presentation path.
            NSMenu.popUpContextMenu(menu, with: event, for: button)
        case .statusItemMenu:
            // Temporarily assign the menu so this click shows it, then clear it so
            // subsequent left-clicks keep going through the normal panel toggle.
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        }
    }

    /// Title matches the primary panel button's wording (`turnOffButtonContent` in
    /// `MenuBarPanel`), so the quick-actions menu never disagrees with the panel.
    static func turnOffTitle(settings: AppSettings) -> String {
        switch DisplayAction.offMode(settings: settings) {
        case .dim:
            String(localized: "Dim Displays", comment: "Quick actions menu: dim all displays")
        case .turnOff:
            String(localized: "Turn Displays Off", comment: "Quick actions menu: put all displays to sleep")
        }
    }

    /// Builds the right-click menu contents. Separated from `showQuickActionsMenu()`
    /// so the menu structure (order, labels, separators) is unit-testable without
    /// needing a live `NSStatusItem`.
    func makeQuickActionsMenu(turnOffTitle: String) -> NSMenu {
        let menu = NSMenu()

        let turnOffItem = NSMenuItem(title: turnOffTitle, action: #selector(handleTurnOff), keyEquivalent: "")
        turnOffItem.target = self
        menu.addItem(turnOffItem)

        // Ellipsis per HIG: the action opens a window that needs further input.
        let settingsItem = NSMenuItem(
            title: String(localized: "Settings…", comment: "Quick actions menu: open the Settings window"),
            action: #selector(handleOpenSettings),
            keyEquivalent: ","
        )
        settingsItem.target = self
        menu.addItem(settingsItem)

        // The App Store edition is updated by the App Store (App Review guideline 2.4.5).
        #if !APPSTORE
            let updatesItem = NSMenuItem(
                title: String(
                    localized: "Check for Updates…",
                    comment: "Quick actions menu: check for a newer version of Dimmerly"
                ),
                action: #selector(handleCheckForUpdates),
                keyEquivalent: ""
            )
            updatesItem.target = self
            menu.addItem(updatesItem)
        #endif

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: String(localized: "Quit Dimmerly", comment: "Quick actions menu: quit the app"),
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quitItem.target = NSApp
        menu.addItem(quitItem)

        return menu
    }

    @objc private func handleTurnOff() {
        MenuBarDisplayAction.performAfterDismissal(
            presentationWindow: nil,
            closePresentation: {},
            action: { [weak self] in self?.performSleep?() }
        )
    }

    @objc private func handleOpenSettings() {
        openSettings?()
    }

    @objc private func handleCheckForUpdates() {
        checkForUpdates?()
    }
}

extension StatusItemQuickActions: NSMenuItemValidation {
    /// "Check for Updates…" is disabled while Sparkle can't start a check, e.g. during one.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(handleCheckForUpdates) {
            return canCheckForUpdates?() ?? true
        }
        return true
    }
}

#if DEBUG
    /// Debug-only staged state for marketing screenshots, driven by `scripts/screenshots.sh refresh`.
    ///
    /// Setting `DIMMERLY_SCREENSHOT` to `menu`, `settings` or `demo` launches a debug build that never
    /// touches the user's displays or saved data: the app-wide managers are replaced with
    /// isolated instances backed by a throwaway defaults suite, gamma tables are left alone,
    /// hardware control finds no monitors, widgets are not synchronized, and launch setup
    /// (shortcuts, schedules, hardware control, widget requests) does not run. The stage then
    /// shows the requested window for capture, or plays the demo storyboard named by
    /// `DIMMERLY_DEMO_STORYBOARD` (see `DemoPlayer`). Release builds don't contain any of this.
    @MainActor
    enum ScreenshotStage {
        enum Scene: String {
            case menu
            case settings
            case demo
        }

        nonisolated static let environmentKey = "DIMMERLY_SCREENSHOT"
        nonisolated static let defaultsSuiteName = "rs.in.olujic.dimmerly.screenshots"

        nonisolated static let scene: Scene? = ProcessInfo.processInfo.environment[environmentKey]
            .flatMap(Scene.init(rawValue:))

        nonisolated static var isActive: Bool {
            scene != nil
        }

        nonisolated static let appearanceEnvironmentKey = "DIMMERLY_SCREENSHOT_APPEARANCE"
        nonisolated static let backdropEnvironmentKey = "DIMMERLY_SCREENSHOT_BACKDROP"
        nonisolated static let storyboardEnvironmentKey = "DIMMERLY_DEMO_STORYBOARD"
        nonisolated static let demoOutputEnvironmentKey = "DIMMERLY_DEMO_OUTPUT"
        nonisolated static let settingsTabEnvironmentKey = "DIMMERLY_SCREENSHOT_SETTINGS_TAB"

        /// Posted by a demo run with a preset ID, so the panel shows that preset's checkmark.
        nonisolated static let presetConfirmedNotification = Notification.Name("DimmerlyDemoPresetConfirmed")

        /// The demo scene's storyboard. A demo run can't do anything useful without one, so a
        /// missing or invalid storyboard ends the run with the reason.
        nonisolated static let storyboard: DemoStoryboard? = {
            guard scene == .demo else { return nil }
            let environment = ProcessInfo.processInfo.environment
            guard let path = environment[storyboardEnvironmentKey], environment[demoOutputEnvironmentKey] != nil else {
                fail("Set \(storyboardEnvironmentKey) and \(demoOutputEnvironmentKey) for a demo run.")
            }
            do {
                return try DemoStoryboard.load(from: URL(fileURLWithPath: path))
            } catch {
                fail(error.localizedDescription)
            }
        }()

        /// `light` or `dark` forces the staged windows' appearance, whatever the Mac uses, so
        /// the website can show a capture that matches each colour scheme. Unset follows the Mac.
        static func stagedAppearance() -> NSAppearance? {
            switch ProcessInfo.processInfo.environment[appearanceEnvironmentKey] {
            case nil, "":
                nil
            case "light":
                NSAppearance(named: .aqua)
            case "dark":
                NSAppearance(named: .darkAqua)
            case let value?:
                fail("\(appearanceEnvironmentKey) must be light or dark, not \(value).")
            }
        }

        private nonisolated static func fail(_ message: String) -> Never {
            FileHandle.standardError.write(Data("Dimmerly demo: \(message)\n".utf8))
            exit(65)
        }

        /// Starts empty on every launch so earlier runs can't leak into a new capture.
        static let defaults: UserDefaults = {
            UserDefaults().removePersistentDomain(forName: defaultsSuiteName)
            return UserDefaults(suiteName: defaultsSuiteName) ?? .standard
        }()

        // MARK: Staged content

        /// What the screenshots show. Edit these to change the staged content; a demo run
        /// uses its storyboard's displays and presets instead.
        nonisolated static let screenshotDisplays = [
            DemoStoryboard.Display(name: "External Display", brightness: 0.75),
        ]
        nonisolated static let screenshotPresets = [
            DemoStoryboard.Preset(name: "Full", brightness: 1.0),
            DemoStoryboard.Preset(name: "Evening", brightness: 0.65),
            DemoStoryboard.Preset(name: "Night", brightness: 0.35),
        ]

        nonisolated static var displays: [DemoStoryboard.Display] {
            storyboard?.displays ?? screenshotDisplays
        }

        nonisolated static var presets: [DemoStoryboard.Preset] {
            storyboard?.presets ?? screenshotPresets
        }

        /// San Francisco, for sunrise and sunset. A storyboard can name another place.
        nonisolated static let defaultLocation = DemoStoryboard.Location(latitude: 37.7749, longitude: -122.4194)
        nonisolated static let defaultTimeZone = "America/Los_Angeles"

        nonisolated static var location: DemoStoryboard.Location {
            storyboard?.location ?? defaultLocation
        }

        /// The staged Mac's time zone, so times shown match the staged location whatever this Mac
        /// uses. The process can't change its own (`NSTimeZone.default` doesn't move
        /// `TimeZone.current`), so the scripts launch with `TZ` set to it.
        nonisolated static var timeZoneIdentifier: String {
            storyboard?.timeZone ?? defaultTimeZone
        }

        /// The Settings tab a `settings` run opens on: `DIMMERLY_SCREENSHOT_SETTINGS_TAB=displays`
        /// (the default) or `schedule`.
        nonisolated static let settingsTab: SettingsView.Tab = switch ProcessInfo.processInfo
            .environment[settingsTabEnvironmentKey]
        {
        case nil, "", "displays":
            .displays
        case "schedule":
            .schedule
        case let value?:
            fail("\(settingsTabEnvironmentKey) must be displays or schedule, not \(value).")
        }

        /// Display rows that open with their warmth and contrast sliders showing.
        nonisolated static var expandedDisplayNames: Set<String> {
            Set(displays.filter { $0.expanded == true }.map(\.name))
        }

        /// Control–Option–number: valid in both builds, and not a Command-number app shortcut.
        static func presetShortcut(_ index: Int) -> GlobalShortcut {
            GlobalShortcut(key: String(index + 1), modifiers: [.control, .option])
        }

        static func makeSettings() -> AppSettings {
            let settings = AppSettings(defaults: defaults)
            // The Schedule tab lists schedules only while scheduling is on. Nothing runs them:
            // launch setup is skipped, and this is set before anything observes it.
            if scene == .settings, settingsTab == .schedule {
                settings.scheduleEnabled = true
            }
            // The Displays tab shows inactivity dimming and automatic warmth switched on, with
            // their options. The same applies: nothing acts on either setting.
            if scene == .settings, settingsTab == .displays {
                settings.idleTimerEnabled = true
                settings.autoColorTempEnabled = true
            }
            return settings
        }

        /// Made-up IDs that no connected display uses, so nothing can address a real screen.
        static let displayID: CGDirectDisplayID = 0x0D1_44E7

        static func makeBrightnessManager(
            displays staged: [DemoStoryboard.Display] = displays
        ) -> BrightnessManager {
            let stagedByID = Dictionary(uniqueKeysWithValues: staged.enumerated().map { index, display in
                (displayID + CGDirectDisplayID(index), display)
            })
            let ids = stagedByID.keys.sorted()
            // The testing initializer skips display enumeration and observers. The hooks keep
            // later refreshes on the staged displays and turn gamma writes into no-ops.
            let manager = BrightnessManager(forTesting: true, defaults: defaults)
            manager.applyGammaHook = { _, _, _, _ in }
            manager.activeDisplayIDsHook = { ids }
            manager.isBuiltInDisplayHook = { stagedByID[$0]?.isBuiltIn ?? false }
            manager.displayIdentityHook = { "screenshot-display-\($0)" }
            manager.displayNameHook = { stagedByID[$0]?.name ?? "" }
            manager.displays = ids.compactMap { id in
                guard let display = stagedByID[id] else { return nil }
                var staged = ExternalDisplay(
                    id: id,
                    name: display.name,
                    brightness: display.brightness,
                    warmth: display.warmth ?? 0,
                    contrast: display.contrast ?? ExternalDisplay.neutralContrast
                )
                staged.isBuiltIn = display.isBuiltIn
                return staged
            }
            return manager
        }

        #if !APPSTORE
            /// Hardware control that sends no DDC traffic. In a staged run the staged external
            /// displays answer like a typical DDC/CI monitor, from memory: the panel shows their
            /// cable badge and Hardware Control lists what they accept. Outside a staged run (in
            /// tests) it finds no monitors.
            static func makeHardwareBrightnessManager() -> HardwareBrightnessManager {
                let answers = isActive
                let externalIDs = answers ? stagedExternalDisplayIDs : []
                let manager = HardwareBrightnessManager(
                    forTesting: true,
                    ddcInterface: StagedDDCInterface(answeringDisplayIDs: Set(externalIDs)),
                    connectedExternalDisplayIDsProvider: { externalIDs },
                    displayRefreshHandler: {},
                    hardwareBrightnessReadHandler: { _, _ in }
                )
                if answers {
                    manager.enable()
                    manager.probeAllDisplays()
                }
                return manager
            }

            /// The made-up IDs `makeBrightnessManager` gives the staged external displays.
            static var stagedExternalDisplayIDs: [CGDirectDisplayID] {
                displays.enumerated().compactMap { index, display in
                    display.isBuiltIn ? nil : displayID + CGDirectDisplayID(index)
                }
            }

            /// Answers DDC/CI from memory for the staged displays it is given and stays silent for
            /// any other ID, so nothing can reach a real monitor.
            struct StagedDDCInterface: DDCInterface {
                let answeringDisplayIDs: Set<CGDirectDisplayID>

                /// What a typical DDC/CI monitor reports: brightness and contrast at mid-range,
                /// speakers on and unmuted, the first DisplayPort input selected.
                static let values: [VCPCode: UInt16] = [
                    .brightness: 75,
                    .contrast: 50,
                    .volume: 30,
                    .audioMute: 2,
                    .inputSource: 0x0F,
                ]

                func read(vcp: VCPCode, for displayID: CGDirectDisplayID) -> DDCReadResult? {
                    guard answeringDisplayIDs.contains(displayID), let value = Self.values[vcp] else { return nil }
                    return DDCReadResult(currentValue: value, maxValue: vcp == .inputSource ? 0xFF : 100)
                }

                func write(vcp: VCPCode, value _: UInt16, for displayID: CGDirectDisplayID) -> Bool {
                    answeringDisplayIDs.contains(displayID) && Self.values[vcp] != nil
                }

                func probeCapabilities(
                    for displayID: CGDirectDisplayID,
                    skippingBrightness: Bool
                ) -> HardwareDisplayCapability {
                    HardwareDisplayCapability.probe(
                        displayID: displayID,
                        skippingBrightness: skippingBrightness,
                        read: read(vcp:for:),
                        transportReachable: { _ in false }
                    )
                }
            }
        #endif

        static func stagedPresets(_ staged: [DemoStoryboard.Preset] = presets) -> [BrightnessPreset] {
            staged.enumerated().map { index, preset in
                BrightnessPreset(
                    name: preset.name,
                    shortcut: presetShortcut(index),
                    universalBrightness: preset.brightness,
                    universalWarmth: preset.warmth
                )
            }
        }

        static func makePresetManager(presets staged: [DemoStoryboard.Preset] = presets) -> PresetManager {
            // Saved first, so the manager loads them like a user's presets instead of seeding
            // its defaults, and the suite holds exactly what the screenshot shows.
            if let data = try? JSONEncoder().encode(stagedPresets(staged)) {
                defaults.set(data, forKey: PresetManager.persistenceKey)
            }
            return PresetManager(
                defaults: defaults,
                mainShortcutProvider: { .default },
                widgetSynchronizer: NoWidgetSynchronizer(),
                notifyWarmthPresetApplied: {}
            )
        }

        static func makeLocationProvider() -> LocationProvider {
            let provider = LocationProvider(forTesting: true, defaults: defaults)
            provider.latitude = location.latitude
            provider.longitude = location.longitude
            return provider
        }

        static func makeColorTemperatureManager() -> ColorTemperatureManager {
            let manager = ColorTemperatureManager(brightnessManager: .shared, settings: .shared)
            if let now = storyboard?.stagedNow {
                manager.currentDate = { now }
            }
            return manager
        }

        /// Sunset and bedtime schedules for the Schedule tab, on the staged presets.
        static func makeScheduleManager() -> ScheduleManager {
            let presets = PresetManager.shared.presets
            func presetID(_ name: String) -> UUID? {
                presets.first { $0.name == name }?.id
            }
            let staged = [
                presetID("Evening").map {
                    DimmingSchedule(name: "Sunset", trigger: .sunset(offsetMinutes: 0), presetID: $0)
                },
                presetID("Night").map {
                    DimmingSchedule(name: "Bedtime", trigger: .fixedTime(hour: 22, minute: 30), presetID: $0)
                },
                presetID("Full").map {
                    DimmingSchedule(name: "Morning", trigger: .sunrise(offsetMinutes: 30), presetID: $0)
                },
            ].compactMap(\.self)
            if let data = try? JSONEncoder().encode(staged) {
                defaults.set(data, forKey: ScheduleManager.schedulesKey)
            }
            return ScheduleManager(defaults: defaults, locationCoordinates: {
                (location.latitude, location.longitude)
            })
        }

        private struct NoWidgetSynchronizer: WidgetPresetSynchronizing {
            func synchronize(_: [BrightnessPreset]) {}
        }

        // MARK: Presentation

        private static var didPresent = false

        /// Shows the staged window once the status item exists. The capture script waits for
        /// the window itself, so this only has to show it.
        static func statusItemDidAttach(openSettings: @escaping () -> Void) {
            guard let scene, !didPresent else { return }
            didPresent = true
            guard TimeZone.current.identifier == timeZoneIdentifier else {
                fail("Launch with TZ=\(timeZoneIdentifier), so sunrise, sunset and times match the staged place.")
            }
            if let appearance = stagedAppearance() {
                NSApp.appearance = appearance
            }
            // A regular app can come to the front, which the Settings region capture requires.
            NSApp.setActivationPolicy(.regular)
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                // The capture needs Dimmerly in front even though another app was active
                // when the script launched it, so take focus rather than request it.
                NSApp.activate(ignoringOtherApps: true)
                // Activation completes a moment later. A panel shown before it never becomes
                // key, and macOS draws it unfocused, with grey accent colours.
                for _ in 0 ..< 100 where !NSApp.isActive {
                    try? await Task.sleep(for: .milliseconds(20))
                }
                switch scene {
                case .menu:
                    MenuBarPanelPresenter.shared.present(selectedPresetID: nil)
                    await showBackdropBehindPanel()
                case .settings:
                    // `settingsWindowDidAttach` centers the window once SwiftUI creates it.
                    openSettings()
                case .demo:
                    await startDemo()
                }
            }
        }

        private static var demoRunner: DemoRunner?

        private static func startDemo() async {
            guard let storyboard,
                  let output = ProcessInfo.processInfo.environment[demoOutputEnvironmentKey]
            else { return }
            // The real panel opens before frame 0 and stays open, so the recorder has its full-size
            // window from the start. The compositor shows and hides it from `panelOpen`; a
            // popover's own appear animation would arrive too late to record anyway.
            MenuBarPanelPresenter.shared.present(selectedPresetID: nil)
            await showBackdropBehindPanel()
            let player = DemoPlayer(
                storyboard: storyboard,
                brightnessManager: .shared,
                presetManager: .shared,
                openPanel: {},
                closePanel: {},
                confirmPreset: { NotificationCenter.default.post(name: presetConfirmedNotification, object: $0) },
                setAutoWarmth: { enabled in
                    // What the panel's switch does; the app's onChange then finds nothing to change.
                    AppSettings.shared.autoColorTempEnabled = enabled
                    ColorTemperatureManager.shared.apply(enabled: enabled)
                }
            )
            do {
                demoRunner = try DemoRunner(player: player, outputURL: URL(fileURLWithPath: output))
            } catch {
                fail("Can't write \(output): \(error.localizedDescription)")
            }
            try? await Task.sleep(for: .seconds(storyboard.leadIn ?? 0))
            demoRunner?.start()
        }

        private static var backdropWindow: NSWindow?

        /// The panel's material blurs whatever is behind it, and a window-only capture has
        /// nothing there, so light mode records as flat grey. `DIMMERLY_SCREENSHOT_BACKDROP=#RRGGBB`
        /// puts a plain window of that colour behind the panel, as a desktop of the colour the
        /// image puts around it would be. The capture keeps only the panel's own shape.
        private static func showBackdropBehindPanel() async {
            guard let hex = ProcessInfo.processInfo.environment[backdropEnvironmentKey], !hex.isEmpty else { return }
            guard let color = color(hex: hex) else {
                fail("\(backdropEnvironmentKey) must be a #RRGGBB colour, not \(hex).")
            }
            // The popover window appears a moment after `present`.
            var panelWindow: NSWindow?
            for _ in 0 ..< 50 where panelWindow == nil {
                try? await Task.sleep(for: .milliseconds(20))
                panelWindow = NSApp.windows.first {
                    $0.isVisible && (280 ... 340).contains($0.frame.width) && $0.frame.height >= 150
                }
            }
            guard let panelWindow else { fail("The panel did not appear, so the backdrop has nowhere to go.") }
            let panelFrame = panelWindow.frame
            let window = NSWindow(
                contentRect: panelFrame.insetBy(dx: -80, dy: -80),
                styleMask: .borderless,
                backing: .buffered,
                defer: false
            )
            window.backgroundColor = color
            window.isOpaque = true
            window.hasShadow = false
            window.ignoresMouseEvents = true
            // Above ordinary windows, below the status-bar-level popover.
            window.level = .floating
            window.orderFrontRegardless()
            backdropWindow = window
            // Keep the panel key, so it is drawn focused, with its accent colours.
            panelWindow.makeKey()
        }

        private static func color(hex: String) -> NSColor? {
            guard hex.count == 7, hex.hasPrefix("#"), let value = UInt32(hex.dropFirst(), radix: 16) else { return nil }
            return NSColor(
                srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
                green: CGFloat((value >> 8) & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255,
                alpha: 1
            )
        }

        /// Called by the Settings window itself, so only that window is moved, and only once
        /// it exists, however long the first launch takes.
        static func settingsWindowDidAttach(_ window: NSWindow) {
            guard scene == .settings else { return }
            window.center()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            showBackdrop(behindSettings: window)
        }

        /// The Settings toolbar's material picks up what is behind the window, which a region
        /// capture would otherwise take from the real desktop. With `DIMMERLY_SCREENSHOT_BACKDROP`
        /// set, a plain window of that colour goes behind it; the mask capture keeps only the window.
        private static func showBackdrop(behindSettings window: NSWindow) {
            guard backdropWindow == nil,
                  let hex = ProcessInfo.processInfo.environment[backdropEnvironmentKey], !hex.isEmpty
            else { return }
            guard let color = color(hex: hex) else {
                fail("\(backdropEnvironmentKey) must be a #RRGGBB colour, not \(hex).")
            }
            let backdrop = NSWindow(
                contentRect: window.frame.insetBy(dx: -80, dy: -80),
                styleMask: .borderless,
                backing: .buffered,
                defer: false
            )
            backdrop.backgroundColor = color
            backdrop.isOpaque = true
            backdrop.hasShadow = false
            backdrop.ignoresMouseEvents = true
            backdrop.order(.below, relativeTo: window.windowNumber)
            backdropWindow = backdrop
        }
    }
#endif

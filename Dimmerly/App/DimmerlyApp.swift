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

@MainActor
func handleWidgetDimNotification(
    settings: AppSettings,
    consumeCommand: () -> Bool = { SharedConstants.consumeWidgetDimCommand() },
    performSleep: (AppSettings) -> Void = { DisplayAction.performSleep(settings: $0) }
) {
    guard consumeCommand() else { return }
    performSleep(settings)
}

/// An acknowledgement follows the action and its state publication, never just receipt.
@MainActor
func handleWidgetActionRequest(
    _ id: UUID,
    defaults: UserDefaults? = SharedConstants.sharedDefaults,
    now: Date = Date(),
    performCommand: (WidgetActionCommand) -> Void
) {
    guard let request = SharedConstants.consumeWidgetActionRequest(id, from: defaults, now: now) else { return }
    performCommand(request.command)
    SharedConstants.acknowledgeWidgetAction(id, in: defaults)
}

@main
struct DimmerlyApp: App {
    /// Application settings shared across all views
    @State private var settings = AppSettings.shared

    /// Manager for global keyboard shortcuts
    @State private var shortcutManager = KeyboardShortcutManager()

    /// Manager for external display brightness
    @State private var brightnessManager = BrightnessManager.shared

    /// Manager for brightness presets
    @State private var presetManager = PresetManager.shared

    /// Manager for idle timer auto-dim (not @Observable — held for lifecycle only)
    @State private var idleTimerManager = IdleTimerManager()

    /// Manager for preset keyboard shortcuts (not @Observable — held for lifecycle only)
    @State private var presetShortcutManager = PresetShortcutManager()

    /// Provider for location data (solar calculations)
    @State private var locationProvider = LocationProvider.shared

    /// Manager for time-based dimming schedules
    @State private var scheduleManager = ScheduleManager()

    /// Manager for automatic color temperature adjustment
    @State private var colorTempManager = ColorTemperatureManager.shared

    #if !APPSTORE
        /// Manager for DDC/CI hardware display control (direct distribution only)
        @State private var hardwareManager = HardwareBrightnessManager.shared
    #endif

    /// Guard against duplicate observer registration if onAppear fires more than once
    @State private var isConfigured = false

    /// Coordinates programmatic menu panel presentation, including Spotlight preset selection.
    @State private var menuBarPanelCoordinator = MenuBarPanelCoordinator.shared

    /// Handles the right-click quick actions menu on the status bar icon.
    @State private var statusItemQuickActions = StatusItemQuickActions()

    /// Reports on the status item whether Dimmerly is currently adjusting the displays.
    @State private var statusItemAccessibility = StatusItemAccessibility()

    @Environment(\.openSettings) private var openSettings

    /// Distributed notification observer for widget "Sleep Displays" action
    @State private var widgetDimObserver: NSObjectProtocol?

    /// Distributed notification observer for widget preset application
    @State private var widgetPresetObserver: NSObjectProtocol?

    /// Distributed notification observer for the Control Center dim toggle
    @State private var widgetDimStateObserver: NSObjectProtocol?

    /// Distributed notification observer for the Control Center Auto Warmth toggle
    @State private var widgetAutoWarmthObserver: NSObjectProtocol?

    /// Acknowledged widget/control actions from extensions on older macOS versions.
    @State private var widgetActionObserver: NSObjectProtocol?

    /// Clears the published dim state on quit, since blanking ends with the process.
    @State private var terminationObserver: NSObjectProtocol?

    /// Blanking state, observed so the Control Center dim toggle can follow it.
    @State private var screenBlanker = ScreenBlanker.shared

    var body: some Scene {
        @Bindable var menuBarPanelCoordinator = menuBarPanelCoordinator

        // Menu bar extra (the main interface) — window style preserves slider controls.
        MenuBarExtra {
            MenuBarPanel(
                selectedPresetID: menuBarPanelCoordinator.requestedPresetID,
                openSettingsAction: {
                    openSettings()
                    NSApp.activate()
                }
            )
            .environment(settings)
            .environment(brightnessManager)
            .environment(presetManager)
            .environment(colorTempManager)
            #if !APPSTORE
                .environment(hardwareManager)
            #endif
                .environment(\.closeMenuBarPanel) { menuBarPanelCoordinator.dismiss() }
        } label: {
            menuBarLabel
                .onAppear {
                    guard !isConfigured else { return }
                    isConfigured = true
                    // Load saved shortcut before starting monitoring (Issue 1)
                    shortcutManager.updateShortcut(settings.keyboardShortcut)
                    startGlobalShortcutMonitoring()
                    configureIdleTimer()
                    configurePresetShortcuts()
                    configureScheduleManager()
                    observeWidgetNotifications()
                    SharedConstants.discardLegacyWidgetCommands()
                    AppEntityIndexingService.shared.reindexPresets(presetManager.presets)
                    // Initial sync for settings-driven managers. `.onChange` below
                    // keeps them current for subsequent edits without needing each
                    // manager to observe UserDefaults directly.
                    syncManagerStateFromSettings()
                    #if !APPSTORE
                        configureHardwareControl()
                    #endif
                }
                .onChange(of: menuBarPanelCoordinator.isPresented) { _, isPresented in
                    if !isPresented {
                        menuBarPanelCoordinator.requestedPresetID = nil
                    }
                }
                .onChange(of: settings.idleTimerEnabled) { _, _ in
                    idleTimerManager.apply(
                        enabled: settings.idleTimerEnabled,
                        thresholdMinutes: settings.idleTimerMinutes
                    )
                }
                .onChange(of: settings.idleTimerMinutes) { _, _ in
                    idleTimerManager.apply(
                        enabled: settings.idleTimerEnabled,
                        thresholdMinutes: settings.idleTimerMinutes
                    )
                }
                .onChange(of: settings.scheduleEnabled) { _, _ in
                    scheduleManager.apply(enabled: settings.scheduleEnabled)
                }
                .onChange(of: settings.autoColorTempEnabled) { _, _ in
                    colorTempManager.apply(enabled: settings.autoColorTempEnabled)
                    ControlCenterStatePublisher.live.publishAutoWarmthState(settings.autoColorTempEnabled)
                }
                .onChange(of: screenBlanker.isBlankingAnyDisplay, initial: true) { _, isBlanking in
                    ControlCenterStatePublisher.live.publishDimState(isBlanking)
                }
                .onChange(of: presetManager.presets) { _, newValue in
                    presetShortcutManager.updateShortcuts(from: newValue)
                    AppEntityIndexingService.shared.reindexPresets(newValue)
                }
                .onChange(of: brightnessManager.isAffectingDisplays, initial: true) { _, isAffecting in
                    statusItemAccessibility.update(isAffectingDisplays: isAffecting)
                }
        }
        .menuBarExtraAccess(isPresented: $menuBarPanelCoordinator.isPresented) { statusItem in
            let panelPresenter = MenuBarPanelPresenter.shared
            panelPresenter.configure(
                statusItem: statusItem,
                contentBuilder: { selectedPresetID in
                    NSHostingController(
                        rootView: MenuBarPanel(
                            selectedPresetID: selectedPresetID,
                            openSettingsAction: {
                                openSettings()
                                NSApp.activate()
                            }
                        )
                        .environment(settings)
                        .environment(brightnessManager)
                        .environment(presetManager)
                        .environment(colorTempManager)
                        #if !APPSTORE
                            .environment(hardwareManager)
                        #endif
                            .environment(\.closeMenuBarPanel) {
                                menuBarPanelCoordinator.dismiss()
                            }
                    )
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
            statusItemQuickActions.configure(
                statusItem: statusItem,
                settings: settings,
                performSleep: { DisplayAction.performSleep(settings: settings) },
                openSettings: {
                    openSettings()
                    NSApp.activate()
                }
            )
            statusItemAccessibility.attach(to: statusItem)
        }
        .menuBarExtraStyle(.window)

        // Settings window
        Settings {
            SettingsView()
                .environment(settings)
                .environment(shortcutManager)
                .environment(presetShortcutManager)
                .environment(presetManager)
                .environment(brightnessManager)
                .environment(scheduleManager)
                .environment(locationProvider)
                .environment(colorTempManager)
            #if !APPSTORE
                .environment(hardwareManager)
            #endif
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
    @ViewBuilder
    private var menuBarLabel: some View {
        if let systemImage = settings.menuBarIcon.systemImageName {
            Image(systemName: systemImage)
                .accessibilityLabel("Dimmerly")
        } else {
            Image(settings.menuBarIcon
                .resolvedAssetName(isActive: brightnessManager.isAffectingDisplays) ?? "MenuBarIcon")
                .accessibilityLabel("Dimmerly")
        }
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
    /// on `settings.idleTimerEnabled` / `.idleTimerMinutes` in the scene body, plus
    /// a one-time `syncManagerStateFromSettings()` at launch.
    private func configureIdleTimer() {
        idleTimerManager.onIdleThresholdReached = { [settings] in
            DisplayAction.performSleep(settings: settings)
        }
    }

    /// Observes distributed notifications from widgets to handle cross-process actions.
    ///
    /// Widgets run in a separate process (extension) and communicate with the main app via:
    /// - Distributed notifications (trigger actions)
    /// - Shared UserDefaults container (pass parameters)
    ///
    /// Notification types:
    /// 1. **Dim notification**: Widget's "Sleep Displays" button was tapped
    /// 2. **Preset notification**: Widget's preset button was tapped (preset ID in shared defaults)
    /// 3. **Dim state notification**: Control Center dim toggle was switched (state in shared defaults)
    /// 4. **Auto Warmth notification**: Control Center Auto Warmth toggle was switched (state in shared defaults)
    ///
    /// Design note: Using DistributedNotificationCenter instead of Darwin notifications
    /// provides better type safety and automatic main queue dispatch.
    private func observeWidgetNotifications() {
        widgetActionObserver = DistributedNotificationCenter.default().addObserver(
            forName: SharedConstants.widgetActionNotification,
            object: nil, queue: .main
        ) { [settings, presetManager, brightnessManager] notification in
            guard let idString = notification.object as? String, let id = UUID(uuidString: idString) else { return }
            Task { @MainActor in
                handleWidgetActionRequest(id) { command in
                    switch command {
                    case .dimDisplays:
                        DisplayAction.performSleep(settings: settings)
                    case let .applyPreset(presetID):
                        guard let uuid = UUID(uuidString: presetID),
                              let preset = presetManager.presets.first(where: { $0.id == uuid })
                        else { return }
                        presetManager.applyPreset(preset, to: brightnessManager, animated: true)
                    case let .setDimming(value):
                        handleWidgetDimStateCommand(settings: settings, consumeCommand: { value })
                    case let .setAutoWarmth(value):
                        handleWidgetAutoWarmthCommand(settings: settings, consumeCommand: { value })
                    }
                }
            }
        }

        // Widget "Sleep Displays" button
        widgetDimObserver = DistributedNotificationCenter.default().addObserver(
            forName: SharedConstants.dimNotification,
            object: nil, queue: .main
        ) { [settings] _ in
            Task { @MainActor in
                handleWidgetDimNotification(settings: settings)
            }
        }

        // Widget preset button (preset ID passed via shared defaults)
        widgetPresetObserver = DistributedNotificationCenter.default().addObserver(
            forName: SharedConstants.presetNotification,
            object: nil, queue: .main
        ) { [presetManager, brightnessManager] _ in
            Task { @MainActor in
                guard let uuid = SharedConstants.consumeWidgetPresetCommand(),
                      let preset = presetManager.presets.first(where: { $0.id == uuid })
                else {
                    return
                }
                presetManager.applyPreset(preset, to: brightnessManager, animated: true)
            }
        }

        // Control Center dim toggle (requested state passed via shared defaults)
        widgetDimStateObserver = DistributedNotificationCenter.default().addObserver(
            forName: SharedConstants.dimStateNotification,
            object: nil, queue: .main
        ) { [settings] _ in
            Task { @MainActor in
                handleWidgetDimStateCommand(settings: settings)
            }
        }

        // Control Center Auto Warmth toggle (requested state passed via shared defaults)
        widgetAutoWarmthObserver = DistributedNotificationCenter.default().addObserver(
            forName: SharedConstants.autoWarmthNotification,
            object: nil, queue: .main
        ) { [settings] _ in
            Task { @MainActor in
                handleWidgetAutoWarmthCommand(settings: settings)
            }
        }

        // Blanking cannot outlive the app, so the dim toggle must not keep showing it as on.
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                ControlCenterStatePublisher.live.publishDimState(false)
            }
        }
    }

    /// Wires the schedule-triggered callback. `.onChange` on `settings.scheduleEnabled`
    /// handles start/stop; the one-time sync in `syncManagerStateFromSettings` handles launch.
    private func configureScheduleManager() {
        scheduleManager.onScheduleTriggered = { [presetManager, brightnessManager] presetID in
            guard let preset = presetManager.presets.first(where: { $0.id == presetID }) else { return }
            presetManager.applyPreset(preset, to: brightnessManager, animated: true)
        }
    }

    /// Wires the preset-shortcut-triggered callback. `.onChange` on `presetManager.presets`
    /// handles re-registration whenever presets/shortcuts change.
    private func configurePresetShortcuts() {
        presetShortcutManager.onPresetTriggered = { [presetManager, brightnessManager] presetID in
            guard let preset = presetManager.presets.first(where: { $0.id == presetID }) else { return }
            presetManager.applyPreset(preset, to: brightnessManager, animated: true)
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
            BrightnessManager.shared.refreshDisplays()
            hardwareManager.probeAllDisplays()
            hardwareManager.startPolling()
        }
    #endif
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
        #if APPSTORE
            "Dim Displays"
        #else
            settings.preventScreenLock ? "Dim Displays" : "Turn Displays Off"
        #endif
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
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(handleOpenSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "Quit Dimmerly",
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
}

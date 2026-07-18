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

    /// Presentation state for the menu bar panel, so it can be dismissed programmatically
    /// (e.g. after "Turn Displays Off") without leaving the status bar icon stuck highlighted.
    @State private var isMenuBarPanelPresented = false

    /// Handles the right-click quick actions menu on the status bar icon.
    @State private var statusItemQuickActions = StatusItemQuickActions()

    @Environment(\.openSettings) private var openSettings

    /// Distributed notification observer for widget "Sleep Displays" action
    @State private var widgetDimObserver: NSObjectProtocol?

    /// Distributed notification observer for widget preset application
    @State private var widgetPresetObserver: NSObjectProtocol?

    var body: some Scene {
        // Menu bar extra (the main interface) — window style preserves slider controls.
        MenuBarExtra {
            MenuBarPanel()
                .environment(settings)
                .environment(brightnessManager)
                .environment(presetManager)
                .environment(colorTempManager)
            #if !APPSTORE
                .environment(hardwareManager)
            #endif
                .environment(\.closeMenuBarPanel) { isMenuBarPanelPresented = false }
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
                    processPendingWidgetCommands()
                    // Initial sync for settings-driven managers. `.onChange` below
                    // keeps them current for subsequent edits without needing each
                    // manager to observe UserDefaults directly.
                    syncManagerStateFromSettings()
                    #if !APPSTORE
                        configureHardwareControl()
                    #endif
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
                }
                .onChange(of: presetManager.presets) { _, newValue in
                    presetShortcutManager.updateShortcuts(from: newValue)
                }
        }
        .menuBarExtraAccess(isPresented: $isMenuBarPanelPresented) { statusItem in
            statusItemQuickActions.configure(
                statusItem: statusItem,
                settings: settings,
                performSleep: { DisplayAction.performSleep(settings: settings) },
                openSettings: {
                    openSettings()
                    NSApp.activate()
                }
            )
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

    /// Menu bar icon view that adapts to the user's selected icon style.
    ///
    /// Displays either an SF Symbol (for built-in styles) or a custom asset (for default style).
    @ViewBuilder
    private var menuBarLabel: some View {
        if let systemImage = settings.menuBarIcon.systemImageName {
            Image(systemName: systemImage)
                .accessibilityLabel("Dimmerly")
        } else {
            Image(settings.menuBarIcon.assetName ?? "MenuBarIcon")
                .accessibilityLabel("Dimmerly")
        }
    }

    /// Configures the global keyboard shortcut monitor to trigger display sleep.
    ///
    /// The shortcut is loaded from settings before monitoring starts.
    /// Requires accessibility permissions to function.
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
    /// Two notification types:
    /// 1. **Dim notification**: Widget's "Sleep Displays" button was tapped
    /// 2. **Preset notification**: Widget's preset button was tapped (preset ID in shared defaults)
    ///
    /// Design note: Using DistributedNotificationCenter instead of Darwin notifications
    /// provides better type safety and automatic main queue dispatch.
    private func observeWidgetNotifications() {
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
    }

    /// Drains widget commands that were written before this process had observers registered.
    private func processPendingWidgetCommands() {
        if SharedConstants.consumeWidgetDimCommand() {
            DisplayAction.performSleep(settings: settings)
        }

        guard let presetID = SharedConstants.consumeWidgetPresetCommand(),
              let preset = presetManager.presets.first(where: { $0.id == presetID })
        else {
            return
        }
        presetManager.applyPreset(preset, to: brightnessManager, animated: true)
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
                writeDelayMilliseconds: settings.ddcWriteDelay
            )
            hardwareManager.probeAllDisplays()
            hardwareManager.startPolling()
        }
    #endif
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

            showQuickActionsMenu()
            return nil
        }
    }

    private func showQuickActionsMenu() {
        guard let statusItem, let settings else { return }

        let menu = makeQuickActionsMenu(turnOffTitle: Self.turnOffTitle(settings: settings))

        // Temporarily assign the menu so this click shows it, then clear it so
        // subsequent left-clicks keep going through the normal panel toggle.
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
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

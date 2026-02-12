//
//  SettingsView.swift
//  Dimmerly
//
//  Settings window for configuring app preferences.
//

import SwiftUI

/// Main settings view for the application
struct SettingsView: View {
    /// Changes on each window appearance to reset scroll position to top
    @State private var formIdentity = UUID()

    var body: some View {
        GeneralSettingsView()
            .id(formIdentity)
            .frame(minWidth: 400, maxWidth: 550, minHeight: 500)
            .onAppear {
                formIdentity = UUID()
                if #available(macOS 14.0, *) {
                    NSApp.activate()
                } else {
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
    }
}

/// General settings tab — all preferences in one place
struct GeneralSettingsView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var shortcutManager: KeyboardShortcutManager
    @EnvironmentObject var presetManager: PresetManager
    @EnvironmentObject var brightnessManager: BrightnessManager
    @EnvironmentObject var scheduleManager: ScheduleManager
    @EnvironmentObject var locationProvider: LocationProvider

    var body: some View {
        Form {
            Section("General") {
                Toggle("Launch at Login", isOn: Binding(
                    get: { settings.launchAtLogin },
                    set: { newValue in
                        settings.launchAtLogin = newValue
                        let result = LaunchAtLoginManager.setEnabled(newValue)
                        if case .failure = result {
                            // Revert toggle on failure
                            settings.launchAtLogin = !newValue
                        }
                    }
                ))
                .help(Text("Automatically start Dimmerly when you log in"))

                menuBarIconPicker
            }

            dimmingSection

            idleTimerSection

            scheduleSection

            keyboardShortcutSection

            presetsManagementSection

            aboutSection
        }
        .formStyle(.grouped)
        .onAppear {
            // Sync launch-at-login state with system (Issue 4)
            settings.launchAtLogin = LaunchAtLoginManager.isEnabled
            // Re-check accessibility permission (Issue 4)
            shortcutManager.hasAccessibilityPermission = KeyboardShortcutManager.checkAccessibilityPermission()
        }
    }

    // MARK: - Menu Bar Icon

    private var menuBarIconPicker: some View {
        LabeledContent("Menu Bar Icon:") {
            HStack(spacing: 8) {
                ForEach(MenuBarIconStyle.allCases) { style in
                    let isSelected = settings.menuBarIconRaw == style.rawValue
                    Button {
                        settings.menuBarIcon = style
                    } label: {
                        Group {
                            if let systemImage = style.systemImageName {
                                Image(systemName: systemImage)
                            } else {
                                Image("MenuBarIcon")
                            }
                        }
                        .frame(width: 32, height: 32)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(isSelected ? Color.accentColor : Color.primary.opacity(0.05))
                        )
                        .foregroundStyle(isSelected ? .white : .primary)
                    }
                    .buttonStyle(.plain)
                    .help(style.displayName)
                    .accessibilityLabel(style.displayName)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
        }
    }

    // MARK: - Dimming

    private var dimmingSection: some View {
        Section("Dimming") {
            #if APPSTORE
            Text("Dims screens without putting displays to sleep. Your session stays unlocked.")
                .font(.caption)
                .foregroundStyle(.secondary)
            #else
            Picker("Turn Displays Off:", selection: Binding(
                get: { settings.preventScreenLock ? 1 : 0 },
                set: { settings.preventScreenLock = $0 == 1 }
            )) {
                Text("Sleep & Lock").tag(0)
                Text("Dim Only").tag(1)
            }
            .pickerStyle(.radioGroup)

            if !settings.preventScreenLock {
                Text("Turns off all displays and locks your Mac, just like closing the lid. To control how quickly your password is required, adjust your Lock Screen settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Lock-Screen-Settings.extension") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    HStack(spacing: 2) {
                        Text("Open Lock Screen Settings")
                        Image(systemName: "arrow.up.forward")
                            .imageScale(.small)
                    }
                }
                .font(.caption)
            } else {
                Text("Dims screens without putting displays to sleep. Your session stays unlocked.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            #endif

            #if APPSTORE
            let showDimOptions = true
            #else
            let showDimOptions = settings.preventScreenLock
            #endif

            if showDimOptions {
                Toggle("Fade transition", isOn: $settings.fadeTransition)
                    .help(Text("Gradually dims displays instead of turning them off instantly"))

                Picker("Wake Displays:", selection: $settings.requireEscapeToDismiss) {
                    Text("Any input").tag(false)
                    Text("Escape key only").tag(true)
                }
                .pickerStyle(.radioGroup)

                if !settings.requireEscapeToDismiss {
                    Toggle("Ignore mouse movement", isOn: $settings.ignoreMouseMovement)
                        .help(Text("Only wake the screen on keyboard input or mouse click, not mouse movement"))
                }
            }
        }
    }

    // MARK: - Idle Timer

    private var idleTimerSection: some View {
        Section("Idle Timer") {
            Toggle("Auto-dim after inactivity", isOn: $settings.idleTimerEnabled)

            if settings.idleTimerEnabled {
                Stepper(value: $settings.idleTimerMinutes, in: 1...60) {
                    Text(
                        String(
                            format: NSLocalizedString(
                                "%d minutes",
                                comment: "Idle timer stepper label: number of minutes"
                            ),
                            settings.idleTimerMinutes
                        )
                    )
                }

                Text(
                    String(
                        format: NSLocalizedString(
                            "Displays will dim automatically after %d minutes of inactivity.",
                            comment: "Idle timer description"
                        ),
                        settings.idleTimerMinutes
                    )
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Schedule

    @State private var showAddSchedule = false
    @State private var showManualLocation = false

    private var scheduleSection: some View {
        Section("Schedule") {
            Toggle("Apply presets on a schedule", isOn: $settings.scheduleEnabled)

            if settings.scheduleEnabled {
                locationRow

                ForEach(scheduleManager.schedules) { schedule in
                    let presetName = presetManager.presets.first(where: { $0.id == schedule.presetID })?.name
                    let triggerTime = triggerTimeDescription(for: schedule)
                    ScheduleRow(
                        schedule: schedule,
                        presetName: presetName,
                        triggerTimeDescription: triggerTime,
                        onToggle: { scheduleManager.toggleSchedule(id: schedule.id) },
                        onDelete: { scheduleManager.deleteSchedule(id: schedule.id) }
                    )
                }

                Button("Add Schedule\u{2026}") {
                    showAddSchedule = true
                }
                .sheet(isPresented: $showAddSchedule) {
                    AddScheduleSheet(presets: presetManager.presets)
                        .environmentObject(scheduleManager)
                }
            }
        }
    }

    private var locationRow: some View {
        Group {
            if locationProvider.hasLocation {
                LabeledContent {
                    Menu {
                        Button("Use Current Location") {
                            locationProvider.requestLocation()
                        }
                        Button("Enter Manually\u{2026}") {
                            showManualLocation = true
                        }
                        Divider()
                        Button("Clear Location", role: .destructive) {
                            locationProvider.clearLocation()
                        }
                    } label: {
                        Text(locationSummary)
                            .foregroundStyle(.secondary)
                    }
                } label: {
                    Label("Location", systemImage: "location.fill")
                }
            } else {
                LabeledContent {
                    HStack(spacing: 8) {
                        Button("Use Current") {
                            locationProvider.requestLocation()
                        }
                        Button("Enter Manually\u{2026}") {
                            showManualLocation = true
                        }
                    }
                } label: {
                    Label("Location", systemImage: "location.slash")
                }

                Text("A location is needed for sunrise and sunset schedules.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .sheet(isPresented: $showManualLocation) {
            ManualLocationSheet()
                .environmentObject(locationProvider)
        }
    }

    private var locationSummary: String {
        let lat = locationProvider.latitude ?? 0
        let lon = locationProvider.longitude ?? 0
        return String(format: "%.2f, %.2f", lat, lon)
    }

    private func triggerTimeDescription(for schedule: DimmingSchedule) -> String? {
        guard schedule.trigger.requiresLocation else { return nil }
        guard let date = scheduleManager.resolveTriggerDate(schedule.trigger, on: Date()) else {
            return nil
        }
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter.string(from: date)
    }

    // MARK: - Keyboard Shortcut

    private var keyboardShortcutSection: some View {
        Section("Keyboard Shortcut") {
            HStack {
                #if APPSTORE
                Text("Dim Displays:")
                #else
                Text(settings.preventScreenLock ? "Dim Displays:" : "Sleep Displays:")
                #endif
                KeyboardShortcutRecorder(
                    shortcut: Binding(
                        get: { settings.keyboardShortcut },
                        set: { newValue in
                            settings.keyboardShortcut = newValue
                            shortcutManager.updateShortcut(newValue)
                        }
                    )
                )
            }

            Text("Global keyboard shortcuts work from any application.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if !shortcutManager.hasAccessibilityPermission {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Accessibility permission is required for global shortcuts.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .symbolRenderingMode(.multicolor)

                    Button {
                        KeyboardShortcutManager.requestAccessibilityPermission()
                    } label: {
                        HStack(spacing: 2) {
                            Text("Open Accessibility Settings")
                            Image(systemName: "arrow.up.forward")
                                .imageScale(.small)
                        }
                    }
                    .font(.caption)
                }
                .accessibilityElement(children: .combine)
                .padding(.top, 4)
            }
        }
    }

    // MARK: - Presets Management

    @State private var showRestoreDefaults = false

    private var presetsManagementSection: some View {
        Section("Presets") {
            ForEach(presetManager.presets) { preset in
                PresetManagementRow(
                    preset: preset,
                    mainShortcut: settings.keyboardShortcut,
                    allPresets: presetManager.presets,
                    onRename: { newName in
                        presetManager.renamePreset(id: preset.id, to: newName)
                    },
                    onDelete: {
                        presetManager.deletePreset(id: preset.id)
                    },
                    onShortcutChanged: { shortcut in
                        presetManager.updateShortcut(for: preset.id, shortcut: shortcut)
                    }
                )
            }

            Button("Restore Defaults") {
                showRestoreDefaults = true
            }
            .alert("Restore Default Presets?", isPresented: $showRestoreDefaults) {
                Button("Cancel", role: .cancel) {}
                Button("Restore", role: .destructive) { presetManager.restoreDefaultPresets() }
            } message: {
                Text("This will replace all your presets with the defaults. Custom presets and shortcuts will be lost.")
            }
        }
    }

    // MARK: - About

    private var aboutSection: some View {
        Section("About") {
            Button("About Dimmerly") {
                showAboutPanel()
            }

            Button {
                if let url = URL(string: "https://github.com/olujicz/Dimmerly") {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                HStack(spacing: 2) {
                    Text("Source Code on GitHub")
                    Image(systemName: "arrow.up.forward")
                        .imageScale(.small)
                }
            }
        }
    }

    private func showAboutPanel() {
        let centeredStyle = NSMutableParagraphStyle()
        centeredStyle.alignment = .center

        let credits = NSMutableAttributedString()

        let description = NSAttributedString(
            string: NSLocalizedString("A macOS menu bar utility for putting your displays to sleep \u{2014} with a single keyboard shortcut.\n", comment: "About panel description"),
            attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: centeredStyle,
            ]
        )
        credits.append(description)

        let linkText = NSAttributedString(
            string: NSLocalizedString("Source Code on GitHub", comment: "About panel link label"),
            attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                .link: URL(string: "https://github.com/olujicz/Dimmerly") as Any,
                .paragraphStyle: centeredStyle,
            ]
        )
        credits.append(linkText)

        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: credits,
        ])
    }
}

// MARK: - Preset Management Row

private struct PresetManagementRow: View {
    let preset: BrightnessPreset
    let mainShortcut: GlobalShortcut
    let allPresets: [BrightnessPreset]
    let onRename: (String) -> Void
    let onDelete: () -> Void
    let onShortcutChanged: (GlobalShortcut?) -> Void

    @State private var isEditing = false
    @State private var editedName: String = ""
    @State private var isRecordingShortcut = false
    @State private var conflictMessage: String?
    @State private var showDeleteConfirmation = false
    @State private var isHovered = false

    var body: some View {
        HStack {
            if isEditing {
                TextField("Name", text: $editedName, onCommit: {
                    let trimmed = editedName.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty {
                        onRename(trimmed)
                    }
                    isEditing = false
                })
                .textFieldStyle(.roundedBorder)
            } else {
                Text(preset.name)
                    .contextMenu {
                        Button("Rename") {
                            editedName = preset.name
                            isEditing = true
                        }
                    }

                if isHovered {
                    Button {
                        editedName = preset.name
                        isEditing = true
                    } label: {
                        Image(systemName: "pencil")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(Text("Rename \(preset.name)"))
                    .help(Text("Rename Preset"))
                }
            }

            Spacer()

            // Shortcut recorder
            PresetShortcutRecorderButton(
                shortcut: preset.shortcut,
                onRecord: { newShortcut in
                    // Check for conflicts
                    if let sc = newShortcut {
                        if sc == mainShortcut {
                            conflictMessage = String(
                                format: NSLocalizedString("This shortcut conflicts with %@", comment: "Shortcut conflict message"),
                                NSLocalizedString("Sleep Displays", comment: "Main shortcut name")
                            )
                            return
                        }
                        for other in allPresets where other.id != preset.id {
                            if other.shortcut == sc {
                                conflictMessage = String(
                                    format: NSLocalizedString("This shortcut conflicts with %@", comment: "Shortcut conflict message"),
                                    other.name
                                )
                                return
                            }
                        }
                    }
                    conflictMessage = nil
                    onShortcutChanged(newShortcut)
                }
            )

            Button {
                showDeleteConfirmation = true
            } label: {
                Image(systemName: "trash")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(Text("Delete \(preset.name)"))
            .help(Text("Delete Preset"))
            .alert("Delete Preset?", isPresented: $showDeleteConfirmation) {
                Button("Cancel", role: .cancel) {}
                Button("Delete", role: .destructive) { onDelete() }
            } message: {
                Text("\"\(preset.name)\" will be permanently deleted.")
            }
        }
        .onHover { isHovered = $0 }

        if let conflictMessage {
            Label(conflictMessage, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .symbolRenderingMode(.multicolor)
        }
    }
}

// MARK: - Preset Shortcut Recorder Button

private struct PresetShortcutRecorderButton: View {
    let shortcut: GlobalShortcut?
    let onRecord: (GlobalShortcut?) -> Void

    @State private var isRecording = false

    var body: some View {
        Button {
            isRecording.toggle()
        } label: {
            if isRecording {
                Text("Press shortcut\u{2026}")
                    .font(.caption)
                    .frame(minWidth: 60)
            } else {
                Text(shortcut?.displayString ?? NSLocalizedString("Set\u{2026}", comment: "Preset shortcut button placeholder"))
                    .font(.caption)
                    .foregroundStyle(shortcut != nil ? .primary : .secondary)
                    .frame(minWidth: 60)
            }
        }
        .buttonStyle(.bordered)
        .tint(isRecording ? .accentColor : nil)
        .overlay(
            PresetShortcutCaptureView(
                isActive: isRecording,
                onCapture: { captured in
                    isRecording = false
                    onRecord(captured)
                },
                onCancel: {
                    isRecording = false
                }
            )
            .allowsHitTesting(isRecording)
            .opacity(0)
        )
        .contextMenu {
            if shortcut != nil {
                Button("Clear Shortcut") {
                    onRecord(nil)
                }
            }
        }
    }
}

// MARK: - Preset Shortcut Capture View

private struct PresetShortcutCaptureView: NSViewRepresentable {
    let isActive: Bool
    let onCapture: (GlobalShortcut) -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> PresetShortcutNSView {
        let view = PresetShortcutNSView()
        view.onCapture = onCapture
        view.onCancel = onCancel
        return view
    }

    func updateNSView(_ nsView: PresetShortcutNSView, context: Context) {
        nsView.isActive = isActive
        if isActive {
            nsView.window?.makeFirstResponder(nsView)
        }
    }
}

private class PresetShortcutNSView: NSView {
    var onCapture: ((GlobalShortcut) -> Void)?
    var onCancel: (() -> Void)?
    var isActive = false

    override var acceptsFirstResponder: Bool { isActive }

    override func keyDown(with event: NSEvent) {
        guard isActive else {
            super.keyDown(with: event)
            return
        }

        if event.keyCode == 53 { // Escape
            onCancel?()
            return
        }

        if let shortcut = GlobalShortcut.from(keyCode: event.keyCode, modifierFlags: event.modifierFlags),
           shortcut.isValid {
            onCapture?(shortcut)
        }
    }

    override func mouseDown(with event: NSEvent) {
        if isActive {
            onCancel?()
        }
        super.mouseDown(with: event)
    }
}

#Preview {
    SettingsView()
        .environmentObject(AppSettings())
        .environmentObject(KeyboardShortcutManager())
        .environmentObject(PresetManager())
        .environmentObject(BrightnessManager())
        .environmentObject(ScheduleManager())
        .environmentObject(LocationProvider.shared)
}

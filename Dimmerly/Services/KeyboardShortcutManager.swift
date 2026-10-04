//
//  KeyboardShortcutManager.swift
//  Dimmerly
//
//  Manager for global keyboard shortcut monitoring.
//  App Store builds use permission-free Carbon hotkey registration.
//

import AppKit
import Carbon
import Foundation
import Observation

/// Coordinates recorder overlays with the two shortcut managers. Monitoring can remain installed
/// while a recorder is visible, but normal actions must be suppressed until every recorder exits.
@MainActor
final class ShortcutRecordingCoordinator {
    static let shared = ShortcutRecordingCoordinator()

    private var activeRecorderIDs: Set<UUID> = []
    private var observers: [UUID: @MainActor () -> Void] = [:]

    var isRecording: Bool {
        !activeRecorderIDs.isEmpty
    }

    func setRecording(_ isRecording: Bool, for recorderID: UUID) {
        let wasRecording = self.isRecording
        if isRecording {
            activeRecorderIDs.insert(recorderID)
        } else {
            activeRecorderIDs.remove(recorderID)
        }
        if wasRecording != self.isRecording {
            for observer in Array(observers.values) {
                observer()
            }
        }
    }

    func observe(_ id: UUID, onChange: @escaping @MainActor () -> Void) {
        observers[id] = onChange
    }

    func removeObserver(_ id: UUID) {
        observers.removeValue(forKey: id)
    }
}

#if !APPSTORE
    /// Manages global keyboard shortcuts for the application
    @MainActor
    @Observable
    class KeyboardShortcutManager {
        typealias PermissionChecker = @MainActor () -> Bool
        typealias GlobalMonitorInstaller = @MainActor (@escaping (NSEvent) -> Void) -> Any?
        typealias LocalMonitorInstaller = @MainActor (@escaping (NSEvent) -> NSEvent?) -> Any?
        typealias MonitorRemover = @MainActor (Any) -> Void
        /// Whether a recorder overlay is capturing keys, in which case normal actions stay suppressed.
        /// Injected like the monitor seams so `handleKeyEvent` is testable without the shared coordinator.
        typealias RecordingSuppressionChecker = @MainActor () -> Bool

        /// The currently registered keyboard shortcut
        var currentShortcut: GlobalShortcut

        /// Whether accessibility permissions have been granted
        var hasAccessibilityPermission: Bool = false

        /// The global event monitor for keyboard events (active when app is not frontmost)
        private var globalEventMonitor: Any?
        /// The local event monitor for keyboard events (active when app is frontmost)
        private var localEventMonitor: Any?

        /// Callback to invoke when the shortcut is triggered
        private var onShortcutTriggered: (() -> Void)?

        private let permissionChecker: PermissionChecker
        private let globalMonitorInstaller: GlobalMonitorInstaller
        private let localMonitorInstaller: LocalMonitorInstaller
        private let monitorRemover: MonitorRemover
        private let isRecordingSuppressed: RecordingSuppressionChecker

        /// Initializes the manager with a keyboard shortcut
        ///
        /// - Parameter shortcut: The keyboard shortcut to monitor
        init(
            shortcut: GlobalShortcut = .default,
            permissionChecker: @escaping PermissionChecker = KeyboardShortcutManager.checkAccessibilityPermission,
            globalMonitorInstaller: @escaping GlobalMonitorInstaller = { handler in
                NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: handler)
            },
            localMonitorInstaller: @escaping LocalMonitorInstaller = { handler in
                NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: handler)
            },
            monitorRemover: @escaping MonitorRemover = { monitor in
                NSEvent.removeMonitor(monitor)
            },
            isRecordingSuppressed: @escaping RecordingSuppressionChecker = {
                ShortcutRecordingCoordinator.shared.isRecording
            }
        ) {
            currentShortcut = shortcut
            self.permissionChecker = permissionChecker
            self.globalMonitorInstaller = globalMonitorInstaller
            self.localMonitorInstaller = localMonitorInstaller
            self.monitorRemover = monitorRemover
            self.isRecordingSuppressed = isRecordingSuppressed
            hasAccessibilityPermission = permissionChecker()
        }

        /// Checks if the app has accessibility permissions
        ///
        /// - Returns: true if permissions are granted
        static func checkAccessibilityPermission() -> Bool {
            AXIsProcessTrusted()
        }

        /// Requests accessibility permissions from the user
        ///
        /// This will show the system dialog prompting the user to grant access
        static func requestAccessibilityPermission() {
            let options = ["AXTrustedCheckOptionPrompt": true]
            AXIsProcessTrustedWithOptions(options as CFDictionary)
        }

        /// Starts monitoring for the configured keyboard shortcut
        ///
        /// - Parameter onTriggered: Callback to invoke when the shortcut is pressed
        func startMonitoring(onTriggered: @escaping () -> Void) {
            onShortcutTriggered = onTriggered
            stopMonitoring()

            // Check for permissions (don't prompt — let the user enable via Settings)
            hasAccessibilityPermission = permissionChecker()

            if !hasAccessibilityPermission {
                return
            }

            // Global monitor for when another app is frontmost
            globalEventMonitor = globalMonitorInstaller { [weak self] event in
                let keyCode = event.keyCode
                let modifierFlags = event.modifierFlags
                Task { @MainActor in
                    _ = self?.handleKeyEvent(keyCode: keyCode, modifierFlags: modifierFlags)
                }
            }

            // Local monitor for when Dimmerly is frontmost. Matched events are swallowed
            // (return nil) instead of always passing through — otherwise the shortcut both
            // triggers its action and reaches whatever UI element has focus (e.g. typing/
            // beeping into a focused text field in Settings). The match check runs
            // synchronously via `MainActor.assumeIsolated`, since NSEvent local monitor
            // callbacks always fire on the main thread, so the return value can reflect
            // the outcome instead of always passing the event through.
            localEventMonitor = localMonitorInstaller { [weak self] event in
                let keyCode = event.keyCode
                let modifierFlags = event.modifierFlags
                let matched = MainActor.assumeIsolated {
                    self?.handleKeyEvent(keyCode: keyCode, modifierFlags: modifierFlags) ?? false
                }
                return matched ? nil : event
            }
        }

        /// Stops monitoring for keyboard shortcuts
        func stopMonitoring() {
            if let monitor = globalEventMonitor {
                monitorRemover(monitor)
                globalEventMonitor = nil
            }
            if let monitor = localEventMonitor {
                monitorRemover(monitor)
                localEventMonitor = nil
            }
        }

        /// Rechecks Accessibility permission and starts monitoring if permission was
        /// granted after an earlier failed start attempt.
        func refreshAccessibilityPermissionAndRestartIfNeeded() {
            hasAccessibilityPermission = permissionChecker()
            guard hasAccessibilityPermission else {
                stopMonitoring()
                return
            }
            guard globalEventMonitor == nil, localEventMonitor == nil,
                  let callback = onShortcutTriggered
            else {
                return
            }
            startMonitoring(onTriggered: callback)
        }

        /// Updates the monitored keyboard shortcut
        ///
        /// This will restart monitoring with the new shortcut if monitoring is active
        ///
        /// - Parameter shortcut: The new keyboard shortcut to monitor
        func updateShortcut(_ shortcut: GlobalShortcut) {
            currentShortcut = shortcut

            // Restart monitoring if it was active
            if globalEventMonitor != nil || localEventMonitor != nil,
               let callback = onShortcutTriggered
            {
                startMonitoring(onTriggered: callback)
            }
        }

        /// Handles incoming keyboard events and triggers the callback if they match the current shortcut.
        ///
        /// This method compares the event's physical key code and modifiers through
        /// `GlobalShortcut.matches`, then invokes the callback if they match. Display labels and
        /// shifted character output do not affect runtime matching.
        ///
        /// - Parameters:
        ///   - keyCode: Raw keyboard key code from NSEvent
        ///   - modifierFlags: Modifier keys (⌘⌥⌃⇧) from NSEvent
        /// - Returns: `true` if the event matched the configured shortcut (and the callback fired).
        @discardableResult
        private func handleKeyEvent(keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags) -> Bool {
            guard !isRecordingSuppressed(),
                  currentShortcut.matches(keyCode: keyCode, modifierFlags: modifierFlags)
            else { return false }
            onShortcutTriggered?()
            return true
        }

        // MARK: - Lifecycle

        // Note: deinit intentionally omitted to avoid @MainActor data race warnings in Swift 6.
        // This manager is held by @State in DimmerlyApp for the app's lifetime, so deinit
        // never executes. Cleanup is handled explicitly via stopMonitoring() when needed.
    }

#endif

/// Owns one Carbon event handler and hotkey. All registration and delivery runs on the main thread.
@MainActor
final class CarbonHotKeyRegistration {
    private static var nextID: UInt32 = 0
    private static let signature: OSType = 0x446d726c // Dmrl
    private var hotKey: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var onTriggered: (@MainActor () -> Void)?
    private let id: UInt32

    private init(onTriggered: @escaping @MainActor () -> Void) {
        Self.nextID += 1
        id = Self.nextID
        self.onTriggered = onTriggered
    }

    static func modifiers(for shortcut: GlobalShortcut) -> UInt32 {
        var flags: UInt32 = 0
        if shortcut.modifiers.contains(.command) {
            flags |= UInt32(cmdKey)
        }
        if shortcut.modifiers.contains(.option) {
            flags |= UInt32(optionKey)
        }
        if shortcut.modifiers.contains(.control) {
            flags |= UInt32(controlKey)
        }
        if shortcut.modifiers.contains(.shift) {
            flags |= UInt32(shiftKey)
        }
        return flags
    }

    static func install(
        shortcut: GlobalShortcut,
        onTriggered: @escaping @MainActor () -> Void
    ) -> Any? {
        guard let keyCode = shortcut.registrationKeyCode, shortcut.isValidCarbonShortcut else { return nil }
        let registration = CarbonHotKeyRegistration(onTriggered: onTriggered)
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(registration).toOpaque()
        let handlerStatus = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            return MainActor.assumeIsolated {
                let registration = Unmanaged<CarbonHotKeyRegistration>.fromOpaque(context).takeUnretainedValue()
                return registration.handle(event)
            }
        }, 1, &eventType, context, &registration.eventHandler)
        guard handlerStatus == noErr else {
            registration.cancel()
            return nil
        }
        let status = RegisterEventHotKey(
            UInt32(keyCode), modifiers(for: shortcut),
            EventHotKeyID(signature: signature, id: registration.id),
            GetApplicationEventTarget(), 0, &registration.hotKey
        )
        guard status == noErr else {
            registration.cancel()
            return nil
        }
        return registration
    }

    private func handle(_ event: EventRef) -> OSStatus {
        var hotKeyID = EventHotKeyID()
        let status = GetEventParameter(
            event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
            nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID
        )
        guard status == noErr, hotKeyID.signature == Self.signature, hotKeyID.id == id,
              let onTriggered
        else { return OSStatus(eventNotHandledErr) }
        onTriggered()
        return noErr
    }

    isolated deinit {
        cancel()
    }

    func cancel() {
        onTriggered = nil
        if let hotKey {
            UnregisterEventHotKey(hotKey)
            self.hotKey = nil
        }
        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
    }
}

/// Shared registration lifecycle, injected in tests without reserving real keys.
/// Carbon consumes registered keys even in our own app, so recording releases them temporarily.
@MainActor
@Observable
final class CarbonShortcutMonitor {
    struct Binding: Equatable {
        let id: UUID
        let shortcut: GlobalShortcut
    }

    typealias Installer = @MainActor (GlobalShortcut, @escaping @MainActor () -> Void) -> Any?
    typealias Remover = @MainActor (Any) -> Void

    private(set) var failedBindingIDs: Set<UUID> = []
    var hasInvalidShortcuts: Bool {
        bindings.contains { !$0.shortcut.isValidCarbonShortcut }
    }

    var onTriggered: ((UUID) -> Void)?
    private var bindings: [Binding] = []
    private var registrations: [UUID: Any] = [:]
    private var generation = UUID()
    private let observerID = UUID()
    private let coordinator: ShortcutRecordingCoordinator
    private let installer: Installer
    private let remover: Remover

    init(
        coordinator: ShortcutRecordingCoordinator = .shared,
        installer: @escaping Installer = { CarbonHotKeyRegistration.install(shortcut: $0, onTriggered: $1) },
        remover: @escaping Remover = { ($0 as? CarbonHotKeyRegistration)?.cancel() }
    ) {
        self.coordinator = coordinator
        self.installer = installer
        self.remover = remover
    }

    func updateBindings(_ newBindings: [Binding]) {
        guard bindings != newBindings else { return }
        releaseRegistrations()
        bindings = newBindings
        if bindings.isEmpty {
            coordinator.removeObserver(observerID)
        } else {
            coordinator.observe(observerID) { [weak self] in
                guard let self else { return }
                if coordinator.isRecording {
                    releaseRegistrations()
                } else {
                    retryFailedRegistrations()
                }
            }
            retryFailedRegistrations()
        }
    }

    func retryFailedRegistrations() {
        guard !coordinator.isRecording else { return }
        let generation = generation
        for binding in bindings where registrations[binding.id] == nil {
            guard binding.shortcut.isValidCarbonShortcut else {
                failedBindingIDs.insert(binding.id)
                continue
            }
            if let token = installer(binding.shortcut, { [weak self] in
                guard let self, self.generation == generation,
                      !self.coordinator.isRecording, self.registrations[binding.id] != nil
                else { return }
                self.onTriggered?(binding.id)
            }) {
                registrations[binding.id] = token
                failedBindingIDs.remove(binding.id)
            } else {
                failedBindingIDs.insert(binding.id)
            }
        }
    }

    isolated deinit {
        for registration in registrations.values {
            remover(registration)
        }
        coordinator.removeObserver(observerID)
    }

    func stop() {
        releaseRegistrations()
        bindings = []
        coordinator.removeObserver(observerID)
    }

    private func releaseRegistrations() {
        generation = UUID()
        for registration in registrations.values {
            remover(registration)
        }
        registrations.removeAll()
        failedBindingIDs.removeAll()
    }
}

#if APPSTORE
    /// Permission-free global shortcut registration for the sandboxed distribution.
    @MainActor
    @Observable
    final class KeyboardShortcutManager {
        var currentShortcut: GlobalShortcut
        private let bindingID = UUID()
        private let monitor: CarbonShortcutMonitor
        private var onShortcutTriggered: (() -> Void)?

        var hasInvalidShortcuts: Bool {
            monitor.hasInvalidShortcuts
        }

        var hasRegistrationFailure: Bool {
            !monitor.failedBindingIDs.isEmpty
        }

        init(shortcut: GlobalShortcut = .default, monitor: CarbonShortcutMonitor = CarbonShortcutMonitor()) {
            currentShortcut = shortcut
            self.monitor = monitor
        }

        func startMonitoring(onTriggered: @escaping () -> Void) {
            onShortcutTriggered = onTriggered
            monitor.onTriggered = { [weak self] _ in self?.onShortcutTriggered?() }
            monitor.updateBindings([.init(id: bindingID, shortcut: currentShortcut)])
            monitor.retryFailedRegistrations()
        }

        func stopMonitoring() {
            monitor.stop()
            onShortcutTriggered = nil
        }

        func updateShortcut(_ shortcut: GlobalShortcut) {
            currentShortcut = shortcut
            guard onShortcutTriggered != nil else { return }
            monitor.updateBindings([.init(id: bindingID, shortcut: shortcut)])
        }

        func retryFailedRegistrations() {
            monitor.retryFailedRegistrations()
        }
    }
#endif

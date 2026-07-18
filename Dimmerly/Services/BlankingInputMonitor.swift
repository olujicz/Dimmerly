//
//  BlankingInputMonitor.swift
//  Dimmerly
//
//  Distribution-specific input filtering used while screen blanking is active.
//

import AppKit
#if !APPSTORE
    import ApplicationServices
#endif

enum BlankingInputPolicy: Equatable, Sendable {
    case escapeOnly
    case anyInput(ignorePointerMovement: Bool)
}

enum BlankingInputMonitorError: LocalizedError, Equatable, Sendable {
    case accessibilityPermissionDenied
    case unavailable
    case invalidated
    case timedOut

    var errorDescription: String? {
        switch self {
        case .accessibilityPermissionDenied:
            String(localized: "Accessibility permission is required to suppress wake input safely.")
        case .unavailable:
            String(localized: "Input filtering could not be started.")
        case .invalidated:
            String(localized: "Input filtering stopped unexpectedly.")
        case .timedOut:
            String(localized: "Input filtering timed out.")
        }
    }

    var settingsURL: URL? {
        guard self == .accessibilityPermissionDenied else { return nil }
        return URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        )
    }
}

enum BlankingInputEvent: Equatable, Sendable {
    case keyDown(keyCode: UInt16)
    case keyUp(keyCode: UInt16)
    case flagsChanged
    case leftMouseDown
    case leftMouseUp
    case leftMouseDragged
    case rightMouseDown
    case rightMouseUp
    case rightMouseDragged
    case otherMouseDown
    case otherMouseUp
    case otherMouseDragged
    case mouseMoved
    case scrollWheel
    case systemDefined
    case gesture
    case tapDisabledByTimeout
    case tapDisabledByUserInput
}

enum BlankingInputDecision: Equatable, Sendable {
    case passThrough
    case suppress
    case suppressAndWake
    case fail(BlankingInputMonitorError)

    static func resolve(
        event: BlankingInputEvent,
        policy: BlankingInputPolicy
    ) -> BlankingInputDecision {
        switch event {
        case .tapDisabledByTimeout:
            return .fail(.timedOut)
        case .tapDisabledByUserInput:
            return .fail(.invalidated)
        case .systemDefined, .gesture:
            return .passThrough
        default:
            break
        }

        switch policy {
        case .escapeOnly:
            if case let .keyDown(keyCode) = event, keyCode == 53 {
                return .suppressAndWake
            }
            return .suppress
        case let .anyInput(ignorePointerMovement):
            if ignorePointerMovement, event == .mouseMoved {
                return .passThrough
            }
            return .suppressAndWake
        }
    }
}

@MainActor
protocol BlankingInputMonitoring: AnyObject {
    func start(
        policy: BlankingInputPolicy,
        onWake: @escaping @MainActor () -> Void,
        onFailure: @escaping @MainActor (BlankingInputMonitorError) -> Void
    ) throws

    func stop()
}

#if !APPSTORE

    /// Active Core Graphics event tap used by the direct build. Returning nil from the tap
    /// discards covered events before the previously frontmost application receives them.
    @MainActor
    final class SystemBlankingInputMonitor: BlankingInputMonitoring {
        private var eventTap: CFMachPort?
        private var runLoopSource: CFRunLoopSource?
        private var context: EventTapContext?

        func start(
            policy: BlankingInputPolicy,
            onWake: @escaping @MainActor () -> Void,
            onFailure: @escaping @MainActor (BlankingInputMonitorError) -> Void
        ) throws {
            stop()

            guard AXIsProcessTrusted() else {
                throw BlankingInputMonitorError.accessibilityPermissionDenied
            }

            let context = EventTapContext(
                policy: policy,
                onWake: onWake,
                onFailure: onFailure
            )
            guard let eventTap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: Self.eventMask,
                callback: blankingEventTapCallback,
                userInfo: Unmanaged.passUnretained(context).toOpaque()
            ) else {
                throw BlankingInputMonitorError.unavailable
            }

            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            CGEvent.tapEnable(tap: eventTap, enable: true)

            self.context = context
            self.eventTap = eventTap
            runLoopSource = source
        }

        func stop() {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: false)
                CFMachPortInvalidate(eventTap)
            }
            if let runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
            }
            runLoopSource = nil
            eventTap = nil
            context = nil
        }

        private static let eventMask: CGEventMask = [
            CGEventType.keyDown, .keyUp, .flagsChanged,
            .leftMouseDown, .leftMouseUp, .leftMouseDragged,
            .rightMouseDown, .rightMouseUp, .rightMouseDragged,
            .otherMouseDown, .otherMouseUp, .otherMouseDragged,
            .mouseMoved, .scrollWheel,
        ].reduce(0) { mask, type in
            mask | (CGEventMask(1) << type.rawValue)
        }
    }

    private final class EventTapContext: @unchecked Sendable {
        private let policy: BlankingInputPolicy
        private let onWake: @MainActor () -> Void
        private let onFailure: @MainActor (BlankingInputMonitorError) -> Void
        private let lock = NSLock()
        private var hasSignalledTerminalEvent = false

        init(
            policy: BlankingInputPolicy,
            onWake: @escaping @MainActor () -> Void,
            onFailure: @escaping @MainActor (BlankingInputMonitorError) -> Void
        ) {
            self.policy = policy
            self.onWake = onWake
            self.onFailure = onFailure
        }

        func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
            guard let inputEvent = BlankingInputEvent(type: type, event: event) else {
                return Unmanaged.passUnretained(event)
            }

            switch BlankingInputDecision.resolve(event: inputEvent, policy: policy) {
            case .passThrough:
                return Unmanaged.passUnretained(event)
            case .suppress:
                return nil
            case .suppressAndWake:
                signalOnce { [onWake] in onWake() }
                return nil
            case let .fail(error):
                signalOnce { [onFailure] in onFailure(error) }
                return Unmanaged.passUnretained(event)
            }
        }

        private func signalOnce(_ action: @escaping @MainActor () -> Void) {
            lock.lock()
            let shouldSignal = !hasSignalledTerminalEvent
            hasSignalledTerminalEvent = true
            lock.unlock()
            guard shouldSignal else { return }

            DispatchQueue.main.async {
                action()
            }
        }
    }

    private let blankingEventTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else { return Unmanaged.passUnretained(event) }
        let context = Unmanaged<EventTapContext>.fromOpaque(userInfo).takeUnretainedValue()
        return context.handle(type: type, event: event)
    }

    private extension BlankingInputEvent {
        init?(type: CGEventType, event: CGEvent) {
            switch type {
            case .keyDown: self = .keyDown(keyCode: UInt16(event.getIntegerValueField(.keyboardEventKeycode)))
            case .keyUp: self = .keyUp(keyCode: UInt16(event.getIntegerValueField(.keyboardEventKeycode)))
            case .flagsChanged: self = .flagsChanged
            case .tapDisabledByTimeout: self = .tapDisabledByTimeout
            case .tapDisabledByUserInput: self = .tapDisabledByUserInput
            default:
                self.init(mouseEventType: type)
            }
        }

        init?(mouseEventType: CGEventType) {
            switch mouseEventType {
            case .leftMouseDown: self = .leftMouseDown
            case .leftMouseUp: self = .leftMouseUp
            case .leftMouseDragged: self = .leftMouseDragged
            case .rightMouseDown: self = .rightMouseDown
            case .rightMouseUp: self = .rightMouseUp
            case .rightMouseDragged: self = .rightMouseDragged
            case .otherMouseDown: self = .otherMouseDown
            case .otherMouseUp: self = .otherMouseUp
            case .otherMouseDragged: self = .otherMouseDragged
            case .mouseMoved: self = .mouseMoved
            case .scrollWheel: self = .scrollWheel
            default: return nil
            }
        }
    }

#else

    /// The App Store build activates key-capable overlay windows and can consume only the
    /// events AppKit routes to Dimmerly. System shortcuts and media keys remain outside this
    /// explicitly limited fallback contract.
    @MainActor
    final class SystemBlankingInputMonitor: BlankingInputMonitoring {
        private var localMonitor: Any?

        func start(
            policy: BlankingInputPolicy,
            onWake: @escaping @MainActor () -> Void,
            onFailure _: @escaping @MainActor (BlankingInputMonitorError) -> Void
        ) throws {
            stop()
            localMonitor = NSEvent.addLocalMonitorForEvents(matching: Self.eventMask) { event in
                guard let inputEvent = BlankingInputEvent(event) else { return event }
                switch BlankingInputDecision.resolve(event: inputEvent, policy: policy) {
                case .passThrough:
                    return event
                case .suppress:
                    return nil
                case .suppressAndWake:
                    MainActor.assumeIsolated { onWake() }
                    return nil
                case .fail:
                    return event
                }
            }
            guard localMonitor != nil else {
                throw BlankingInputMonitorError.unavailable
            }
        }

        func stop() {
            if let localMonitor {
                NSEvent.removeMonitor(localMonitor)
            }
            localMonitor = nil
        }

        private static let eventMask: NSEvent.EventTypeMask = [
            .keyDown, .keyUp, .flagsChanged,
            .leftMouseDown, .leftMouseUp, .leftMouseDragged,
            .rightMouseDown, .rightMouseUp, .rightMouseDragged,
            .otherMouseDown, .otherMouseUp, .otherMouseDragged,
            .mouseMoved, .scrollWheel,
        ]
    }

    private extension BlankingInputEvent {
        init?(_ event: NSEvent) {
            switch event.type {
            case .keyDown: self = .keyDown(keyCode: event.keyCode)
            case .keyUp: self = .keyUp(keyCode: event.keyCode)
            case .flagsChanged: self = .flagsChanged
            case .systemDefined: self = .systemDefined
            case .gesture, .magnify, .swipe, .rotate, .beginGesture, .endGesture: self = .gesture
            default:
                self.init(mouseEventType: event.type)
            }
        }

        init?(mouseEventType: NSEvent.EventType) {
            switch mouseEventType {
            case .leftMouseDown: self = .leftMouseDown
            case .leftMouseUp: self = .leftMouseUp
            case .leftMouseDragged: self = .leftMouseDragged
            case .rightMouseDown: self = .rightMouseDown
            case .rightMouseUp: self = .rightMouseUp
            case .rightMouseDragged: self = .rightMouseDragged
            case .otherMouseDown: self = .otherMouseDown
            case .otherMouseUp: self = .otherMouseUp
            case .otherMouseDragged: self = .otherMouseDragged
            case .mouseMoved: self = .mouseMoved
            case .scrollWheel: self = .scrollWheel
            default: return nil
            }
        }
    }

#endif

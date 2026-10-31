//
//  PresetShortcutCaptureViewTests.swift
//  DimmerlyTests
//
//  Tests that the shared shortcut capture view always uses the latest caller callbacks.
//

import AppKit
@testable import Dimmerly
import XCTest

@MainActor
final class PresetShortcutCaptureViewTests: XCTestCase {
    private let shortcut = GlobalShortcut(key: "x", modifiers: [.command, .option])

    func testLaterConfigurationReplacesCaptureCallbacks() {
        let nsView = ShortcutCaptureNSView()
        var captures: [String] = []

        makeCaptureView(label: "first") { captures.append($0) }.configure(nsView)
        makeCaptureView(label: "second") { captures.append($0) }.configure(nsView)
        nsView.onCapture?(shortcut)
        nsView.onCancel?()
        nsView.onConflictDetected?("conflict")

        XCTAssertEqual(captures, ["second capture", "second cancel", "second conflict"])
    }

    func testConfigurationUpdatesActiveState() {
        let nsView = ShortcutCaptureNSView()

        makeCaptureView(label: "on", isActive: true) { _ in }.configure(nsView)
        XCTAssertTrue(nsView.acceptsFirstResponder)

        makeCaptureView(label: "off", isActive: false) { _ in }.configure(nsView)
        XCTAssertFalse(nsView.acceptsFirstResponder)
    }

    func testLosingFirstResponderCancelsRecording() {
        let (window, nsView) = makeHostedCaptureView()
        var cancelCount = 0
        nsView.onCancel = { cancelCount += 1 }
        nsView.isActive = true
        XCTAssertTrue(window.makeFirstResponder(nsView))

        // Clicking another recorder or field moves first responder away.
        XCTAssertTrue(window.makeFirstResponder(nil))

        XCTAssertEqual(cancelCount, 1)
        XCTAssertFalse(nsView.isActive)
    }

    func testWindowResigningKeyCancelsRecording() {
        let (window, nsView) = makeHostedCaptureView()
        var cancelCount = 0
        nsView.onCancel = { cancelCount += 1 }
        nsView.isActive = true

        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)

        XCTAssertEqual(cancelCount, 1)
        XCTAssertFalse(nsView.isActive)
    }

    func testOtherWindowResigningKeyDoesNotCancelRecording() {
        let (_, nsView) = makeHostedCaptureView()
        let otherWindow = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
        var cancelCount = 0
        nsView.onCancel = { cancelCount += 1 }
        nsView.isActive = true

        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: otherWindow)

        XCTAssertEqual(cancelCount, 0)
        XCTAssertTrue(nsView.isActive)
    }

    func testCapturedShortcutDoesNotAlsoCancelWhenFocusLeaves() throws {
        let (window, nsView) = makeHostedCaptureView()
        var events: [String] = []
        nsView.onCapture = { _ in events.append("capture") }
        nsView.onCancel = { events.append("cancel") }
        nsView.isActive = true
        XCTAssertTrue(window.makeFirstResponder(nsView))

        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.command, .option],
            timestamp: 0, windowNumber: 0, context: nil,
            characters: "x", charactersIgnoringModifiers: "x",
            isARepeat: false, keyCode: 7 // kVK_ANSI_X
        ))
        nsView.keyDown(with: event)
        window.makeFirstResponder(nil)
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)

        XCTAssertEqual(events, ["capture"])
    }

    /// ⌘ combinations reach the window as key equivalents before `keyDown`. When another view
    /// claims one (⌥⇧⌘D in the Settings window), recording must still capture it.
    func testRecordingCapturesKeyEquivalent() throws {
        let (window, nsView) = makeHostedCaptureView()
        var captured: [GlobalShortcut] = []
        nsView.onCapture = { captured.append($0) }
        nsView.isActive = true
        XCTAssertTrue(window.makeFirstResponder(nsView))

        XCTAssertTrue(try nsView.performKeyEquivalent(with: makeKeyEvent()))

        XCTAssertEqual(captured.map(\.displayString), [shortcut.displayString])
        XCTAssertFalse(nsView.isActive)
    }

    func testIdleOrUnfocusedCaptureViewLeavesKeyEquivalentsAlone() throws {
        let (window, nsView) = makeHostedCaptureView()
        var captureCount = 0
        nsView.onCapture = { _ in captureCount += 1 }
        let event = try makeKeyEvent()

        XCTAssertFalse(nsView.performKeyEquivalent(with: event))

        // A second recorder in the same window sees the event too; only the focused one records.
        nsView.isActive = true
        window.makeFirstResponder(nil)
        XCTAssertFalse(nsView.performKeyEquivalent(with: event))

        XCTAssertEqual(captureCount, 0)
    }

    func testResigningFirstResponderWhileIdleDoesNotCancel() {
        let (window, nsView) = makeHostedCaptureView()
        var cancelCount = 0
        nsView.onCancel = { cancelCount += 1 }
        nsView.isActive = true
        XCTAssertTrue(window.makeFirstResponder(nsView))
        nsView.isActive = false

        window.makeFirstResponder(nil)

        XCTAssertEqual(cancelCount, 0)
    }

    private func makeKeyEvent() throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.command, .option],
            timestamp: 0, windowNumber: 0, context: nil,
            characters: "x", charactersIgnoringModifiers: "x",
            isARepeat: false, keyCode: 7 // kVK_ANSI_X
        ))
    }

    private func makeHostedCaptureView() -> (NSWindow, ShortcutCaptureNSView) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
            styleMask: [.titled], backing: .buffered, defer: true
        )
        window.isReleasedWhenClosed = false
        let nsView = ShortcutCaptureNSView(frame: NSRect(x: 0, y: 0, width: 100, height: 20))
        window.contentView?.addSubview(nsView)
        return (window, nsView)
    }

    private func makeCaptureView(
        label: String,
        isActive: Bool = true,
        record: @escaping (String) -> Void
    ) -> ShortcutCaptureView {
        ShortcutCaptureView(
            isActive: isActive,
            onCapture: { _ in record("\(label) capture") },
            onCancel: { record("\(label) cancel") },
            onConflictDetected: { record("\(label) \($0)") }
        )
    }
}

//
//  PresetShortcutCaptureViewTests.swift
//  DimmerlyTests
//
//  Tests that the preset shortcut capture view always uses the latest row callbacks.
//

@testable import Dimmerly
import XCTest

@MainActor
final class PresetShortcutCaptureViewTests: XCTestCase {
    private let shortcut = GlobalShortcut(key: "x", modifiers: [.command, .option])

    func testLaterConfigurationReplacesCaptureCallbacks() {
        let nsView = PresetShortcutNSView()
        var captures: [String] = []

        makeCaptureView(label: "first") { captures.append($0) }.configure(nsView)
        makeCaptureView(label: "second") { captures.append($0) }.configure(nsView)
        nsView.onCapture?(shortcut)
        nsView.onCancel?()
        nsView.onConflictDetected?("conflict")

        XCTAssertEqual(captures, ["second capture", "second cancel", "second conflict"])
    }

    func testConfigurationUpdatesActiveState() {
        let nsView = PresetShortcutNSView()

        makeCaptureView(label: "on", isActive: true) { _ in }.configure(nsView)
        XCTAssertTrue(nsView.acceptsFirstResponder)

        makeCaptureView(label: "off", isActive: false) { _ in }.configure(nsView)
        XCTAssertFalse(nsView.acceptsFirstResponder)
    }

    private func makeCaptureView(
        label: String,
        isActive: Bool = true,
        record: @escaping (String) -> Void
    ) -> PresetShortcutCaptureView {
        PresetShortcutCaptureView(
            isActive: isActive,
            onCapture: { _ in record("\(label) capture") },
            onCancel: { record("\(label) cancel") },
            onConflictDetected: { record("\(label) \($0)") }
        )
    }
}

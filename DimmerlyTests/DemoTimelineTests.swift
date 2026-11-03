//
//  DemoTimelineTests.swift
//  DimmerlyTests
//
//  The debug-only demo storyboard and player behind `scripts/demo.sh`.
//

@testable import Dimmerly
import XCTest

@MainActor
final class DemoTimelineTests: XCTestCase {
    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: ScreenshotStage.defaultsSuiteName)
        super.tearDown()
    }

    // MARK: Helpers

    private static var bundledStoryboardURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts/demo/storyboard.json")
    }

    private func decode(_ json: String) throws -> DemoStoryboard {
        try JSONDecoder().decode(DemoStoryboard.self, from: Data(json.utf8))
    }

    private final class PanelCalls {
        var opened = 0
        var closed = 0
    }

    private func makePlayer(
        _ storyboard: DemoStoryboard,
        calls: PanelCalls = PanelCalls()
    ) -> (DemoPlayer, BrightnessManager) {
        let brightness = ScreenshotStage.makeBrightnessManager(displays: storyboard.displays)
        let presets = ScreenshotStage.makePresetManager(presets: storyboard.presets)
        let player = DemoPlayer(
            storyboard: storyboard,
            brightnessManager: brightness,
            presetManager: presets,
            openPanel: { calls.opened += 1 },
            closePanel: { calls.closed += 1 }
        )
        return (player, brightness)
    }

    private let oneDisplay = """
    {"fps": 10, "displays": [{"name": "A", "brightness": 1}], "presets": [],
     "steps": [{"action": "setBrightness", "value": 0.5, "duration": 1, "easing": "EASING"}]}
    """

    // MARK: The bundled storyboard

    func testBundledStoryboardIsValid() throws {
        let storyboard = try DemoStoryboard.load(from: Self.bundledStoryboardURL)
        XCTAssertEqual(storyboard.totalFrames, 450, "The demo is a 15-second loop at 30 fps")
    }

    /// The video loops, so its last frame must show what its first frame shows.
    func testBundledStoryboardEndsWhereItStarts() throws {
        let storyboard = try DemoStoryboard.load(from: Self.bundledStoryboardURL)
        let calls = PanelCalls()
        let (player, _) = makePlayer(storyboard, calls: calls)

        let records = player.advance(to: .max)

        XCTAssertEqual(records.count, storyboard.totalFrames)
        XCTAssertEqual(records.map(\.frame), Array(0 ..< storyboard.totalFrames))
        let first = try XCTUnwrap(records.first)
        let last = try XCTUnwrap(records.last)
        XCTAssertFalse(first.panelOpen)
        XCTAssertFalse(last.panelOpen)
        XCTAssertEqual(first.displays.count, last.displays.count)
        for (start, end) in zip(first.displays, last.displays) {
            XCTAssertEqual(start.brightness, end.brightness, accuracy: 0.001, start.name)
            XCTAssertEqual(start.warmth, end.warmth, accuracy: 0.001, start.name)
            XCTAssertEqual(start.contrast, end.contrast, accuracy: 0.001, start.name)
        }
        XCTAssertEqual(calls.opened, 1)
        XCTAssertEqual(calls.closed, 1)
        XCTAssertTrue(player.isFinished)
    }

    /// Every gamma write in a demo run reaches the staged no-op hook, and nothing is saved to
    /// the user's settings.
    func testBundledStoryboardLeavesRealDisplaysAndSettingsAlone() throws {
        let watchedKeys = [PresetManager.persistenceKey, "dimmerlyDisplayBrightness", "dimmerlyDisplayWarmth"]
        let before = watchedKeys.map { UserDefaults.standard.object(forKey: $0) as? NSObject }

        let storyboard = try DemoStoryboard.load(from: Self.bundledStoryboardURL)
        let (player, brightness) = makePlayer(storyboard)
        var gammaWrites = 0
        brightness.applyGammaHook = { _, _, _, _ in gammaWrites += 1 }
        _ = player.advance(to: .max)

        XCTAssertGreaterThan(gammaWrites, 0, "Value changes should reach the gamma hook")
        let after = watchedKeys.map { UserDefaults.standard.object(forKey: $0) as? NSObject }
        XCTAssertEqual(before, after)
    }

    // MARK: Timing and easing

    func testLinearStepReachesItsTargetOnItsLastFrame() throws {
        let storyboard = try decode(oneDisplay.replacingOccurrences(of: "EASING", with: "linear"))
        let (player, _) = makePlayer(storyboard)

        let records = player.advance(to: .max)

        XCTAssertEqual(records.count, 10)
        XCTAssertEqual(records[0].displays[0].brightness, 0.95, accuracy: 1e-9)
        XCTAssertEqual(records[4].displays[0].brightness, 0.75, accuracy: 1e-9)
        XCTAssertEqual(records[9].displays[0].brightness, 0.5, accuracy: 1e-9)
    }

    func testEaseInOutStartsSlowAndEndsOnTarget() throws {
        let storyboard = try decode(oneDisplay.replacingOccurrences(of: "EASING", with: "easeInOut"))
        let (player, _) = makePlayer(storyboard)

        let records = player.advance(to: .max)

        // Smoothstep at 0.2 is 0.104, so the first step is far smaller than a linear one.
        XCTAssertEqual(records[1].displays[0].brightness, 1 - 0.5 * 0.104, accuracy: 1e-9)
        XCTAssertEqual(records[4].displays[0].brightness, 0.75, accuracy: 1e-9)
        XCTAssertEqual(records[9].displays[0].brightness, 0.5, accuracy: 1e-9)
    }

    func testAdvancingInPiecesMatchesOneRun() throws {
        let storyboard = try DemoStoryboard.load(from: Self.bundledStoryboardURL)
        let (whole, _) = makePlayer(storyboard)
        let (pieces, _) = makePlayer(storyboard)

        let expected = whole.advance(to: .max)
        var actual: [DemoFrameRecord] = []
        for frame in stride(from: 3, through: storyboard.totalFrames + 3, by: 7) {
            actual += pieces.advance(to: frame)
        }

        XCTAssertEqual(actual, expected)
    }

    func testCaptionsHoldUntilTheNextOneAndEmptyClears() throws {
        let storyboard = try decode("""
        {"fps": 10, "displays": [{"name": "A", "brightness": 1}], "presets": [],
         "steps": [{"action": "wait", "duration": 0.2, "caption": "One"},
                   {"action": "wait", "duration": 0.2},
                   {"action": "wait", "duration": 0.2, "caption": ""}]}
        """)
        let (player, _) = makePlayer(storyboard)

        let captions = player.advance(to: .max).map(\.caption)

        XCTAssertEqual(captions, ["One", "One", "One", "One", "", ""])
    }

    func testPresetStepAppliesBrightnessAndWarmthToEveryDisplay() throws {
        let storyboard = try decode("""
        {"fps": 10, "displays": [{"name": "A", "brightness": 1}, {"name": "B", "brightness": 1}],
         "presets": [{"name": "Evening", "brightness": 0.6, "warmth": 0.45}],
         "steps": [{"action": "applyPreset", "preset": "Evening", "duration": 0.1}]}
        """)
        let (player, _) = makePlayer(storyboard)

        let record = try XCTUnwrap(player.advance(to: .max).last)

        for display in record.displays {
            XCTAssertEqual(display.brightness, 0.6, accuracy: 1e-9, display.name)
            XCTAssertEqual(display.warmth, 0.45, accuracy: 1e-9, display.name)
        }
    }

    // MARK: Validation

    func testBadStoryboardsAreRejectedWithTheReason() throws {
        let display = #"{"name": "A", "brightness": 1}"#
        func storyboard(steps: String, displays: String? = nil, fps: Int = 30) -> String {
            #"{"fps": \#(fps), "displays": [\#(displays ?? display)], "presets": [], "steps": [\#(steps)]}"#
        }
        let wait = #"{"action": "wait", "duration": 1}"#
        let cases: [(json: String, reason: String)] = [
            (storyboard(steps: wait, fps: 0), "fps must be between 1 and 120"),
            (storyboard(steps: wait, displays: ""), "at least one display"),
            (storyboard(steps: wait, displays: "\(display), \(display)"), #"Two displays are named "A""#),
            (
                storyboard(steps: #"{"action": "setBrightness", "duration": 1}"#),
                "Step 1 (setBrightness): needs a value"
            ),
            (
                storyboard(steps: #"{"action": "setBrightness", "value": 0.01}"#),
                "Step 1 (setBrightness) value must be between 0.1 and 1"
            ),
            (
                storyboard(steps: #"{"action": "setWarmth", "value": 0.5, "display": "B"}"#),
                #"Step 1 (setWarmth): no display is named "B""#
            ),
            (
                storyboard(steps: #"{"action": "applyPreset", "preset": "Night"}"#),
                #"Step 1 (applyPreset): no preset is named "Night""#
            ),
            (
                storyboard(steps: #"{"action": "wait", "duration": -1}"#),
                "Step 1 (wait): duration must be zero or more seconds"
            ),
            (storyboard(steps: #"{"action": "openPanel"}"#), "The steps last no time at all"),
        ]
        for (json, reason) in cases {
            let storyboard = try decode(json)
            XCTAssertThrowsError(try storyboard.validate(), reason) { error in
                XCTAssertTrue(
                    error.localizedDescription.contains(reason),
                    "Expected \"\(reason)\", got \"\(error.localizedDescription)\""
                )
            }
        }
    }

    func testUnknownActionIsRejectedWhenLoading() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("demo-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(#"{"fps": 30, "displays": [], "presets": [], "steps": [{"action": "dance"}]}"#.utf8).write(to: url)

        XCTAssertThrowsError(try DemoStoryboard.load(from: url)) { error in
            XCTAssertTrue(error.localizedDescription.contains("is not a valid storyboard"), error.localizedDescription)
        }
    }

    // MARK: Staging

    func testStagedDisplaysKeepTheirKindAndNamesAcrossARefresh() throws {
        let storyboard = try DemoStoryboard.load(from: Self.bundledStoryboardURL)
        let brightness = ScreenshotStage.makeBrightnessManager(displays: storyboard.displays)

        brightness.refreshDisplays()

        XCTAssertEqual(brightness.displays.map(\.name), storyboard.displays.map(\.name))
        XCTAssertEqual(brightness.displays.map(\.isBuiltIn), storyboard.displays.map(\.isBuiltIn))
        let realIDs = Set(BrightnessManager.activeDisplayIDs())
        XCTAssertTrue(realIDs.isDisjoint(with: brightness.displays.map(\.id)))
    }
}

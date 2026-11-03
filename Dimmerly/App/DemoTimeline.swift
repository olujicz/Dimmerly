//
//  DemoTimeline.swift
//  Dimmerly
//
//  Debug-only scripted timeline for the demo video, driven by `scripts/demo.sh`.
//

#if DEBUG
    import AppKit
    import Foundation

    /// A scripted demo: the staged displays and presets, and the steps that change them.
    ///
    /// Loaded from `scripts/demo/storyboard.json` when Dimmerly runs with
    /// `DIMMERLY_SCREENSHOT=demo`. The app ignores `caption`, which the compositor reads.
    struct DemoStoryboard: Codable, Equatable {
        struct Display: Codable, Equatable {
            var name: String
            var builtIn: Bool?
            var brightness: Double
            var warmth: Double?
            var contrast: Double?
            /// Opens the row's warmth and contrast sliders when the panel appears.
            var expanded: Bool?

            var isBuiltIn: Bool {
                builtIn ?? false
            }
        }

        struct Preset: Codable, Equatable {
            var name: String
            var brightness: Double
            var warmth: Double?
        }

        struct Step: Codable, Equatable {
            var action: DemoStepAction
            /// Seconds the step lasts. A value change animates across it; other actions happen
            /// on its first frame and then hold.
            var duration: Double?
            /// Display name for `setBrightness` and `setWarmth`; nil changes every display.
            var display: String?
            var value: Double?
            var preset: String?
            var easing: DemoEasing?
            /// Text the compositor shows from this step on; an empty string clears it.
            var caption: String?

            var seconds: Double {
                duration ?? 0
            }
        }

        var fps: Int
        /// Seconds between the panel being presentable and frame 0, so a recorder can start.
        var leadIn: Double?
        var displays: [Display]
        var presets: [Preset]
        var steps: [Step]

        var totalSeconds: Double {
            steps.reduce(0) { $0 + $1.seconds }
        }

        var totalFrames: Int {
            Int((totalSeconds * Double(fps)).rounded())
        }

        static func load(from url: URL) throws -> DemoStoryboard {
            let data: Data
            do {
                data = try Data(contentsOf: url)
            } catch {
                throw DemoStoryboardError("Can't read \(url.path): \(error.localizedDescription)")
            }
            let storyboard: DemoStoryboard
            do {
                storyboard = try JSONDecoder().decode(DemoStoryboard.self, from: data)
            } catch {
                throw DemoStoryboardError("\(url.lastPathComponent) is not a valid storyboard: \(error)")
            }
            try storyboard.validate()
            return storyboard
        }

        /// Rejects anything the player would otherwise have to guess about.
        func validate() throws {
            guard (1 ... 120).contains(fps) else {
                throw DemoStoryboardError("fps must be between 1 and 120, not \(fps).")
            }
            if let leadIn, !(leadIn.isFinite && leadIn >= 0) {
                throw DemoStoryboardError("leadIn must be zero or more seconds.")
            }
            guard !displays.isEmpty else { throw DemoStoryboardError("Add at least one display.") }
            try Self.requireUnique(displays.map(\.name), kind: "display")
            try Self.requireUnique(presets.map(\.name), kind: "preset")
            for display in displays {
                try Self.requireBrightness(display.brightness, "display \"\(display.name)\" brightness")
                try Self.requireUnit(display.warmth ?? 0, "display \"\(display.name)\" warmth")
                try Self.requireUnit(
                    display.contrast ?? ExternalDisplay.neutralContrast,
                    "display \"\(display.name)\" contrast"
                )
            }
            for preset in presets {
                try Self.requireBrightness(preset.brightness, "preset \"\(preset.name)\" brightness")
                try Self.requireUnit(preset.warmth ?? 0, "preset \"\(preset.name)\" warmth")
            }
            guard !steps.isEmpty else { throw DemoStoryboardError("Add at least one step.") }
            for (index, step) in steps.enumerated() {
                try validate(step, number: index + 1)
            }
            guard totalFrames > 0 else { throw DemoStoryboardError("The steps last no time at all.") }
        }

        private func validate(_ step: Step, number: Int) throws {
            let label = "Step \(number) (\(step.action.rawValue))"
            if let duration = step.duration, !(duration.isFinite && duration >= 0) {
                throw DemoStoryboardError("\(label): duration must be zero or more seconds.")
            }
            switch step.action {
            case .setBrightness, .setWarmth:
                guard let value = step.value else {
                    throw DemoStoryboardError("\(label): needs a value.")
                }
                if step.action == .setBrightness {
                    try Self.requireBrightness(value, "\(label) value")
                } else {
                    try Self.requireUnit(value, "\(label) value")
                }
                if let display = step.display, !displays.contains(where: { $0.name == display }) {
                    throw DemoStoryboardError("\(label): no display is named \"\(display)\".")
                }
            case .applyPreset:
                guard let preset = step.preset else {
                    throw DemoStoryboardError("\(label): needs a preset name.")
                }
                guard presets.contains(where: { $0.name == preset }) else {
                    throw DemoStoryboardError("\(label): no preset is named \"\(preset)\".")
                }
            case .wait, .openPanel, .closePanel:
                break
            }
        }

        private static func requireUnique(_ names: [String], kind: String) throws {
            var seen: Set<String> = []
            for name in names where !seen.insert(name).inserted {
                throw DemoStoryboardError("Two \(kind)s are named \"\(name)\".")
            }
        }

        /// The app clamps brightness to its minimum, so a lower value would not be what plays.
        private static func requireBrightness(_ value: Double, _ label: String) throws {
            guard value.isFinite, (BrightnessManager.minimumBrightness ... 1).contains(value) else {
                throw DemoStoryboardError(
                    "\(label) must be between \(BrightnessManager.minimumBrightness) and 1, not \(value)."
                )
            }
        }

        private static func requireUnit(_ value: Double, _ label: String) throws {
            guard value.isFinite, (0 ... 1).contains(value) else {
                throw DemoStoryboardError("\(label) must be between 0 and 1, not \(value).")
            }
        }
    }

    /// What a storyboard step does.
    enum DemoStepAction: String, Codable {
        case wait
        case openPanel
        case closePanel
        case setBrightness
        case setWarmth
        case applyPreset
    }

    /// How a value change moves between its start and target.
    enum DemoEasing: String, Codable {
        case linear
        case easeInOut

        func apply(_ progress: Double) -> Double {
            switch self {
            case .linear:
                progress
            case .easeInOut:
                // Smoothstep: starts and ends at rest, so value changes read as a drag.
                progress * progress * (3 - 2 * progress)
            }
        }
    }

    struct DemoStoryboardError: LocalizedError, Equatable {
        let message: String

        init(_ message: String) {
            self.message = message
        }

        var errorDescription: String? {
            message
        }
    }

    /// One line of `values.jsonl`: what the panel and the displays should show on a frame.
    struct DemoFrameRecord: Codable, Equatable {
        struct Display: Codable, Equatable {
            var name: String
            var builtIn: Bool
            var brightness: Double
            var warmth: Double
            var contrast: Double
        }

        var frame: Int
        var panelOpen: Bool
        var caption: String
        var displays: [Display]
    }

    /// Plays a storyboard one frame at a time through the managers the panel observes.
    ///
    /// Values change through the same setters the sliders use, so the panel animates as it does
    /// for a user. Frames depend only on their index, never on the clock, so a run is repeatable
    /// and tests can step through it.
    @MainActor
    final class DemoPlayer {
        private struct ScheduledStep {
            let step: DemoStoryboard.Step
            let startFrame: Int
            let frameCount: Int
        }

        /// Where an animated value started, per display ID, captured on the step's first frame.
        private struct Animation {
            let scheduled: ScheduledStep
            let from: [CGDirectDisplayID: Double]
            let to: Double
        }

        let storyboard: DemoStoryboard
        private let brightnessManager: BrightnessManager
        private let presetManager: PresetManager
        private let openPanel: () -> Void
        private let closePanel: () -> Void
        private let schedule: [ScheduledStep]
        private var nextStepIndex = 0
        private var animations: [Animation] = []
        private(set) var lastFrame = -1
        private(set) var isPanelOpen = false
        private(set) var caption = ""

        init(
            storyboard: DemoStoryboard,
            brightnessManager: BrightnessManager,
            presetManager: PresetManager,
            openPanel: @escaping () -> Void,
            closePanel: @escaping () -> Void
        ) {
            self.storyboard = storyboard
            self.brightnessManager = brightnessManager
            self.presetManager = presetManager
            self.openPanel = openPanel
            self.closePanel = closePanel

            let fps = Double(storyboard.fps)
            let lastFrame = storyboard.totalFrames - 1
            var elapsed = 0.0
            var schedule: [ScheduledStep] = []
            for step in storyboard.steps {
                let start = Int((elapsed * fps).rounded())
                elapsed += step.seconds
                let end = Int((elapsed * fps).rounded())
                // An instant step at the very end would never play, so it lands on the last frame.
                schedule.append(ScheduledStep(step: step, startFrame: min(start, lastFrame), frameCount: end - start))
            }
            self.schedule = schedule
        }

        var totalFrames: Int {
            storyboard.totalFrames
        }

        var isFinished: Bool {
            lastFrame >= totalFrames - 1
        }

        /// Plays every frame up to and including `frame`, and returns one record per frame.
        func advance(to frame: Int) -> [DemoFrameRecord] {
            let target = min(frame, totalFrames - 1)
            var records: [DemoFrameRecord] = []
            while lastFrame < target {
                lastFrame += 1
                play(frame: lastFrame)
                records.append(record(frame: lastFrame))
            }
            return records
        }

        private func play(frame: Int) {
            while nextStepIndex < schedule.count, schedule[nextStepIndex].startFrame <= frame {
                begin(schedule[nextStepIndex])
                nextStepIndex += 1
            }
            for animation in animations {
                apply(animation, at: frame)
            }
            animations.removeAll { frame >= $0.scheduled.startFrame + $0.scheduled.frameCount - 1 }
        }

        private func begin(_ scheduled: ScheduledStep) {
            let step = scheduled.step
            if let newCaption = step.caption {
                caption = newCaption
            }
            switch step.action {
            case .wait:
                break
            case .openPanel:
                isPanelOpen = true
                openPanel()
            case .closePanel:
                isPanelOpen = false
                closePanel()
            case .applyPreset:
                if let preset = presetManager.presets.first(where: { $0.name == step.preset }) {
                    presetManager.applyPreset(preset, to: brightnessManager)
                }
            case .setBrightness, .setWarmth:
                guard let value = step.value else { return }
                let targets = brightnessManager.displays.filter { step.display == nil || $0.name == step.display }
                let from = Dictionary(uniqueKeysWithValues: targets.map {
                    ($0.id, step.action == .setBrightness ? $0.brightness : $0.warmth)
                })
                let animation = Animation(scheduled: scheduled, from: from, to: value)
                if scheduled.frameCount > 0 {
                    animations.append(animation)
                } else {
                    apply(animation, at: scheduled.startFrame)
                }
            }
        }

        private func apply(_ animation: Animation, at frame: Int) {
            let scheduled = animation.scheduled
            let progress = scheduled.frameCount > 0
                ? min(1, Double(frame - scheduled.startFrame + 1) / Double(scheduled.frameCount))
                : 1
            let eased = (scheduled.step.easing ?? .easeInOut).apply(progress)
            for (displayID, from) in animation.from {
                let value = from + (animation.to - from) * eased
                if scheduled.step.action == .setBrightness {
                    brightnessManager.setBrightness(for: displayID, to: value)
                } else {
                    brightnessManager.setWarmth(for: displayID, to: value)
                }
            }
        }

        private func record(frame: Int) -> DemoFrameRecord {
            DemoFrameRecord(
                frame: frame,
                panelOpen: isPanelOpen,
                caption: caption,
                displays: brightnessManager.displays.map {
                    DemoFrameRecord.Display(
                        name: $0.name,
                        builtIn: $0.isBuiltIn,
                        brightness: $0.brightness,
                        warmth: $0.warmth,
                        contrast: $0.contrast
                    )
                }
            )
        }
    }

    /// Runs a `DemoPlayer` against the wall clock and writes `values.jsonl`, then quits.
    ///
    /// The first line is a header with the frame rate, frame count and the Unix time of frame 0,
    /// so a recording made at the same time can be matched to frames.
    @MainActor
    final class DemoRunner {
        private struct Header: Codable {
            let fps: Int
            let frames: Int
            let startedAt: Double
        }

        private let player: DemoPlayer
        private let output: FileHandle
        private let encoder = JSONEncoder()
        private var timer: Timer?
        private var startedAt = Date()

        init(player: DemoPlayer, outputURL: URL) throws {
            self.player = player
            FileManager.default.createFile(atPath: outputURL.path, contents: nil)
            output = try FileHandle(forWritingTo: outputURL)
            encoder.outputFormatting = [.sortedKeys]
        }

        func start() {
            startedAt = Date()
            write(Header(
                fps: player.storyboard.fps,
                frames: player.totalFrames,
                startedAt: startedAt.timeIntervalSince1970
            ))
            tick()
            // Ticks run faster than the frame rate; each one catches up to the clock.
            let interval = 1 / Double(player.storyboard.fps) / 2
            timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
        }

        private func tick() {
            let frame = Int(Date().timeIntervalSince(startedAt) * Double(player.storyboard.fps))
            for record in player.advance(to: frame) {
                write(record)
            }
            guard player.isFinished else { return }
            timer?.invalidate()
            timer = nil
            try? output.close()
            // Let the last frame reach the screen before quitting.
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                NSApp.terminate(nil)
            }
        }

        private func write(_ value: some Encodable) {
            guard let data = try? encoder.encode(value) else { return }
            output.write(data)
            output.write(Data("\n".utf8))
        }
    }
#endif

//
//  MenuBarDisplayControls.swift
//  Dimmerly
//

import AppIntents
import AppKit
import SwiftUI

private struct DisplayEntityContextModifier: ViewModifier {
    let identifier: EntityIdentifier

    func body(content: Content) -> some View {
        #if compiler(>=6.4)
            if #available(macOS 15.4, *) {
                content.appEntityIdentifier(identifier)
            } else {
                content
            }
        #else
            content
        #endif
    }
}

#if !APPSTORE
    struct InputSourceMenuItemPresentation: Equatable {
        let title: String
        let systemImageName: String?

        static func forSource(_ source: InputSource, active: InputSource?) -> Self {
            Self(
                title: source.displayName,
                systemImageName: source == active ? "checkmark" : nil
            )
        }
    }
#endif

// MARK: - Display Brightness Row

struct SliderSyncGate {
    private var shouldSuppressNextChange = false

    mutating func markProgrammaticSync() {
        shouldSuppressNextChange = true
    }

    mutating func shouldPropagateChange() -> Bool {
        if shouldSuppressNextChange {
            shouldSuppressNextChange = false
            return false
        }
        return true
    }
}

private let displaySliderSyncTolerance = 0.0005

enum DisplaySliderSnap {
    static let releaseTolerance = 0.03

    /// How long a non-drag adjustment (keyboard, VoiceOver) must stay still before it
    /// settles onto an anchor. Dragging settles on release instead; keyboard input has
    /// no release, so idling stands in for it and keeps intermediate values reachable
    /// while the user is still pressing.
    static let settleDelay = Duration.milliseconds(450)

    // Mirrors BrightnessManager.minimumBrightness, which is main-actor isolated. The snap
    // policy is intentionally pure so it can be exercised without crossing the main actor;
    // testSnapMinimumBrightnessMatchesBrightnessManager guards the two against drifting.
    static let minimumBrightness = 0.10
    private static let brightnessAnchors = [
        minimumBrightness,
        0.25,
        0.5,
        0.75,
        1.0,
    ]
    private static let warmthKelvinAnchors = [6500.0, 4500.0, 3500.0, 2700.0, 1900.0]
    private static let contrastAnchors = [0.0, ExternalDisplay.neutralContrast, 1.0]
    private static let volumeAnchors = [0.0, 0.25, 0.5, 0.75, 1.0]

    static let brightnessMarkerPositions = [0.25, 0.5, 0.75].map(brightnessPosition)

    /// Where a brightness value sits along its track, which starts at the minimum rather
    /// than at zero. Shared by the markers and the knob so the two cannot disagree.
    static func brightnessPosition(for value: Double) -> Double {
        (value - minimumBrightness) / (1.0 - minimumBrightness)
    }

    /// Whether a marker is far enough from the knob to be worth drawing. Markers are drawn
    /// over the track, so one passing beneath the knob would otherwise score a line across it.
    static func markerIsClearOfKnob(
        marker: Double,
        knob: Double,
        trackWidth: Double,
        knobRadius: Double
    ) -> Bool {
        abs(marker - knob) * trackWidth >= knobRadius
    }

    static let warmthMarkerPositions = [4500.0, 3500.0, 2700.0].map(GammaMath.warmthForKelvin)
    static let contrastMarkerPositions = [ExternalDisplay.neutralContrast]
    static let volumeMarkerPositions = [0.25, 0.5, 0.75]

    static func brightness(_ value: Double) -> Double {
        nearestAnchor(to: value, in: brightnessAnchors)
    }

    static func warmth(_ value: Double) -> Double {
        let anchors = warmthKelvinAnchors.map(GammaMath.warmthForKelvin)
        return nearestAnchor(to: value, in: anchors)
    }

    static func contrast(_ value: Double) -> Double {
        nearestAnchor(to: value, in: contrastAnchors)
    }

    static func volume(_ value: Double) -> Double {
        nearestAnchor(to: value, in: volumeAnchors)
    }

    private static func nearestAnchor(to value: Double, in anchors: [Double]) -> Double {
        guard let nearest = anchors.min(by: { abs($0 - value) < abs($1 - value) }) else {
            return value
        }

        return abs(nearest - value) <= releaseTolerance ? nearest : value
    }
}

/// Decorative snap ticks, drawn as an overlay. The native track is opaque, so a background
/// layer would be hidden behind it; overlaying paints onto the track without touching the
/// slider's own shape, knob or tint.
private struct SliderSnapMarkerLayer: View {
    let positions: [Double]
    /// Normalised knob position, used only to skip the marker currently under the knob.
    let knobPosition: Double

    var body: some View {
        GeometryReader { geometry in
            // The knob travels between its own centre points, so the usable track is inset
            // by one knob radius at each end. Deriving the radius from the layer height
            // keeps the ticks aligned with the knob across control sizes; measuring against
            // the raw width would drift outward toward both ends.
            let knobRadius = geometry.size.height / 2
            let trackWidth = max(geometry.size.width - geometry.size.height, 0)

            ForEach(Array(positions.enumerated()), id: \.offset) { _, position in
                Capsule()
                    // Primary rather than secondary: the tick has to stay legible against
                    // both the filled and unfilled halves of the track.
                    .fill(.primary.opacity(0.3))
                    .frame(width: 1, height: 5)
                    .position(
                        x: knobRadius + trackWidth * position,
                        y: knobRadius
                    )
                    .opacity(
                        DisplaySliderSnap.markerIsClearOfKnob(
                            marker: position,
                            knob: knobPosition,
                            trackWidth: trackWidth,
                            knobRadius: knobRadius
                        ) ? 1 : 0
                    )
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Owns the interaction state shared by the display sliders. The row keeps the value
/// bindings so its percentage and Kelvin captions update during a drag.
private struct DisplayControlSlider: View {
    @Binding var value: Double
    let modelValue: Double?
    let range: ClosedRange<Double>
    let markerPositions: [Double]
    let knobPosition: (Double) -> Double
    let snap: (Double) -> Double
    let accessibilityLabel: String
    let accessibilityValue: (Double) -> String
    let onChange: (Double) -> Void

    @State private var syncGate = SliderSyncGate()
    @State private var isDragging = false
    @State private var settleTask: Task<Void, Never>?

    var body: some View {
        Slider(value: $value, in: range) { isEditing in
            settleTask?.cancel()
            isDragging = isEditing
            if !isEditing {
                value = snap(value)
            }
        }
        .overlay {
            SliderSnapMarkerLayer(
                positions: markerPositions,
                knobPosition: knobPosition(value)
            )
        }
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(accessibilityValue(value))
        .onAppear(perform: syncFromModel)
        .onChange(of: modelValue) {
            syncFromModel()
        }
        .onChange(of: value) {
            guard syncGate.shouldPropagateChange() else { return }
            onChange(value)
            scheduleSettle()
        }
        .onDisappear {
            settleTask?.cancel()
            settleTask = nil
        }
    }

    private func syncFromModel() {
        guard let modelValue, abs(value - modelValue) > displaySliderSyncTolerance else { return }
        syncGate.markProgrammaticSync()
        value = modelValue
    }

    /// Keyboard and VoiceOver edits have no drag release, so settle after inactivity.
    private func scheduleSettle() {
        settleTask?.cancel()
        guard !isDragging else { return }

        settleTask = Task { @MainActor in
            try? await Task.sleep(for: DisplaySliderSnap.settleDelay)
            guard !Task.isCancelled else { return }
            value = snap(value)
        }
    }
}

struct DisplayBrightnessRow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let display: ExternalDisplay
    let isBlanked: Bool
    let isAutoColorTemp: Bool
    let onChange: (Double) -> Void
    let onWarmthChange: (Double) -> Void
    let onContrastChange: (Double) -> Void
    let onToggleBlank: () -> Void

    #if !APPSTORE
        /// Hardware volume change callback (nil if DDC not supported)
        var onVolumeChange: ((Double) -> Void)?
        /// Hardware mute toggle callback (nil if DDC not supported)
        var onMuteToggle: (() -> Void)?
        /// Input source change callback (nil if display doesn't support input switching)
        var onInputSourceChange: ((InputSource) -> Void)?
        /// Current hardware volume (0.0–1.0)
        var hardwareVolume: Double?
        /// Current mute state
        var isMuted: Bool = false
        /// Currently active input source (nil if unknown or unsupported)
        var activeInputSource: InputSource?
        /// Available input sources for this display (empty if unsupported)
        var availableInputSources: [InputSource] = []
        /// Whether this display supports DDC
        var hasDDC: Bool = false
    #endif

    @State private var sliderValue: Double
    @State private var warmthValue: Double
    @State private var contrastValue: Double
    @State private var showAdjustments = false
    #if !APPSTORE
        @State private var volumeValue: Double
    #endif

    init(
        display: ExternalDisplay,
        isBlanked: Bool,
        isAutoColorTemp: Bool = false,
        onChange: @escaping (Double) -> Void,
        onWarmthChange: @escaping (Double) -> Void,
        onContrastChange: @escaping (Double) -> Void,
        onToggleBlank: @escaping () -> Void
    ) {
        self.display = display
        self.isBlanked = isBlanked
        self.isAutoColorTemp = isAutoColorTemp
        self.onChange = onChange
        self.onWarmthChange = onWarmthChange
        self.onContrastChange = onContrastChange
        self.onToggleBlank = onToggleBlank
        _sliderValue = State(initialValue: display.brightness)
        _warmthValue = State(initialValue: display.warmth)
        _contrastValue = State(initialValue: display.contrast)
        #if !APPSTORE
            // `hardwareVolume` is always nil at this point: `.ddcControls(...)` sets it by
            // mutating a *copy* of this view's properties after construction, not during this
            // initializer. The slider syncs on appear, after `hardwareVolume` is set.
            _volumeValue = State(initialValue: 0.5)
        #endif
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Button {
                    withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.8)) {
                        showAdjustments.toggle()
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .rotationEffect(.degrees(showAdjustments ? 90 : 0))
                        Text(display.name)
                            .font(.callout)
                            .lineLimit(1)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(
                    Text(showAdjustments
                        ? "Hide adjustments for \(display.name)"
                        : "Show adjustments for \(display.name)")
                )

                #if !APPSTORE
                    if hasDDC {
                        Text("HW")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .help("Hardware control via DDC/CI")
                    }
                #endif

                Spacer()
                Text("\(Int(sliderValue * 100))%")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .accessibilityHidden(true)

                Button {
                    onToggleBlank()
                } label: {
                    Image(systemName: isBlanked ? "moon.fill" : "moon")
                        .font(.caption2)
                        .frame(width: 12)
                        .foregroundStyle(isBlanked ? .primary : .secondary)
                }
                .buttonStyle(.borderless)
                .help(isBlanked ? Text("Restore display") : Text("Dim display"))
                .accessibilityLabel(isBlanked ? Text("Restore display") : Text("Dim display"))
                .accessibilityHint(
                    isBlanked
                        ? Text("Restores the display to its previous brightness")
                        : Text("Dims the display to minimum brightness")
                )
            }

            HStack(spacing: 6) {
                Image(systemName: "sun.min")
                    .font(.caption2)
                    .frame(width: 12)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)

                DisplayControlSlider(
                    value: $sliderValue,
                    modelValue: display.brightness,
                    range: BrightnessManager.minimumBrightness ... 1,
                    markerPositions: DisplaySliderSnap.brightnessMarkerPositions,
                    knobPosition: DisplaySliderSnap.brightnessPosition,
                    snap: DisplaySliderSnap.brightness,
                    accessibilityLabel: String(
                        format: NSLocalizedString(
                            "%@ brightness",
                            comment: "Accessibility label: display brightness slider"
                        ),
                        display.name
                    ),
                    accessibilityValue: { value in String(
                        format: NSLocalizedString(
                            "%d percent",
                            comment: "Accessibility value: brightness percentage"
                        ),
                        Int(value * 100)
                    ) },
                    onChange: onChange
                )

                Image(systemName: "sun.max")
                    .font(.caption2)
                    .frame(width: 12)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .opacity(isBlanked ? 0.4 : 1.0)
            .disabled(isBlanked)

            if showAdjustments {
                VStack(spacing: 2) {
                    HStack(spacing: 6) {
                        Image(systemName: "thermometer.snowflake")
                            .font(.caption2)
                            .frame(width: 12)
                            .foregroundStyle(.blue)
                            .accessibilityHidden(true)

                        DisplayControlSlider(
                            value: $warmthValue,
                            modelValue: display.warmth,
                            range: 0 ... 1,
                            markerPositions: DisplaySliderSnap.warmthMarkerPositions,
                            knobPosition: { $0 },
                            snap: DisplaySliderSnap.warmth,
                            accessibilityLabel: String(
                                format: NSLocalizedString(
                                    "%@ warmth",
                                    comment: "Accessibility label: display warmth slider"
                                ),
                                display.name
                            ),
                            accessibilityValue: { value in String(
                                format: NSLocalizedString(
                                    "%dK",
                                    comment: "Accessibility value: warmth in Kelvin"
                                ),
                                Int(GammaMath.kelvinForWarmth(value))
                            ) },
                            onChange: onWarmthChange
                        )
                        .tint(.orange)

                        Image(systemName: "thermometer.sun")
                            .font(.caption2)
                            .frame(width: 12)
                            .foregroundStyle(.orange)
                            .accessibilityHidden(true)
                    }

                    HStack {
                        Text(verbatim: "\(Int(GammaMath.kelvinForWarmth(warmthValue)))K")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()

                        if isAutoColorTemp {
                            Text("Auto")
                                .font(.caption2)
                                .fontWeight(.semibold)
                                .foregroundStyle(.primary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background {
                                    Capsule().fill(.orange.opacity(0.16))
                                }
                                .overlay {
                                    Capsule().stroke(.orange, lineWidth: 0.75)
                                }
                                .accessibilityHidden(true)
                        }

                        Spacer()
                    }
                    .padding(.leading, 18)
                }
                .opacity(isBlanked ? 0.4 : 1.0)
                .disabled(isBlanked)
                .transition(.opacity.combined(with: .move(edge: .top)))
                .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.8), value: showAdjustments)

                HStack(spacing: 6) {
                    Image(systemName: "circle.lefthalf.filled")
                        .font(.caption2)
                        .frame(width: 12)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)

                    DisplayControlSlider(
                        value: $contrastValue,
                        modelValue: display.contrast,
                        range: 0 ... 1,
                        markerPositions: DisplaySliderSnap.contrastMarkerPositions,
                        knobPosition: { $0 },
                        snap: DisplaySliderSnap.contrast,
                        accessibilityLabel: String(
                            format: NSLocalizedString(
                                "%@ contrast",
                                comment: "Accessibility label: display contrast slider"
                            ),
                            display.name
                        ),
                        accessibilityValue: { value in String(
                            format: NSLocalizedString(
                                "%d percent",
                                comment: "Accessibility value: contrast percentage"
                            ),
                            Int(value * 100)
                        ) },
                        onChange: onContrastChange
                    )

                    Image(systemName: "circle.righthalf.filled")
                        .font(.caption2)
                        .frame(width: 12)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                .opacity(isBlanked ? 0.4 : 1.0)
                .disabled(isBlanked)
                .transition(.opacity.combined(with: .move(edge: .top)))

                #if !APPSTORE

                    // MARK: Hardware Controls (DDC only)

                    if hasDDC, onVolumeChange != nil || (!availableInputSources.isEmpty && onInputSourceChange != nil) {
                        Divider()
                            .padding(.vertical, 2)
                    }

                    // MARK: Volume Slider + Mute (DDC only)

                    if hasDDC, onVolumeChange != nil {
                        HStack(spacing: 6) {
                            Button {
                                onMuteToggle?()
                            } label: {
                                Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2")
                                    .font(.caption2)
                                    .frame(width: 12)
                                    .foregroundStyle(isMuted ? .red : .secondary)
                            }
                            .buttonStyle(.borderless)
                            .help(isMuted ? "Unmute" : "Mute")
                            .accessibilityLabel(isMuted ? Text("Unmute") : Text("Mute"))

                            DisplayControlSlider(
                                value: $volumeValue,
                                modelValue: hardwareVolume,
                                range: 0 ... 1,
                                markerPositions: DisplaySliderSnap.volumeMarkerPositions,
                                knobPosition: { $0 },
                                snap: DisplaySliderSnap.volume,
                                accessibilityLabel: String(
                                    format: NSLocalizedString(
                                        "%@ volume",
                                        comment: "Accessibility label: display volume slider"
                                    ),
                                    display.name
                                ),
                                accessibilityValue: { value in String(
                                    format: NSLocalizedString(
                                        "%d percent",
                                        comment: "Accessibility value: volume percentage"
                                    ),
                                    Int(value * 100)
                                ) },
                                onChange: { onVolumeChange?($0) }
                            )

                            Image(systemName: "speaker.wave.3")
                                .font(.caption2)
                                .frame(width: 12)
                                .foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                        }
                        .opacity(isBlanked ? 0.4 : 1.0)
                        .disabled(isBlanked)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }

                    // MARK: Input Source Picker (DDC only)

                    if hasDDC, !availableInputSources.isEmpty, onInputSourceChange != nil {
                        HStack(spacing: 6) {
                            Image(systemName: "rectangle.on.rectangle.angled")
                                .font(.caption2)
                                .frame(width: 12)
                                .foregroundStyle(.secondary)
                                .accessibilityHidden(true)

                            // Use a Menu-based picker for compact presentation.
                            // Picker with .menu style provides a native dropdown
                            // without taking up extra vertical space.
                            Menu {
                                // Group common modern inputs first for quick access
                                ForEach(availableInputSources, id: \.self) { source in
                                    Button {
                                        onInputSourceChange?(source)
                                    } label: {
                                        let presentation = InputSourceMenuItemPresentation.forSource(
                                            source,
                                            active: activeInputSource
                                        )
                                        if let systemImageName = presentation.systemImageName {
                                            Label(presentation.title, systemImage: systemImageName)
                                                .labelStyle(.titleAndIcon)
                                        } else {
                                            Text(presentation.title)
                                        }
                                    }
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    Text(activeInputSource?.displayName ?? "Unknown")
                                        .font(.callout)
                                        .lineLimit(1)
                                    Image(systemName: "chevron.up.chevron.down")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .menuStyle(.borderlessButton)
                            .accessibilityLabel(
                                String(
                                    format: NSLocalizedString(
                                        "%@ input source",
                                        comment: "Accessibility label: display input source picker"
                                    ),
                                    display.name
                                )
                            )
                            .accessibilityValue(activeInputSource?.displayName ?? "No input source detected")
                        }
                        .opacity(isBlanked ? 0.4 : 1.0)
                        .disabled(isBlanked)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                        // Warn that switching away from the current input may lose the display.
                        // This is inherent to DDC input switching — the monitor will switch
                        // to the new source, and if the Mac isn't connected on that port,
                        // the display will show "No Signal" until switched back (either via
                        // the monitor's OSD or by reconnecting to this app on the active input).
                        .help(
                            "Switch monitor input source. Switching away from the Mac's "
                                + "input will cause this display to show \"No Signal\" "
                                + "until switched back."
                        )
                    }
                #endif
            }
        }
        .controlSize(.small)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(display.name)
        .contextMenu {
            Button(isBlanked ? "Restore Display" : "Dim Display") {
                onToggleBlank()
            }
            Divider()
            Button("Set to Minimum") { onChange(BrightnessManager.minimumBrightness) }
            Button("Set to 100%") { onChange(1.0) }
            Button("Set to 75%") { onChange(0.75) }
            Button("Set to 50%") { onChange(0.5) }
            Button("Set to 25%") { onChange(0.25) }
            Divider()
            Button("Reset Warmth") { onWarmthChange(0.0) }
            Button("Reset Contrast") { onContrastChange(0.5) }
        }
        .modifier(
            DisplayEntityContextModifier(
                identifier: EntityIdentifier(for: DisplayEntity.self, identifier: String(display.id))
            )
        )
    }
}

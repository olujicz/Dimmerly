//
//  MenuBarDisplayControls.swift
//  Dimmerly
//

import AppKit
import SwiftUI

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
    @State private var brightnessSyncGate = SliderSyncGate()
    @State private var warmthSyncGate = SliderSyncGate()
    @State private var contrastSyncGate = SliderSyncGate()
    @State private var showAdjustments = false
    #if !APPSTORE
        @State private var volumeValue: Double
        @State private var volumeSyncGate = SliderSyncGate()
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
            // initializer. The real value is applied by `syncVolumeFromHardware()` in
            // `onAppear`, once `hardwareVolume` has actually been set.
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

                Slider(
                    value: $sliderValue,
                    in: BrightnessManager.minimumBrightness ... 1
                )
                .accessibilityLabel(
                    String(
                        format: NSLocalizedString(
                            "%@ brightness",
                            comment: "Accessibility label: display brightness slider"
                        ),
                        display.name
                    )
                )
                .accessibilityValue(
                    String(
                        format: NSLocalizedString(
                            "%d percent",
                            comment: "Accessibility value: brightness percentage"
                        ),
                        Int(sliderValue * 100)
                    )
                )
                .onChange(of: sliderValue) {
                    guard brightnessSyncGate.shouldPropagateChange() else { return }
                    onChange(sliderValue)
                }

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

                        Slider(value: $warmthValue, in: 0 ... 1)
                            .tint(.orange)
                            .accessibilityLabel(
                                String(
                                    format: NSLocalizedString(
                                        "%@ warmth",
                                        comment: "Accessibility label: display warmth slider"
                                    ),
                                    display.name
                                )
                            )
                            .accessibilityValue(
                                String(
                                    format: NSLocalizedString(
                                        "%dK",
                                        comment: "Accessibility value: warmth in Kelvin"
                                    ),
                                    Int(GammaMath.kelvinForWarmth(warmthValue))
                                )
                            )
                            .onChange(of: warmthValue) {
                                guard warmthSyncGate.shouldPropagateChange() else { return }
                                onWarmthChange(warmthValue)
                            }

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
                                .foregroundStyle(.background)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(.orange.opacity(0.7)))
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

                    Slider(value: $contrastValue, in: 0 ... 1)
                        .accessibilityLabel(
                            String(
                                format: NSLocalizedString(
                                    "%@ contrast",
                                    comment: "Accessibility label: display contrast slider"
                                ),
                                display.name
                            )
                        )
                        .accessibilityValue(
                            String(
                                format: NSLocalizedString(
                                    "%d percent",
                                    comment: "Accessibility value: contrast percentage"
                                ),
                                Int(contrastValue * 100)
                            )
                        )
                        .onChange(of: contrastValue) {
                            guard contrastSyncGate.shouldPropagateChange() else { return }
                            onContrastChange(contrastValue)
                        }

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

                            Slider(value: $volumeValue, in: 0 ... 1)
                                .accessibilityLabel(
                                    String(
                                        format: NSLocalizedString(
                                            "%@ volume",
                                            comment: "Accessibility label: display volume slider"
                                        ),
                                        display.name
                                    )
                                )
                                .accessibilityValue(
                                    String(
                                        format: NSLocalizedString(
                                            "%d percent",
                                            comment: "Accessibility value: volume percentage"
                                        ),
                                        Int(volumeValue * 100)
                                    )
                                )
                                .onChange(of: volumeValue) {
                                    guard volumeSyncGate.shouldPropagateChange() else { return }
                                    onVolumeChange?(volumeValue)
                                }

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
                                        if source == activeInputSource {
                                            Label(source.displayName, systemImage: "checkmark")
                                        } else {
                                            Text(source.displayName)
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
        .onAppear {
            syncDisplayValuesFromModel()
        }
        .onChange(of: display.brightness) {
            if abs(sliderValue - display.brightness) > displaySliderSyncTolerance {
                brightnessSyncGate.markProgrammaticSync()
                sliderValue = display.brightness
            }
        }
        .onChange(of: display.warmth) {
            if abs(warmthValue - display.warmth) > displaySliderSyncTolerance {
                warmthSyncGate.markProgrammaticSync()
                warmthValue = display.warmth
            }
        }
        .onChange(of: display.contrast) {
            if abs(contrastValue - display.contrast) > displaySliderSyncTolerance {
                contrastSyncGate.markProgrammaticSync()
                contrastValue = display.contrast
            }
        }
        #if !APPSTORE
        .onChange(of: hardwareVolume) {
                syncVolumeFromHardware()
            }
        #endif
            .accessibilityElement(children: .contain)
            .accessibilityLabel(display.name)
            .contextMenu {
                Button(isBlanked ? "Restore Display" : "Dim Display") {
                    onToggleBlank()
                }
                Divider()
                Button("Set to 100%") { onChange(1.0) }
                Button("Set to 50%") { onChange(0.5) }
                Button("Set to 25%") { onChange(0.25) }
                Divider()
                Button("Reset Warmth") { onWarmthChange(0.0) }
                Button("Reset Contrast") { onContrastChange(0.5) }
            }
    }

    private func syncDisplayValuesFromModel() {
        if abs(sliderValue - display.brightness) > displaySliderSyncTolerance {
            brightnessSyncGate.markProgrammaticSync()
            sliderValue = display.brightness
        }
        if abs(warmthValue - display.warmth) > displaySliderSyncTolerance {
            warmthSyncGate.markProgrammaticSync()
            warmthValue = display.warmth
        }
        if abs(contrastValue - display.contrast) > displaySliderSyncTolerance {
            contrastSyncGate.markProgrammaticSync()
            contrastValue = display.contrast
        }
        #if !APPSTORE
            syncVolumeFromHardware()
        #endif
    }

    #if !APPSTORE
        private func syncVolumeFromHardware() {
            guard let hardwareVolume else { return }
            if abs(volumeValue - hardwareVolume) > displaySliderSyncTolerance {
                volumeSyncGate.markProgrammaticSync()
                volumeValue = hardwareVolume
            }
        }
    #endif
}

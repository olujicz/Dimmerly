//
//  SettingsHiDPISection.swift
//  Dimmerly
//
//  Settings section that turns HiDPI sizes on for external displays below 4K and picks
//  the size each one uses. Direct download only.
//

#if !APPSTORE

    import AppKit
    import SwiftUI

    struct HiDPISettingsSection: View {
        @Environment(BrightnessManager.self) private var brightnessManager
        /// The shared manager, so a change waiting on the password prompt keeps its lock when
        /// Settings closes and reopens. Set on first appearance, and it re-reads the displays
        /// and override files each time the section appears.
        @State private var manager: HiDPIModeManager?

        var body: some View {
            Section {
                if let manager {
                    content(manager)
                }
            } header: {
                Label("HiDPI", systemImage: "textformat.size")
            }
            .onAppear {
                if manager == nil {
                    manager = .shared
                }
                refresh()
            }
            .onChange(of: brightnessManager.displays.map(\.id)) { refresh() }
            .onReceive(
                NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            ) { _ in refresh() }
        }

        @ViewBuilder
        private func content(_ manager: HiDPIModeManager) -> some View {
            Text(
                """
                Draws external displays below 4K at twice the resolution and scales the image down, \
                so text looks smoother. Changes need your administrator password and a restart.
                """
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            Text(
                "Turning HiDPI on also sets a system-wide display preference. It stays on when you turn HiDPI off."
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            if manager.displays.isEmpty {
                Text("No external display below 4K is connected.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(manager.displays) { display in
                HiDPIDisplayRow(
                    display: display,
                    manager: manager,
                    sharesModel: manager.displays.contains {
                        $0.id != display.id && $0.identity.isSameModel(as: display.identity)
                    }
                )
            }
        }

        private func refresh() {
            manager?.refresh(names: Dictionary(
                brightnessManager.displays.map { ($0.id, $0.name) },
                uniquingKeysWith: { first, _ in first }
            ))
        }
    }

    private struct HiDPIDisplayRow: View {
        let display: HiDPIDisplayState
        let manager: HiDPIModeManager
        let sharesModel: Bool

        private var name: String {
            display.identity.name
        }

        private var isBusy: Bool {
            manager.isBusy(display)
        }

        private var showsSizePicker: Bool {
            !display.availableSizes.isEmpty && display.status.allowsSizeChange
        }

        /// One line per display, like the rest of Settings: the name on the left, the state and
        /// the action on the right. While HiDPI is on, the size picker is the state.
        var body: some View {
            VStack(alignment: .leading, spacing: 4) {
                LabeledContent {
                    HStack(spacing: 8) {
                        if showsSizePicker {
                            sizePicker
                        } else if display.status == .off {
                            Text("Off")
                                .foregroundStyle(.secondary)
                        }

                        // The spinner takes the button's place, so nothing shifts while the
                        // password prompt is open.
                        if isBusy {
                            ProgressView()
                                .controlSize(.small)
                                .accessibilityLabel(Text("Changing HiDPI for \(name)"))
                        } else {
                            actionButton
                        }
                    }
                } label: {
                    Text(name)
                }

                if let note {
                    caption(note)
                }

                if sharesModel {
                    caption(String(
                        localized: "Applies to all displays of this model.",
                        comment: """
                        HiDPI note under a display when an identical monitor is also connected; \
                        both share one override file
                        """
                    ))
                }

                if let message = manager.errors[display.id]?.errorDescription {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }

        // MARK: Status

        private func caption(_ text: String) -> some View {
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        /// Explains states that need more than the row shows. On and Off need no note.
        private var note: String? {
            if display.recoveryPending {
                return String(
                    localized: "A HiDPI change for this display didn’t finish. Finish it before making another change.",
                    comment: "HiDPI note under a display whose earlier change was interrupted"
                )
            }
            return switch display.status {
            case .off, .on:
                nil
            case .restartToEnable:
                String(
                    localized: "Restart your Mac to use the HiDPI sizes.",
                    comment: "HiDPI status after the override file was installed"
                )
            case .notAccepted:
                String(
                    localized: """
                    macOS didn’t use the HiDPI sizes for this display. \
                    Turn HiDPI off to remove the file.
                    """,
                    comment: """
                    HiDPI note when the override was installed before the last restart but macOS \
                    ignores it, as some docks and adapters do
                    """
                )
            case .restartToRemove:
                String(
                    localized: "Restart your Mac to finish turning HiDPI off.",
                    comment: "HiDPI status after the override file was removed"
                )
            case .otherOverride(hiDPIOnly: true):
                String(
                    localized: "Another app set up HiDPI for this display.",
                    comment: "HiDPI status when another tool wrote a HiDPI-only override file"
                )
            case .otherOverride(hiDPIOnly: false):
                String(
                    localized: """
                    Another app installed a display override for this display, \
                    so Dimmerly leaves it alone.
                    """,
                    comment: "HiDPI status when another tool wrote an override file with other settings"
                )
            }
        }

        // MARK: Actions

        @ViewBuilder
        private var actionButton: some View {
            switch display.primaryAction {
            case .finishPendingChange:
                Button("Finish Change…") { Task { await manager.recoverPendingChange(display) } }
                    .accessibilityLabel(Text("Finish HiDPI change for \(name)"))
            case .turnOn:
                Button("Turn On…") { Task { await manager.enable(display) } }
                    .accessibilityLabel(Text("Turn On HiDPI for \(name)"))
            case .turnOff:
                Button("Turn Off…") { Task { await manager.disable(display) } }
                    .accessibilityLabel(Text("Turn Off HiDPI for \(name)"))
            case nil:
                EmptyView()
            }
        }

        // MARK: Size

        private var sizePicker: some View {
            Picker("Size", selection: Binding(
                get: { display.current ?? .native },
                set: { manager.select($0, for: display) }
            )) {
                ForEach(pickerChoices, id: \.self) { choice in
                    Text(label(for: choice)).tag(choice)
                }
            }
            .labelsHidden()
            .fixedSize()
            .accessibilityLabel(Text("Size for \(name)"))
            .help("The size the interface looks like. Smaller sizes make everything larger.")
        }

        /// Native, then the HiDPI sizes from most space to largest text. The current mode is
        /// added when it isn't one of those, so the picker always shows the truth.
        private var pickerChoices: [HiDPIModeChoice] {
            var choices: [HiDPIModeChoice] = [.native] + display.availableSizes.map { .hiDPI($0) }
            if let current = display.current, !choices.contains(current) {
                choices.append(current)
            }
            return choices
        }

        private func label(for choice: HiDPIModeChoice) -> String {
            switch choice {
            case .native:
                return String(
                    localized: "Native (\(sizeText(nativeSize)))",
                    comment: """
                    HiDPI size picker option for the display's native 1x mode; \
                    the placeholder is a size such as 1920 × 1080
                    """
                )
            case let .lowResolution(size):
                return String(
                    localized: "\(sizeText(size)) (low resolution)",
                    comment: """
                    HiDPI size picker: the display runs a blurry 1x mode that isn't native; \
                    the placeholder is a size such as 1600 × 900
                    """
                )
            case let .hiDPI(size):
                // With a single size, neither end of the range is worth naming.
                guard display.availableSizes.count > 1 else { return sizeText(size) }
                if size == display.availableSizes.first {
                    return String(
                        localized: "\(sizeText(size)) (More space)",
                        comment: """
                        HiDPI size picker: the largest size, which fits the most on screen; \
                        the placeholder is a size such as 1856 × 1044
                        """
                    )
                }
                if size == display.availableSizes.last {
                    return String(
                        localized: "\(sizeText(size)) (Larger text)",
                        comment: """
                        HiDPI size picker: the smallest size, which shows everything largest; \
                        the placeholder is a size such as 1472 × 828
                        """
                    )
                }
                return sizeText(size)
            }
        }

        private var nativeSize: HiDPISize {
            HiDPISize(width: display.identity.nativeWidth, height: display.identity.nativeHeight)
        }

        private func sizeText(_ size: HiDPISize) -> String {
            "\(size.width) × \(size.height)"
        }
    }

#endif

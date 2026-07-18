//
//  MenuBarPanel.swift
//  Dimmerly
//
//  MenuBarExtra content with per-display brightness sliders.
//

import AppKit
import MenuBarExtraAccess
import SwiftUI

extension EnvironmentValues {
    @Entry var closeMenuBarPanel: @MainActor @Sendable () -> Void = {}
}

@MainActor
enum MenuBarDisplayAction {
    static func performAfterDismissal(
        presentationWindow: NSWindow? = NSApp.keyWindow,
        closePresentation: @escaping @MainActor () -> Void,
        action: @escaping @MainActor () -> Void
    ) {
        closePresentation()
        presentationWindow?.close()
        Task { @MainActor in
            await Task.yield()
            action()
        }
    }
}

enum MenuBarPanelGlassStyle {
    static let windowMaterial: NSVisualEffectView.Material = .menu
    static let blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
    static let state: NSVisualEffectView.State = .active
    static let clearsHostWindowBackground = true
    static let cornerRadius: CGFloat = 22
    static let separatorOpacity = 0.55
}

@MainActor
enum MenuBarPanelGlassBackgroundPolicy {
    static func shouldClearLayerBackground(
        for view: NSView,
        glassIdentifier: NSUserInterfaceItemIdentifier
    ) -> Bool {
        guard view.identifier != glassIdentifier else { return false }
        guard !(view is NSVisualEffectView), !(view is NSControl) else { return false }
        guard !(view is NSScrollView) else { return false }

        return isContainerView(view)
    }

    static func shouldVisitSubviews(
        of view: NSView,
        glassIdentifier: NSUserInterfaceItemIdentifier
    ) -> Bool {
        guard view.identifier != glassIdentifier else { return false }
        return !(view is NSVisualEffectView) && !(view is NSControl) && !(view is NSScrollView)
    }

    private static func isContainerView(_ view: NSView) -> Bool {
        view is NSClipView
            || type(of: view) == NSView.self
            || view.subviews.isEmpty == false
    }
}

@MainActor
enum MenuBarPanelScrollStyle {
    static func apply(to scrollView: NSScrollView) {
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        scrollView.verticalScroller?.controlSize = .small
        scrollView.horizontalScroller?.controlSize = .small
    }
}

struct MenuBarPanel: View {
    @Environment(BrightnessManager.self) var brightnessManager
    @Environment(AppSettings.self) var settings
    @Environment(PresetManager.self) var presetManager
    @Environment(ColorTemperatureManager.self) var colorTempManager
    #if !APPSTORE
        @Environment(HardwareBrightnessManager.self) var hardwareManager
    #endif
    @Environment(\.openSettings) private var openSettings
    @Environment(\.closeMenuBarPanel) private var closeMenuBarPanel

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 0) {
                    displaySliders

                    panelDivider
                    presetsSection
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)
                }
                .menuBarPanelScrollStyle()
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(idealHeight: 200, maxHeight: 400)
            .fixedSize(horizontal: false, vertical: true)

            panelDivider

            turnOffButton
                .padding(.horizontal, 20)
                .padding(.vertical, 8)

            panelDivider

            footer
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
        }
        .frame(width: 300)
        .menuBarPanelHostGlass()
        .menuBarPanelChrome()
    }

    // MARK: - Sliders

    private var panelDivider: some View {
        Divider()
            .opacity(MenuBarPanelGlassStyle.separatorOpacity)
    }

    private var displaySliders: some View {
        VStack(spacing: 0) {
            ForEach(brightnessManager.displays) { display in
                if display.id != brightnessManager.displays.first?.id {
                    Divider()
                        .padding(.vertical, 8)
                }
                DisplayBrightnessRow(
                    display: display,
                    isBlanked: ScreenBlanker.shared.isDisplayBlanked(display.id),
                    isAutoColorTemp: colorTempManager.isActive,
                    onChange: { newValue in
                        brightnessManager.setBrightness(for: display.id, to: newValue)
                    },
                    onWarmthChange: { newValue in
                        brightnessManager.setWarmth(for: display.id, to: newValue)
                    },
                    onContrastChange: { newValue in
                        brightnessManager.setContrast(for: display.id, to: newValue)
                    },
                    onToggleBlank: {
                        brightnessManager.toggleBlank(for: display.id)
                    }
                )
                #if !APPSTORE
                .ddcControls(
                        hardwareManager: hardwareManager,
                        displayID: display.id,
                        isBuiltIn: display.isBuiltIn
                    )
                #endif
            }

            autoWarmthToggle
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    // MARK: - Auto Warmth Toggle

    private var autoWarmthToggle: some View {
        @Bindable var settings = settings
        return VStack(spacing: 2) {
            HStack {
                Image(systemName: "sun.horizon")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .frame(width: 14)
                Text("Auto Warmth")
                    .font(.callout)
                Spacer()
                Toggle("", isOn: $settings.autoColorTempEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
                    .accessibilityLabel(Text("Auto Warmth"))
            }

            if settings.autoColorTempEnabled {
                HStack {
                    autoWarmthStatusText
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.leading, 20)
            }
        }
        .padding(.top, 6)
    }

    @ViewBuilder
    private var autoWarmthStatusText: some View {
        if !LocationProvider.shared.hasLocation {
            Text("Set location in Settings")
        } else if let desc = colorTempManager.nextTransitionDescription() {
            Text("\(Int(colorTempManager.currentKelvin))K · \(desc)")
        } else {
            Text("\(Int(colorTempManager.currentKelvin))K")
        }
    }

    // MARK: - Presets

    private var presetsSection: some View {
        PresetsSectionView()
            .environment(presetManager)
            .environment(brightnessManager)
    }

    // MARK: - Turn Off Button

    @ViewBuilder
    private var turnOffButton: some View {
        #if compiler(>=6.2)
            if #available(macOS 26.0, *) {
                turnOffButtonContent
                    .buttonStyle(.glassProminent)
            } else {
                turnOffButtonContent
                    .buttonStyle(.borderedProminent)
            }
        #else
            turnOffButtonContent
                .buttonStyle(.borderedProminent)
        #endif
    }

    private var turnOffButtonContent: some View {
        Button {
            MenuBarDisplayAction.performAfterDismissal(
                closePresentation: closeMenuBarPanel,
                action: { DisplayAction.performSleep(settings: settings) }
            )
        } label: {
            HStack {
                #if APPSTORE
                    Image(systemName: "sun.min.fill")
                    Text("Dim Displays")
                #else
                    Image(systemName: settings.preventScreenLock ? "sun.min.fill" : "moon.fill")
                    Text(settings.preventScreenLock ? "Dim Displays" : "Turn Displays Off")
                #endif
                Spacer()
                Text("↩")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity)
        }
        .controlSize(.large)
        .keyboardShortcut(.return, modifiers: [])
        #if APPSTORE
            .accessibilityLabel(Text("Dim all displays"))
        #else
            .accessibilityLabel(settings.preventScreenLock ? Text("Dim all displays") : Text("Turn off all displays"))
        #endif
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 0) {
            Button {
                openSettings()
                NSApp.activate()
            } label: {
                FooterLabel("Settings", icon: "gear", shortcut: "⌘,")
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(",", modifiers: .command)
            .help("Open Dimmerly settings")

            Spacer()

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                FooterLabel("Quit", icon: "power", shortcut: "⌘Q")
            }
            .buttonStyle(.borderless)
            .keyboardShortcut("q", modifiers: .command)
            .help("Quit Dimmerly")
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }
}

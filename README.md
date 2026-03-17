# Dimmerly

A lightweight macOS menu bar utility for controlling external display brightness — with presets, keyboard shortcuts, and desktop widgets.

![macOS 15.0+](https://img.shields.io/badge/macOS-15.0%2B-blue)
![Swift](https://img.shields.io/badge/Swift-6-orange)
![License](https://img.shields.io/badge/License-MIT-green)

![Dimmerly — menu bar panel, brightness presets, and desktop widgets](images/image1.png)

## Features

- **Per-Display Brightness Control** — Individual sliders for each connected external display
- **Color Temperature (Warmth)** — Per-display warmth adjustment from neutral to warm (~1900K)
- **Auto Color Temperature** — Automatic warmth adjustment based on time of day using sunrise/sunset data
- **Contrast Control** — Per-display contrast via symmetric S-curve gamma adjustment
- **DDC/CI Hardware Control** — Direct hardware brightness, contrast, and volume control via DDC/CI protocol (direct distribution only, enabled by default with automatic software fallback)
- **Input Source Switching** — Switch monitor inputs (HDMI, DisplayPort, USB-C) from the menu bar
- **Audio Mute Toggle** — Mute/unmute monitors with built-in speakers via DDC
- **Brightness Presets** — Save, name, and instantly apply display configurations (brightness, warmth, contrast)
- **Smooth Preset Transitions** — Animated ~300ms interpolation when switching presets (respects Reduce Motion)
- **Global Keyboard Shortcuts** — Dim displays or apply presets from any app
- **Desktop Widgets** — Small and medium widgets for quick access
- **Control Center Integration** — Quick toggle from Control Center (macOS 26+)
- **Shortcuts App Support** — Automate display control with Shortcuts workflows (6 actions: brightness, warmth, contrast, sleep, toggle dim, apply preset)
- **Scheduled Presets** — Automatically apply presets at specific times, sunrise, or sunset
- **Auto-Dim** — Automatically dim displays after a configurable idle period
- **Fade Transition** — Smooth fade-to-black animation option
- **Ignore Mouse Movement** — Only wake screens on keyboard or click
- **Display Blanking** — Dim individual displays independently
- **Accessibility** — Full VoiceOver support, respects Reduce Motion, semantic accessibility labels on all controls
- **Menu Bar Icon Styles** — Choose from 5 icon styles
- **Launch at Login** — Start automatically when you log in
- **Light & Dark Mode** — Full support for both appearances
- **Localized** — Available in 11 languages (English, German, Spanish, French, Italian, Japanese, Korean, Dutch, Portuguese (BR), Serbian, Chinese (Simplified))
- **Privacy-Focused** — No data collection, no app-managed network requests, no tracking

## Requirements

- macOS 15.0 (Sequoia) or later
- External display (DDC/CI-capable monitors get hardware control automatically; others use software gamma)
- Optional: Accessibility permissions for global keyboard shortcuts
- Optional: Location permission for sunrise/sunset schedules

## Installation

### Mac App Store

Dimmerly is available on the [Mac App Store](https://apps.apple.com/app/dimmerly). The App Store version uses screen blanking to comply with sandbox requirements.

### From Source

If you want to build Dimmerly yourself, use the instructions in [BUILDING.md](BUILDING.md).

## Usage

### Menu Bar Panel

Click the Dimmerly icon in your menu bar to open the panel:

- Adjust brightness per display with sliders
- Expand "Display Adjustments" for warmth, contrast, and auto color temperature
- Toggle Auto Warmth to automatically adjust color temperature throughout the day
- Dim individual displays with the moon toggle
- Apply saved presets with a click, or right-click to save current settings to a preset
- Save current display settings as a new preset
- Dim all displays with the main button

### Keyboard Shortcuts

| Action | Default Shortcut | Customizable |
|--------|------------------|--------------|
| Dim Displays | ⌘⌥⇧D | Yes |
| Apply Preset | — | Yes (per preset) |
| Open Settings | ⌘, | No (in menu) |
| Quit | ⌘Q | No (in menu) |

Global shortcuts require Accessibility permission (System Settings > Privacy & Security > Accessibility).

### Presets

Dimmerly includes three default presets:

- **Full** — 100% brightness, neutral warmth and contrast
- **Evening** — 70% brightness, moderate warmth
- **Night** — 30% brightness, high warmth

You can save up to 10 custom presets and assign keyboard shortcuts to each. Right-click a preset to update it with your current display settings.

### Widgets

- **Small Widget** — Quick dim button
- **Medium Widget** — Dim button + up to 3 preset buttons

Add widgets by right-clicking the desktop > Edit Widgets > Dimmerly.

### Scheduled Presets

Automatically apply presets at specific times of day:

- **Fixed Time** — Trigger at an exact time (e.g., 8:00 PM)
- **Sunrise/Sunset** — Trigger relative to sunrise or sunset with an optional offset (e.g., 30 min before sunset)

Schedules reference your existing presets, so editing a preset automatically updates what the schedule applies. Sunrise and sunset triggers require a location — use "Use Current Location" or enter coordinates manually in Settings.

### Settings

Access via the menu bar panel (Settings... or ⌘,). All settings are presented in a single grouped form:

- **General** — Launch at login, menu bar icon style
- **Color Temperature** — Day and night temperature targets, transition duration
- **Dimming** — Display sleep vs dim-only mode, fade transition, wake input options, ignore mouse movement
- **Idle Timer** — Auto-dim after inactivity with configurable timeout (1–60 minutes)
- **Schedule** — Enable scheduled presets, set location (automatic or manual coordinates), manage schedules
- **Keyboard Shortcut** — Global keyboard shortcut for dimming, accessibility permission status
- **Presets** — Rename, delete, assign per-preset shortcuts, restore defaults
- **About** — App information, source code link

## Developer Docs

For development, source builds, test commands, and technical architecture notes, see [BUILDING.md](BUILDING.md).

## Privacy

- **No Data Collection** — Dimmerly does not collect, store, or transmit any personal data
- **No App-Managed Network Requests** — The app does not send data to developer-owned servers, analytics, or tracking services
- **No Tracking** — No analytics, crash reporting, or usage statistics
- **Local Only** — All settings are stored locally using UserDefaults
- **Open Source** — The entire codebase is available for inspection

Optional system location services may use Apple-provided location infrastructure when you choose "Use Current Location" for sunrise/sunset schedules.

See the full [Privacy Policy](https://olujicz.github.io/Dimmerly/privacy-policy.html).

## Open Source + App Store

Dimmerly is fully open source under the MIT License. You can build and run it from source for free.

The [Mac App Store listing](https://apps.apple.com/app/dimmerly) is a convenient way to install the app and support ongoing development.

If you find Dimmerly useful, consider:
- Purchasing from the App Store to support development
- Starring the repository on GitHub
- Contributing code, bug reports, or feature ideas

## Contributing

Contributions are welcome! Please feel free to submit issues, feature requests, or pull requests.

1. Fork the repository
2. Create a feature branch: `git checkout -b feature-name`
3. Run `just setup` to configure pre-commit hooks
4. Make your changes and add tests
5. Run `just lint` and `just test` to ensure code quality and all tests pass
6. Submit a Pull Request

Please review the [Code of Conduct](CODE_OF_CONDUCT.md) before participating. See the [Security Policy](SECURITY.md) for reporting vulnerabilities.

## Troubleshooting

### Displays Don't Sleep

1. Ensure `/usr/bin/pmset` exists on your system (included with macOS)
2. Check System Settings > Lock Screen and ensure display sleep is not disabled
3. In dim-only mode (App Store build or "Prevent Screen Lock"), wake behavior follows your Dimming settings:
   - Default: keyboard, click, scroll, or mouse movement
   - "Ignore Mouse Movement" enabled: keyboard, click, or scroll
   - "Require Escape to Dismiss" enabled: Escape key only
4. After system sleep/wake, full-screen dimming is cleared automatically

### Keyboard Shortcut Doesn't Work

1. Check that Accessibility permission is granted in System Settings > Privacy & Security > Accessibility
2. Restart Dimmerly after granting permissions
3. Try a different shortcut to avoid conflicts with other apps

### Brightness Slider Has No Effect

1. DDC/CI hardware control is enabled by default — if your display supports it, the menu bar panel shows an "HW" indicator next to the display name
2. If no "HW" indicator appears, the display is using software gamma control (still adjusts perceived brightness, but not the backlight)
3. Some USB-C/DisplayPort hubs may not pass through DDC commands — try connecting the display directly
4. On Apple Silicon (M1–M4), Dimmerly tries three I2C transport paths automatically (IOAVService, IOAVDevice, direct IOConnect)
5. Built-in HDMI on M1/entry M2 Macs does not support DDC; use USB-C or DisplayPort instead
6. You can check DDC status per display in Settings > Displays > Hardware Control

## License

This project is licensed under the MIT License — see the [LICENSE](LICENSE) file for details.

## Support

If you encounter issues:

1. Check the [Troubleshooting](#troubleshooting) section
2. Search existing [GitHub Issues](https://github.com/olujicz/Dimmerly/issues)
3. Create a new issue with your macOS version, Dimmerly version, and steps to reproduce

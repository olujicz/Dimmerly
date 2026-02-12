# Dimmerly

A lightweight macOS menu bar utility for controlling external display brightness — with presets, keyboard shortcuts, and desktop widgets.

![macOS 14.0+](https://img.shields.io/badge/macOS-14.0%2B-blue)
![Swift](https://img.shields.io/badge/Swift-6-orange)
![License](https://img.shields.io/badge/License-MIT-green)

![Dimmerly — menu bar panel, brightness presets, and desktop widgets](images/image1.png)

## Features

- **Per-Display Brightness Control** — Individual sliders for each connected external display
- **Color Temperature (Warmth)** — Per-display warmth adjustment from neutral to warm (~2700K)
- **Contrast Control** — Per-display contrast via symmetric S-curve gamma adjustment
- **Brightness Presets** — Save, name, and instantly apply display configurations (brightness, warmth, contrast)
- **Global Keyboard Shortcuts** — Dim displays or apply presets from any app
- **Desktop Widgets** — Small and medium widgets for quick access (macOS 14+)
- **Control Center Integration** — Quick toggle from Control Center (macOS 15+)
- **Shortcuts App Support** — Automate display control with Shortcuts workflows
- **Auto-Dim** — Automatically dim displays after a configurable idle period
- **Fade Transition** — Smooth fade-to-black animation option
- **Ignore Mouse Movement** — Only wake screens on keyboard or click
- **Display Blanking** — Dim individual displays independently
- **Menu Bar Icon Styles** — Choose from 5 icon styles
- **Launch at Login** — Start automatically when you log in
- **Light & Dark Mode** — Full support for both appearances
- **Localized** — Available in 11 languages
- **Privacy-Focused** — No data collection, no network access, no tracking

## Requirements

- macOS 14.0 (Sonoma) or later
- External display with DDC/CI brightness support
- Optional: Accessibility permissions for global keyboard shortcuts

## Installation

### Mac App Store

Dimmerly is available on the [Mac App Store](https://apps.apple.com/app/dimmerly). The App Store version uses screen blanking to comply with sandbox requirements.

### From Source

1. Clone this repository:
   ```bash
   git clone https://github.com/olujicz/Dimmerly.git
   cd Dimmerly
   ```

2. Open the project in Xcode:
   ```bash
   open Dimmerly.xcodeproj
   ```

3. Build and run:
   - Select the **Dimmerly** scheme
   - Press **⌘R**
   - The app will appear in your menu bar

## Usage

### Menu Bar Panel

Click the Dimmerly icon in your menu bar to open the panel:

- Adjust brightness per display with sliders
- Expand "Display Adjustments" for warmth and contrast sliders
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

### Settings

Access via the menu bar panel (Settings... or ⌘,):

- **General** — Launch at login, ignore mouse movement, fade transition, menu bar icon style, auto-dim idle timer
- **Shortcuts** — Global keyboard shortcut for dimming, per-preset shortcuts
- **About** — App information

## Building from Source

### Prerequisites

- Xcode 15.0 or later
- macOS 14.0 SDK or later
- Swift 6.0 or later

### Build Configurations

| Configuration | Scheme | Description |
|---------------|--------|-------------|
| Debug | Dimmerly | Development build with `pmset` display sleep |
| Release | Dimmerly | Distribution build with `pmset` display sleep |
| Debug-AppStore | Dimmerly App Store | Development build with gamma-based screen blanking |
| Release-AppStore | Dimmerly App Store | App Store submission build |

### Running Tests

```bash
xcodebuild test -scheme Dimmerly -destination 'platform=macOS'
```

Or use Xcode's Test Navigator (⌘6).

## Technical Details

### Standard Build (Direct Distribution)

Uses `pmset displaysleepnow` to sleep displays. Includes an optional "Prevent Screen Lock" mode that blanks screens via gamma tables without triggering a session lock.

### App Store Build (Sandboxed)

Uses gamma table dimming (`CGSetDisplayTransferByFormula`) to black out displays. Works over fullscreen apps and dims the cursor. Gamma is restored instantly on any user input via `CGDisplayRestoreColorSyncSettings()`. If the app exits unexpectedly, macOS automatically restores gamma to normal.

## Privacy

- **No Data Collection** — Dimmerly does not collect, store, or transmit any personal data
- **No Network Access** — The app never connects to the internet
- **No Tracking** — No analytics, crash reporting, or usage statistics
- **Local Only** — All settings are stored locally using UserDefaults
- **Open Source** — The entire codebase is available for inspection

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
3. Make your changes and add tests
4. Ensure all tests pass
5. Submit a Pull Request

Please review the [Code of Conduct](CODE_OF_CONDUCT.md) before participating. See the [Security Policy](SECURITY.md) for reporting vulnerabilities.

## Troubleshooting

### Displays Don't Sleep

1. Ensure `/usr/bin/pmset` exists on your system (included with macOS)
2. Check System Settings > Lock Screen and ensure display sleep is not disabled
3. App Store version blanks screens rather than sleeping displays — move your mouse or press any key to dismiss

### Keyboard Shortcut Doesn't Work

1. Check that Accessibility permission is granted in System Settings > Privacy & Security > Accessibility
2. Restart Dimmerly after granting permissions
3. Try a different shortcut to avoid conflicts with other apps

### Brightness Slider Has No Effect

1. Verify your external display supports DDC/CI brightness control
2. Some USB-C/DisplayPort hubs may not pass through DDC commands
3. Try connecting the display directly to your Mac

## License

This project is licensed under the MIT License — see the [LICENSE](LICENSE) file for details.

## Support

If you encounter issues:

1. Check the [Troubleshooting](#troubleshooting) section
2. Search existing [GitHub Issues](https://github.com/olujicz/Dimmerly/issues)
3. Create a new issue with your macOS version, Dimmerly version, and steps to reproduce

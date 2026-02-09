# Dimmerly

A minimal macOS menu bar utility for quickly sleeping displays with a single click or keyboard shortcut.

## Features

- **One-Click Display Sleep**: Put all connected displays to sleep instantly from the menu bar
- **Global Keyboard Shortcuts**: Trigger display sleep from any application (default: ⌘⌥⇧D)
- **Launch at Login**: Optionally start Dimmerly automatically when you log in
- **Privacy-Focused**: No data collection, no network access, no tracking
- **Lightweight**: Minimal resource usage, lives quietly in your menu bar

## Requirements

- macOS 13.0 (Ventura) or later
- Optional: Accessibility permissions for global keyboard shortcuts

## Installation

### From Source

1. Clone this repository:
   ```bash
   git clone https://github.com/olujicz/dimmerly.git
   cd dimmerly
   ```

2. Open the project in Xcode:
   ```bash
   open Dimmerly.xcodeproj
   ```

3. Build and run:
   - Select the Dimmerly scheme
   - Click the Run button or press ⌘R
   - The app will appear in your menu bar with a moon icon

### Installing for Daily Use

After building, you can copy the app to your Applications folder:

1. In Xcode, select Product > Archive
2. Once archiving completes, click "Distribute App"
3. Select "Copy App"
4. Choose a destination (e.g., Applications folder)
5. Launch Dimmerly from your Applications folder

## Usage

### Basic Usage

1. Click the moon icon in your menu bar
2. Select "Turn Displays Off" to immediately sleep all displays
3. Move your mouse or press any key to wake displays

### Keyboard Shortcuts

- **Default shortcut**: ⌘⌥⇧D (Command + Option + Shift + D)
- Works from any application when accessibility permissions are granted
- Customize in Settings (see below)

### Settings

Access settings by clicking the menu bar icon and selecting "Settings..." or pressing ⌘, while the menu is open.

#### General Settings
- **Launch at Login**: Toggle whether Dimmerly starts automatically when you log in

#### Keyboard Shortcuts
- **Custom Shortcuts**: Click on the shortcut display to record a new key combination
- **Reset**: Click the circular arrow icon to restore the default shortcut
- **Accessibility Permissions**: If you see a warning, click "Grant Access" to enable global shortcuts

## Building from Source

### Prerequisites

- Xcode 15.0 or later
- macOS 13.0 SDK or later
- Swift 5.9 or later

### Build Steps

1. Clone the repository
2. Open `Dimmerly.xcodeproj` in Xcode
3. Select the Dimmerly scheme
4. Build with ⌘B or run with ⌘R

### Running Tests

```bash
xcodebuild test -scheme Dimmerly -destination 'platform=macOS'
```

Or use Xcode's Test Navigator (⌘6) and click the play button next to the test suite.

## Keyboard Shortcuts Reference

| Action | Default Shortcut | Customizable |
|--------|------------------|--------------|
| Sleep Displays | ⌘⌥⇧D | Yes |
| Open Settings | ⌘, | No (in menu only) |
| Quit Dimmerly | ⌘Q | No (in menu only) |

## Privacy

Dimmerly is designed with privacy as a core principle:

- **No Data Collection**: Dimmerly does not collect, store, or transmit any personal data
- **No Network Access**: The app never connects to the internet
- **No Tracking**: No analytics, crash reporting, or usage statistics
- **Local Only**: All settings are stored locally on your Mac using UserDefaults
- **Open Source**: The entire codebase is available for inspection

### Permissions

Dimmerly may request the following permissions:

1. **Accessibility Permission** (Optional): Required for global keyboard shortcuts
   - Without this permission, keyboard shortcuts will not work
   - The app remains fully functional using the menu bar interface
   - You can grant this in System Settings > Privacy & Security > Accessibility

## Troubleshooting

### Displays Don't Sleep

1. Ensure `/usr/bin/pmset` exists on your system (standard on macOS 10.9+)
2. Check System Settings > Lock Screen and ensure display sleep is not disabled by policy
3. Try running the app with administrator privileges if needed

### Keyboard Shortcut Doesn't Work

1. Open Settings and check if accessibility permissions are granted
2. Click "Grant Access" and add Dimmerly to the Accessibility list
3. Restart Dimmerly after granting permissions
4. Try changing the keyboard shortcut to avoid conflicts with other apps

### Menu Bar Icon Not Visible

1. Check that the menu bar is not hidden in System Settings
2. Reduce the number of menu bar items if the bar is too crowded
3. Restart Dimmerly

## Technical Details

Dimmerly uses the macOS `pmset` command-line utility to trigger display sleep:

```bash
/usr/bin/pmset displaysleepnow
```

This is the same mechanism used by System Settings to sleep displays, ensuring compatibility and reliability.

## Contributing

Contributions are welcome! Please feel free to submit issues, feature requests, or pull requests.
Please review the Code of Conduct before participating.
See the security policy for reporting vulnerabilities.

### Development Setup

1. Fork the repository
2. Create a feature branch: `git checkout -b feature-name`
3. Make your changes and add tests
4. Ensure all tests pass: `xcodebuild test -scheme Dimmerly`
5. Commit your changes: `git commit -m 'Add feature'`
6. Push to your fork: `git push origin feature-name`
7. Create a Pull Request

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Code of Conduct

This project follows the [Code of Conduct](CODE_OF_CONDUCT.md).

## Security

Please see the [Security Policy](SECURITY.md) for reporting vulnerabilities.

## Acknowledgments

- Icon design inspired by macOS system icons
- Built with SwiftUI and AppKit
- Uses the macOS `pmset` utility for display control

## Support

If you encounter any issues or have questions:

1. Check the [Troubleshooting](#troubleshooting) section above
2. Search existing [GitHub Issues](https://github.com/olujicz/dimmerly/issues)
3. Create a new issue with:
   - macOS version
   - Dimmerly version
   - Steps to reproduce the problem
   - Expected vs actual behavior

---

Made with ❤️ for macOS users who want quick display control.

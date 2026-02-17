# Changelog

All notable changes to this project will be documented in this file.

The format is based on Keep a Changelog, and this project adheres to
Semantic Versioning.

## [Unreleased]

### Added
- Per-display brightness, warmth (color temperature), and contrast control
- Automatic color temperature adjustment based on time of day (Helland blackbody algorithm, ~1900K–6500K)
- Brightness presets with save, rename, and keyboard shortcut assignment (up to 10)
- Smooth animated transitions (~300ms) when switching presets
- Global keyboard shortcuts for dimming and per-preset activation
- Scheduled presets with fixed time, sunrise, and sunset triggers
- Solar calculator (NOAA algorithm) for offline sunrise/sunset times
- Location services integration (automatic or manual coordinates)
- Auto-dim after configurable idle period (1–60 minutes)
- Per-display blanking via moon toggle
- Fade-to-black transition option
- Ignore mouse movement option (wake only on keyboard or click)
- Desktop widgets (small and medium) for quick access
- Control Center integration (macOS 26+)
- Shortcuts app support (set brightness, warmth, contrast, sleep displays, toggle dim)
- Five menu bar icon styles
- Launch at login
- Light and dark mode support
- Localized in 11 languages
- SwiftLint and SwiftFormat configuration
- Justfile with build, test, lint, and format commands
- Comprehensive unit tests
- **DDC/CI hardware display control** (direct distribution only):
  - Real hardware brightness, contrast, and volume control via DDC/CI protocol
  - Audio mute toggle for monitors with built-in speakers
  - Input source switching (HDMI, DisplayPort, USB-C, etc.)
  - Input source picker in menu bar panel (compact dropdown in Display Adjustments section)
  - Apple Silicon support via IOAVService (ARM64)
  - Intel Mac support via IOI2CRequest/IOFramebuffer (x86_64)
  - Three control modes: Software Only, Hardware Only, Combined
  - Background polling to detect OSD-initiated changes
  - Debounced writes (100ms) and rate limiting (50ms min interval) to protect monitor MCU
  - Per-display DDC capability probing with cached results
  - "DDC" badge on capable displays in the menu bar panel
  - Hardware Control settings section with per-display status
  - Configurable polling interval and write delay
  - Unit tests with injectable DDC mocks (no hardware required)

  **DDC/CI Known Limitations:**
  - Not available in App Store builds (DDC requires IOKit access incompatible with App Sandbox)
  - Built-in HDMI on M1/entry M2 Macs does not support DDC (USB-C/DisplayPort works)
  - DisplayLink USB display adapters do not support DDC on macOS
  - Some EIZO monitors use a proprietary USB protocol instead of DDC/CI
  - Most TVs do not implement DDC/CI (they use HDMI-CEC instead)
  - DDC transactions are slow (~40ms per read/write) — requires debouncing and rate-limiting
  - Some monitors only implement a subset of MCCS commands; unsupported codes are silently ignored
  - Monitors may silently clamp or ignore out-of-range VCP values
  - DDC/CI has no authentication — any process on the system can control the display
  - Monitor OSD changes may take up to one polling interval to reflect in Dimmerly
  - Switching input source away from the Mac's active input will cause "No Signal" until switched back via the monitor's OSD or physical buttons
  - Most monitors only respond to input sources they physically have; unavailable sources are silently ignored


# Changelog

All notable changes to this project will be documented in this file.

The format is based on Keep a Changelog, and this project adheres to
Semantic Versioning.

## [Unreleased]

### Added
- Per-display brightness, warmth (color temperature), and contrast control
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


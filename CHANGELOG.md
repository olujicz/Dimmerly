# Changelog

All notable changes to this project will be documented in this file.

The format is based on Keep a Changelog, and this project adheres to
Semantic Versioning.

## [Unreleased]

## [1.1.1] - 2026-07-21

### Changed
- Simplified display control to Software and Hardware modes. Hardware mode now uses DDC/CI where supported and automatically falls back to software brightness for unsupported displays while preserving software warmth and contrast adjustments.
- Clarified Hardware Control settings and availability messages so unsupported displays and software fallback behavior are easier to understand.
- Improved the contrast of the automatic color-temperature badge across warm and cool display temperatures.

### Fixed
- Fixed the Settings window appearing behind the active application the first time it was opened.
- Fixed display blanking so wake input is captured reliably, does not leak through to the foreground application, and remains recoverable if input monitoring becomes unavailable.
- Fixed App Store builds sometimes removing the black display overlay when the menu-bar panel closed, leaving input capture inactive or inconsistent.
- Fixed queued DDC/CI work and stale polling results continuing after Hardware Control was disabled.
- Fixed display automations targeting disconnected displays instead of reporting that the display is unavailable.
- Fixed duplicate keyboard shortcuts being assigned to multiple presets.
- Tightened DDC/CI packet validation so malformed or mismatched monitor replies are rejected safely.

## [1.1.0] - 2026-07-12

### Added
- Added a right-click quick actions menu on the menu bar icon (Turn Displays Off / Dim Displays, Settings, Quit) for one-step access without opening the full panel.
- Added an Acknowledgements section to Settings > About crediting third-party open-source software used by Dimmerly.
- Added a "Classic" menu bar icon style that keeps the previous monitor glyph, so the earlier look stays available alongside the new default (six styles total).

### Changed
- Redesigned the app icon and the default menu bar icon around a clearer brightness mark.
- Refined Hardware Control settings so unavailable hardware control modes are disabled with clearer fallback guidance.
- Clarified per-display DDC/CI support status and tightened the advanced polling and write-delay controls.
- Control-click on the menu bar icon now also opens the quick actions menu, matching right-click.
- The "Apply Brightness Preset" Shortcuts action now uses a preset picker instead of a typed preset name, so it keeps working after a preset is renamed.

### Fixed
- Fixed the menu bar icon staying visually highlighted after using "Turn Displays Off" to close the panel.
- Fixed hardware brightness control fallback so DDC/CI control is only used when hardware control is enabled and available.
- Fixed display schedules so missed events between app checks are applied in chronological order.
- Fixed keyboard shortcut recording so the recorder reliably receives focus before capturing keys.
- Fixed auto-dim after inactivity so it correctly measures real user inactivity instead of triggering almost immediately.
- Fixed hardware (DDC/CI) brightness control so newly connected or hot-plugged displays are detected without needing a relaunch or a Settings toggle.
- Fixed preset transitions so hardware-controlled displays (built-in backlight, DDC/CI) no longer flash dark partway through applying a preset.
- Fixed the menu bar panel so per-display dim/blank state stays in sync when dismissed by keyboard or mouse input, instead of showing stale state.
- Fixed hardware control so an unreliable volume or input-source control no longer disables hardware brightness for the whole display.
- Fixed a rare case where a display that doesn't support DDC/CI could delay brightness updates on other connected displays.
- Fixed the dim/blank fade so it starts from the display's actual current brightness and warmth instead of flashing to the wrong value.
- Fixed sunrise/sunset schedules and automatic color temperature so times are correct on daylight saving time transition days.
- Fixed built-in display brightness so it no longer jumps up unexpectedly after waking or connecting an external display.
- Fixed error alerts so they no longer pause schedules, auto-dim, or color temperature transitions while shown.
- Fixed preset keyboard shortcuts so they're checked against reserved system shortcuts, and matched shortcuts no longer also type into a focused field.
- Fixed the right-click quick actions menu so it keeps working reliably if the menu bar icon is recreated.
- Reduced unnecessary background work while dragging brightness sliders in the menu bar panel.
- Fixed the "Save Current" preset field so it's focused and ready to type into immediately, and fixed the launch-at-login alert so its message no longer flashes empty while dismissing.

## [1.0.2] - 2026-07-01

### Fixed
- Polished the menu bar panel glass styling so it more closely matches macOS menu surfaces while keeping the window-style panel behavior.
- Restored subtle overlay scrollbars in the menu bar panel and kept scrollbar behavior aligned with the user's macOS appearance settings.

## [1.0.1] - 2026-06-29

### Added
- Added structured GitHub issue templates for bug reports, feature requests, and monitor compatibility reports, making it easier to collect the display details needed to diagnose hardware-specific issues.
- Added Homebrew installation guidance and release-maintenance documentation for direct-download distribution.
- Added GitHub Pages deployment for the public privacy policy and support pages.

### Changed
- Updated release, CI, and documentation workflows so release candidates, App Store smoke builds, public Pages assets, and repository settings are checked more consistently.
- Moved public release documentation into `documentation/`.
- App Store builds now avoid direct IOKit display-name fallbacks while preserving deeper display-name resolution in direct-download builds.
- The menu bar panel now respects the user's macOS scrollbar visibility setting instead of forcing overlay scrollbars.
- Build documentation now includes the App Store scheme build and the aggregate `just check` validation command.

### Fixed
- Fixed widget "Turn Displays Off" handling so duplicate, stale, or unrelated notifications do not dim or sleep displays unless a pending widget command exists.
- Fixed DDC/CI settings so saved control mode, polling interval, and write delay are applied immediately when hardware control is enabled after launch.
- Fixed preset, widget preset, and schedule persistence diagnostics so encode/decode failures are logged instead of failing silently.

## [1.0.0] - 2026-06-22

### Added
- Built-in display support: brightness, warmth, and contrast controls now available for the laptop screen (always shown alongside external displays)
- Hardware backlight control for built-in display (direct distribution only): brightness slider drives the actual backlight via DisplayServices, syncing bidirectionally with Control Center and keyboard brightness keys (~1s polling). Warmth and contrast continue to use gamma tables.
- Per-display adjustment disclosure: each display has its own expand/collapse chevron for warmth and contrast sliders
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
- Shortcuts app support with 6 actions (set brightness, warmth, contrast, sleep displays, toggle dim, apply preset)
- Five menu bar icon styles
- Launch at login
- Light and dark mode support
- Localized in 11 languages (English, German, Spanish, French, Italian, Japanese, Korean, Dutch, Portuguese (BR), Serbian, Chinese (Simplified))
- Comprehensive accessibility: VoiceOver labels, Reduce Motion support, semantic grouping on all controls
- SwiftLint and SwiftFormat configuration
- Pre-commit hooks for format, lint, and secrets detection (`just setup`)
- GitHub Actions CI with lint and test jobs
- Justfile with build, test, lint, format, and setup commands
- Comprehensive unit tests with injectable mocks
- **DDC/CI hardware display control** (direct distribution only):
  - Real hardware brightness, contrast, and volume control via DDC/CI protocol
  - Audio mute toggle for monitors with built-in speakers
  - Input source switching (HDMI, DisplayPort, USB-C, etc.)
  - Input source picker in menu bar panel (compact dropdown in Display Adjustments section)
  - Apple Silicon support via IOAVService (ARM64) with multi-transport fallback
  - M4 Apple Silicon support via DCPAVServiceProxy for DCP display pipeline
  - Intel Mac support via IOI2CRequest/IOFramebuffer (x86_64)
  - Three I2C transport paths on Apple Silicon, tried in priority order:
    1. IOAVService (standard path, works for USB-C/DP on all Apple Silicon)
    2. IOAVDevice (alternative DCP firmware path, may help for HDMI)
    3. Direct IOConnectCallMethod (last resort, tries raw IOConnect selectors)
  - Retry logic with multiple write cycles per attempt for reliable I2C communication
  - Auto-downgrade to software-only control after 3 consecutive DDC write failures
  - Three control modes: Software Only, Hardware Only, Combined
  - Background polling to detect OSD-initiated changes
  - Debounced writes (100ms) and rate limiting (50ms min interval) to protect monitor MCU
  - Per-display DDC capability probing with cached results
  - "HW" indicator with cable icon on capable displays in the menu bar panel
  - Hardware Control settings section with per-display status
  - Configurable polling interval and write delay
  - Unit tests with injectable DDC mocks (no hardware required)

  **DDC/CI Known Limitations:**
  - Not available in App Store builds (DDC requires IOKit access incompatible with App Sandbox)
  - Built-in HDMI on M1/entry M2 Macs does not support DDC (USB-C/DisplayPort works)
  - DisplayLink USB display adapters do not support DDC on macOS
  - Some EIZO monitors use a proprietary USB protocol instead of DDC/CI
  - Most TVs do not implement DDC/CI (they use HDMI-CEC instead)
  - DDC transactions are slow (~50ms per read/write) — requires debouncing and rate-limiting
  - Some monitors only implement a subset of MCCS commands; unsupported codes are silently ignored
  - Monitors may silently clamp or ignore out-of-range VCP values
  - DDC/CI has no authentication — any process on the system can control the display
  - Monitor OSD changes may take up to one polling interval to reflect in Dimmerly
  - Switching input source away from the Mac's active input will cause "No Signal" until switched back via the monitor's OSD or physical buttons
  - Most monitors only respond to input sources they physically have; unavailable sources are silently ignored

### Changed
- Migrated from ObservableObject/Combine to Swift Observation framework (`@Observable`)
- Adopted macOS Tahoe design patterns across all views
- Improved VoiceOver accessibility across the Settings window
- Improved HIG compliance across Settings and menu bar panel
- Menu bar panel uses compact slider control size (`.controlSize(.small)`)
- Menu bar panel uses overlay scroller style for a cleaner appearance
- Scroll bounce only activates when content overflows (`.scrollBounceBehavior(.basedOnSize)`)
- Removed "No External Displays" empty state — built-in display is always available
- Narrowed SwiftLint scope to shipping code by excluding the local `tools/` research folder
- Extracted gamma math (Helland blackbody, contrast curve, 256-entry LUT builder) from `BrightnessManager` into a new `GammaMath` enum
- Extracted display-name resolution (NSScreen → Apple override plist → EDID/IOKit) from `BrightnessManager` into a new `DisplayNameResolver` enum
- Consolidated three near-duplicate preset/warmth transition methods in `BrightnessManager` onto a single `runTransition(targets:)` helper with per-axis start/end values, cutting ~60 lines of copy-paste
- Replaced `UserDefaults.didChangeNotification` fan-out in `IdleTimerManager`, `ScheduleManager`, `ColorTemperatureManager`, and `PresetShortcutManager` with explicit `.onChange(of: settings.X)` modifiers on the `MenuBarExtra` label plus a one-time `syncManagerStateFromSettings()` at launch; each manager now exposes a single `apply(enabled:…)` entry point and no longer reacts to unrelated UserDefaults writes
- Unified the four per-intent `IntentError.invalidDisplay` declarations into a single `DisplayIntentError` type shared across `SetDisplayBrightnessIntent`, `SetDisplayContrastIntent`, `SetDisplayWarmthIntent`, and `ToggleDimIntent`
- `BrightnessManager` now cancels any running preset/warmth transition when a direct `setBrightness` / `setWarmth` / `setContrast` call arrives, so slider drags during an animated preset apply win cleanly instead of fighting the animation loop
- `ScreenBlanker` dismiss-monitor callbacks now invoke their action inline via `MainActor.assumeIsolated` instead of hopping through `Task { @MainActor in … }`, preserving the grace-period timing guarantee

### Fixed
- Serialized DDC/CI probe, read, and write operations to prevent overlapping hardware transactions on the monitor control bus
- Enforced the DDC/CI write delay between actual queued hardware writes, even after slow reads or probes have backed up the control bus
- Ignored stale DDC/CI poll results when a newer local hardware control change is already pending or visible in the UI
- Fixed menu bar sliders sending redundant brightness, warmth, contrast, and DDC volume writes when syncing from presets, polling, or model updates
- Fixed DDC volume sliders initially showing a default midpoint before the current hardware volume was applied
- Fixed remaining menu bar panel hover and disclosure animations so they fully respect Reduce Motion
- Fixed DDC/CI display matching on M4 Macs: EDID reads now use `IOAVServiceCopyEDID` (DCP firmware path) instead of raw I2C, which is more reliable on M4+ where the DCP display pipeline handles I2C differently
- Fixed DDC/CI response parser accepting bus noise as valid data by adding checksum validation (using host write address 0x50 as seed per DDC/CI spec)
- Fixed DDC/CI hardware brightness control not working on Apple Silicon Macs:
  - Fixed response parser swapping opcode and result code bytes, which caused all valid DDC replies to be rejected
  - Added EDID-based display matching via I2C (address 0x50) for Apple Silicon Macs where the IOKit registry lacks vendor/model properties in the DCPAVServiceProxy parent chain
  - Fixed BrightnessManager not refreshing display DDC flags after async capability probing completed
- Fixed NotificationCenter observer tokens not being stored in BrightnessManager and DimmerlyApp (widget notifications, wake observer)
- Added missing translations for location privacy descriptions (NSLocationUsageDescription) in all 11 languages
- Fixed untranslated temperature format string ("%@K · %@") across all localizations
- Fixed locale-locked time formatting and duplicate localization keys
- Reduced blank-dismiss flash artifacts in dimming/blanking flow
- Disabled full-screen dimming immediately on system wake to prevent screens staying dimmed after unlock
- Launch at Login settings now surface a user-facing error alert instead of silently reverting on failure
- Clarified the location permission prompt to cover both schedules and automatic color temperature
- Moved `CLLocationManager.locationServicesEnabled()` off the main thread (Apple-recommended; the class method can block briefly)

### Changed
- DDC/CI hardware control is now enabled by default in direct distribution builds; automatically falls back to software gamma control for displays that don't support DDC
- Refined DDC indicator in menu bar panel to a subtle HW label with cable icon, replacing the bold blue capsule badge

# Building Dimmerly

This guide is for developers and contributors building Dimmerly from source.

## Prerequisites

- macOS 15.0 SDK or later
- Xcode 16.0 or later
- Swift 6.0 or later
- Optional: [just](https://github.com/casey/just)
- Optional: [SwiftLint](https://github.com/realm/SwiftLint)
- Optional: [SwiftFormat](https://github.com/nicklockwood/SwiftFormat)

## Build and Run

1. Clone the repository:

```bash
git clone https://github.com/olujicz/Dimmerly.git
cd Dimmerly
```

2. Open the project:

```bash
open Dimmerly.xcodeproj
```

3. In Xcode, select the desired scheme and press `⌘R`.

## Build Configurations

| Configuration | Scheme | Description |
|---------------|--------|-------------|
| Debug | Dimmerly | Development build with `pmset` display sleep |
| Release | Dimmerly | Distribution build with `pmset` display sleep |
| Debug-AppStore | Dimmerly App Store | Development build with gamma-based screen blanking |
| Release-AppStore | Dimmerly App Store | App Store submission build |

## Justfile Commands

A [Justfile](Justfile) provides shortcuts for common tasks:

```bash
just setup          # Configure pre-commit hooks (SwiftFormat, SwiftLint, secrets detection)
just build          # Build debug
just build-release  # Build release
just test           # Run tests
just run            # Build and run
just lint           # Lint Swift sources (SwiftLint)
just lint-fix       # Auto-fix linting issues
just format         # Format Swift sources (SwiftFormat)
just format-check   # Check formatting without changes
just clean          # Clean build artifacts
```

## Running Tests

```bash
just test
```

Or with xcodebuild directly:

```bash
xcodebuild test -scheme Dimmerly -destination 'platform=macOS'
```

## CI

GitHub Actions runs on every push and pull request to `main`:

- Lint: SwiftLint with `--strict`
- Test: Full test suite on macOS 15 with Xcode 16.4

## Architecture Notes

- Built with Swift 6 and the Observation framework (`@Observable`)
- State is managed through observable managers injected via SwiftUI environment
- No third-party runtime dependencies

## Display Control Behavior

### Direct Distribution Build

- Uses `pmset displaysleepnow` for real display sleep
- Includes an optional "Prevent Screen Lock" mode that uses gamma-based dimming instead of display sleep

### App Store Build

- Uses gamma tables + fullscreen overlay windows for dimming/blanking
- Dimming can be dismissed by configured wake input (or Escape-only mode)
- Full-screen dimming is force-cleared on system wake before gamma reapply

## Control Center Integration

Control Center integration is available on macOS 26+ and is currently gated by compiler/toolchain support in source builds (`Swift >= 6.2` and matching SDK availability).

## Contributing

For contribution workflow and standards, see [CONTRIBUTING.md](CONTRIBUTING.md).

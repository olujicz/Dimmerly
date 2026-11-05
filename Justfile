project := "Dimmerly.xcodeproj"
scheme := "Dimmerly"
appstore_scheme := "Dimmerly App Store"
destination := "platform=macOS,arch=arm64"
build_dir := ".build"
source_paths := "Dimmerly DimmerlyTests DimmerlyWidget"
swiftformat_config := ".swiftformat"
swiftformat_cache := ".build/swiftformat.cache"
swiftlint_config := ".swiftlint.yml"

# List available recipes
default:
    @just --list

# Build the app (debug)
build:
    xcodebuild -project {{project}} -scheme {{scheme}} -configuration Debug -destination '{{destination}}' -derivedDataPath {{build_dir}} build

# Build the app (release)
build-release:
    xcodebuild -project {{project}} -scheme {{scheme}} -configuration Release -destination '{{destination}}' -derivedDataPath {{build_dir}} build

# Build the App Store scheme
build-appstore:
    xcodebuild -quiet -project {{project}} -scheme '{{appstore_scheme}}' -destination '{{destination}}' build

# Run tests for both distributions (each suite launches its app host)
test: test-direct test-appstore

# Run direct-distribution tests
test-direct:
    xcodebuild -quiet -project {{project}} -scheme {{scheme}} -configuration Debug -destination '{{destination}}' -derivedDataPath {{build_dir}} test

# Run App Store tests, including the sandboxed shortcut managers
test-appstore:
    xcodebuild -quiet -project {{project}} -scheme '{{appstore_scheme}}' -configuration Debug-AppStore -destination '{{destination}}' -derivedDataPath {{build_dir}}/appstore test

# Run all project quality checks
check: format-check lint test build-appstore

# Build and run the app
run: build
    @open "{{build_dir}}/Build/Products/Debug/Dimmerly.app"

# Compose a menu-and-Settings App Store image from the live app (unlocked Mac, Screen Recording for the helper)
screenshots:
    scripts/screenshots.sh refresh --variant app-store --appearance dark

# Recreate the README and website screenshots from the direct-download build
screenshots-github:
    scripts/screenshots.sh refresh --variant github --appearance dark

# Render the demo loop: staged app, panel recording, composite, exports (unlocked Mac, Screen Recording)
demo:
    scripts/demo.sh render

# Check the installed TestFlight/App Store build's global shortcuts (dims displays; needs Accessibility for the terminal)
qa-app-store-shortcuts *args:
    @mkdir -p {{build_dir}}/qa
    xcrun swiftc -O -parse-as-library scripts/qa/AppStoreShortcutsCheck.swift -o {{build_dir}}/qa/AppStoreShortcutsCheck
    {{build_dir}}/qa/AppStoreShortcutsCheck {{args}}

# Lint Swift sources
lint:
    swiftlint lint --config {{swiftlint_config}} --quiet --strict {{source_paths}}

# Lint and auto-fix Swift sources
lint-fix:
    swiftlint lint --fix --config {{swiftlint_config}} --quiet {{source_paths}}

# Format Swift sources
format:
    swiftformat {{source_paths}} --config {{swiftformat_config}} --cache {{swiftformat_cache}}

# Check formatting without making changes
format-check:
    swiftformat {{source_paths}} --config {{swiftformat_config}} --cache {{swiftformat_cache}} --lint

# Install git hooks (run once after clone)
setup:
    git config core.hooksPath .githooks
    @echo "Git hooks installed from .githooks/"

# Clean build artifacts
clean:
    rm -rf {{build_dir}}
    xcodebuild -project {{project}} -scheme {{scheme}} clean

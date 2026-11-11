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

# Install the pinned Sparkle release into Vendor/Sparkle (checksum-checked; no-op when current).
# Only the direct-download build needs it; the App Store recipes don't.
sparkle:
    bash packaging/sparkle/fetch-sparkle.sh

# Build the app (debug)
build: sparkle
    xcodebuild -project {{project}} -scheme {{scheme}} -configuration Debug -destination '{{destination}}' -derivedDataPath {{build_dir}} build

# Build the app (release)
build-release: sparkle
    xcodebuild -project {{project}} -scheme {{scheme}} -configuration Release -destination '{{destination}}' -derivedDataPath {{build_dir}} build

# Archive the App Store edition and check it was built with the required major Xcode
archive-appstore version build:
    xcodebuild archive -project {{project}} -scheme '{{appstore_scheme}}' -configuration Release-AppStore -destination 'generic/platform=macOS' -archivePath build/appstore-{{version}}-{{build}}/Dimmerly.xcarchive -allowProvisioningUpdates
    bash .github/scripts/verify-built-xcode.sh build/appstore-{{version}}-{{build}}/Dimmerly.xcarchive
    bash .github/scripts/verify-no-updater.sh build/appstore-{{version}}-{{build}}/Dimmerly.xcarchive
    @info=build/appstore-{{version}}-{{build}}/Dimmerly.xcarchive/Products/Applications/Dimmerly.app/Contents/Info.plist; \
        v="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$info")"; \
        b="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$info")"; \
        if [ "$v" != '{{version}}' ] || [ "$b" != '{{build}}' ]; then \
            echo "Archived app is $v ($b), expected {{version}} ({{build}}); update MARKETING_VERSION and CURRENT_PROJECT_VERSION" >&2; exit 1; \
        fi; \
        echo "Archived app is $v ($b)"

# Build the App Store scheme and check it contains no part of the updater
build-appstore:
    xcodebuild -quiet -project {{project}} -scheme '{{appstore_scheme}}' -configuration Debug-AppStore -destination '{{destination}}' -derivedDataPath {{build_dir}}/appstore build
    bash .github/scripts/verify-no-updater.sh {{build_dir}}/appstore/Build/Products/Debug-AppStore/Dimmerly.app

# Run tests for both distributions (each suite launches its app host)
test: test-direct test-appstore

# Run direct-distribution tests
test-direct: sparkle
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

# Capture three launch scenes with the real menu bar, in light and dark appearances
[positional-arguments]
screenshots-launch *args:
    scripts/screenshots.sh launch "$@"

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

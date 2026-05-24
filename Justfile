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

# Run tests
test:
    xcodebuild -quiet -project {{project}} -scheme {{scheme}} -configuration Debug -destination '{{destination}}' -derivedDataPath {{build_dir}} test

# Run all project quality checks
check: format-check lint test build-appstore

# Build and run the app
run: build
    @open "{{build_dir}}/Build/Products/Debug/Dimmerly.app"

# Lint Swift sources
lint:
    swiftlint lint --config {{swiftlint_config}} --quiet

# Lint and auto-fix Swift sources
lint-fix:
    swiftlint lint --fix --quiet

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

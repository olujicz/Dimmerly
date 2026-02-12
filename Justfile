project := "Dimmerly.xcodeproj"
scheme := "Dimmerly"
build_dir := ".build"

# List available recipes
default:
    @just --list

# Build the app (debug)
build:
    xcodebuild -project {{project}} -scheme {{scheme}} -configuration Debug -derivedDataPath {{build_dir}} build

# Build the app (release)
build-release:
    xcodebuild -project {{project}} -scheme {{scheme}} -configuration Release -derivedDataPath {{build_dir}} build

# Run tests
test:
    xcodebuild -project {{project}} -scheme {{scheme}} -configuration Debug -derivedDataPath {{build_dir}} test

# Build and run the app
run: build
    @open "{{build_dir}}/Build/Products/Debug/Dimmerly.app"

# Clean build artifacts
clean:
    rm -rf {{build_dir}}
    xcodebuild -project {{project}} -scheme {{scheme}} clean

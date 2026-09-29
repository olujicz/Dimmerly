#!/usr/bin/env bash
set -euo pipefail

# Keep the selected Xcode path in CI and Release aligned with this released build.
expected_xcode=$'Xcode 27.0\nBuild version 27A266a'
actual_xcode="$(xcodebuild -version)"
if [[ "$actual_xcode" != "$expected_xcode" ]]; then
    printf 'Expected released %s; got:\n%s\n' "$expected_xcode" "$actual_xcode" >&2
    exit 1
fi

swift_output="$(swift --version 2>&1)"
swift_version="$(printf '%s\n' "$swift_output" | sed -n 's/.*Apple Swift version \([0-9][0-9.]*\).*/\1/p' | head -1)"
if [[ ! "$swift_version" =~ ^([0-9]+)\.([0-9]+)(\.[0-9]+)*$ ]]; then
    echo 'Cannot determine the Apple Swift compiler version.' >&2
    exit 1
fi
major="${BASH_REMATCH[1]}"
minor="${BASH_REMATCH[2]}"
if (( major < 6 || (major == 6 && minor < 4) )); then
    echo "Swift $swift_version excludes the macOS 27 code (requires >= 6.4)." >&2
    exit 1
fi

sdk_version="$(xcrun --sdk macosx --show-sdk-version)"
if [[ ! "$sdk_version" =~ ^([0-9]+)\.([0-9]+)(\.[0-9]+)*$ ]] ||
   (( BASH_REMATCH[1] < 27 )); then
    echo "Expected macOS SDK >= 27.0; got: $sdk_version" >&2
    exit 1
fi

printf '%s\nSwift %s, macOS SDK %s\n' "$actual_xcode" "$swift_version" "$sdk_version"

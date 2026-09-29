#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fixture_dir="$(mktemp -d)"
trap 'rm -rf "$fixture_dir"' EXIT

# Exercise the gate without requiring Xcode on the Linux scope-check runner.
cat > "$fixture_dir/xcodebuild" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$TEST_XCODE_VERSION"
SH
cat > "$fixture_dir/swift" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$TEST_SWIFT_VERSION"
SH
cat > "$fixture_dir/xcrun" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$TEST_SDK_VERSION"
SH
chmod +x "$fixture_dir/xcodebuild" "$fixture_dir/swift" "$fixture_dir/xcrun"

export PATH="$fixture_dir:$PATH"
export TEST_XCODE_VERSION=$'Xcode 27.0\nBuild version 27A266a'
export TEST_SWIFT_VERSION='Apple Swift version 6.4 (swiftlang-6.4.0)'
export TEST_SDK_VERSION='27.0'

assert_gate() {
    local expected="$1"
    local description="$2"
    local actual=0
    bash "$script_dir/verify-xcode.sh" > "$fixture_dir/output" 2>&1 || actual=$?
    if [[ "$actual" != "$expected" ]]; then
        printf 'FAIL: %s (expected %s, got %s)\n' "$description" "$expected" "$actual" >&2
        cat "$fixture_dir/output" >&2
        exit 1
    fi
    printf 'PASS: %s\n' "$description"
}

assert_gate 0 'released Xcode 27 toolchain is accepted'
TEST_XCODE_VERSION=$'Xcode 27.0\nBuild version 27A5000b'
assert_gate 1 'a different Xcode build is rejected'
TEST_XCODE_VERSION=$'Xcode 26.6\nBuild version 17F113'
assert_gate 1 'an older Xcode is rejected'
TEST_XCODE_VERSION=$'Xcode 27.0\nBuild version 27A266a'
TEST_SWIFT_VERSION='Apple Swift version 6.3 (swiftlang-6.3.0)'
assert_gate 1 'a compiler that excludes macOS 27 code is rejected'
TEST_SWIFT_VERSION='unrecognized compiler output'
assert_gate 1 'an unrecognized compiler fails closed'
TEST_SWIFT_VERSION='Apple Swift version 6.4 (swiftlang-6.4.0)'
TEST_SDK_VERSION='26.6'
assert_gate 1 'an older SDK is rejected'
TEST_SDK_VERSION=''
assert_gate 1 'a missing SDK version fails closed'

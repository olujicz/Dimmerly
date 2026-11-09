#!/usr/bin/env bash
# Tests .github/scripts/verify-no-updater.sh with fixture bundles and a stand-in otool.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
gate="$script_dir/verify-no-updater.sh"
fixture_dir="$(mktemp -d)"
trap 'rm -rf "$fixture_dir"' EXIT

# otool stand-in: lists Sparkle for any binary whose path is in $TEST_LINKED_BINARIES.
mkdir -p "$fixture_dir/bin"
cat > "$fixture_dir/bin/otool" <<'SH'
#!/usr/bin/env bash
binary="${*: -1}"
if [[ " ${TEST_UNREADABLE_BINARIES:-} " == *" $binary "* ]]; then
    echo "otool: can't open file: $binary" >&2
    exit 1
fi
printf '%s:\n\t/usr/lib/libSystem.B.dylib (compatibility version 1.0.0)\n' "$binary"
if [[ " ${TEST_LINKED_BINARIES:-} " == *" $binary "* ]]; then
    printf '\t@rpath/Sparkle.framework/Versions/B/Sparkle (compatibility version 1.6.0)\n'
fi
SH
chmod +x "$fixture_dir/bin/otool"
export PATH="$fixture_dir/bin:$PATH"

# Makes a minimal app bundle with a widget extension at $1.
make_app() {
    local app="$1"
    mkdir -p "$app/Contents/MacOS" "$app/Contents/PlugIns/Widget.appex/Contents/MacOS"
    printf 'binary\n' > "$app/Contents/MacOS/Dimmerly"
    printf 'binary\n' > "$app/Contents/PlugIns/Widget.appex/Contents/MacOS/Widget"
    plutil -create xml1 "$app/Contents/Info.plist"
    plutil -insert CFBundleExecutable -string Dimmerly "$app/Contents/Info.plist"
    plutil -create xml1 "$app/Contents/PlugIns/Widget.appex/Contents/Info.plist"
    plutil -insert CFBundleExecutable -string Widget "$app/Contents/PlugIns/Widget.appex/Contents/Info.plist"
}

assert_gate() {
    local expected="$1"
    local description="$2"
    local bundle="$3"
    local actual=0
    bash "$gate" "$bundle" > "$fixture_dir/output" 2>&1 || actual=$?
    if [[ "$actual" != "$expected" ]]; then
        printf 'FAIL: %s (expected exit %s, got %s)\n' "$description" "$expected" "$actual" >&2
        cat "$fixture_dir/output" >&2
        exit 1
    fi
    printf 'PASS: %s\n' "$description"
}

clean="$fixture_dir/clean/Dimmerly.app"
make_app "$clean"
assert_gate 0 'passes a clean bundle' "$clean"

framework="$fixture_dir/framework/Dimmerly.app"
make_app "$framework"
mkdir -p "$framework/Contents/Frameworks/Sparkle.framework"
assert_gate 1 'fails when Sparkle.framework is in Contents/Frameworks' "$framework"

nested="$fixture_dir/nested/Dimmerly.app"
make_app "$nested"
mkdir -p "$nested/Contents/PlugIns/Widget.appex/Contents/Frameworks/Sparkle.framework"
assert_gate 1 'fails when Sparkle.framework is nested elsewhere' "$nested"

keys="$fixture_dir/keys/Dimmerly.app"
make_app "$keys"
plutil -insert SUFeedURL -string https://example.com/appcast.xml "$keys/Contents/Info.plist"
assert_gate 1 'fails when Info.plist has an SU key' "$keys"

linked="$fixture_dir/linked/Dimmerly.app"
make_app "$linked"
TEST_LINKED_BINARIES="$linked/Contents/MacOS/Dimmerly" \
    assert_gate 1 'fails when the executable links Sparkle' "$linked"

linked_extension="$fixture_dir/linked-extension/Dimmerly.app"
make_app "$linked_extension"
TEST_LINKED_BINARIES="$linked_extension/Contents/PlugIns/Widget.appex/Contents/MacOS/Widget" \
    assert_gate 1 'fails when an extension links Sparkle' "$linked_extension"

unreadable="$fixture_dir/unreadable/Dimmerly.app"
make_app "$unreadable"
TEST_UNREADABLE_BINARIES="$unreadable/Contents/MacOS/Dimmerly" \
    assert_gate 1 'fails when otool cannot read an executable' "$unreadable"

archive="$fixture_dir/Dimmerly.xcarchive"
make_app "$archive/Products/Applications/Dimmerly.app"
assert_gate 0 'accepts an .xcarchive path' "$archive"

mkdir -p "$archive/Products/Applications/Dimmerly.app/Contents/Frameworks/Sparkle.framework"
assert_gate 1 'checks the app inside an .xcarchive' "$archive"

assert_gate 1 'fails when the bundle does not exist' "$fixture_dir/missing/Dimmerly.app"

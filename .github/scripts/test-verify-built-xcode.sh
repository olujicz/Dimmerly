#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fixture_dir="$(mktemp -d)"
trap 'rm -rf "$fixture_dir"' EXIT

# Writes an app bundle Info.plist with the given DTXcodeBuild and DTSDKName ('' leaves a key out).
make_app() {
    local app="$1" xcode_build="$2" sdk="$3"
    mkdir -p "$app/Contents"
    python3 -I -c 'import plistlib, sys
info = {"CFBundleIdentifier": "rs.in.olujic.dimmerly"}
if sys.argv[2]:
    info["DTXcodeBuild"] = sys.argv[2]
if sys.argv[3]:
    info["DTSDKName"] = sys.argv[3]
with open(sys.argv[1], "wb") as f:
    plistlib.dump(info, f)' "$app/Contents/Info.plist" "$xcode_build" "$sdk"
}

assert_gate() {
    local expected="$1" path="$2" description="$3" actual=0
    bash "$script_dir/verify-built-xcode.sh" "$path" > "$fixture_dir/output" 2>&1 || actual=$?
    if [[ "$actual" != "$expected" ]]; then
        printf 'FAIL: %s (expected %s, got %s)\n' "$description" "$expected" "$actual" >&2
        cat "$fixture_dir/output" >&2
        exit 1
    fi
    printf 'PASS: %s\n' "$description"
}

make_app "$fixture_dir/ci/Dimmerly.app" '27A9275' 'macosx27.0'
assert_gate 0 "$fixture_dir/ci/Dimmerly.app" 'an app from the pinned CI Xcode is accepted'

make_app "$fixture_dir/Local.xcarchive/Products/Applications/Dimmerly.app" '27B52' 'macosx27.2'
assert_gate 0 "$fixture_dir/Local.xcarchive/" 'an archive from a newer Xcode 27 is accepted'

make_app "$fixture_dir/old/Dimmerly.app" '26E100' 'macosx26.4'
assert_gate 1 "$fixture_dir/old/Dimmerly.app" 'an app from an older major Xcode is rejected'

make_app "$fixture_dir/New.xcarchive/Products/Applications/Dimmerly.app" '28A100' 'macosx28.0'
assert_gate 1 "$fixture_dir/New.xcarchive" 'an archive from a newer major Xcode is rejected'

make_app "$fixture_dir/mixed/Dimmerly.app" '27B52' 'macosx26.4'
assert_gate 1 "$fixture_dir/mixed/Dimmerly.app" 'an older major SDK is rejected'

make_app "$fixture_dir/unknown/Dimmerly.app" '' 'macosx27.0'
assert_gate 1 "$fixture_dir/unknown/Dimmerly.app" 'a missing DTXcodeBuild fails closed'

make_app "$fixture_dir/nosdk/Dimmerly.app" '27A9275' ''
assert_gate 1 "$fixture_dir/nosdk/Dimmerly.app" 'a missing DTSDKName fails closed'

assert_gate 1 "$fixture_dir/missing/Dimmerly.app" 'a missing app fails closed'

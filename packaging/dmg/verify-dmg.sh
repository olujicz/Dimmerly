#!/usr/bin/env bash
# Inspects a finished Dimmerly DMG the way a user's Mac will see it.
#
# Usage: packaging/dmg/verify-dmg.sh <dmg> <version> <build number> <minimum macOS> <team ID>
#
# Run after signing, notarization, and stapling. The checks are read-only.
set -euo pipefail

if [[ $# -ne 5 ]]; then
    echo "Usage: $0 <dmg> <version> <build number> <minimum macOS> <team ID>" >&2
    exit 64
fi

dmg_path="$1"
expected_version="$2"
expected_build="$3"
expected_minimum_macos="$4"
expected_team_id="$5"
expected_format="ULMO"
app_name="Dimmerly.app"

failures=0
fail() {
    echo "FAIL: $*" >&2
    failures=$((failures + 1))
}
pass() {
    echo "ok: $*"
}

if [[ ! -f "$dmg_path" ]]; then
    echo "DMG not found: $dmg_path" >&2
    exit 1
fi

format="$(hdiutil imageinfo -plist "$dmg_path" 2>/dev/null | plutil -extract Format raw -o - -)"
if [[ "$format" == "$expected_format" ]]; then
    pass "image format is $format"
else
    fail "image format is $format, expected $expected_format"
fi

dmg_signature="$(codesign -dvvv "$dmg_path" 2>&1 || true)"
if grep -q "^TeamIdentifier=${expected_team_id}$" <<<"$dmg_signature"; then
    pass "DMG is signed by team $expected_team_id"
else
    fail "DMG is not signed by team $expected_team_id"
fi
if grep -q "^Timestamp=" <<<"$dmg_signature"; then
    pass "DMG signature has a secure timestamp"
else
    fail "DMG signature has no secure timestamp"
fi

mount_point="$(mktemp -d "${TMPDIR:-/tmp}/dimmerly-dmg-verify.XXXXXX")"
detach() {
    hdiutil detach "$mount_point" -quiet 2>/dev/null || hdiutil detach "$mount_point" -force -quiet 2>/dev/null || true
    rmdir "$mount_point" 2>/dev/null || true
}
trap detach EXIT

if ! hdiutil attach "$dmg_path" -readonly -nobrowse -noautoopen -mountpoint "$mount_point" -quiet; then
    echo "FAIL: could not mount $dmg_path" >&2
    exit 1
fi

app_path="$mount_point/$app_name"
if [[ -d "$app_path" ]]; then
    pass "$app_name is present"
else
    fail "$app_name is missing"
fi

if [[ -L "$mount_point/Applications" && "$(readlink "$mount_point/Applications")" == "/Applications" ]]; then
    pass "Applications shortcut points to /Applications"
else
    fail "Applications shortcut is missing or does not point to /Applications"
fi

for layout_file in .DS_Store .background.tiff .VolumeIcon.icns; do
    if [[ -f "$mount_point/$layout_file" ]]; then
        pass "$layout_file is present"
    else
        fail "$layout_file is missing"
    fi
done

unexpected="$(find "$mount_point" -mindepth 1 -maxdepth 1 \
    ! -name "$app_name" ! -name Applications \
    ! -name .DS_Store ! -name .background.tiff ! -name .VolumeIcon.icns \
    ! -name .fseventsd ! -name .Trashes \
    -exec basename {} \;)"
if [[ -z "$unexpected" ]]; then
    pass "no unexpected items at the volume root"
else
    fail "unexpected items at the volume root: $(tr '\n' ' ' <<<"$unexpected")"
fi

if [[ -d "$app_path" ]]; then
    info_plist="$app_path/Contents/Info.plist"
    plist_value() {
        /usr/libexec/PlistBuddy -c "Print :$1" "$info_plist" 2>/dev/null || true
    }

    app_version="$(plist_value CFBundleShortVersionString)"
    if [[ "$app_version" == "$expected_version" ]]; then
        pass "app version is $app_version"
    else
        fail "app version is $app_version, expected $expected_version"
    fi

    app_build="$(plist_value CFBundleVersion)"
    if [[ "$app_build" == "$expected_build" ]]; then
        pass "app build is $app_build"
    else
        fail "app build is $app_build, expected $expected_build"
    fi

    minimum_macos="$(plist_value LSMinimumSystemVersion)"
    if [[ "$minimum_macos" == "$expected_minimum_macos" ]]; then
        pass "minimum macOS is $minimum_macos"
    else
        fail "minimum macOS is $minimum_macos, expected $expected_minimum_macos"
    fi

    executable="$app_path/Contents/MacOS/$(plist_value CFBundleExecutable)"
    architectures="$(lipo -archs "$executable" 2>/dev/null || true)"
    if [[ " $architectures " == *" arm64 "* && " $architectures " == *" x86_64 "* ]]; then
        pass "app is universal ($architectures)"
    else
        fail "app architectures are '$architectures', expected arm64 and x86_64"
    fi

    if codesign --verify --deep --strict "$app_path" 2>/dev/null; then
        pass "app signature verifies"
    else
        fail "app signature does not verify"
    fi

    app_signature="$(codesign -dvvv "$app_path" 2>&1 || true)"
    if grep -q "^TeamIdentifier=${expected_team_id}$" <<<"$app_signature"; then
        pass "app is signed by team $expected_team_id"
    else
        fail "app is not signed by team $expected_team_id"
    fi
    if grep -Eq "^CodeDirectory .*flags=0x[0-9a-f]+\([^)]*runtime" <<<"$app_signature"; then
        pass "app has the Hardened Runtime enabled"
    else
        fail "app does not have the Hardened Runtime enabled"
    fi
    if grep -q "^Timestamp=" <<<"$app_signature"; then
        pass "app signature has a secure timestamp"
    else
        fail "app signature has no secure timestamp"
    fi

    if xcrun stapler validate -q "$app_path" 2>/dev/null; then
        pass "app has a stapled notarization ticket"
    else
        fail "app has no stapled notarization ticket"
    fi
fi

if [[ "$failures" -gt 0 ]]; then
    echo "$failures DMG check(s) failed." >&2
    exit 1
fi

echo "All DMG checks passed."

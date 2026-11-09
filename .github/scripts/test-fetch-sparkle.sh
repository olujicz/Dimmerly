#!/usr/bin/env bash
# Tests packaging/sparkle/fetch-sparkle.sh against a local stand-in for the Sparkle release.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fetch_script="$script_dir/../../packaging/sparkle/fetch-sparkle.sh"
fixture_dir="$(mktemp -d)"
trap 'rm -rf "$fixture_dir"' EXIT

# A release archive with the same layout as Sparkle's.
mkdir -p "$fixture_dir/release/Sparkle.framework/Versions/B" "$fixture_dir/release/bin"
printf 'framework\n' > "$fixture_dir/release/Sparkle.framework/Versions/B/Sparkle"
printf '#!/bin/sh\n' > "$fixture_dir/release/bin/generate_appcast"
chmod +x "$fixture_dir/release/bin/generate_appcast"
printf 'license\n' > "$fixture_dir/release/LICENSE"
tar -cJf "$fixture_dir/Sparkle-9.9.9.tar.xz" -C "$fixture_dir/release" .
good_sha="$(shasum -a 256 "$fixture_dir/Sparkle-9.9.9.tar.xz" | awk '{ print $1 }')"

write_pin() {
    printf 'SPARKLE_VERSION=%s\nSPARKLE_SHA256=%s\n' "$1" "$2" > "$fixture_dir/sparkle-version.env"
}

export SPARKLE_VERSION_FILE="$fixture_dir/sparkle-version.env"
export SPARKLE_VENDOR_DIR="$fixture_dir/Vendor/Sparkle"
export SPARKLE_DOWNLOAD_URL="file://$fixture_dir/Sparkle-9.9.9.tar.xz"

run_fetch() {
    local expected="$1"
    local description="$2"
    local actual=0
    bash "$fetch_script" > "$fixture_dir/output" 2>&1 || actual=$?
    if [[ "$actual" != "$expected" ]]; then
        printf 'FAIL: %s (expected exit %s, got %s)\n' "$description" "$expected" "$actual" >&2
        cat "$fixture_dir/output" >&2
        exit 1
    fi
}

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

write_pin 9.9.9 "$(printf '0%.0s' {1..64})"
run_fetch 1 'a checksum mismatch fails'
[[ ! -e "$SPARKLE_VENDOR_DIR" ]] || fail 'a checksum mismatch left a vendor directory behind'
printf 'PASS: fails when the checksum does not match\n'

write_pin 9.9.9 "$good_sha"
run_fetch 0 'a matching checksum installs'
[[ -f "$SPARKLE_VENDOR_DIR/Sparkle.framework/Versions/B/Sparkle" ]] || fail 'the framework was not installed'
[[ -x "$SPARKLE_VENDOR_DIR/bin/generate_appcast" ]] || fail 'the tools were not installed'
[[ "$(cat "$SPARKLE_VENDOR_DIR/.version")" == 9.9.9 ]] || fail '.version does not name the pinned version'
printf 'PASS: installs when the checksum matches\n'

SPARKLE_DOWNLOAD_URL="file://$fixture_dir/missing.tar.xz" run_fetch 0 'an installed pinned version is kept'
printf 'PASS: does nothing when the pinned version is already installed\n'

printf '9.9.8\n' > "$SPARKLE_VENDOR_DIR/.version"
printf 'stale\n' > "$SPARKLE_VENDOR_DIR/stale-file"
run_fetch 0 'a different installed version is replaced'
[[ "$(cat "$SPARKLE_VENDOR_DIR/.version")" == 9.9.9 ]] || fail 'the reinstall did not record the pinned version'
[[ ! -e "$SPARKLE_VENDOR_DIR/stale-file" ]] || fail 'the reinstall kept files from the old version'
printf 'PASS: reinstalls when .version differs\n'

printf '9.9.8\n' > "$SPARKLE_VENDOR_DIR/.version"
SPARKLE_DOWNLOAD_URL="file://$fixture_dir/missing.tar.xz" run_fetch 1 'a failed download fails'
[[ "$(cat "$SPARKLE_VENDOR_DIR/.version")" == 9.9.8 ]] || fail 'a failed download changed the installed copy'
printf 'PASS: a failed download leaves the installed copy alone\n'

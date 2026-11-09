#!/usr/bin/env bash
# Installs the pinned Sparkle release into Vendor/Sparkle (gitignored).
#
# The version and SHA-256 come from packaging/sparkle/sparkle-version.env. The archive
# is checked before anything is unpacked, and the new copy replaces the old one only
# after it unpacked completely, so a failed run never leaves a partial install.
# Does nothing when the pinned version is already installed.
#
# Overrides (for tests): SPARKLE_VERSION_FILE, SPARKLE_VENDOR_DIR, SPARKLE_DOWNLOAD_URL.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
version_file="${SPARKLE_VERSION_FILE:-$script_dir/sparkle-version.env}"
vendor_dir="${SPARKLE_VENDOR_DIR:-$repo_root/Vendor/Sparkle}"

pinned_value() {
    local value
    value="$(sed -n "s/^$1=//p" "$version_file")"
    if [[ -z "$value" ]]; then
        echo "$1 is missing from $version_file" >&2
        exit 1
    fi
    printf '%s' "$value"
}

version="$(pinned_value SPARKLE_VERSION)"
expected_sha="$(pinned_value SPARKLE_SHA256)"
url="${SPARKLE_DOWNLOAD_URL:-https://github.com/sparkle-project/Sparkle/releases/download/$version/Sparkle-$version.tar.xz}"

if [[ -f "$vendor_dir/.version" && "$(cat "$vendor_dir/.version")" == "$version" ]]; then
    echo "Sparkle $version is already installed in $vendor_dir"
    exit 0
fi

parent_dir="$(dirname "$vendor_dir")"
mkdir -p "$parent_dir"
work_dir="$(mktemp -d "$parent_dir/.sparkle-fetch.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT

archive="$work_dir/Sparkle-$version.tar.xz"
if ! curl -fsSL --retry 3 -o "$archive" "$url"; then
    echo "Could not download Sparkle $version from $url" >&2
    exit 1
fi

actual_sha="$(shasum -a 256 "$archive" | awk '{ print $1 }')"
if [[ "$actual_sha" != "$expected_sha" ]]; then
    printf 'Sparkle %s checksum mismatch: expected %s, got %s\n' "$version" "$expected_sha" "$actual_sha" >&2
    exit 1
fi

mkdir "$work_dir/unpacked"
tar -xJf "$archive" -C "$work_dir/unpacked"
printf '%s\n' "$version" > "$work_dir/unpacked/.version"

rm -rf "$vendor_dir"
mv "$work_dir/unpacked" "$vendor_dir"
echo "Installed Sparkle $version in $vendor_dir"

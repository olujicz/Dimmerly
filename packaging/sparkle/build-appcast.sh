#!/usr/bin/env bash
# Makes the signed appcast.xml for one release with Sparkle's generate_appcast.
#
# Usage: packaging/sparkle/build-appcast.sh <dmg> <version> <output appcast.xml>
#
# The private EdDSA key is read from standard input (CI pipes the secret in), so it never
# touches disk. For local testing, set SPARKLE_KEY_ACCOUNT (e.g. "dimmerly") to use the key
# stored in the login Keychain under that account instead.
#
# The release notes are this version's CHANGELOG.md section, embedded as Markdown.
# generate_appcast reads the version, build and minimum macOS from the app inside the DMG,
# and signs the feed because the app requires a signed feed (SURequireSignedFeed).
set -euo pipefail

if [[ $# -ne 3 ]]; then
    echo "Usage: $0 <dmg> <version> <output appcast.xml>" >&2
    exit 64
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
dmg="$1"
version="$2"
output="$3"
generate_appcast="${SPARKLE_BIN_DIR:-$repo_root/Vendor/Sparkle/bin}/generate_appcast"

if [[ ! -f "$dmg" ]]; then
    echo "DMG not found: $dmg" >&2
    exit 1
fi
if [[ ! -x "$generate_appcast" ]]; then
    echo "generate_appcast not found; run packaging/sparkle/fetch-sparkle.sh first" >&2
    exit 1
fi

stage="$(mktemp -d "${TMPDIR:-/tmp}/dimmerly-appcast.XXXXXX")"
trap 'rm -rf "$stage"' EXIT

archive_name="$(basename "$dmg" .dmg)"
cp "$dmg" "$stage/$archive_name.dmg"
bash "$script_dir/changelog-section.sh" "$version" > "$stage/$archive_name.md"

key_arguments=(--ed-key-file -)
if [[ -n "${SPARKLE_KEY_ACCOUNT:-}" ]]; then
    key_arguments=(--account "$SPARKLE_KEY_ACCOUNT")
fi

"$generate_appcast" "${key_arguments[@]}" \
    --download-url-prefix "https://github.com/olujicz/Dimmerly/releases/download/v$version/" \
    --embed-release-notes \
    -o "$stage/appcast.xml" \
    "$stage"

mkdir -p "$(dirname "$output")"
cp "$stage/appcast.xml" "$output"
echo "Wrote $output"

#!/usr/bin/env bash
# Tests packaging/sparkle/verify-appcast.sh with a signed fixture appcast.
# Needs macOS: the signature check uses CryptoKit through packaging/sparkle/ed25519.swift.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
sparkle_dir="$script_dir/../../packaging/sparkle"
verifier="$sparkle_dir/verify-appcast.sh"
fixture_dir="$(mktemp -d)"
trap 'rm -rf "$fixture_dir"' EXIT

version=1.5.0
build=16
prefix="https://github.com/olujicz/Dimmerly/releases/download/v$version/"
dmg="$fixture_dir/Dimmerly-$version.dmg"
head -c 4096 /dev/urandom > "$dmg"
length="$(stat -f%z "$dmg")"

# Compile the signature helper once instead of once per call.
xcrun swiftc -O "$sparkle_dir/ed25519.swift" -o "$fixture_dir/ed25519"
export ED25519_TOOL="$fixture_dir/ed25519"

# One ephemeral key signs the fixture; another stands in for a stranger's key.
read -r public_key signature < <("$ED25519_TOOL" test-sign "$dmg")
read -r other_public_key _ < <("$ED25519_TOOL" test-sign "$dmg")

# Writes an appcast to $1. Fields can be overridden through the environment.
write_appcast() {
    local path="$1"
    local items="${ITEM_COUNT:-1}"
    {
        printf '<?xml version="1.0" encoding="utf-8"?>\n'
        printf '<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">\n'
        printf '    <channel>\n        <title>Dimmerly</title>\n'
        for _ in $(seq "$items"); do
            printf '        <item>\n'
            printf '            <title>%s</title>\n' "${SHORT_VERSION:-$version}"
            printf '            <pubDate>Fri, 20 Nov 2026 10:00:00 +0000</pubDate>\n'
            printf '            <sparkle:version>%s</sparkle:version>\n' "${BUILD:-$build}"
            printf '            <sparkle:shortVersionString>%s</sparkle:shortVersionString>\n' "${SHORT_VERSION:-$version}"
            printf '            <sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion>\n'
            if [[ "${NOTES:-markdown}" == markdown ]]; then
                printf '            <description sparkle:format="markdown"><![CDATA[### Fixed\n- Brightness & warmth stay <in range>.\n]]></description>\n'
            fi
            printf '            <enclosure url="%s" length="%s" type="application/octet-stream" sparkle:edSignature="%s"/>\n' \
                "${URL:-${prefix}Dimmerly-$version.dmg}" "${LENGTH:-$length}" "${SIGNATURE:-$signature}"
            printf '        </item>\n'
        done
        printf '    </channel>\n</rss>\n'
    } > "$path"
}

assert_verifier() {
    local expected="$1"
    local description="$2"
    local key="${3:-$public_key}"
    local appcast="${APPCAST:-$fixture_dir/appcast.xml}"
    [[ -n "${APPCAST:-}" ]] || write_appcast "$appcast"
    local actual=0
    bash "$verifier" "$appcast" "$dmg" "$version" "$build" "$key" > "$fixture_dir/output" 2>&1 || actual=$?
    if [[ "$actual" != "$expected" ]]; then
        printf 'FAIL: %s (expected exit %s, got %s)\n' "$description" "$expected" "$actual" >&2
        cat "$fixture_dir/output" >&2
        exit 1
    fi
    printf 'PASS: %s\n' "$description"
}

assert_verifier 0 'passes a correct appcast'
SHORT_VERSION=1.5.1 assert_verifier 1 'fails on a wrong version'
BUILD=17 assert_verifier 1 'fails on a wrong build'
URL="${prefix}Dimmerly-1.4.2.dmg" assert_verifier 1 'fails on a wrong URL'
URL="http://github.com/olujicz/Dimmerly/releases/download/v$version/Dimmerly-$version.dmg" \
    assert_verifier 1 'fails on a plain-HTTP URL'
LENGTH=$((length + 1)) assert_verifier 1 'fails on a wrong length'
NOTES=none assert_verifier 1 'fails without embedded markdown notes'
ITEM_COUNT=2 assert_verifier 1 'fails with two items'
assert_verifier 1 'fails when signed by another key' "$other_public_key"
replacement=A
[[ "${signature:10:1}" != A ]] || replacement=B
SIGNATURE="${signature:0:10}${replacement}${signature:11}" assert_verifier 1 'fails on a tampered signature'

cp "$dmg" "$fixture_dir/original.dmg"
printf '\x00' | dd of="$dmg" bs=1 seek=100 count=1 conv=notrunc 2>/dev/null
assert_verifier 1 'fails on a tampered DMG'
cp "$fixture_dir/original.dmg" "$dmg"

printf 'not xml' > "$fixture_dir/broken.xml"
APPCAST="$fixture_dir/broken.xml" assert_verifier 1 'fails on unreadable XML'

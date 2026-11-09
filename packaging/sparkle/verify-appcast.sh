#!/usr/bin/env bash
# Checks a release's appcast.xml before it's attached to the draft GitHub Release.
#
# Usage: packaging/sparkle/verify-appcast.sh <appcast.xml> <dmg> <version> <build> [public key]
#
# The public key defaults to SUPublicEDKey in packaging/sparkle/SparkleInfo.plist, the
# key the app ships with. Checks: one item; version and build; the GitHub download URL
# for this version; the DMG's length; a minimum macOS version; embedded Markdown notes;
# and the enclosure's EdDSA signature against the public key. The feed signature is
# checked separately with `sign_update --verify`, which needs the private key.
set -euo pipefail

if [[ $# -lt 4 || $# -gt 5 ]]; then
    echo "Usage: $0 <appcast.xml> <dmg> <version> <build> [public key]" >&2
    exit 64
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
appcast="$1"
dmg="$2"
version="$3"
build="$4"
public_key="${5:-$(plutil -extract SUPublicEDKey raw -o - "$script_dir/SparkleInfo.plist")}"
expected_url="https://github.com/olujicz/Dimmerly/releases/download/v$version/Dimmerly-$version.dmg"

failures=0
fail() {
    echo "FAIL: $*" >&2
    failures=$((failures + 1))
}
pass() {
    echo "ok: $*"
}

# Prints one "name<TAB>value" line per field, or fails if the XML can't be read.
fields="$(/usr/bin/python3 -I - "$appcast" <<'PY'
import sys
import xml.etree.ElementTree as ET

SPARKLE = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
try:
    root = ET.parse(sys.argv[1]).getroot()
except (ET.ParseError, OSError) as error:
    sys.exit(f"appcast is not readable XML: {error}")

items = root.findall("./channel/item")
print(f"items\t{len(items)}")
if items:
    item = items[0]
    enclosure = item.find("enclosure")
    description = item.find("description")
    values = {
        "version": item.findtext(f"{SPARKLE}version", ""),
        "short_version": item.findtext(f"{SPARKLE}shortVersionString", ""),
        "minimum_system": item.findtext(f"{SPARKLE}minimumSystemVersion", ""),
        "notes_format": "" if description is None else description.get(f"{SPARKLE}format", ""),
        "notes_length": "0" if description is None else str(len((description.text or "").strip())),
        "url": "" if enclosure is None else enclosure.get("url", ""),
        "length": "" if enclosure is None else enclosure.get("length", ""),
        "signature": "" if enclosure is None else enclosure.get(f"{SPARKLE}edSignature", ""),
    }
    for name, value in values.items():
        print(f"{name}\t{value.strip()}")
PY
)" || exit 1

field() {
    awk -F '\t' -v name="$1" '$1 == name { print $2; exit }' <<<"$fields"
}

if [[ "$(field items)" == 1 ]]; then pass "one item"; else fail "expected one item, found $(field items)"; fi
if [[ "$(field version)" == "$build" ]]; then
    pass "sparkle:version is $build"
else
    fail "sparkle:version is '$(field version)', expected $build"
fi
if [[ "$(field short_version)" == "$version" ]]; then
    pass "sparkle:shortVersionString is $version"
else
    fail "sparkle:shortVersionString is '$(field short_version)', expected $version"
fi
if [[ "$(field url)" == "$expected_url" ]]; then
    pass "enclosure URL is $expected_url"
else
    fail "enclosure URL is '$(field url)', expected $expected_url"
fi
dmg_length="$(stat -f%z "$dmg")"
if [[ "$(field length)" == "$dmg_length" ]]; then
    pass "enclosure length matches the DMG ($dmg_length bytes)"
else
    fail "enclosure length is '$(field length)', the DMG is $dmg_length bytes"
fi
if [[ -n "$(field minimum_system)" ]]; then
    pass "sparkle:minimumSystemVersion is $(field minimum_system)"
else
    fail "sparkle:minimumSystemVersion is missing"
fi
if [[ "$(field notes_format)" == markdown && "$(field notes_length)" -gt 0 ]]; then
    pass "release notes are embedded as Markdown"
else
    fail "release notes are not embedded as Markdown (format '$(field notes_format)', $(field notes_length) characters)"
fi

signature="$(field signature)"
if [[ -n "$signature" ]] &&
    xcrun swift "$script_dir/ed25519.swift" verify "$public_key" "$signature" "$dmg" >/dev/null 2>&1; then
    pass "enclosure signature matches the DMG and the app's public key"
else
    fail "enclosure signature does not match the DMG and the app's public key"
fi

if [[ "$failures" -ne 0 ]]; then
    exit 1
fi

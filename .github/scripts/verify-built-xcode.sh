#!/usr/bin/env bash
# Checks that a built Dimmerly.app, or the app inside an .xcarchive, was built with the
# required major Xcode and macOS SDK from xcode-pin.sh, so the DMG from CI and the App Store
# archive from a local Xcode stay on the same toolchain generation.
#
# Usage: .github/scripts/verify-built-xcode.sh <Dimmerly.app | Dimmerly.xcarchive>
set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "Usage: $0 <Dimmerly.app | Dimmerly.xcarchive>" >&2
    exit 64
fi

# shellcheck source-path=SCRIPTDIR source=xcode-pin.sh
source "$(dirname "${BASH_SOURCE[0]}")/xcode-pin.sh"

bundle="${1%/}"
if [[ "$bundle" == *.xcarchive ]]; then
    bundle="$bundle/Products/Applications/Dimmerly.app"
fi
info_plist="$bundle/Contents/Info.plist"
if [[ ! -f "$info_plist" ]]; then
    echo "No Info.plist at $info_plist" >&2
    exit 1
fi

read_key() {
    python3 -I -c 'import plistlib, sys
with open(sys.argv[1], "rb") as f:
    print(plistlib.load(f).get(sys.argv[2], ""))' "$info_plist" "$1"
}

built_xcode="$(read_key DTXcodeBuild)"
built_sdk="$(read_key DTSDKName)"
# Xcode build numbers start with the major version and a letter, e.g. 27A9275 or 27B52.
if [[ ! "$built_xcode" =~ ^${required_xcode_major}[A-Z] || ! "$built_sdk" =~ ^macosx${required_xcode_major}\. ]]; then
    printf 'Built with Xcode build %s and SDK %s; expected Xcode %s with a macOS %s SDK.\n' \
        "${built_xcode:-unknown}" "${built_sdk:-unknown}" "$required_xcode_major" "$required_xcode_major" >&2
    exit 1
fi
printf 'Built with Xcode %s and SDK %s (Xcode %s required)\n' "$built_xcode" "$built_sdk" "$required_xcode_major"

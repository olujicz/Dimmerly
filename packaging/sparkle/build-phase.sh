#!/usr/bin/env bash
# Xcode build phase for the Dimmerly target, run last.
#
# Direct-download configurations (Debug, Release): copies the Sparkle keys from
# packaging/sparkle/SparkleInfo.plist into the built Info.plist.
# App Store configurations (*-AppStore): does nothing. Those configurations don't link
# Sparkle and exclude it from embedding (EXCLUDED_SOURCE_FILE_NAMES = Sparkle.framework),
# because App Review doesn't allow another update mechanism (guideline 2.4.5(vii)).
# .github/scripts/verify-no-updater.sh checks the result.
set -euo pipefail

: "${CONFIGURATION:?run from an Xcode build phase}"
: "${TARGET_BUILD_DIR:?}" "${INFOPLIST_PATH:?}" "${SRCROOT:?}" "${DERIVED_FILE_DIR:?}"

# Xcode needs one ordinary output besides the Info.plist this phase edits in place.
mkdir -p "$DERIVED_FILE_DIR"
touch "$DERIVED_FILE_DIR/sparkle-build-phase.stamp"

if [[ "$CONFIGURATION" == *-AppStore ]]; then
    exit 0
fi

fragment="$SRCROOT/packaging/sparkle/SparkleInfo.plist"
info_plist="$TARGET_BUILD_DIR/$INFOPLIST_PATH"

# A Release build must carry a real public key: base64 for 32 bytes.
if [[ "$CONFIGURATION" == Release ]]; then
    public_key="$(/usr/bin/plutil -extract SUPublicEDKey raw -o - "$fragment")"
    key_bytes="$(/usr/bin/python3 -I -c 'import base64, binascii, sys
try:
    print(len(base64.b64decode(sys.argv[1], validate=True)))
except (binascii.Error, ValueError):
    print(0)' "$public_key")"
    if [[ "$key_bytes" != 32 ]]; then
        echo "error: SUPublicEDKey in packaging/sparkle/SparkleInfo.plist is not an Ed25519 public key" >&2
        exit 1
    fi
fi

keys="$(/usr/bin/python3 -I -c 'import plistlib, sys
with open(sys.argv[1], "rb") as f:
    print("\n".join(plistlib.load(f)))' "$fragment")"

while IFS= read -r key; do
    [[ -n "$key" ]] || continue
    value_xml="$(/usr/bin/plutil -extract "$key" xml1 -o - "$fragment")"
    /usr/bin/plutil -replace "$key" -xml "$value_xml" "$info_plist"
done <<<"$keys"

#!/usr/bin/env bash
# Xcode build phase for the Dimmerly target, run first.
#
# Writes $DERIVED_FILE_DIR/Info-Direct.plist: Dimmerly/Resources/Info.plist plus,
# for the direct-download configurations (Debug, Release), the Sparkle keys from
# packaging/sparkle/SparkleInfo.plist. Debug and Release use that file as their
# INFOPLIST_FILE, so Xcode's own Info.plist step writes the final file and the
# shared Info.plist stays free of updater keys. App Store configurations keep
# using Dimmerly/Resources/Info.plist; for them this writes a plain copy.
#
# The keys used to be added by editing the built Info.plist in a last phase that
# declared it as an output. That made the phase the file's last writer, and Xcode
# then dropped the widget's ValidateEmbeddedBinary dependency on it: the check
# could run before the Info.plist existed ("Couldn't load Info dictionary for
# containing app"), which failed CI on 2026-11-10 and the v1.5.0 Release run.
set -euo pipefail

: "${CONFIGURATION:?run from an Xcode build phase}"
: "${SRCROOT:?}" "${DERIVED_FILE_DIR:?}"

source_plist="$SRCROOT/Dimmerly/Resources/Info.plist"
fragment="$SRCROOT/packaging/sparkle/SparkleInfo.plist"
merged="$DERIVED_FILE_DIR/Info-Direct.plist"

# Script sandboxing only allows writing the declared output, so build it in place
# and remove it if any step fails.
trap 'rm -f "$merged"' ERR
mkdir -p "$DERIVED_FILE_DIR"
cp "$source_plist" "$merged"

if [[ "$CONFIGURATION" != *-AppStore ]]; then
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
            rm -f "$merged"
            exit 1
        fi
    fi

    keys="$(/usr/bin/python3 -I -c 'import plistlib, sys
with open(sys.argv[1], "rb") as f:
    print("\n".join(plistlib.load(f)))' "$fragment")"

    while IFS= read -r key; do
        [[ -n "$key" ]] || continue
        value_xml="$(/usr/bin/plutil -extract "$key" xml1 -o - "$fragment")"
        /usr/bin/plutil -replace "$key" -xml "$value_xml" "$merged"
    done <<<"$keys"
fi


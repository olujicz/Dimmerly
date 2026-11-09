#!/usr/bin/env bash
# Fails if an App Store build of Dimmerly contains any part of the Sparkle updater.
#
# App Review guideline 2.4.5(vii): Mac App Store apps must use the Mac App Store to
# distribute updates. A Sparkle framework left in the bundle gets the build rejected,
# and a Sparkle load command without the framework crashes the app at launch.
#
# Usage: .github/scripts/verify-no-updater.sh <Dimmerly.app | Dimmerly.xcarchive>
set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "Usage: $0 <Dimmerly.app | Dimmerly.xcarchive>" >&2
    exit 64
fi

bundle="${1%/}"
if [[ "$bundle" == *.xcarchive ]]; then
    bundle="$bundle/Products/Applications/Dimmerly.app"
fi
if [[ ! -f "$bundle/Contents/Info.plist" ]]; then
    echo "No app bundle at $bundle" >&2
    exit 1
fi

failures=0
fail() {
    echo "FAIL: $*" >&2
    failures=$((failures + 1))
}

while IFS= read -r -d '' framework; do
    fail "bundle contains ${framework#"$bundle"/}"
done < <(find "$bundle" -name 'Sparkle.framework' -print0)

# Main executable and every app extension executable.
executables=()
while IFS= read -r -d '' info_plist; do
    contents_dir="$(dirname "$info_plist")"
    executable_name="$(plutil -extract CFBundleExecutable raw -o - "$info_plist" 2>/dev/null || true)"
    if [[ -n "$executable_name" && -f "$contents_dir/MacOS/$executable_name" ]]; then
        executables+=("$contents_dir/MacOS/$executable_name")
    fi
done < <(find "$bundle/Contents" -path '*/Contents/Info.plist' -print0)

for executable in "${executables[@]}"; do
    if otool -L "$executable" | grep -q 'Sparkle.framework'; then
        fail "${executable#"$bundle"/} links Sparkle"
    fi
done

updater_keys="$(/usr/bin/python3 -I -c 'import plistlib, sys
with open(sys.argv[1], "rb") as f:
    print(" ".join(sorted(key for key in plistlib.load(f) if key.startswith("SU"))))' "$bundle/Contents/Info.plist")"
if [[ -n "$updater_keys" ]]; then
    fail "Info.plist has updater keys: $updater_keys"
fi

if [[ "$failures" -ne 0 ]]; then
    exit 1
fi
echo "ok: no Sparkle framework, load command, or SU keys in $bundle"

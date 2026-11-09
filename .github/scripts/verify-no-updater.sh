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

# The bundle must name a main executable that exists; otherwise there's nothing to check.
main_executable="$(plutil -extract CFBundleExecutable raw -o - "$bundle/Contents/Info.plist" 2>/dev/null || true)"
if [[ -z "$main_executable" ]]; then
    fail "Info.plist names no CFBundleExecutable"
elif [[ ! -f "$bundle/Contents/MacOS/$main_executable" ]]; then
    fail "the main executable Contents/MacOS/$main_executable is missing"
fi

# Every Mach-O file in the bundle, found by its magic number, not just the executables
# Info.plist names: Debug builds keep the app's code in Contents/MacOS/<name>.debug.dylib.
# Symbolic links are skipped, so a framework's Versions/Current isn't read twice.
macho_files=()
while IFS= read -r -d '' macho_file; do
    macho_files+=("$macho_file")
done < <(/usr/bin/python3 -I -c 'import os, sys
MAGIC = {b"\xfe\xed\xfa\xce", b"\xce\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xcf\xfa\xed\xfe",
         b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca"}
for root, dirs, files in os.walk(sys.argv[1]):
    for name in files:
        path = os.path.join(root, name)
        if os.path.islink(path):
            continue
        with open(path, "rb") as f:
            if f.read(4) in MAGIC:
                sys.stdout.write(path + "\0")' "$bundle")
if (( ${#macho_files[@]} == 0 )); then
    fail "found no Mach-O files to check in $bundle"
fi

# Capture first: piping otool into grep -q would pass a binary otool can't read.
for macho_file in ${macho_files[@]+"${macho_files[@]}"}; do
    if ! libraries="$(otool -L "$macho_file" 2>&1)"; then
        fail "could not read the load commands of ${macho_file#"$bundle"/}"
    elif grep -q 'Sparkle.framework' <<<"$libraries"; then
        fail "${macho_file#"$bundle"/} links Sparkle"
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

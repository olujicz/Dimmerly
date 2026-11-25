#!/usr/bin/env bash
# Xcode build phase for the Dimmerly target, run last. It only reads the build.
#
# App Store configurations (*-AppStore): App Review doesn't allow a second update
# mechanism (guideline 2.4.5(vii)), so the build fails if these configurations would link
# or embed Sparkle, or if the built Info.plist has SU* keys. Checking here covers every
# way of building, including Xcode's Product > Archive; .github/scripts/verify-no-updater.sh
# re-checks the finished bundle in CI and the just recipes.
#
# Direct-download configurations get their Sparkle keys from merge-info-plist.sh, which
# runs first. This phase must not write the built Info.plist or declare it as an output:
# see merge-info-plist.sh for the build race that caused.
set -euo pipefail

: "${CONFIGURATION:?run from an Xcode build phase}"
: "${TARGET_BUILD_DIR:?}" "${INFOPLIST_PATH:?}" "${DERIVED_FILE_DIR:?}"

# Xcode needs an output to schedule the phase.
mkdir -p "$DERIVED_FILE_DIR"
touch "$DERIVED_FILE_DIR/sparkle-build-phase.stamp"

[[ "$CONFIGURATION" == *-AppStore ]] || exit 0

problems=()
[[ " ${OTHER_LDFLAGS:-} " != *Sparkle* ]] || problems+=("OTHER_LDFLAGS links Sparkle")
[[ " ${EXCLUDED_SOURCE_FILE_NAMES:-} " == *" Sparkle.framework "* ]] ||
    problems+=("EXCLUDED_SOURCE_FILE_NAMES doesn't exclude Sparkle.framework, so it would be embedded")
[[ " ${EXCLUDED_SOURCE_FILE_NAMES:-} " == *" DimmerlyHiDPIHelper "* ]] ||
    problems+=("EXCLUDED_SOURCE_FILE_NAMES doesn't exclude DimmerlyHiDPIHelper, so the HiDPI helper would be embedded")
updater_keys="$(/usr/bin/python3 -I -c 'import plistlib, sys
with open(sys.argv[1], "rb") as f:
    print(" ".join(sorted(key for key in plistlib.load(f) if key.startswith("SU"))))' "$TARGET_BUILD_DIR/$INFOPLIST_PATH")"
[[ -z "$updater_keys" ]] || problems+=("Info.plist has updater keys: $updater_keys")
for problem in ${problems[@]+"${problems[@]}"}; do
    echo "error: App Store build: $problem" >&2
done
(( ${#problems[@]} == 0 ))

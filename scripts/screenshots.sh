#!/bin/bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_dir="$(cd -- "$script_dir/.." && pwd)"
helper_app="$repo_dir/.build/DimmerlyScreenshotHelper.app"
helper_id="rs.in.olujic.dimmerly.screenshot-helper"

usage() {
    cat <<'HELP'
Usage:
  scripts/screenshots.sh build-helper
  scripts/screenshots.sh capture --pid PID --mode menu|settings-region|settings --output PATH
  scripts/screenshots.sh compose [composition options]

build-helper compiles and signs the helper without launching it. Set SIGNING_IDENTITY
if multiple Apple Development identities exist (use the certificate fingerprint).
capture launches the helper only; Dimmerly must already be running with the target
window visible. Screen Recording approval may be required. settings-region avoids
the sharing badge, but captures any visible occlusions. Inspect every result.
compose runs the image compositor; use compose --help for its options.
HELP
}

build_helper() {
    local identity="${SIGNING_IDENTITY:-}"
    if [[ -z "$identity" ]]; then
        local identities=()
        local fingerprint
        while IFS= read -r fingerprint; do
            [[ -n "$fingerprint" ]] && identities+=("$fingerprint")
        done < <(security find-identity -v -p codesigning | awk '/"Apple Development:/ {print $2}')
        if [[ ${#identities[@]} -ne 1 ]]; then
            echo 'Expected one Apple Development identity. Set SIGNING_IDENTITY to the desired certificate fingerprint.' >&2
            return 1
        fi
        identity="${identities[0]}"
    fi
    mkdir -p "$helper_app/Contents/MacOS"
    cat > "$helper_app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>DimmerlyScreenshotHelper</string>
<key>CFBundleIdentifier</key><string>$helper_id</string>
<key>CFBundleName</key><string>DimmerlyScreenshotHelper</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
    xcrun swiftc -parse-as-library "$script_dir/screenshots/CaptureWindows.swift" \
        -o "$helper_app/Contents/MacOS/DimmerlyScreenshotHelper" \
        -framework AppKit -framework CoreGraphics -framework ScreenCaptureKit
    codesign --force --sign "$identity" --identifier "$helper_id" "$helper_app"
    codesign --verify --strict "$helper_app"
    echo "Built $helper_app (not launched)."
}

capture() {
    local pid='' mode='' output=''
    while [[ $# -gt 0 ]]; do
        [[ $# -ge 2 ]] || { usage >&2; return 64; }
        case "$1" in
            --pid) [[ -z "$pid" ]] || return 64; pid="$2" ;;
            --mode) [[ -z "$mode" ]] || return 64; mode="$2" ;;
            --output) [[ -z "$output" ]] || return 64; output="$2" ;;
            *) usage >&2; return 64 ;;
        esac
        shift 2
    done
    [[ "$pid" =~ ^[1-9][0-9]*$ && -n "$output" ]] || { usage >&2; return 64; }
    case "$mode" in menu|settings-region|settings) ;; *) usage >&2; return 64 ;; esac
    [[ -x "$helper_app/Contents/MacOS/DimmerlyScreenshotHelper" ]] || {
        echo 'Build the helper first: scripts/screenshots.sh build-helper' >&2
        return 1
    }
    codesign --verify --strict "$helper_app"
    mkdir -p -- "$(dirname -- "$output")"
    output="$(cd -- "$(dirname -- "$output")" && pwd)/$(basename -- "$output")"
    capture_status_file="$(mktemp "${TMPDIR:-/tmp}/dimmerly-capture.XXXXXX")"
    trap 'rm -f -- "$capture_status_file"' EXIT
    open -W -n "$helper_app" --args --pid "$pid" --mode "$mode" --output "$output" --status "$capture_status_file"
    if [[ "$(cat "$capture_status_file")" != 'ok' ]]; then
        echo 'Capture failed. Approve Screen Recording for DimmerlyScreenshotHelper if requested, then retry.' >&2
        cat "$capture_status_file" >&2
        return 1
    fi
    echo "Captured $output"
}

command="${1:-help}"
[[ $# -eq 0 ]] || shift
case "$command" in
    build-helper) [[ $# -eq 0 ]] || { usage >&2; exit 64; }; build_helper ;;
    capture) capture "$@" ;;
    compose)
        mkdir -p "$repo_dir/.build"
        xcrun swiftc "$script_dir/screenshots/ComposeScreenshots.swift" \
            -o "$repo_dir/.build/ComposeScreenshots" -framework AppKit -framework CoreGraphics
        exec "$repo_dir/.build/ComposeScreenshots" "$@"
        ;;
    help|--help|-h) usage ;;
    *) usage >&2; exit 64 ;;
esac

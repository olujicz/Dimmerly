#!/bin/bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_dir="$(cd -- "$script_dir/.." && pwd)"
helper_app="$repo_dir/.build/DimmerlyScreenshotHelper.app"
helper_id="rs.in.olujic.dimmerly.screenshot-helper"

usage() {
    cat <<'HELP'
Usage:
  scripts/screenshots.sh refresh [--variant app-store|github] [--output PATH] [--skip-build]
  scripts/screenshots.sh build-helper
  scripts/screenshots.sh capture --pid PID --mode menu|settings-region|settings --output PATH
  scripts/screenshots.sh compose [composition options]

refresh does everything: builds the debug app for the variant, launches it in its
staged screenshot mode (isolated settings, no display or data changes), captures the
menu panel and Displays settings, quits it, and composes the final image.
  app-store (default): Dimmerly App Store / Debug-AppStore
                       -> images/app-store/01-menu-and-displays.png
  github:              Dimmerly / Debug -> images/image1.png and images/image2.png
Raw captures are kept in .build/screenshots/<variant>/. Inspect the result before
committing it.

build-helper compiles and signs the capture helper without launching it, using the
first valid Apple Development identity; set SIGNING_IDENTITY to a certificate
fingerprint to choose another. Screen Recording approval for
DimmerlyScreenshotHelper is requested on the first capture.
capture launches the helper only; Dimmerly must already be running with the target
window visible. settings-region avoids the sharing badge, but captures any visible
occlusions. Inspect every result.
compose runs the image compositor; use compose --help for its options.
HELP
}

# Prints the fingerprint of a valid Apple Development identity. Expired certificates are
# not listed as valid, and identities with the same name satisfy the same code requirement,
# so Screen Recording approval carries over whichever one signs the helper.
first_development_identity() {
    security find-identity -v -p codesigning | awk '/"Apple Development:/ {print $2; exit}'
}

build_helper() {
    local identity="${SIGNING_IDENTITY:-}"
    if [[ -z "$identity" ]]; then
        identity="$(first_development_identity)"
        if [[ -z "$identity" ]]; then
            echo 'No valid Apple Development identity found. Set SIGNING_IDENTITY to a certificate fingerprint.' >&2
            return 1
        fi
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
    local status_file status
    status_file="$(mktemp "${TMPDIR:-/tmp}/dimmerly-capture.XXXXXX")"
    open -W -n "$helper_app" --args --pid "$pid" --mode "$mode" --output "$output" --status "$status_file"
    status="$(cat -- "$status_file")"
    rm -f -- "$status_file"
    if [[ "$status" != 'ok' ]]; then
        [[ -n "${QUIET_CAPTURE_FAILURE:-}" ]] || {
            echo 'Capture failed. Approve Screen Recording for DimmerlyScreenshotHelper if requested, then retry.' >&2
            echo "$status" >&2
        }
        last_capture_error="$status"
        return 1
    fi
    echo "Captured $output"
}

# Stops early, before anything is launched, when the helper can't record the screen.
check_screen_recording() {
    local status_file status
    status_file="$(mktemp "${TMPDIR:-/tmp}/dimmerly-capture.XXXXXX")"
    open -W -n "$helper_app" --args --preflight "$status_file"
    status="$(cat -- "$status_file")"
    rm -f -- "$status_file"
    [[ "$status" == 'ok' ]] && return 0
    if [[ "$status" == 'unavailable' ]]; then
        echo 'The screen is locked or the displays are asleep, so macOS cannot take screenshots.' >&2
        echo 'Unlock the Mac, keep a display awake, and run this command again.' >&2
        return 1
    fi
    cat >&2 <<'MESSAGE'
DimmerlyScreenshotHelper does not have Screen Recording permission.
Open System Settings > Privacy & Security > Screen & System Audio Recording, switch on
DimmerlyScreenshotHelper (add .build/DimmerlyScreenshotHelper.app with + if it is missing),
then run this command again. The approval is kept when the helper is rebuilt.
MESSAGE
    open 'x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture'
    return 1
}

# Launches the staged debug app for one scene and records its PID in staged_pid.
launch_staged() {
    local app="$1" scene="$2"
    DIMMERLY_SCREENSHOT="$scene" "$app/Contents/MacOS/Dimmerly" >/dev/null 2>&1 &
    staged_pid=$!
}

stop_staged() {
    if [[ -n "${staged_pid:-}" ]] && kill -0 "$staged_pid" 2>/dev/null; then
        kill "$staged_pid" 2>/dev/null || true
        wait "$staged_pid" 2>/dev/null || true
    fi
    staged_pid=''
}

# Retries until the staged window is on screen, for up to about 20 seconds.
capture_when_ready() {
    local mode="$1" output="$2"
    last_capture_error=''
    for _ in $(seq 1 20); do
        kill -0 "$staged_pid" 2>/dev/null || { echo 'The staged Dimmerly app exited early.' >&2; return 1; }
        QUIET_CAPTURE_FAILURE=1 capture --pid "$staged_pid" --mode "$mode" --output "$output" && return 0
        sleep 1
    done
    echo "Capture of $mode failed: $last_capture_error" >&2
    echo 'If macOS asked for Screen Recording, approve DimmerlyScreenshotHelper and run refresh again.' >&2
    return 1
}

refresh() {
    local variant='app-store' output='' skip_build=''
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --variant) [[ $# -ge 2 ]] || { usage >&2; return 64; }; variant="$2"; shift 2 ;;
            --output) [[ $# -ge 2 ]] || { usage >&2; return 64; }; output="$2"; shift 2 ;;
            --skip-build) skip_build=1; shift ;;
            *) usage >&2; return 64 ;;
        esac
    done

    local scheme configuration
    case "$variant" in
        app-store)
            scheme='Dimmerly App Store'; configuration='Debug-AppStore'
            output="${output:-$repo_dir/images/app-store/01-menu-and-displays.png}" ;;
        github)
            scheme='Dimmerly'; configuration='Debug'
            output="${output:-$repo_dir/images}" ;;
        *) usage >&2; return 64 ;;
    esac

    local derived="$repo_dir/.build/screenshots/DerivedData"
    local inputs="$repo_dir/.build/screenshots/$variant"
    local app="$derived/Build/Products/$configuration/Dimmerly.app"

    if [[ -z "$skip_build" ]]; then
        echo "Building $scheme ($configuration)..."
        xcodebuild -quiet -project "$repo_dir/Dimmerly.xcodeproj" -scheme "$scheme" \
            -configuration "$configuration" -destination "platform=macOS,arch=$(uname -m)" \
            -derivedDataPath "$derived" build
    fi
    [[ -x "$app/Contents/MacOS/Dimmerly" ]] || { echo "Missing $app; run without --skip-build." >&2; return 1; }

    local helper_binary="$helper_app/Contents/MacOS/DimmerlyScreenshotHelper"
    if [[ ! -x "$helper_binary" || "$script_dir/screenshots/CaptureWindows.swift" -nt "$helper_binary" ]]; then
        build_helper
    fi

    check_screen_recording || return 1

    mkdir -p "$inputs"
    rm -f -- "$inputs"/menu.png "$inputs"/settings.png "$inputs"/settings-mask.png
    trap stop_staged EXIT INT TERM

    echo 'Capturing the menu panel...'
    launch_staged "$app" menu
    capture_when_ready menu "$inputs/menu.png"
    stop_staged

    echo 'Capturing Displays settings...'
    launch_staged "$app" settings
    capture_when_ready settings-region "$inputs/settings.png"
    # The mask capture must match the region capture, so take it right away.
    capture --pid "$staged_pid" --mode settings --output "$inputs/settings-mask.png"
    stop_staged
    trap - EXIT INT TERM

    echo 'Composing...'
    run_compose --variant "$variant" --menu "$inputs/menu.png" --settings "$inputs/settings.png" \
        --settings-mask "$inputs/settings-mask.png" --output "$output"

    if [[ "$variant" == 'app-store' ]]; then
        local info
        info="$(sips -g pixelWidth -g pixelHeight -g hasAlpha "$output")"
        if ! grep -q 'pixelWidth: 2880' <<<"$info" || ! grep -q 'pixelHeight: 1800' <<<"$info" ||
            ! grep -q 'hasAlpha: no' <<<"$info"; then
            echo "Unexpected App Store image format:" >&2
            echo "$info" >&2
            return 1
        fi
    fi
    echo "Done. Raw captures: $inputs"
    echo 'Inspect the result, then review it with git diff --stat before committing.'
}

run_compose() {
    mkdir -p "$repo_dir/.build"
    xcrun swiftc "$script_dir/screenshots/ComposeScreenshots.swift" \
        -o "$repo_dir/.build/ComposeScreenshots" -framework AppKit -framework CoreGraphics
    "$repo_dir/.build/ComposeScreenshots" "$@"
}

command="${1:-help}"
[[ $# -eq 0 ]] || shift
case "$command" in
    build-helper) [[ $# -eq 0 ]] || { usage >&2; exit 64; }; build_helper ;;
    capture) capture "$@" ;;
    refresh) refresh "$@" ;;
    compose) run_compose "$@" ;;
    help|--help|-h) usage ;;
    *) usage >&2; exit 64 ;;
esac

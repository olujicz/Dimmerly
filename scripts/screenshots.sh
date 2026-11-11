#!/bin/bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_dir="$(cd -- "$script_dir/.." && pwd)"
helper_app="$repo_dir/.build/DimmerlyScreenshotHelper.app"
helper_id="rs.in.olujic.dimmerly.screenshot-helper"
helper_sources=("$script_dir/screenshots/CaptureWindows.swift" "$script_dir/screenshots/RecordPanel.swift"
    "$script_dir/screenshots/CaptureLayout.swift" "$script_dir/screenshots/RunningApplications.swift")

usage() {
    cat <<'HELP'
Usage:
  scripts/screenshots.sh launch [--appearance light|dark|both] [--output DIR] [--skip-build]
  scripts/screenshots.sh refresh [--variant app-store|github] [--appearance light|dark]
                                 [--output PATH] [--skip-build]
  scripts/screenshots.sh build-helper
  scripts/screenshots.sh capture --pid PID --mode menu|settings-region|settings --output PATH
                                 [--backdrop required]
  scripts/screenshots.sh compose [composition options]

refresh does everything: builds the debug app for the variant, launches it in its
staged screenshot mode (isolated settings, no display or data changes), captures the
menu panel and Displays settings, quits it, and composes the final image.
  app-store (default): Dimmerly App Store / Debug-AppStore
                       -> .build/screenshots/app-store/menu-and-displays.png
  github:              Dimmerly / Debug -> images/image1.png and images/image2.png
--appearance forces the app into light or dark; without it the app follows the system.
The panel is captured over a plain window whose colour its frosted glass picks up: the
App Store background's colour, or a dark slate for the GitHub images.
Raw captures are kept in .build/screenshots/<variant>/. Inspect the result before
committing it.

build-helper compiles and signs the capture helper without launching it, using the
valid Apple Development identity; set SIGNING_IDENTITY to a certificate fingerprint
when several people's or teams' identities are installed. Screen Recording approval for
DimmerlyScreenshotHelper is requested on the first capture.
launch captures expanded controls, an applied Evening preset and Schedule settings
with the real macOS menu bar, in both appearances by default. No composition. Files
go to docs/launch/assets/menubar-{1,2,3}-{light,dark}.png, plus menubar-{1,2,3}.png
(light controls, dark Evening, light Schedule). --output selects another directory.
The staged app uses isolated debug data and does not adjust physical displays.
Quitting the original app can temporarily clear its dimming/warmth until it reopens.
Keep the Mac idle
while it captures; inspect the real menu bar for private icons before sharing.
Existing Dimmerly instances are gracefully closed first and reopened from their
original app paths afterward, including when capture fails or is interrupted.

capture launches the helper only; Dimmerly must already be running with the target
window visible. settings-region avoids the sharing badge, but captures any visible
occlusions. --backdrop required makes a menu capture fail until the staged app's backdrop
window is showing. Inspect every result.
compose runs the image compositor; use compose --help for its options.
HELP
}

# Prints the fingerprint of a valid Apple Development identity. Expired certificates are
# not listed as valid, and identities with the same name satisfy the same code requirement,
# so Screen Recording approval carries over whichever of them signs the helper. Identities
# with different names would not, so the choice is left to SIGNING_IDENTITY then.
development_identity() {
    local identities names
    identities="$(security find-identity -v -p codesigning | grep '"Apple Development:' || true)"
    [[ -n "$identities" ]] || return 0
    names="$(sed -E 's/^[^"]*"([^"]*)".*$/\1/' <<<"$identities" | sort -u)"
    if [[ "$(wc -l <<<"$names" | tr -d ' ')" -gt 1 ]]; then
        echo 'Several Apple Development identities with different names are installed:' >&2
        sed 's/^/  /' <<<"$names" >&2
        echo 'Set SIGNING_IDENTITY to the fingerprint of the one that should sign the helper.' >&2
        return 1
    fi
    awk 'NR == 1 {print $2}' <<<"$identities"
}

build_helper() {
    local identity="${SIGNING_IDENTITY:-}"
    if [[ -z "$identity" ]]; then
        identity="$(development_identity)" || return 1
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
    xcrun swiftc -O -parse-as-library "${helper_sources[@]}" \
        -o "$helper_app/Contents/MacOS/DimmerlyScreenshotHelper" \
        -framework AppKit -framework CoreGraphics -framework ScreenCaptureKit
    codesign --force --sign "$identity" --identifier "$helper_id" "$helper_app"
    codesign --verify --strict "$helper_app"
    echo "Built $helper_app (not launched)."
}

# Rebuilds the helper when it is missing or older than any of its sources.
ensure_helper() {
    local helper_binary="$helper_app/Contents/MacOS/DimmerlyScreenshotHelper" source
    if [[ -x "$helper_binary" ]]; then
        for source in "${helper_sources[@]}"; do
            [[ "$source" -nt "$helper_binary" ]] && { build_helper; return; }
        done
        return 0
    fi
    build_helper
}

capture() {
    local pid='' mode='' output='' backdrop=''
    while [[ $# -gt 0 ]]; do
        [[ $# -ge 2 ]] || { usage >&2; return 64; }
        case "$1" in
            --pid) [[ -z "$pid" ]] || return 64; pid="$2" ;;
            --mode) [[ -z "$mode" ]] || return 64; mode="$2" ;;
            --output) [[ -z "$output" ]] || return 64; output="$2" ;;
            --backdrop) [[ -z "$backdrop" && "$2" == 'required' ]] || { usage >&2; return 64; }; backdrop="$2" ;;
            *) usage >&2; return 64 ;;
        esac
        shift 2
    done
    [[ "$pid" =~ ^[1-9][0-9]*$ && -n "$output" ]] || { usage >&2; return 64; }
    case "$mode" in menu|settings-region|settings|menu-desktop|settings-desktop) ;; *) usage >&2; return 64 ;; esac
    [[ -z "$backdrop" || "$mode" == 'menu' ]] || { usage >&2; return 64; }
    # Setup failures return 2 so capture_when_ready stops instead of retrying them. Each step
    # is checked explicitly because set -e does not apply when capture runs in a condition.
    [[ -x "$helper_app/Contents/MacOS/DimmerlyScreenshotHelper" ]] || {
        echo 'Build the helper first: scripts/screenshots.sh build-helper' >&2
        return 2
    }
    codesign --verify --strict "$helper_app" || {
        echo "The helper's signature is invalid; rebuild it with scripts/screenshots.sh build-helper." >&2
        return 2
    }
    mkdir -p -- "$(dirname -- "$output")" || return 2
    output="$(cd -- "$(dirname -- "$output")" && pwd)/$(basename -- "$output")" || return 2
    local status
    local helper_args=(--pid "$pid" --mode "$mode" --output "$output")
    [[ -z "$backdrop" ]] || helper_args+=(--backdrop "$backdrop")
    status="$(run_helper "${helper_args[@]}" --status)" || return 2
    [[ -n "$status" ]] || status='The capture helper exited without reporting a result.'
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

# Runs the helper with the given arguments plus a status file path, and prints the status
# it wrote, or nothing if it crashed or never launched. The status file is always removed.
run_helper() {
    local status_file status=''
    status_file="$(mktemp "${TMPDIR:-/tmp}/dimmerly-capture.XXXXXX")" || return 1
    # -g keeps the helper in the background: taking focus would turn the panel's accent
    # colours grey, as macOS draws an unfocused panel.
    if open -g -W -n "$helper_app" --args "$@" "$status_file"; then
        status="$(cat -- "$status_file" 2>/dev/null || true)"
    fi
    rm -f -- "$status_file"
    printf '%s' "$status"
}

# Stops early, before anything is launched, when the helper can't record the screen.
check_screen_recording() {
    local status
    status="$(run_helper --preflight)" || return 1
    case "$status" in
        ok) return 0 ;;
        unavailable)
            echo 'The screen is locked or the displays are asleep, so macOS cannot take screenshots.' >&2
            echo 'Unlock the Mac, keep a display awake, and run this command again.' >&2
            return 1 ;;
        denied) ;;
        *)
            echo 'The capture helper failed before it could check Screen Recording permission.' >&2
            echo "${status:-It exited without reporting a result.}" >&2
            echo 'Rebuild it with scripts/screenshots.sh build-helper and run this command again.' >&2
            return 1 ;;
    esac
    cat >&2 <<'MESSAGE'
DimmerlyScreenshotHelper does not have Screen Recording permission.
Open System Settings > Privacy & Security > Screen & System Audio Recording, switch on
DimmerlyScreenshotHelper (add .build/DimmerlyScreenshotHelper.app with + if it is missing),
then run this command again. The approval is kept when the helper is rebuilt.
MESSAGE
    open 'x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture'
    return 1
}

# Staged runs format times and numbers as US English, whatever this Mac's region is, so
# captures match the en-US listing (for example 5:20 PM, not 17:20).
staged_locale_args=(-AppleLocale en_US -AppleLanguages '(en)')
# The staged Mac's time zone (ScreenshotStage.defaultTimeZone; a demo storyboard can name
# another). The app can't change its own, so it refuses to stage in any other.
staged_time_zone='America/Los_Angeles'

# Launches the staged debug app for one scene and records its PID in staged_pid. An optional
# appearance (light or dark, empty to follow the system) and #RRGGBB backdrop colour follow.
launch_staged() {
    local app="$1" scene="$2" appearance="${3:-}" backdrop="${4:-}"
    # Debug builds write coverage data to the working directory unless told otherwise.
    TZ="$staged_time_zone" DIMMERLY_SCREENSHOT="$scene" DIMMERLY_SCREENSHOT_APPEARANCE="$appearance" \
        DIMMERLY_SCREENSHOT_BACKDROP="$backdrop" LLVM_PROFILE_FILE="$repo_dir/.build/default.profraw" \
        "$app/Contents/MacOS/Dimmerly" "${staged_locale_args[@]}" >/dev/null 2>&1 &
    staged_pid=$!
}

stop_staged() {
    if [[ -n "${staged_pid:-}" ]] && kill -0 "$staged_pid" 2>/dev/null; then
        kill "$staged_pid" 2>/dev/null || true
        wait "$staged_pid" 2>/dev/null || true
    fi
    staged_pid=''
}

# Retries until the staged window is on screen, for up to about 20 seconds. Extra arguments
# go to capture.
capture_when_ready() {
    local mode="$1" output="$2"
    shift 2
    last_capture_error=''
    for _ in $(seq 1 20); do
        kill -0 "$staged_pid" 2>/dev/null || { echo 'The staged Dimmerly app exited early.' >&2; return 1; }
        local result=0
        QUIET_CAPTURE_FAILURE=1 capture --pid "$staged_pid" --mode "$mode" --output "$output" "$@" || result=$?
        [[ $result -eq 0 ]] && return 0
        # Setup failures (a missing or broken helper) won't fix themselves.
        [[ $result -eq 1 ]] || return "$result"
        sleep 1
    done
    echo "Capture of $mode failed: $last_capture_error" >&2
    echo 'If macOS asked for Screen Recording, approve DimmerlyScreenshotHelper and run refresh again.' >&2
    return 1
}

# Prints an image's pixel width and height, for example "1040x2226".
pixel_size() {
    sips -g pixelWidth -g pixelHeight "$1" | awk '/pixelWidth/ {w = $2} /pixelHeight/ {h = $2} END {print w "x" h}'
}

refresh() {
    local variant='app-store' output='' skip_build='' appearance=''
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --variant) [[ $# -ge 2 ]] || { usage >&2; return 64; }; variant="$2"; shift 2 ;;
            --appearance)
                [[ $# -ge 2 && ( "$2" == 'light' || "$2" == 'dark' ) ]] || { usage >&2; return 64; }
                appearance="$2"; shift 2 ;;
            --output) [[ $# -ge 2 ]] || { usage >&2; return 64; }; output="$2"; shift 2 ;;
            --skip-build) skip_build=1; shift ;;
            *) usage >&2; return 64 ;;
        esac
    done

    # The colour behind the panel while it is captured, which its frosted glass picks up.
    # app-store: the average of background.png behind the panel, as on a real desktop.
    # github: the panel stands alone on the page, so a dark slate (the dark demo's backdrop)
    # keeps the text clear on both GitHub themes.
    local scheme configuration backdrop
    case "$variant" in
        app-store)
            scheme='Dimmerly App Store'; configuration='Debug-AppStore'; backdrop='#708FA7'
            output="${output:-$repo_dir/.build/screenshots/app-store/menu-and-displays.png}" ;;
        github)
            scheme='Dimmerly'; configuration='Debug'; backdrop='#1E252E'
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

    ensure_helper

    check_screen_recording || return 1

    mkdir -p "$inputs"
    rm -f -- "$inputs"/menu.png "$inputs"/settings.png "$inputs"/settings-mask.png
    # A signal handler must exit itself, or bash resumes the next command after it.
    trap stop_staged EXIT
    trap 'stop_staged; exit 130' INT
    trap 'stop_staged; exit 143' TERM

    echo 'Capturing the menu panel...'
    launch_staged "$app" menu "$appearance" "$backdrop"
    capture_when_ready menu "$inputs/menu.png" --backdrop required
    stop_staged

    echo 'Capturing Displays settings...'
    launch_staged "$app" settings "$appearance"
    capture_when_ready settings-region "$inputs/settings.png"
    # The mask capture must match the region capture, so take it right away.
    capture --pid "$staged_pid" --mode settings --output "$inputs/settings-mask.png"
    stop_staged
    trap - EXIT INT TERM

    # A pane taller than the screen (the direct-download Displays tab with Hardware Control,
    # on a 1080-point display) leaves the region capture cut off at the screen's edge. The
    # window capture holds the whole pane, so it stands in for both.
    if [[ "$(pixel_size "$inputs/settings.png")" != "$(pixel_size "$inputs/settings-mask.png")" ]]; then
        echo 'Displays settings is taller than the screen, so the full window capture is used.'
        echo 'Check its title bar for a screen-sharing badge.'
        cp -- "$inputs/settings-mask.png" "$inputs/settings.png"
    fi

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

launch_screenshots() {
    local output="$repo_dir/docs/launch/assets" appearance='both' skip_build=''
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --output) [[ $# -ge 2 && -n "$2" ]] || return 64; output="$2"; shift 2 ;;
            --appearance)
                [[ $# -ge 2 ]] || return 64
                case "$2" in light|dark|both) appearance="$2" ;; *) usage >&2; return 64 ;; esac
                shift 2 ;;
            --skip-build) skip_build=1; shift ;;
            *) usage >&2; return 64 ;;
        esac
    done
    local derived="$repo_dir/.build/screenshots/DerivedData"
    local inputs="$repo_dir/.build/screenshots/launch"
    local app="$derived/Build/Products/Debug/Dimmerly.app"
    launch_staged_app="$app"
    launch_capture_lock="$repo_dir/.build/screenshots/launch.lock"
    launch_resume_manifest="$inputs/running-apps.json"
    mkdir -p "$(dirname "$launch_capture_lock")"
    acquire_launch_lock || return 1
    trap 'cleanup_launch_capture $?' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    ensure_helper
    check_screen_recording || return 1
    if [[ -z "$skip_build" ]]; then
        bash "$repo_dir/packaging/sparkle/fetch-sparkle.sh"
        xcodebuild -quiet -project "$repo_dir/Dimmerly.xcodeproj" -scheme Dimmerly \
            -configuration Debug -destination "platform=macOS,arch=$(uname -m)" \
            -derivedDataPath "$derived" build
    fi
    [[ -x "$app/Contents/MacOS/Dimmerly" ]] || { echo 'Build missing; run without --skip-build.' >&2; return 1; }
    mkdir -p "$inputs" "$output"
    local status interrupted=''
    # LaunchServices starts a detached helper. Don't let cleanup race that helper's quit
    # requests or manifest write; finish the bounded close operation before honoring signals.
    trap 'interrupted=130' INT
    trap 'interrupted=143' TERM
    # Recover a saved app path after a previous terminal crash before taking a new snapshot.
    if [[ -f "$launch_resume_manifest" ]]; then
        (trap '' INT TERM; restore_launch_apps) || return 1
        [[ -z "$interrupted" ]] || return "$interrupted"
    fi
    echo 'Closing existing Dimmerly instances for capture (they will reopen afterward)...'
    status="$(trap '' INT TERM; run_helper --pause-apps "$launch_resume_manifest" --staged-app "$launch_staged_app" --status)" || status='Helper failed to launch.'
    trap 'exit 130' INT
    trap 'exit 143' TERM
    [[ -z "$interrupted" ]] || return "$interrupted"
    [[ "$status" == ok ]] || { echo "Cannot close Dimmerly for capture: $status" >&2; return 1; }
    local each number scene mode backdrop
    local appearances=(light dark)
    [[ "$appearance" == both ]] || appearances=("$appearance")
    for each in "${appearances[@]}"; do
        for number in 1 2 3; do
            mode='menu-desktop'
            backdrop='#CCD9E4'
            [[ "$each" == light ]] || backdrop='#25313F'
            case "$number" in
                1) scene='launch-menu' ;;
                2) scene='launch-evening'; [[ "$each" == light ]] && backdrop='#DED2C2' || backdrop='#3B302A' ;;
                3) scene='launch-schedule'; mode='settings-desktop' ;;
            esac
            echo "Capturing $scene ($each)..."
            launch_staged "$app" "$scene" "$each" "$backdrop"
            capture_when_ready "$mode" "$inputs/menubar-$number-$each.png"
            stop_staged
        done
    done
    # Publish only after the whole requested set succeeded, preserving earlier captures on failure.
    for each in "${appearances[@]}"; do
        for number in 1 2 3; do
            cp -- "$inputs/menubar-$number-$each.png" "$output/menubar-$number-$each.png"
        done
    done
    if [[ "$appearance" == both ]]; then
        cp -- "$output/menubar-1-light.png" "$output/menubar-1.png"
        cp -- "$output/menubar-2-dark.png" "$output/menubar-2.png"
        cp -- "$output/menubar-3-light.png" "$output/menubar-3.png"
    fi
    echo "Launch screenshots saved to $output"
}

acquire_launch_lock() {
    local owner current_owner
    if ! mkdir "$launch_capture_lock" 2>/dev/null; then
        owner="$(cat "$launch_capture_lock/pid" 2>/dev/null || true)"
        if [[ "$owner" =~ ^[1-9][0-9]*$ ]] && ! kill -0 "$owner" 2>/dev/null &&
            mkdir "$launch_capture_lock/recovery" 2>/dev/null; then
            # Recheck after taking the recovery marker: a different contender may have
            # replaced the lock between our first read and acquiring the marker.
            current_owner="$(cat "$launch_capture_lock/pid" 2>/dev/null || true)"
            if [[ "$current_owner" == "$owner" ]] && ! kill -0 "$owner" 2>/dev/null; then
                rm -- "$launch_capture_lock/pid"
                rmdir "$launch_capture_lock/recovery" "$launch_capture_lock"
                mkdir "$launch_capture_lock" 2>/dev/null || return 1
                echo "Recovered capture lock from exited process $owner."
            else
                rmdir "$launch_capture_lock/recovery"
                return 1
            fi
        else
            echo "Launch capture lock is held by process ${owner:-unknown}: $launch_capture_lock" >&2
            echo 'Wait for that capture; an unknown owner needs manual inspection before removing the lock.' >&2
            return 1
        fi
    fi
    printf '%s\n' "$$" > "$launch_capture_lock/pid"
}

restore_launch_apps() {
    local status
    status="$(run_helper --resume-apps "$launch_resume_manifest" --staged-app "$launch_staged_app" --status)" || status='Helper failed to launch.'
    case "$status" in
        ok) return 0 ;;
        $'ok\n'*) printf '%s\n' "${status#*$'\n'}" >&2; return 0 ;;
        *)
            echo "Could not restore Dimmerly: $status" >&2
            echo "Saved app locations are kept in $launch_resume_manifest. Finish closing the original app, then rerun launch." >&2
            return 1 ;;
    esac
}

cleanup_launch_capture() {
    local result="$1"
    trap '' INT TERM
    stop_staged
    if [[ -f "$launch_resume_manifest" ]]; then
        echo 'Restoring the Dimmerly app that was running before capture...'
        restore_launch_apps || result=1
    fi
    rm -- "$launch_capture_lock/pid"
    rmdir "$launch_capture_lock"
    exit "$result"
}

run_compose() {
    mkdir -p "$repo_dir/.build"
    xcrun swiftc "$script_dir/screenshots/ComposeScreenshots.swift" \
        -o "$repo_dir/.build/ComposeScreenshots" -framework AppKit -framework CoreGraphics
    "$repo_dir/.build/ComposeScreenshots" "$@"
}

# scripts/demo.sh sources this file for the helper functions; only run a command when executed.
[[ "${BASH_SOURCE[0]}" == "$0" ]] || return 0

command="${1:-help}"
[[ $# -eq 0 ]] || shift
case "$command" in
    build-helper) [[ $# -eq 0 ]] || { usage >&2; exit 64; }; build_helper ;;
    capture) capture "$@" ;;
    refresh) refresh "$@" ;;
    launch) launch_screenshots "$@" ;;
    compose) run_compose "$@" ;;
    help|--help|-h) usage ;;
    *) usage >&2; exit 64 ;;
esac

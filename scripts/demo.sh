#!/bin/bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# Shares the signed capture helper and its checks with the screenshot script.
# shellcheck source-path=SCRIPTDIR source=screenshots.sh
source "$script_dir/screenshots.sh"

# DEMO_VARIANT=app-store records the App Store build's panel, which differs from the
# direct-download one (for example "Dim Displays" instead of "Turn Displays Off"). Use it for
# App Store screenshots; the website and README use the default direct-download variant.
# The demo reads its storyboard from the repo and writes the frame log there, which the sandbox
# forbids, so this build keeps the APPSTORE code but signs with the non-sandbox entitlements.
# Nothing in the app checks for the sandbox at runtime, so the panel is the same.
demo_build_settings=()
case "${DEMO_VARIANT:-direct}" in
    direct) demo_dir="$repo_dir/.build/demo" demo_scheme=Dimmerly demo_configuration=Debug ;;
    app-store)
        demo_dir="$repo_dir/.build/demo-app-store" demo_scheme='Dimmerly App Store'
        demo_configuration=Debug-AppStore
        demo_build_settings=(CODE_SIGN_ENTITLEMENTS=Dimmerly/Resources/Dimmerly.entitlements)
        ;;
    *) echo "Unknown DEMO_VARIANT: $DEMO_VARIANT (use direct or app-store)" >&2; exit 64 ;;
esac
derived="$demo_dir/DerivedData"
storyboard="$script_dir/demo/storyboard.json"
# The App Store stills play their own storyboard into .build/demo-app-store/stills-<appearance>.
stills_storyboard="$script_dir/demo/app-store-stills.json"
stills_output="$repo_dir/images/app-store"
# The App Store app preview: its own storyboard, rendered outside the repo (it is ~25 MB).
preview_storyboard="$script_dir/demo/app-store-preview.json"
run_prefix=''
exports="$repo_dir/images/demo"
# The website follows the system colour scheme, so every capture and export is made in both.
appearances=(light dark)
# Seconds into the loop for the poster frame: the Evening preset, with its caption.
poster_time=9.3

demo_usage() {
    cat <<'HELP'
Usage:
  scripts/demo.sh render                      build, then capture, compose and export both
  scripts/demo.sh build                       build the Debug app into .build/demo
  scripts/demo.sh capture [light|dark]        play the storyboard and record the panel
  scripts/demo.sh compose [light|dark] [--check]
                                              render .build/demo/<appearance>/master.mov
  scripts/demo.sh export [light|dark]         encode the website, README and social files
  scripts/demo.sh check-release               build Release and confirm it has no demo code
  DEMO_VARIANT=app-store scripts/demo.sh stills-capture
                                              record the App Store stills storyboard and Settings
  DEMO_VARIANT=app-store scripts/demo.sh stills
                                              render images/app-store from those recordings
  DEMO_VARIANT=app-store scripts/demo.sh preview-capture
                                              record the App Store preview storyboard
  DEMO_VARIANT=app-store scripts/demo.sh preview
                                              render the App Store preview video

Without an appearance, capture, compose and export run for light and then dark. The
demo app is forced into that appearance, whatever this Mac uses.

capture launches the Debug app in its staged demo mode (isolated settings, made-up
displays, no gamma or DDC writes). It needs an unlocked Mac and Screen Recording
for DimmerlyScreenshotHelper. The storyboard is scripts/demo/storyboard.json.
Raw frames and masters stay in .build/demo/<appearance>; export writes
images/demo/dimmerly-demo-<appearance>.mp4, .webp and -poster.jpg.

stills-capture plays scripts/demo/app-store-stills.json in light and dark, then captures
each window still's Settings tab. stills renders every image that file lists into
images/app-store and checks each is 2560x1600 and opaque. Run build first.
HELP
}

# Points run_dir, values and master at one appearance's files.
use_appearance() {
    case "$1" in
        light|dark) ;;
        *) echo "Unknown appearance: $1 (use light or dark)" >&2; return 64 ;;
    esac
    appearance="$1"
    run_dir="$demo_dir/$run_prefix$appearance"
    values="$run_dir/values.jsonl"
    master="$run_dir/master.mov"
}

# Runs a command for the appearance given first, or for each one when none is given.
for_appearances() {
    local command="$1" each
    shift
    if [[ "${1:-}" == light || "${1:-}" == dark ]]; then
        use_appearance "$1"
        shift
        "$command" "$@"
        return
    fi
    for each in "${appearances[@]}"; do
        use_appearance "$each"
        "$command" "$@"
    done
}

# The colour behind the panel while recording: what the compositor draws around it, so the
# panel's frosted material looks as it will in the video.
backdrop_color() {
    case "$appearance" in
        light) echo '#F3F1EC' ;;
        dark) echo '#1E252E' ;;
    esac
}

demo_app() {
    echo "$derived/Build/Products/$demo_configuration/Dimmerly.app"
}

demo_build() {
    echo "Building $demo_scheme ($demo_configuration)..."
    xcodebuild -quiet -project "$repo_dir/Dimmerly.xcodeproj" -scheme "$demo_scheme" \
        -configuration "$demo_configuration" -destination "platform=macOS,arch=$(uname -m)" \
        -derivedDataPath "$derived" ${demo_build_settings[@]+"${demo_build_settings[@]}"} build
}

demo_capture() {
    [[ $# -eq 0 ]] || { demo_usage >&2; return 64; }
    local app
    app="$(demo_app)"
    [[ -x "$app/Contents/MacOS/Dimmerly" ]] || { echo "Missing $app; run scripts/demo.sh build." >&2; return 1; }
    ensure_helper
    check_screen_recording || return 1

    mkdir -p "$run_dir"
    rm -f -- "$values"
    local record_status="$run_dir/record-status" app_pid recorder_pid
    rm -f -- "$record_status"

    echo "Playing the storyboard and recording the $appearance panel (about 20 seconds)..."
    local time_zone
    time_zone="$(plutil -extract timeZone raw -o - "$storyboard" 2>/dev/null || echo "$staged_time_zone")"
    TZ="$time_zone" DIMMERLY_SCREENSHOT=demo DIMMERLY_SCREENSHOT_APPEARANCE="$appearance" \
        DIMMERLY_SCREENSHOT_BACKDROP="$(backdrop_color)" \
        DIMMERLY_DEMO_STORYBOARD="$storyboard" DIMMERLY_DEMO_OUTPUT="$values" \
        LLVM_PROFILE_FILE="$run_dir/default.profraw" \
        "$app/Contents/MacOS/Dimmerly" "${staged_locale_args[@]}" >"$run_dir/app.log" 2>&1 &
    app_pid=$!
    staged_pid=$app_pid
    trap stop_staged EXIT
    trap 'stop_staged; exit 130' INT
    trap 'stop_staged; exit 143' TERM

    run_helper --pid "$app_pid" --mode record --values "$values" --output "$run_dir" --status \
        >"$record_status" &
    recorder_pid=$!

    local app_result=0 recorder_result=0
    wait "$app_pid" || app_result=$?
    staged_pid=''
    wait "$recorder_pid" || recorder_result=$?
    trap - EXIT INT TERM

    if [[ $app_result -ne 0 ]]; then
        echo "The demo app exited with status $app_result:" >&2
        tail -5 "$run_dir/app.log" >&2
        return 1
    fi
    local status
    status="$(cat -- "$record_status" 2>/dev/null || true)"
    if [[ $recorder_result -ne 0 || "$status" != 'ok' ]]; then
        echo "Recording failed: ${status:-the helper exited without reporting a result.}" >&2
        return 1
    fi
    echo "Recorded $appearance: $(tr -d '\n ' <"$run_dir/record.json")"
}

# A capture occasionally misses the panel (seen once, on the first launch after a build), so
# a failed capture is retried once before giving up.
capture_with_retry() {
    demo_capture "$@" && return
    echo "Retrying the $appearance capture once..." >&2
    demo_capture "$@"
}

compose_tool() {
    local tool="$demo_dir/tools/ComposeDemo" source="$script_dir/demo/ComposeDemo.swift"
    local gamma="$repo_dir/Dimmerly/Services/GammaMath.swift"
    if [[ ! -x "$tool" || "$source" -nt "$tool" || "$gamma" -nt "$tool" ]]; then
        mkdir -p "$(dirname -- "$tool")"
        xcrun swiftc -O -parse-as-library "$source" "$gamma" -o "$tool" \
            -framework AppKit -framework CoreGraphics -framework AVFoundation -framework CoreText
    fi
    echo "$tool"
}

demo_compose() {
    [[ -s "$values" && -d "$run_dir/panel" ]] || {
        echo "Run scripts/demo.sh capture $appearance first." >&2
        return 1
    }
    local tool
    tool="$(compose_tool)"
    local common=(--values "$values" --panel-dir "$run_dir/panel" --storyboard "$storyboard"
        --appearance "$appearance")
    case "${1:-}" in
        ''|--check) ;;
        *) demo_usage >&2; return 64 ;;
    esac
    if [[ "${1:-}" == '--check' ]]; then
        "$tool" "${common[@]}" --check
        return
    fi
    echo "Composing the $appearance master..."
    "$tool" "${common[@]}" --output "$master"
    "$tool" "${common[@]}" --check
}

# Fails when a file is larger than its budget in bytes.
check_budget() {
    local file="$1" budget="$2" size
    size="$(stat -f %z "$file")"
    if ((size > budget)); then
        echo "$(basename -- "$file") is $size bytes, over its $budget-byte budget." >&2
        echo 'Lower the quality or frame rate rather than shortening the story.' >&2
        return 1
    fi
    echo "$(basename -- "$file"): $size bytes (budget $budget)"
}

demo_export() {
    [[ $# -eq 0 ]] || { demo_usage >&2; return 64; }
    [[ -s "$master" ]] || { echo "Run scripts/demo.sh compose $appearance first." >&2; return 1; }
    command -v ffmpeg >/dev/null || { echo 'ffmpeg is required: brew install ffmpeg' >&2; return 1; }
    command -v img2webp >/dev/null || { echo 'img2webp is required: brew install webp' >&2; return 1; }
    mkdir -p "$exports"

    local website="$exports/dimmerly-demo-$appearance.mp4" poster="$exports/dimmerly-demo-$appearance-poster.jpg"
    local readme="$exports/dimmerly-demo-$appearance.webp" social="$run_dir/dimmerly-demo-social.mp4"
    local quiet=(-hide_banner -loglevel error -y)

    echo "Encoding the $appearance website MP4..."
    ffmpeg "${quiet[@]}" -i "$master" -vf scale=1280:800:flags=lanczos -c:v libx264 -preset slow -crf 24 \
        -pix_fmt yuv420p -movflags +faststart -an "$website"
    # The poster shows before the video plays (and instead of it under Reduce Motion), so it
    # uses a frame that explains the app: panel open, presets applied, caption showing.
    echo 'Encoding the poster...'
    ffmpeg "${quiet[@]}" -ss "$poster_time" -i "$master" -frames:v 1 -vf scale=1280:800:flags=lanczos -q:v 3 "$poster"
    # The website hero's desk: frame 0, with both displays at full brightness and the panel
    # closed. The page draws its own panel and dims each screen over this picture. The crop
    # stops above the caption, and delogo paints out the pointer, which storyboard.json holds
    # at panel point (210, 470) when the loop starts. Move the box if that key moves.
    echo 'Encoding the desk stills...'
    local desk_width
    for desk_width in 1280 2320; do
        ffmpeg "${quiet[@]}" -i "$master" -frames:v 1 \
            -vf "delogo=x=2286:y=968:w=90:h=100,crop=2560:1360:0:0,scale=$desk_width:-2:flags=lanczos" \
            -q:v 4 "$exports/dimmerly-desk-$appearance-$desk_width.jpg"
    done
    echo 'Encoding the social MP4...'
    ffmpeg "${quiet[@]}" -i "$master" -vf scale=1920:1200:flags=lanczos -c:v libx264 -preset slow -crf 20 \
        -pix_fmt yuv420p -movflags +faststart -an "$social"

    echo 'Encoding the README WebP...'
    local webp_frames="$run_dir/webp-frames"
    rm -rf -- "$webp_frames"
    mkdir -p "$webp_frames"
    ffmpeg "${quiet[@]}" -i "$master" -vf fps=20,scale=960:600:flags=lanczos "$webp_frames/%04d.png"
    img2webp -loop 0 -lossy -q 70 -d 50 "$webp_frames"/*.png -o "$readme" >/dev/null

    check_budget "$website" $((1500 * 1024))
    check_budget "$poster" $((150 * 1024))
    check_budget "$exports/dimmerly-desk-$appearance-1280.jpg" $((80 * 1024))
    check_budget "$exports/dimmerly-desk-$appearance-2320.jpg" $((160 * 1024))
    check_budget "$readme" $((3 * 1024 * 1024))
    check_budget "$social" $((8 * 1024 * 1024))
    echo "Exports: $exports (social MP4: $social)"
}

# Reads one value from a JSON file, such as stills.0.file; empty when it isn't there.
json_value() {
    plutil -extract "$2" raw -o - "$1" 2>/dev/null || true
}

require_app_store_variant() {
    [[ "${DEMO_VARIANT:-}" == app-store ]] || {
        echo 'The App Store stills come from the App Store build: run with DEMO_VARIANT=app-store.' >&2
        return 64
    }
}

stills_capture() {
    [[ $# -eq 0 ]] || { demo_usage >&2; return 64; }
    require_app_store_variant || return
    storyboard="$stills_storyboard" run_prefix='stills-'
    for_appearances capture_with_retry

    local app index=0 file tab
    app="$(demo_app)"
    while file="$(json_value "$stills_storyboard" "windowStills.$index.file")"; [[ -n "$file" ]]; do
        tab="$(json_value "$stills_storyboard" "windowStills.$index.settingsTab")"
        use_appearance "$(json_value "$stills_storyboard" "windowStills.$index.appearance")"
        local inputs="$demo_dir/stills-settings-$tab-$appearance"
        mkdir -p "$inputs"
        rm -f -- "$inputs/settings.png" "$inputs/settings-mask.png"
        echo "Capturing the $tab settings ($appearance)..."
        trap stop_staged EXIT
        trap 'stop_staged; exit 130' INT
        trap 'stop_staged; exit 143' TERM
        DIMMERLY_SCREENSHOT_SETTINGS_TAB="$tab" launch_staged "$app" settings "$appearance" "$(backdrop_color)"
        capture_when_ready settings-region "$inputs/settings.png"
        # The mask capture must match the region capture, so take it right away.
        capture --pid "$staged_pid" --mode settings --output "$inputs/settings-mask.png"
        stop_staged
        trap - EXIT INT TERM
        index=$((index + 1))
    done
    echo "Captured. Render with: DEMO_VARIANT=app-store scripts/demo.sh stills"
}

# Fails unless an App Store screenshot is 2560x1600 with no alpha channel.
check_still() {
    local info
    info="$(sips -g pixelWidth -g pixelHeight -g hasAlpha "$1")"
    if ! grep -q 'pixelWidth: 2560' <<<"$info" || ! grep -q 'pixelHeight: 1600' <<<"$info" ||
        ! grep -q 'hasAlpha: no' <<<"$info"; then
        echo "$(basename -- "$1") is not a 2560x1600 opaque PNG:" >&2
        echo "$info" >&2
        return 1
    fi
}

stills_render() {
    [[ $# -eq 0 ]] || { demo_usage >&2; return 64; }
    require_app_store_variant || return
    local tool index file
    tool="$(compose_tool)"
    run_prefix='stills-'
    mkdir -p "$stills_output"
    index=0
    while file="$(json_value "$stills_storyboard" "stills.$index.file")"; [[ -n "$file" ]]; do
        use_appearance "$(json_value "$stills_storyboard" "stills.$index.appearance")"
        [[ -s "$values" && -d "$run_dir/panel" ]] || {
            echo "Missing the $appearance stills recording; run DEMO_VARIANT=app-store scripts/demo.sh stills-capture." >&2
            return 1
        }
        "$tool" --appearance "$appearance" --values "$values" --panel-dir "$run_dir/panel" \
            --storyboard "$stills_storyboard" --still --frame "$(json_value "$stills_storyboard" "stills.$index.frame")" \
            --clock "$(json_value "$stills_storyboard" "stills.$index.clock")" --png "$stills_output/$file"
        check_still "$stills_output/$file"
        index=$((index + 1))
    done
    index=0
    while file="$(json_value "$stills_storyboard" "windowStills.$index.file")"; [[ -n "$file" ]]; do
        local tab inputs
        tab="$(json_value "$stills_storyboard" "windowStills.$index.settingsTab")"
        use_appearance "$(json_value "$stills_storyboard" "windowStills.$index.appearance")"
        inputs="$demo_dir/stills-settings-$tab-$appearance"
        [[ -s "$inputs/settings.png" && -s "$inputs/settings-mask.png" ]] || {
            echo "Missing the $tab settings capture; run DEMO_VARIANT=app-store scripts/demo.sh stills-capture." >&2
            return 1
        }
        "$tool" --appearance "$appearance" --window "$inputs/settings.png" --window-mask "$inputs/settings-mask.png" \
            --caption "$(json_value "$stills_storyboard" "windowStills.$index.caption")" \
            --clock "$(json_value "$stills_storyboard" "windowStills.$index.clock")" --png "$stills_output/$file"
        check_still "$stills_output/$file"
        index=$((index + 1))
    done
    echo "Stills: $stills_output. Inspect every image before uploading."
}

preview_capture() {
    [[ $# -eq 0 ]] || { demo_usage >&2; return 64; }
    require_app_store_variant || return
    storyboard="$preview_storyboard" run_prefix='preview-'
    for_appearances capture_with_retry "$(json_value "$preview_storyboard" preview.appearance)"
    echo "Recorded. Render with: DEMO_VARIANT=app-store scripts/demo.sh preview"
}

# Renders the preview to ProRes, then encodes what App Store Connect accepts for a Mac preview:
# 1920x1080 H.264 High 4.0 at 30 fps, 15-30 s, with a silent stereo AAC track.
preview_render() {
    [[ $# -eq 0 ]] || { demo_usage >&2; return 64; }
    require_app_store_variant || return
    command -v ffmpeg >/dev/null || { echo 'ffmpeg is required: brew install ffmpeg' >&2; return 1; }
    local tool tab caption seconds settings out
    tool="$(compose_tool)"
    run_prefix='preview-'
    use_appearance "$(json_value "$preview_storyboard" preview.appearance)"
    tab="$(json_value "$preview_storyboard" preview.settingsTab)"
    caption="$(json_value "$preview_storyboard" preview.settingsCaption)"
    seconds="$(json_value "$preview_storyboard" preview.settingsSeconds)"
    settings="$demo_dir/stills-settings-$tab-$appearance"
    [[ -s "$values" && -d "$run_dir/panel" ]] || {
        echo 'Missing the preview recording; run DEMO_VARIANT=app-store scripts/demo.sh preview-capture.' >&2
        return 1
    }
    [[ -s "$settings/settings.png" && -s "$settings/settings-mask.png" ]] || {
        echo "Missing the $tab settings capture; run DEMO_VARIANT=app-store scripts/demo.sh stills-capture." >&2
        return 1
    }
    out="$demo_dir/preview"
    mkdir -p "$out"
    "$tool" --appearance "$appearance" --values "$values" --panel-dir "$run_dir/panel" \
        --storyboard "$preview_storyboard" --window "$settings/settings.png" \
        --window-mask "$settings/settings-mask.png" --caption "$caption" --window-seconds "$seconds" \
        --preview "$out/master.mov"
    ffmpeg -hide_banner -loglevel error -y -i "$out/master.mov" \
        -f lavfi -i anullsrc=channel_layout=stereo:sample_rate=48000 \
        -map 0:v -map 1:a -shortest -c:v libx264 -profile:v high -level 4.0 -pix_fmt yuv420p -r 30 \
        -b:v 11M -maxrate 12M -bufsize 24M -c:a aac -b:a 256k -ar 48000 -ac 2 -movflags +faststart \
        "$out/Dimmerly-App-Store-Preview.mp4"
    echo "Preview: $out/Dimmerly-App-Store-Preview.mp4"
}

# The demo and screenshot stage are DEBUG-only; a Release binary must not contain them.
demo_check_release() {
    local release_derived="$demo_dir/ReleaseDerivedData"
    echo 'Building Dimmerly (Release)...'
    xcodebuild -quiet -project "$repo_dir/Dimmerly.xcodeproj" -scheme Dimmerly -configuration Release \
        -destination "platform=macOS,arch=$(uname -m)" -derivedDataPath "$release_derived" \
        CODE_SIGNING_ALLOWED=NO build
    # Debug builds keep app code in Dimmerly.debug.dylib, so scan every binary, not just the main one.
    local binary found
    for binary in "$release_derived/Build/Products/Release/Dimmerly.app/Contents/MacOS"/*; do
        found="$(nm "$binary" 2>/dev/null | grep -E 'DemoPlayer|DemoRunner|DemoStoryboard|ScreenshotStage' || true)"
        if [[ -n "$found" ]]; then
            echo "$(basename -- "$binary") in the Release build contains demo or screenshot code:" >&2
            head -5 <<<"$found" >&2
            return 1
        fi
        if strings "$binary" | grep -qE 'DIMMERLY_SCREENSHOT|DIMMERLY_DEMO'; then
            echo "$(basename -- "$binary") in the Release build mentions the demo environment variables." >&2
            return 1
        fi
    done
    echo 'Release build has no demo or screenshot code.'
}

command="${1:-help}"
[[ $# -eq 0 ]] || shift
case "$command" in
    build) demo_build ;;
    capture) for_appearances capture_with_retry "$@" ;;
    compose) for_appearances demo_compose "$@" ;;
    export) for_appearances demo_export "$@" ;;
    render)
        demo_build
        for_appearances capture_with_retry
        for_appearances demo_compose
        for_appearances demo_export
        ;;
    check-release) demo_check_release ;;
    stills-capture) stills_capture "$@" ;;
    stills) stills_render "$@" ;;
    preview-capture) preview_capture "$@" ;;
    preview) preview_render "$@" ;;
    help|--help|-h) demo_usage ;;
    *) demo_usage >&2; exit 64 ;;
esac

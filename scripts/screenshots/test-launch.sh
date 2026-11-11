#!/bin/bash
# Test launch orchestration without opening apps or recording a screen.
set -euo pipefail
source_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/dimmerly-launch-tests.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
export SCREENSHOT_SCRIPT="$source_dir/../screenshots.sh"
export FIXTURE_ROOT="$scratch"
mkdir -p "$scratch/.build/screenshots/DerivedData/Build/Products/Debug/Dimmerly.app/Contents/MacOS"
touch "$scratch/.build/screenshots/DerivedData/Build/Products/Debug/Dimmerly.app/Contents/MacOS/Dimmerly"
chmod +x "$scratch/.build/screenshots/DerivedData/Build/Products/Debug/Dimmerly.app/Contents/MacOS/Dimmerly"
cat > "$scratch/fixture.sh" <<'FIXTURE'
source "$SCREENSHOT_SCRIPT"
repo_dir="$FIXTURE_ROOT"
ensure_helper() { :; }
check_screen_recording() { :; }
run_helper() {
    case "$1" in
        --pause-apps)
            [[ "$3" == --staged-app && "$4" == */Debug/Dimmerly.app ]] || return 1
            echo pause >> "$FIXTURE_ROOT/events"; echo saved > "$2"
            if [[ "${SIGNAL_DURING_PAUSE:-}" == 1 ]]; then kill -TERM "$$"; fi ;;
        --resume-apps) echo resume >> "$FIXTURE_ROOT/events"; rm "$2" ;;
    esac
    echo ok
}
launch_staged() { scene="$2"; }
stop_staged() { echo stop >> "$FIXTURE_ROOT/events"; }
capture_when_ready() {
    echo "$scene" >> "$FIXTURE_ROOT/events"
    [[ "${FAIL_SCENE:-}" != "$scene" ]] || return 1
    echo "$scene" > "$2"
}
launch_screenshots --skip-build --output "$FIXTURE_ROOT/output directory" "$@"
FIXTURE

bash "$scratch/fixture.sh" > "$scratch/log" 2>&1
[[ "$(cat "$scratch/output directory/menubar-2.png")" == launch-evening ]]
[[ "$(find "$scratch/output directory" -name '*.png' | wc -l | tr -d ' ')" == 9 ]]
[[ "$(head -1 "$scratch/events")" == pause ]]
[[ "$(tail -1 "$scratch/events")" == resume ]]
[[ ! -e "$scratch/.build/screenshots/launch.lock" ]]
[[ ! -e "$scratch/.build/screenshots/launch/running-apps.json" ]]

# Failure must restore the app, release the lock, and preserve the previous final set.
echo previous > "$scratch/output directory/menubar-1-light.png"
if FAIL_SCENE=launch-evening bash "$scratch/fixture.sh" > "$scratch/log" 2>&1; then
    echo 'Expected a failed capture to fail the command' >&2
    exit 1
fi
[[ "$(cat "$scratch/output directory/menubar-1-light.png")" == previous ]]
[[ "$(tail -1 "$scratch/events")" == resume ]]
[[ ! -e "$scratch/.build/screenshots/launch.lock" ]]

# A single appearance must leave the curated selection alone.
echo chosen > "$scratch/output directory/menubar-1.png"
bash "$scratch/fixture.sh" --appearance dark > "$scratch/log" 2>&1
[[ "$(cat "$scratch/output directory/menubar-1.png")" == chosen ]]

# Another invocation's lock is never removed or used as permission to close apps.
mkdir "$scratch/.build/screenshots/launch.lock"
echo "$$" > "$scratch/.build/screenshots/launch.lock/pid"
cp "$scratch/events" "$scratch/events-before"
if bash "$scratch/fixture.sh" > "$scratch/log" 2>&1; then exit 1; fi
cmp "$scratch/events" "$scratch/events-before"
[[ -d "$scratch/.build/screenshots/launch.lock" ]]

# A provably dead owner can be recovered; a live owner's lock remains untouched above.
echo 99999999 > "$scratch/.build/screenshots/launch.lock/pid"
bash "$scratch/fixture.sh" --appearance light > "$scratch/log" 2>&1
[[ ! -e "$scratch/.build/screenshots/launch.lock" ]]

# Terminating the shell during the detached close operation must not start cleanup early.
signal_result=0
SIGNAL_DURING_PAUSE=1 bash "$scratch/fixture.sh" --appearance light > "$scratch/log" 2>&1 || signal_result=$?
[[ "$signal_result" == 143 ]]
[[ "$(tail -1 "$scratch/events")" == resume ]]
[[ ! -e "$scratch/.build/screenshots/launch/running-apps.json" ]]
echo 'Launch lifecycle checks passed'

#!/usr/bin/env bash
# Builds the Dimmerly installer DMG with the designed Finder window layout.
#
# Usage: packaging/dmg/build-dmg.sh <path to Dimmerly.app> <volume name> <output.dmg>
#
# dmgbuild runs from a private virtual environment with hash-pinned wheels so the
# release job does not depend on whatever Python packages the runner has.
set -euo pipefail

if [[ $# -ne 3 ]]; then
    echo "Usage: $0 <path to Dimmerly.app> <volume name> <output.dmg>" >&2
    exit 64
fi

app_path="$1"
volume_name="$2"
output_path="$3"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ ! -d "$app_path" ]]; then
    echo "App bundle not found: $app_path" >&2
    exit 1
fi

if [[ ! -f "$app_path/Contents/Resources/AppIcon.icns" ]]; then
    echo "App bundle has no Contents/Resources/AppIcon.icns for the volume icon: $app_path" >&2
    exit 1
fi

venv_dir="$(mktemp -d "${TMPDIR:-/tmp}/dimmerly-dmgbuild.XXXXXX")"
trap 'rm -rf "$venv_dir"' EXIT

python3 -m venv "$venv_dir"
"$venv_dir/bin/python" -m pip install \
    --quiet \
    --disable-pip-version-check \
    --require-hashes \
    --only-binary=:all: \
    -r "$script_dir/requirements.txt"

mkdir -p "$(dirname "$output_path")"

"$venv_dir/bin/python" -B -m dmgbuild \
    -s "$script_dir/dmgbuild-settings.py" \
    -D app="$(cd "$(dirname "$app_path")" && pwd)/$(basename "$app_path")" \
    -D background="$script_dir/background.png" \
    "$volume_name" \
    "$output_path"

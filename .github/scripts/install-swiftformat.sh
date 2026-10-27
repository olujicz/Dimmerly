#!/usr/bin/env bash
set -euo pipefail

# Install the SwiftFormat release that CI, Release and local checks agree on.
# `brew install swiftformat` takes whatever the runner image's Homebrew has, which drifted
# from developer machines and made formatting checks disagree. Keep `version` in step with
# `--minversion` in `.swiftformat`, and take `sha256` from the release's `swiftformat.zip`
# asset digest.
version="0.64.4"
sha256="bb42fbfb0b9d5f1b8b83db3147087220ea414916fce8c5cf71abaea5ad5a3175"

dest="${RUNNER_TEMP:-$(mktemp -d)}/swiftformat-$version"
mkdir -p "$dest"
archive="$dest/swiftformat.zip"

curl --fail --silent --show-error --location --retry 3 --output "$archive" \
    "https://github.com/nicklockwood/SwiftFormat/releases/download/$version/swiftformat.zip"
printf '%s  %s\n' "$sha256" "$archive" | shasum -a 256 --check --status || {
    echo "SwiftFormat $version archive checksum mismatch." >&2
    exit 1
}

unzip -q -o "$archive" -d "$dest"
binary="$(find "$dest" -type f -name swiftformat | head -1)"
if [[ -z "$binary" ]]; then
    echo "SwiftFormat binary not found in the $version archive." >&2
    exit 1
fi
chmod +x "$binary"

actual="$("$binary" --version)"
if [[ "$actual" != "$version" ]]; then
    echo "Expected SwiftFormat $version; got $actual." >&2
    exit 1
fi

if [[ -n "${GITHUB_PATH:-}" ]]; then
    dirname "$binary" >> "$GITHUB_PATH"
fi
echo "SwiftFormat $actual at $binary"

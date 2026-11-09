#!/usr/bin/env bash
# Tests packaging/sparkle/changelog-section.sh, which cuts one version's release notes
# from CHANGELOG.md for Sparkle's update window.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cutter="$script_dir/../../packaging/sparkle/changelog-section.sh"
fixture_dir="$(mktemp -d)"
trap 'rm -rf "$fixture_dir"' EXIT

changelog="$fixture_dir/CHANGELOG.md"
cat > "$changelog" <<'MD'
# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

### Changed
- Something not released yet.

## [1.5.10] - 2027-01-02

### Fixed
- The tenth patch.

## [1.5.1] - 2026-12-01

### Fixed
- Brightness & warmth stay <in range> after "waking" the display.

### Changed
- Settings opens faster.

## [1.5.0] - 2026-11-20

## [1.4.2] - 2026-11-05

### Fixed
- The panel grows with its content.
MD

expected_151='### Fixed
- Brightness & warmth stay <in range> after "waking" the display.

### Changed
- Settings opens faster.'

run_cutter() {
    local expected_exit="$1"
    local description="$2"
    shift 2
    local actual=0
    bash "$cutter" "$@" > "$fixture_dir/output" 2> "$fixture_dir/errors" || actual=$?
    if [[ "$actual" != "$expected_exit" ]]; then
        printf 'FAIL: %s (expected exit %s, got %s)\n' "$description" "$expected_exit" "$actual" >&2
        cat "$fixture_dir/output" "$fixture_dir/errors" >&2
        exit 1
    fi
}

expect_output() {
    local expected="$1"
    local description="$2"
    if [[ "$(cat "$fixture_dir/output")" != "$expected" ]]; then
        printf 'FAIL: %s\n--- expected\n%s\n--- got\n%s\n' "$description" "$expected" "$(cat "$fixture_dir/output")" >&2
        exit 1
    fi
    printf 'PASS: %s\n' "$description"
}

run_cutter 0 'prints the section body' 1.5.1 "$changelog"
expect_output "$expected_151" 'prints the section body and stops at the next version'

run_cutter 0 'keeps markdown verbatim' 1.5.1 "$changelog"
grep -Fq 'Brightness & warmth stay <in range> after "waking" the display.' "$fixture_dir/output" ||
    { echo 'FAIL: markdown with & < > characters was changed' >&2; exit 1; }
printf 'PASS: keeps markdown with & < > characters verbatim\n'

run_cutter 0 'does not match 1.5.10 when asked for 1.5.1' 1.5.10 "$changelog"
expect_output '### Fixed
- The tenth patch.' 'cuts 1.5.10 on its own'

run_cutter 0 'the last section ends at the end of the file' 1.4.2 "$changelog"
expect_output '### Fixed
- The panel grows with its content.' 'the last section ends at the end of the file'

run_cutter 1 'fails when the version is missing' 9.9.9 "$changelog"
printf 'PASS: fails when the version is missing\n'

run_cutter 1 'fails when the section is empty' 1.5.0 "$changelog"
printf 'PASS: fails when the section is empty\n'

run_cutter 1 'ignores [Unreleased]' Unreleased "$changelog"
printf 'PASS: ignores [Unreleased]\n'

run_cutter 1 'a version with regex characters does not match loosely' '1.5.' "$changelog"
printf 'PASS: a version with regex characters does not match loosely\n'

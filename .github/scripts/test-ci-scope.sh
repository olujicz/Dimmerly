#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
classifier="$script_dir/ci-scope.sh"

assert_scope() {
    local expected="$1"
    local description="$2"
    shift 2

    local actual
    actual="$(printf '%s\0' "$@" | "$classifier")"

    if [[ "$actual" != "full_ci=$expected" ]]; then
        printf 'FAIL: %s\n  expected: full_ci=%s\n  actual:   %s\n' \
            "$description" "$expected" "$actual" >&2
        return 1
    fi

    printf 'PASS: %s\n' "$description"
}

assert_empty_scope() {
    local actual
    actual="$(printf '' | "$classifier")"

    if [[ "$actual" != "full_ci=true" ]]; then
        printf 'FAIL: empty diff fails closed\n  expected: full_ci=true\n  actual:   %s\n' \
            "$actual" >&2
        return 1
    fi

    printf 'PASS: empty diff fails closed\n'
}

assert_scope false "root Markdown is lightweight" README.md
assert_scope false "nested Markdown is lightweight" guides/setup.md
assert_scope false "documentation files are lightweight" documentation/RELEASE.pdf
assert_scope false "images are lightweight" images/app-icon.png
assert_scope false "root license is lightweight" LICENSE
assert_scope false "multiple lightweight paths stay lightweight" README.md images/demo.png documentation/guide.txt

assert_scope true "Swift source requires full CI" Dimmerly/App.swift
assert_scope true "workflow changes require full CI" .github/workflows/ci.yml
assert_scope true "build scripts require full CI" Justfile
assert_scope true "Xcode project changes require full CI" Dimmerly.xcodeproj/project.pbxproj
assert_scope true "mixed docs and code require full CI" README.md Dimmerly/App.swift
assert_empty_scope

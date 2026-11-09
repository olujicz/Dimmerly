#!/usr/bin/env bash
# Prints one version's release notes from CHANGELOG.md, for Sparkle's update window.
#
# Usage: packaging/sparkle/changelog-section.sh <version> [CHANGELOG.md]
#
# Prints the lines between "## [<version>] - <date>" and the next "## [" heading, without
# leading or trailing blank lines. Fails if the version has no section or the section is
# empty. The Markdown is printed unchanged; generate_appcast escapes it for the XML.
set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
    echo "Usage: $0 <version> [CHANGELOG.md]" >&2
    exit 64
fi

version="$1"
changelog="${2:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/CHANGELOG.md}"

if [[ ! "$version" =~ ^[0-9]+(\.[0-9]+)*$ ]]; then
    echo "Not a release version: $version" >&2
    exit 1
fi

found=0
section="$(awk -v heading="## [$version]" '
    index($0, "## [") == 1 {
        if (in_section) exit
        if (index($0, heading) == 1) {
            rest = substr($0, length(heading) + 1)
            if (rest == "" || substr(rest, 1, 1) == " ") { in_section = 1; print "\001found"; next }
        }
    }
    in_section { print }
' "$changelog")"

if [[ "$section" == $'\001found'* ]]; then
    found=1
    section="${section#$'\001found'}"
fi
if [[ "$found" -ne 1 ]]; then
    echo "CHANGELOG has no section for $version" >&2
    exit 1
fi

# Trim leading and trailing blank lines.
section="$(printf '%s\n' "$section" | sed -e '/./,$!d' | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}')"
if [[ -z "${section//[[:space:]]/}" ]]; then
    echo "The CHANGELOG section for $version is empty" >&2
    exit 1
fi

printf '%s\n' "$section"

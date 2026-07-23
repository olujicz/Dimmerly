#!/usr/bin/env bash
set -euo pipefail

seen_path=false
full_ci=false

while IFS= read -r -d '' path; do
    seen_path=true

    case "$path" in
        *.md | documentation/* | images/* | LICENSE)
            ;;
        *)
            full_ci=true
            ;;
    esac
done

if [[ "$seen_path" == false ]]; then
    full_ci=true
fi

printf 'full_ci=%s\n' "$full_ci"

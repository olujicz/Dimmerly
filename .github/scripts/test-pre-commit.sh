#!/usr/bin/env bash
# Exercise hook exit handling without invoking installed linters or scanning secrets.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fixture_dir="$(mktemp -d)"
trap 'rm -rf "$fixture_dir"' EXIT
mkdir -p "$fixture_dir/bin" "$fixture_dir/repo"
git -C "$fixture_dir/repo" init -q
printf 'let value = 1\n' > "$fixture_dir/repo/Example.swift"
git -C "$fixture_dir/repo" add Example.swift

for tool in swiftformat gitleaks; do
    printf '#!/bin/sh\nexit 0\n' > "$fixture_dir/bin/$tool"
done
cat > "$fixture_dir/bin/swiftlint" <<'SH'
#!/bin/sh
if [ -n "${LINT_ERROR:-}" ]; then
    printf '%s\n' "$LINT_ERROR" >&2
fi
exit "${LINT_EXIT:-0}"
SH
chmod +x "$fixture_dir/bin/"*

check_hook() {
    local description="$1" expected="$2" lint_exit="$3" lint_error="$4"
    local actual=0
    (
        cd "$fixture_dir/repo"
        PATH="$fixture_dir/bin:$PATH" LINT_EXIT="$lint_exit" LINT_ERROR="$lint_error" \
            bash "$repo_root/.githooks/pre-commit"
    ) > "$fixture_dir/output" 2>&1 || actual=$?
    if [[ "$actual" != "$expected" ]]; then
        printf 'FAIL: %s (expected %s, got %s)\n' "$description" "$expected" "$actual" >&2
        cat "$fixture_dir/output" >&2
        exit 1
    fi
    if [[ -n "$lint_error" ]] && ! grep -qF "$lint_error" "$fixture_dir/output"; then
        printf 'FAIL: %s hid the diagnostic\n' "$description" >&2
        exit 1
    fi
    printf 'PASS: %s\n' "$description"
}

check_hook 'successful lint passes' 0 0 ''
check_hook 'stderr-only lint failure blocks the commit' 1 2 'Invalid lint configuration'
check_hook 'silent lint failure blocks the commit' 1 2 ''
check_hook 'successful lint with a diagnostic passes' 0 0 'Informational diagnostic'

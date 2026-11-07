#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fixture_dir="$(mktemp -d)"
trap 'rm -rf "$fixture_dir"' EXIT

# Stand in for notarytool so the notarization gate runs without Apple credentials.
cat > "$fixture_dir/xcrun" <<'SH'
#!/usr/bin/env bash
case "$2" in
    submit)
        [[ " $* " == *" --key $NOTARY_KEY_PATH --key-id $NOTARY_KEY_ID --issuer $NOTARY_ISSUER_ID "* ]] || exit 2
        printf '%s\n' "$TEST_SUBMIT_OUTPUT"
        exit "${TEST_SUBMIT_EXIT:-0}"
        ;;
    log)
        if [[ "$3" != "test-id" || " $* " != *" --key $NOTARY_KEY_PATH --key-id $NOTARY_KEY_ID --issuer $NOTARY_ISSUER_ID "* ]]; then
            exit 1
        fi
        log_path="${*: -1}"
        printf '%s\n' "$TEST_LOG" > "$log_path"
        ;;
    *)
        exit 1
        ;;
esac
SH
chmod +x "$fixture_dir/xcrun"

export PATH="$fixture_dir:$PATH"
export NOTARY_KEY_PATH="$fixture_dir/AuthKey_TEST.p8"
export NOTARY_KEY_ID=TEST
export NOTARY_ISSUER_ID=test-issuer
touch "$fixture_dir/Dimmerly.dmg"

accepted='{"id":"test-id","status":"Accepted","message":"Processing complete"}'
clean_log='{"status":"Accepted","statusSummary":"Ready for distribution","issues":null}'
warning_log='{"status":"Accepted","statusSummary":"Ready for distribution","issues":[{"severity":"warning","path":"Dimmerly.app","message":"note"}]}'
error_log='{"status":"Accepted","statusSummary":"Ready for distribution","issues":[{"severity":"error","path":"Dimmerly.app","message":"bad"}]}'

assert_gate() {
    local expected="$1"
    local description="$2"
    local actual=0
    rm -f "$fixture_dir/notary-log.json"
    bash "$script_dir/notarize.sh" "$fixture_dir/Dimmerly.dmg" "$fixture_dir/notary-log.json" \
        > "$fixture_dir/output" 2>&1 || actual=$?
    if [[ "$actual" != "$expected" ]]; then
        printf 'FAIL: %s (expected %s, got %s)\n' "$description" "$expected" "$actual" >&2
        cat "$fixture_dir/output" >&2
        exit 1
    fi
    if grep -q -e "$NOTARY_KEY_ID" -e "$NOTARY_ISSUER_ID" -e "$NOTARY_KEY_PATH" "$fixture_dir/output"; then
        printf 'FAIL: %s printed credentials\n' "$description" >&2
        exit 1
    fi
    printf 'PASS: %s\n' "$description"
}

export TEST_SUBMIT_OUTPUT="$accepted" TEST_LOG="$clean_log"
assert_gate 0 'an accepted submission with a clean log passes'
[[ -s "$fixture_dir/notary-log.json" ]] || { echo 'FAIL: accepted log was not kept' >&2; exit 1; }
printf 'PASS: the log of an accepted submission is kept\n'
TEST_LOG="$warning_log"
assert_gate 1 'a warning in an accepted log fails'
[[ -s "$fixture_dir/notary-log.json" ]] || { echo 'FAIL: warning log was not kept' >&2; exit 1; }
TEST_LOG='{"status":"Accepted","statusSummary":"Ready for distribution","issues":[]}'
assert_gate 0 'an empty issue list passes'
TEST_LOG="$error_log"
assert_gate 1 'an error issue in an accepted log fails'
TEST_LOG='not json'
assert_gate 1 'an unreadable log fails closed'
export TEST_SUBMIT_OUTPUT='{"id":"test-id","status":"Invalid"}' TEST_SUBMIT_EXIT=1 TEST_LOG="$error_log"
assert_gate 1 'an invalid submission fails and still fetches its log'
[[ -s "$fixture_dir/notary-log.json" ]] || { echo 'FAIL: invalid log was not kept' >&2; exit 1; }
export TEST_SUBMIT_OUTPUT="$accepted" TEST_SUBMIT_EXIT=1 TEST_LOG="$clean_log"
assert_gate 1 'an accepted status with a failing notarytool exit fails'
export TEST_SUBMIT_OUTPUT='{"id":"test-id","status":"In Progress"}' TEST_SUBMIT_EXIT=0 TEST_LOG="$clean_log"
assert_gate 1 'a submission that is not accepted fails'
export TEST_SUBMIT_OUTPUT='Error: HTTP status code: 401' TEST_SUBMIT_EXIT=1
assert_gate 1 'a submission without an ID fails'

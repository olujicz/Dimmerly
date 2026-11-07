#!/usr/bin/env bash
# Submits a file for notarization, waits, and always keeps the notary log.
#
# Usage: .github/scripts/notarize.sh <file> <log path>
#
# Reads the App Store Connect API key from NOTARY_KEY_PATH, NOTARY_KEY_ID, and
# NOTARY_ISSUER_ID. Fails unless the submission is Accepted and its log lists
# no issues at all, warnings included. The log itself contains no credentials.
set -euo pipefail

if [[ $# -ne 2 ]]; then
    echo "Usage: $0 <file> <log path>" >&2
    exit 64
fi

file_path="$1"
log_path="$2"
: "${NOTARY_KEY_PATH:?NOTARY_KEY_PATH is required}"
: "${NOTARY_KEY_ID:?NOTARY_KEY_ID is required}"
: "${NOTARY_ISSUER_ID:?NOTARY_ISSUER_ID is required}"

auth=(--key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID")

mkdir -p "$(dirname "$log_path")"

submit_status=0
submission="$(xcrun notarytool submit "$file_path" "${auth[@]}" --wait --output-format json)" || submit_status=$?

submission_id="$(jq -r '.id // empty' <<<"$submission" 2>/dev/null || true)"
status="$(jq -r '.status // empty' <<<"$submission" 2>/dev/null || true)"

if [[ -z "$submission_id" ]]; then
    echo "notarytool returned no submission ID (exit $submit_status):" >&2
    printf '%s\n' "$submission" >&2
    exit 1
fi

echo "Submission $submission_id for $(basename "$file_path"): ${status:-unknown}"

# Fetch the log for every outcome, so warnings on Accepted submissions are kept.
if ! xcrun notarytool log "$submission_id" "${auth[@]}" "$log_path" >/dev/null; then
    echo "Could not fetch the notary log for submission $submission_id." >&2
    exit 1
fi

if ! jq -e 'type == "object"' "$log_path" >/dev/null 2>&1; then
    echo "The notary log for submission $submission_id is not a JSON object." >&2
    exit 1
fi

jq -r '
    "Notary log status: \(.status // "unknown") (\(.statusSummary // ""))",
    ((.issues // [])[] | "\(.severity // "unknown"): \(.path // "-"): \(.message // "")")
' "$log_path"

issue_count="$(jq '(.issues // []) | length' "$log_path")"

if [[ "$status" != "Accepted" || "$submit_status" -ne 0 ]]; then
    echo "Notarization of $(basename "$file_path") was not accepted (status: ${status:-unknown})." >&2
    exit 1
fi

if [[ "$issue_count" -ne 0 ]]; then
    echo "The notary log for $(basename "$file_path") lists $issue_count issue(s); warnings fail the release too." >&2
    exit 1
fi

echo "Notarization of $(basename "$file_path") accepted with no issues."

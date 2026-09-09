#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   ./get-cf-alias-txt.sh --dist-id ESTJ95U0UEHYG --alias fonts.juniorbay.com [--profile default]
#
# It will:
#   - Run associate-alias with --debug
#   - Dump the raw "Response body:" to /tmp/cf_alias_body.txt (and print a preview)
#   - Try to extract the TXT name/value from JSON or XML
#   - Exit nonzero if no TXT is present in the body (so you know to contact AWS Support)

PROFILE=default
DIST_ID=""
ALIAS=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dist-id) DIST_ID="$2"; shift 2;;
    --alias)   ALIAS="$2"; shift 2;;
    --profile) PROFILE="$2"; shift 2;;
    *) echo "Unknown arg: $1"; exit 1;;
  esac
done

[[ -n "$DIST_ID" && -n "$ALIAS" ]] || { echo "Usage: $0 --dist-id <ID> --alias <name> [--profile default]"; exit 1; }

DBG="/tmp/cf_alias_debug.txt"
BODY="/tmp/cf_alias_body.txt"
: > "$DBG"; : > "$BODY"

echo "→ Calling associate-alias (capturing debug to $DBG)..."
# Make retries predictable and avoid pager noise
export AWS_MAX_ATTEMPTS=1 AWS_RETRY_MODE=standard AWS_PAGER=""
set +e
aws cloudfront associate-alias \
  --target-distribution-id "$DIST_ID" \
  --alias "$ALIAS" \
  --profile "$PROFILE" \
  --output json --debug 1>/dev/null 2>"$DBG"
rc=$?
set -e

if [[ $rc -eq 0 ]]; then
  echo "✓ Alias already associated (no TXT needed)."
  exit 0
fi

# Extract *raw* body after the first "Response body:" marker (JSON or XML)
awk '
  /Response body:/ { copying=1; next }
  copying {
    # Stop when we hit a blank "Response headers" section or a next major block
    if ($0 ~ /^Response headers:/ || $0 ~ /^DEBUG:/) exit
    print
  }
' "$DBG" > "$BODY"

echo "— Raw response body (first 40 lines) —"
nl -ba "$BODY" | sed -n '1,40p'
echo "—— end preview ——"
echo

# Try to parse TXT from JSON or XML
NAME="$(grep -Eo '"resource-?record-?name"\s*:\s*"[^"]+"' "$BODY" | head -1 | sed -E 's/.*"([^"]+)"/\1/')"
VALUE="$(grep -Eo '"resource-?record-?value"\s*:\s*"[^"]+"' "$BODY" | head -1 | sed -E 's/.*"([^"]+)"/\1/')"

if [[ -z "$NAME" || -z "$VALUE" ]]; then
  NAME="$(grep -Eo '<ResourceRecordName>[^<]+' "$BODY" | sed -E 's/.*>(.*)/\1/' | head -1 || true)"
  VALUE="$(grep -Eo '<ResourceRecordValue>[^<]+' "$BODY" | sed -E 's/.*>(.*)/\1/' | head -1 || true)"
fi

if [[ -n "$NAME" && -n "$VALUE" ]]; then
  echo "TXT record found:"
  echo "  NAME : $NAME"
  echo "  TYPE : TXT"
  echo "  VALUE: \"$VALUE\""
  echo
  echo "(Next) UPSERT this into Route 53, wait ~1–5 min, then re-run:"
  echo "  aws cloudfront associate-alias --target-distribution-id \"$DIST_ID\" --alias \"$ALIAS\" --profile \"$PROFILE\""
  exit 0
else
  echo "!! No TXT fields present in the response body."
  echo "   - Body saved at: $BODY"
  echo "   - Debug log at  : $DBG"
  echo
  echo "This typically means CloudFront did not include the TXT challenge in your response."
  echo "Next steps:"
  echo "  1) Ensure your distro $DIST_ID already has the ACM covering $ALIAS (you said it does)."
  echo "  2) Update awscli to latest v2 (older botocore sometimes drops bodies on 409)."
  echo "  3) If it still shows no TXT in the body, open an AWS Support ticket to force-move the alias."
  exit 2
fi

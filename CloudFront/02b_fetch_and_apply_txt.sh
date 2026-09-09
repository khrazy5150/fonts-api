#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   ./02b_fetch_and_apply_txt.sh --dist-id ESTJ95U0UEHYG --alias fonts.juniorbay.com
#   ./02b_fetch_and_apply_txt.sh --dist-id ESTJ95U0UEHYG --alias fonts.juniorbay.com --apply
#
# It:
#   - Calls associate-alias with --debug to get the error JSON body.
#   - Extracts the JSON between "Response body:" and its matching closing brace.
#   - Parses resource-record-name/value and (optionally) UPSERTs the TXT in Route 53.

PROFILE=default
DIST_ID=""
ALIAS=""
APPLY=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dist-id) DIST_ID="$2"; shift 2;;
    --alias)   ALIAS="$2"; shift 2;;
    --profile) PROFILE="$2"; shift 2;;
    --apply)   APPLY=true; shift;;
    *) echo "Unknown arg: $1"; exit 1;;
  esac
done

[[ -n "$DIST_ID" && -n "$ALIAS" ]] || { echo "Usage: $0 --dist-id <ID> --alias fonts.juniorbay.com [--apply]"; exit 1; }
command -v jq >/dev/null || { echo "jq not found"; exit 1; }

tmpdir="$(mktemp -d)"; trap 'rm -rf "$tmpdir"' EXIT

echo "→ Probing CloudFront for TXT instructions (expecting a failure with details)..."
set +e
aws cloudfront associate-alias \
  --target-distribution-id "$DIST_ID" \
  --alias "$ALIAS" \
  --profile "$PROFILE" \
  --output json --debug \
  1>"$tmpdir/out.txt" 2>"$tmpdir/err.txt"
rc=$?
set -e

if [[ $rc -eq 0 ]]; then
  echo "✓ Alias associated immediately (no TXT required)."
  exit 0
fi

# Extract JSON after "Response body:" with brace balancing.
# This avoids jq parse errors due to extra log text.
json_body="$(
  awk '
    /Response body:/ {inbody=1; depth=0; next}
    inbody {
      # detect first "{"
      if (depth==0) {
        # scan for first "{"
        if (index($0,"{")) {
          start=index($0,"{")
          line=substr($0,start)
        } else {
          next
        }
      } else {
        line=$0
      }

      # append line
      buf = buf line ORS

      # update brace depth
      for (i=1;i<=length(line);i++) {
        c=substr(line,i,1)
        if (c=="{") depth++
        else if (c=="}") {
          depth--
          if (depth==0) {print buf; exit}
        }
      }
    }
  ' "$tmpdir/err.txt"
)"

if [[ -z "$json_body" ]]; then
  echo "!! Could not isolate JSON response body. See $tmpdir/err.txt (look for 'Response body:'),"
  echo "   then copy the JSON block here and I’ll parse it for you."
  exit 2
fi

# Pull the TXT name and value
TXT_NAME="$(jq -r '..|.["resource-record-name"]? // empty' <<<"$json_body" | head -n1)"
TXT_VALUE_RAW="$(jq -r '..|.["resource-record-value"]? // empty' <<<"$json_body" | head -n1)"

if [[ -z "$TXT_NAME" || -z "$TXT_VALUE_RAW" ]]; then
  echo "!! TXT fields not present in parsed JSON. Body was:"
  echo "$json_body"
  exit 3
fi

# Ensure Route53-friendly quoting around the TXT value
if [[ "$TXT_VALUE_RAW" != \"*\" ]]; then
  TXT_VALUE="\"$TXT_VALUE_RAW\""
else
  TXT_VALUE="$TXT_VALUE_RAW"
fi

echo "→ TXT verification required. Add this DNS record:"
echo "  NAME : $TXT_NAME"
echo "  TYPE : TXT"
echo "  VALUE: $TXT_VALUE"
echo

if ! $APPLY; then
  echo "(Tip) Re-run with --apply to UPSERT this TXT into Route 53 automatically.)"
  exit 0
fi

echo "→ UPSERTing TXT into Route 53 ..."
BASE_ZONE="${ALIAS#*.}."
HZ_ID="$(aws route53 list-hosted-zones-by-name --dns-name "$BASE_ZONE" --profile "$PROFILE" \
  --query 'HostedZones[?Name==`'"$BASE_ZONE"'` && Config.PrivateZone==`false`][0].Id' \
  --output text)"

if [[ -z "$HZ_ID" || "$HZ_ID" == "None" ]]; then
  echo "!! Could not find public hosted zone for $BASE_ZONE."
  exit 4
fi

cat > "$tmpdir/r53.json" <<JSON
{
  "Comment": "TXT for CloudFront alias move: $ALIAS",
  "Changes": [{
    "Action": "UPSERT",
    "ResourceRecordSet": {
      "Name": "$TXT_NAME",
      "Type": "TXT",
      "TTL": 60,
      "ResourceRecords": [{ "Value": $TXT_VALUE }]
    }
  }]
}
JSON

aws route53 change-resource-record-sets \
  --hosted-zone-id "$HZ_ID" \
  --change-batch "file://$tmpdir/r53.json" \
  --profile "$PROFILE" >/dev/null

echo "✓ TXT upserted. Wait ~1-5 minutes, then finish the move:"
echo "  aws cloudfront associate-alias --target-distribution-id \"$DIST_ID\" --alias \"$ALIAS\" --profile \"$PROFILE\""

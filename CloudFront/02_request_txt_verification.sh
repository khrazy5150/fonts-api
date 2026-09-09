#!/usr/bin/env bash
set -euo pipefail

# ========= CONFIG =========
PROFILE=default
DIST_ID="${DIST_ID:-}"                 # you can export DIST_ID before running, or pass --dist-id
#DIST_ID="ESTJ95U0UEHYG"
ALIAS="fonts.juniorbay.com"
AUTO_APPLY="${AUTO_APPLY:-false}"      # or run with --apply-txt

# ========= ARGS =========
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dist-id) DIST_ID="$2"; shift 2;;
    --apply-txt) AUTO_APPLY=true; shift;;
    --alias) ALIAS="$2"; shift 2;;
    --profile) PROFILE="$2"; shift 2;;
    *) echo "Unknown arg: $1"; exit 1;;
  esac
done

if [[ -z "${DIST_ID:-}" ]]; then
  echo "Usage: DIST_ID=<id> $0 [--apply-txt] [--alias fonts.juniorbay.com] [--profile default]"
  exit 1
fi

echo "→ Requesting alias association: $ALIAS → $DIST_ID"
set +e
RESP="$(aws cloudfront associate-alias --target-distribution-id "$DIST_ID" --alias "$ALIAS" --profile "$PROFILE" 2>&1)"
CODE=$?
set -e

if [[ $CODE -eq 0 ]]; then
  echo "✓ Alias associated immediately."
  exit 0
fi

# Try to parse the TXT instruction from the error message.
# Typical guidance mentions a name like _cf-custom-hostname.<alias> and a token value.
TXT_NAME="$(grep -Eo '_cf-[^ ]+\.'"$ALIAS" <<<"$RESP" | head -n1 || true)"
TXT_VAL="$(grep -Eo '"[A-Za-z0-9+/=:_-]{10,}"' <<<"$RESP" | head -n1 || true)"

echo "CloudFront response:"
echo "$RESP"
echo

if [[ -z "$TXT_NAME" || -z "$TXT_VAL" ]]; then
  echo "Could not auto-parse TXT instructions from the response."
  echo "Please read the message above and add the requested TXT manually."
  exit 2
fi

echo "→ TXT verification required. Add this record in DNS:"
echo "  NAME : $TXT_NAME"
echo "  TYPE : TXT"
echo "  VALUE: $TXT_VAL"
echo

if [[ "$AUTO_APPLY" != "true" ]]; then
  echo "(Tip) Re-run with --apply-txt to UPSERT this TXT into Route 53 automatically."
  exit 3
fi

echo "→ Attempting to UPSERT TXT into Route 53 automatically..."
BASE_ZONE="${ALIAS#*.}."
HZ_ID="$(aws route53 list-hosted-zones-by-name --dns-name "$BASE_ZONE" --profile "$PROFILE" \
  --query 'HostedZones[?Name==`'"$BASE_ZONE"'` && Config.PrivateZone==`false`][0].Id' --output text)"

if [[ -z "$HZ_ID" || "$HZ_ID" == "None" ]]; then
  echo "!! Could not find a public hosted zone for $BASE_ZONE. Please add the TXT manually."
  exit 4
fi

cat > r53.txt.json <<JSON
{
  "Comment": "TXT for CloudFront alias move: $ALIAS",
  "Changes": [{
    "Action": "UPSERT",
    "ResourceRecordSet": {
      "Name": "$TXT_NAME",
      "Type": "TXT",
      "TTL": 60,
      "ResourceRecords": [{ "Value": $TXT_VAL }]
    }
  }]
}
JSON

aws route53 change-resource-record-sets \
  --hosted-zone-id "$HZ_ID" \
  --change-batch file://r53.txt.json \
  --profile "$PROFILE" >/dev/null

echo "✓ TXT record upserted."
echo "Now wait ~1-5 minutes, then run 03_attach_alias_and_cert.sh"

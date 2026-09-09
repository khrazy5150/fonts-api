#!/usr/bin/env bash
set -euo pipefail

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
command -v python3 >/dev/null || { echo "python3 not found"; exit 1; }

tmpdir="$(mktemp -d)"; trap 'rm -rf "$tmpdir"' EXIT

echo "→ Probing CloudFront for TXT instructions (expect a failure with JSON details)..."
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

JSON_PATH="$tmpdir/body.json"
python3 - "$tmpdir/err.txt" "$JSON_PATH" <<'PY'
import sys, json, re
err_path, out_path = sys.argv[1], sys.argv[2]
text = open(err_path, 'r', errors='ignore').read()
start = text.find("Response body:")
if start < 0: sys.exit(1)
after = text[start+len("Response body:"):]
i = after.find('{')
if i < 0: sys.exit(2)
buf=[]; depth=0; started=False
for ch in after[i:]:
    if ch=='{': depth+=1; started=True
    if started: buf.append(ch)
    if ch=='}':
        depth-=1
        if started and depth==0: break
js=''.join(buf).strip()
open(out_path,'w').write(js)
PY

# extract fields (accept both hyphenated and camelCase)
TXT_NAME=$(jq -r '..|.["resource-record-name"]? // .["resourceRecordName"]? // empty' "$JSON_PATH" | head -n1)
TXT_VAL_RAW=$(jq -r '..|.["resource-record-value"]? // .["resourceRecordValue"]? // empty' "$JSON_PATH" | head -n1)

if [[ -z "$TXT_NAME" || -z "$TXT_VAL_RAW" || "$TXT_NAME" == "null" || "$TXT_VAL_RAW" == "null" ]]; then
  echo "!! Could not find TXT details. Inspect $JSON_PATH to locate the fields."
  exit 3
fi

# quote value for Route53
[[ "$TXT_VAL_RAW" == \"*\" ]] && TXT_VAL="$TXT_VAL_RAW" || TXT_VAL="\"$TXT_VAL_RAW\""

echo "→ TXT verification required. Add this DNS record:"
echo "  NAME : $TXT_NAME"
echo "  TYPE : TXT"
echo "  VALUE: $TXT_VAL"
echo

if ! $APPLY; then
  echo "(Tip) Re-run with --apply to UPSERT this TXT into Route 53 automatically.)"
  exit 0
fi

echo "→ UPSERTing TXT into Route 53 ..."
# derive base zone robustly (juniorbay.com)
BASE_ZONE="${TXT_NAME#*_cf-*\.}"
BASE_ZONE="${BASE_ZONE#*.}"
HZ_ID=$(aws route53 list-hosted-zones-by-name --dns-name "$BASE_ZONE" --profile "$PROFILE" \
  --query 'HostedZones[?Name==`'"$BASE_ZONE."'` && Config.PrivateZone==`false`][0].Id' --output text)

if [[ -z "$HZ_ID" || "$HZ_ID" == "None" ]]; then
  echo "!! Could not find public hosted zone for $BASE_ZONE"
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
      "ResourceRecords": [{ "Value": $TXT_VAL }]
    }
  }]
}
JSON

aws route53 change-resource-record-sets \
  --hosted-zone-id "$HZ_ID" \
  --change-batch "file://$tmpdir/r53.json" \
  --profile "$PROFILE" >/dev/null

echo "✓ TXT upserted. After ~1-5 minutes, finish the move:"
echo "  aws cloudfront associate-alias --target-distribution-id \"$DIST_ID\" --alias \"$ALIAS\" --profile \"$PROFILE\""

#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   ./02d_fetch_and_apply_txt.sh --dist-id ESTJ95U0UEHYG --alias fonts.juniorbay.com
#   ./02d_fetch_and_apply_txt.sh --dist-id ESTJ95U0UEHYG --alias fonts.juniorbay.com --apply
#
# Requires: aws, python3

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

# Use Python to robustly extract TXT name/value from the debug response (even if not strict JSON).
python3 - "$tmpdir/err.txt" <<'PY'
import sys, re, json

log_path = sys.argv[1]
with open(log_path, 'r', errors='ignore') as f:
    log = f.read()

# 1) Isolate the "Response body:" block and balance braces
start = log.find("Response body:")
if start < 0:
    print("ERR|NO_BODY")
    sys.exit(0)

after = log[start + len("Response body:"):]
brace = after.find('{')
if brace < 0:
    print("ERR|NO_JSON_START")
    sys.exit(0)

buf = []
depth = 0
started = False
for ch in after[brace:]:
    if ch == '{':
        depth += 1
        started = True
    if started:
        buf.append(ch)
    if ch == '}':
        depth -= 1
        if started and depth == 0:
            break

raw = ''.join(buf).strip()
if not raw.startswith('{'):
    print("ERR|NO_JSON_OBJ")
    sys.exit(0)

# 2) Try to parse JSON; if it fails, try converting single quotes → double quotes naively
def try_parse(s):
    try:
        return json.loads(s)
    except Exception:
        return None

data = try_parse(raw)
if data is None:
    fixed = re.sub(r"'", r'"', raw)
    data = try_parse(fixed)

# 3) If still not JSON, fallback to regex search across entire log for the fields
def find_kv(d, keys):
    if isinstance(d, dict):
        for k, v in d.items():
            if k in keys:
                yield v
            else:
                yield from find_kv(v, keys)
    elif isinstance(d, list):
        for it in d:
            yield from find_kv(it, keys)

name = val = None
if data is not None:
    # Accept hyphenated or camelCase variants
    names = list(find_kv(data, {"resource-record-name","resourceRecordName"}))
    vals  = list(find_kv(data, {"resource-record-value","resourceRecordValue"}))
    name = names[0] if names else None
    val  = vals[0]  if vals  else None

if not name or not val:
    # Fallback: regex scan the whole log
    # Examples:
    #   "resource-record-name":"_cf-custom-hostname.fonts.juniorbay.com"
    #   "resourceRecordName":"_cf-custom-hostname.fonts.juniorbay.com"
    name_pat = re.compile(r'"(?:resource-record-name|resourceRecordName)"\s*:\s*"([^"]+)"')
    val_pat  = re.compile(r'"(?:resource-record-value|resourceRecordValue)"\s*:\s*"([^"]+)"')
    m1 = name_pat.search(log)
    m2 = val_pat.search(log)
    if m1: name = m1.group(1)
    if m2: val  = m2.group(1)

if not name or not val:
    print("ERR|NO_FIELDS")
    # Dump the raw JSON to help debugging
    print(raw)
    sys.exit(0)

print(f"OK|{name}|{val}")
PY

RESULT="$(tail -n1 "$tmpdir/err.txt" | sed -n '1p' )"  # fallback if python didn't print to stdout
if grep -q '^OK|' <<<"$RESULT"; then
  :
else
  # If Python printed to stdout, capture it directly:
  RESULT="$(python3 - "$tmpdir/err.txt" <<'PY'
import sys, re, json
log = open(sys.argv[1],'r',errors='ignore').read()
print(log)  # default to printing full log if previous step failed
PY
)"
fi

if [[ "$RESULT" != OK* ]]; then
  echo "!! Could not extract TXT details automatically."
  echo "Open this file and look for resource-record-name/value:"
  echo "  $tmpdir/err.txt"
  exit 2
fi

TXT_NAME="$(cut -d'|' -f2 <<<"$RESULT")"
TXT_VALUE_RAW="$(cut -d'|' -f3 <<<"$RESULT")"

echo "→ TXT verification required. Add this DNS record:"
echo "  NAME : $TXT_NAME"
echo "  TYPE : TXT"
echo "  VALUE: \"$TXT_VALUE_RAW\""
echo

if ! $APPLY; then
  echo "(Tip) Re-run with --apply to UPSERT this TXT into Route 53 automatically.)"
  exit 0
fi

echo "→ UPSERTing TXT into Route 53 ..."
# Derive the hosted zone from the ALIAS (simplest, avoids double-dot issues)
BASE_ZONE="${ALIAS#*.}"          # e.g., juniorbay.com
HZ_ID="$(aws route53 list-hosted-zones-by-name --dns-name "${BASE_ZONE}." --profile "$PROFILE" \
  --query 'HostedZones[?Name==`'"${BASE_ZONE}."'` && Config.PrivateZone==`false`][0].Id' --output text)"

if [[ -z "$HZ_ID" || "$HZ_ID" == "None" ]]; then
  echo "!! Could not find public hosted zone for $BASE_ZONE"
  exit 3
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
      "ResourceRecords": [{ "Value": "\"$TXT_VALUE_RAW\"" }]
    }
  }]
}
JSON

aws route53 change-resource-record-sets \
  --hosted-zone-id "$HZ_ID" \
  --change-batch "file://$tmpdir/r53.json" \
  --profile "$PROFILE" >/dev/null

echo "✓ TXT upserted. After ~1–5 minutes, finish the move:"
echo "  aws cloudfront associate-alias --target-distribution-id \"$DIST_ID\" --alias \"$ALIAS\" --profile \"$PROFILE\""

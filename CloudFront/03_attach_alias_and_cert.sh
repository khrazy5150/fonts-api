#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   DIST_ID=EXXXXX ./03_attach_alias_and_cert.sh                 # autodetect cert for alias (pass --alias)
#   DIST_ID=EXXXXX ./03_attach_alias_and_cert.sh --alias fonts.juniorbay.com
#   DIST_ID=EXXXXX ./03_attach_alias_and_cert.sh --acm arn:...  # use specific cert ARN
#
# This will:
# 1) Ensure the distribution uses an ACM cert covering the alias (autodetect if not provided).
# 2) associate-alias (requires TXT if alias is held elsewhere).
# 3) Add alias to DistributionConfig.Aliases and UPSERT Route53 A/ALIAS.

PROFILE=default
DIST_ID="${DIST_ID:-}"
ALIAS="fonts.juniorbay.com"
ACM="${ACM:-}"
ACM_REGION="us-east-1"
CF_ZONE_ID="Z2FDTNDATAQYW2"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dist-id) DIST_ID="$2"; shift 2;;
    --alias)   ALIAS="$2"; shift 2;;
    --acm)     ACM="$2"; shift 2;;
    --profile) PROFILE="$2"; shift 2;;
    *) echo "Unknown arg: $1"; exit 1;;
  esac
done

[[ -n "${DIST_ID:-}" ]] || { echo "Usage: DIST_ID=<id> $0 [--alias fonts.juniorbay.com] [--acm <arn>] [--profile default]"; exit 1; }

pick_cert() {
  local alias="$1"
  local tmpdir; tmpdir="$(mktemp -d)"; trap 'rm -rf "$tmpdir"' RETURN

  aws acm list-certificates --region "$ACM_REGION" --profile "$PROFILE" \
    --certificate-statuses ISSUED \
    --query 'CertificateSummaryList[].CertificateArn' --output text > "$tmpdir/certs.txt" || true

  local best_arn="" best_score=-1 best_notafter=0
  while read -r arn; do
    [[ -n "$arn" ]] || continue
    aws acm describe-certificate --certificate-arn "$arn" --region "$ACM_REGION" --profile "$PROFILE" > "$tmpdir/cert.json" || continue
    local domain; domain="$(jq -r '.Certificate.DomainName' "$tmpdir/cert.json")"
    local sans;   sans=($(jq -r '.Certificate.SubjectAlternativeNames[]?' "$tmpdir/cert.json"))
    local notafter_epoch; notafter_epoch="$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$(jq -r '.Certificate.NotAfter' "$tmpdir/cert.json")" "+%s" 2>/dev/null || date -d "$(jq -r '.Certificate.NotAfter' "$tmpdir/cert.json")" +%s )"

    local score=0
    for name in "$domain" "${sans[@]}"; do
      [[ "$name" == "$alias" ]] && score=3 && break
    done
    if [[ $score -lt 3 ]]; then
      for name in "$domain" "${sans[@]}"; do
        if [[ "$name" == \*.* ]]; then
          local suf="${name#*.}"
          [[ "$alias" == *".$suf" ]] && score=2 && break
        fi
      done
    fi
    if [[ $score -lt 2 ]]; then
      local base="${alias#*.}"
      for name in "$domain" "${sans[@]}"; do
        [[ "$name" == "$base" ]] && score=1 && break
      done
    fi

    if (( score > best_score )) || { (( score == best_score )) && (( notafter_epoch > best_notafter )); }; then
      best_score=$score; best_arn="$arn"; best_notafter=$notafter_epoch
    fi
  done < "$tmpdir/certs.txt"

  if [[ -z "$best_arn" || $best_score -lt 1 ]]; then
    echo "!! No suitable ISSUED ACM cert found in $ACM_REGION covering $ALIAS" >&2
    return 1
  fi
  echo "$best_arn"
}

# Ensure a covering cert is attached first
if [[ -z "$ACM" ]]; then
  echo "→ Autodetecting ACM cert in $ACM_REGION for $ALIAS ..."
  ACM="$(pick_cert "$ALIAS")"
  echo "   Using ACM: $ACM"
else
  echo "→ Using provided ACM: $ACM"
fi

echo "→ Fetching distribution config for $DIST_ID ..."
aws cloudfront get-distribution-config --id "$DIST_ID" --profile "$PROFILE" > dist.json
ETAG=$(jq -r '.ETag' dist.json)
jq '.DistributionConfig' dist.json > cfg.json

# Put the cert on before associate-alias
echo "→ Ensuring ViewerCertificate is the ACM provided/selected ..."
jq --arg acm "$ACM" '
  .ViewerCertificate = {
    "ACMCertificateArn": $acm,
    "SSLSupportMethod": "sni-only",
    "MinimumProtocolVersion": "TLSv1.2_2021",
    "Certificate": $acm,
    "CertificateSource": "acm",
    "CloudFrontDefaultCertificate": false
  }
' cfg.json > cfg.acm.json

aws cloudfront update-distribution \
  --id "$DIST_ID" \
  --if-match "$ETAG" \
  --distribution-config file://cfg.acm.json \
  --profile "$PROFILE" >/dev/null
echo "✓ Distribution now uses ACM."

# Try to associate the alias
echo "→ Associating alias $ALIAS ..."
set +e
RESP="$(aws cloudfront associate-alias --target-distribution-id "$DIST_ID" --alias "$ALIAS" --profile "$PROFILE" 2>&1)"
CODE=$?
set -e

if [[ $CODE -eq 0 ]]; then
  echo "✓ Alias associated."
else
  echo "CloudFront response:"
  echo "$RESP"
  # If TXT needed, show the parsed record
  TXT_NAME="$(grep -Eo '_cf-[[:alnum:]-]+\.'"$ALIAS" <<<"$RESP" | head -n1 || true)"
  TXT_VAL="$(grep -Eo '"[A-Za-z0-9+/=:_-]{10,}"' <<<"$RESP" | head -n1 || true)"
  if [[ -n "$TXT_NAME" && -n "$TXT_VAL" ]]; then
    echo
    echo "→ TXT verification required. Add this DNS record, wait 1–5 minutes, then rerun this script:"
    echo "  NAME : $TXT_NAME"
    echo "  TYPE : TXT"
    echo "  VALUE: $TXT_VAL"
    exit 2
  else
    echo "!! associate-alias failed (no TXT parsed). Ensure cert covers the alias and try again."
    exit 3
  fi
fi

# Add alias into distro config + Route53 ALIAS
echo "→ Adding alias to DistributionConfig and UPSERT Route53 A/ALIAS ..."
aws cloudfront get-distribution-config --id "$DIST_ID" --profile "$PROFILE" > dist2.json
ETAG2=$(jq -r '.ETag' dist2.json)
jq '.DistributionConfig' dist2.json > cfg2.json

jq --arg alias "$ALIAS" '
  .Aliases.Items = ((.Aliases.Items // []) + [$alias]) | .Aliases.Items |= unique
  | .Aliases.Quantity = (.Aliases.Items | length)
' cfg2.json > cfg2.alias.json

aws cloudfront update-distribution \
  --id "$DIST_ID" \
  --if-match "$ETAG2" \
  --distribution-config file://cfg2.alias.json \
  --profile "$PROFILE" >/dev/null

CF_DOMAIN="$(aws cloudfront get-distribution --id "$DIST_ID" --profile "$PROFILE" --query 'Distribution.DomainName' --output text)"
BASE_ZONE="${ALIAS#*.}."
HZ_ID="$(aws route53 list-hosted-zones-by-name --dns-name "$BASE_ZONE" --profile "$PROFILE" \
  --query 'HostedZones[?Name==`'"$BASE_ZONE"'` && Config.PrivateZone==`false`][0].Id' --output text)"

if [[ -z "$HZ_ID" || "$HZ_ID" == "None" ]]; then
  echo "!! Could not find public hosted zone for $BASE_ZONE. Create the ALIAS manually:"
  echo "   Name: $ALIAS → Alias to $CF_DOMAIN (Zone ID: $CF_ZONE_ID)"; exit 4
fi

cat > alias.json <<JSON
{
  "Comment": "ALIAS $ALIAS -> $CF_DOMAIN",
  "Changes": [{
    "Action": "UPSERT",
    "ResourceRecordSet": {
      "Name": "$ALIAS",
      "Type": "A",
      "AliasTarget": {
        "HostedZoneId": "$CF_ZONE_ID",
        "DNSName": "$CF_DOMAIN",
        "EvaluateTargetHealth": false
      }
    }
  }]
}
JSON

aws route53 change-resource-record-sets \
  --hosted-zone-id "$HZ_ID" \
  --change-batch file://alias.json \
  --profile "$PROFILE" >/dev/null

echo "✓ Alias added to distribution and Route 53 ALIAS upserted."
echo "Test once Deployed:"
echo "  curl -I \"https://$ALIAS/?family=Aileron:400,600&display=swap\""
echo "  curl -I \"https://$ALIAS/Aileron/Aileron-Regular.woff2\""

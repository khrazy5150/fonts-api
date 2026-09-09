#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   DIST_ID=EXXXXX ./02a_attach_cert_only.sh                # autodetect cert for alias (pass --alias)
#   DIST_ID=EXXXXX ./02a_attach_cert_only.sh --alias fonts.juniorbay.com
#   DIST_ID=EXXXXX ./02a_attach_cert_only.sh --acm arn:...  # use specific cert ARN
#
# Notes:
# - ACM region must be us-east-1 for CloudFront.

PROFILE=default
DIST_ID="${DIST_ID:-}"            # or pass --dist-id
ALIAS="fonts.juniorbay.com"       # only used for autodetect
ACM="${ACM:-}"                    # or pass --acm
ACM_REGION="us-east-1"

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
  # Autodetect an ISSUED cert in us-east-1 that covers $ALIAS.
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

    # scoring: exact=3, wildcard match (*.base)=2, base domain=1
    local score=0
    # exact?
    for name in "$domain" "${sans[@]}"; do
      [[ "$name" == "$alias" ]] && score=3 && break
    done
    # wildcard?
    if [[ $score -lt 3 ]]; then
      for name in "$domain" "${sans[@]}"; do
        if [[ "$name" == \*.* ]]; then
          local suf="${name#*.}"            # drop "*."
          [[ "$alias" == *".$suf" ]] && score=2 && break
        fi
      done
    fi
    # base fallback?
    if [[ $score -lt 2 ]]; then
      local base="${alias#*.}"             # juniorbay.com
      for name in "$domain" "${sans[@]}"; do
        [[ "$name" == "$base" ]] && score=1 && break
      done
    fi

    # keep best by (score, notAfter)
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

echo "→ Setting ViewerCertificate to ACM ..."
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

echo "✓ ACM attached to $DIST_ID. Proceed to TXT/alias association."

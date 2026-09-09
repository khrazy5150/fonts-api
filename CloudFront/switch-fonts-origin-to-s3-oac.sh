#!/usr/bin/env bash
set -euo pipefail

# ====== CONFIG ======
PROFILE=default
FONTS_ALIAS="fonts.juniorbay.com"     # the CF alias we created
BUCKET="juniorbay.com"                # bucket holding /fonts/**
ORIGIN_ID="S3-jb-fonts"               # origin id used in your fonts distro
ORIGIN_PATH="/fonts"

# ====== PRECHECKS ======
command -v aws >/dev/null || { echo "aws CLI not found"; exit 1; }
command -v jq  >/dev/null || { echo "jq not found"; exit 1; }

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text --profile "$PROFILE")"

echo "→ Locating CloudFront distribution for alias $FONTS_ALIAS ..."
DIST_ID="$(aws cloudfront list-distributions --profile "$PROFILE" \
  --query "DistributionList.Items[?Aliases.Items && contains(Aliases.Items, '$FONTS_ALIAS')].Id | [0]" \
  --output text)"
if [[ -z "$DIST_ID" || "$DIST_ID" == "None" ]]; then
  echo "!! Could not find a distribution with alias $FONTS_ALIAS"; exit 1
fi
echo "   Found distribution: $DIST_ID"

echo "→ Detecting S3 bucket region for $BUCKET ..."
LOC="$(aws s3api get-bucket-location --bucket "$BUCKET" --profile "$PROFILE" --query LocationConstraint --output text)"
if [[ "$LOC" == "None" || "$LOC" == "null" ]]; then
  REGION="us-east-1"
else
  REGION="$LOC"
fi
# Build REST endpoint
if [[ "$REGION" == "us-east-1" ]]; then
  REST_DOMAIN="${BUCKET}.s3.amazonaws.com"
else
  REST_DOMAIN="${BUCKET}.s3.${REGION}.amazonaws.com"
fi
echo "   Bucket region: $REGION"
echo "   REST endpoint: $REST_DOMAIN"

echo "→ Fetching current distribution config..."
aws cloudfront get-distribution-config --id "$DIST_ID" --profile "$PROFILE" > dist.json
ETAG="$(jq -r '.ETag' dist.json)"
jq '.DistributionConfig' dist.json > cfg.json

echo "→ Switching origin to S3 REST endpoint + keeping OriginPath=$ORIGIN_PATH ..."
jq --arg oid "$ORIGIN_ID" --arg dom "$REST_DOMAIN" --arg path "$ORIGIN_PATH" '
  .Origins.Items |= map(
    if .Id == $oid then
      .DomainName = $dom
      | .OriginPath = $path
      | (if has("CustomOriginConfig") then del(.CustomOriginConfig) else . end)
      | .S3OriginConfig = { "OriginAccessIdentity": "" }
    else . end
  )
' cfg.json > cfg.rest.json

echo "→ Ensuring OAC exists and attaching it ..."
OAC_NAME="OAC-${FONTS_ALIAS}"
OAC_ID="$(aws cloudfront list-origin-access-controls --profile "$PROFILE" --output json \
  | jq -r --arg name "$OAC_NAME" '.OriginAccessControlList.Items[]? | select(.Name==$name) | .Id' | head -n1)"
if [[ -z "$OAC_ID" || "$OAC_ID" == "None" ]]; then
  OAC_ID="$(aws cloudfront create-origin-access-control --profile "$PROFILE" \
    --origin-access-control-config "{
      \"Name\":\"$OAC_NAME\",
      \"Description\":\"OAC for $FONTS_ALIAS\",
      \"SigningProtocol\":\"sigv4\",
      \"SigningBehavior\":\"always\",
      \"OriginAccessControlOriginType\":\"s3\"
    }" --query OriginAccessControl.Id --output text)"
  echo "   Created OAC: $OAC_ID"
else
  echo "   Reusing OAC: $OAC_ID"
fi

jq --arg oid "$ORIGIN_ID" --arg oac "$OAC_ID" '
  .Origins.Items |= map(
    if .Id == $oid then
      .OriginAccessControlId = $oac
      | (.S3OriginConfig.OriginAccessIdentity = "")
    else . end
  )
' cfg.rest.json > cfg.oac.json

echo "→ Updating distribution ..."
aws cloudfront update-distribution \
  --id "$DIST_ID" \
  --if-match "$ETAG" \
  --distribution-config file://cfg.oac.json \
  --profile "$PROFILE" >/dev/null
echo "   Submitted update."

echo "→ Blocking public access on the bucket (safe if already set) ..."
aws s3api put-public-access-block --bucket "$BUCKET" --profile "$PROFILE" \
  --public-access-block-configuration '{
    "BlockPublicAcls": true,
    "IgnorePublicAcls": true,
    "BlockPublicPolicy": true,
    "RestrictPublicBuckets": true
  }'

echo "→ Applying bucket policy to allow ONLY this CloudFront distribution via OAC ..."
DIST_ARN="arn:aws:cloudfront::${ACCOUNT_ID}:distribution/${DIST_ID}"
cat > bucket-oac-policy.json <<JSON
{
  "Version": "2012-10-17",
  "Statement": [{
    "Sid": "AllowCloudFrontOACOnly",
    "Effect": "Allow",
    "Principal": { "Service": "cloudfront.amazonaws.com" },
    "Action": "s3:GetObject",
    "Resource": "arn:aws:s3:::${BUCKET}/*",
    "Condition": { "StringEquals": { "AWS:SourceArn": "${DIST_ARN}" } }
  }]
}
JSON
aws s3api put-bucket-policy --bucket "$BUCKET" --policy file://bucket-oac-policy.json --profile "$PROFILE"

echo "→ Invalidate CSS and font paths (optional but helpful after origin switch) ..."
aws cloudfront create-invalidation \
  --distribution-id "$DIST_ID" \
  --paths "/*" \
  --profile "$PROFILE" >/dev/null

echo "✓ Done. After status is Deployed, test:"
echo "  curl -I \"https://${FONTS_ALIAS}/?family=Aileron:400,600&display=swap\""
echo "  curl -I \"https://${FONTS_ALIAS}/Aileron/Aileron-Regular.woff2\""

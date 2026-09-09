#!/usr/bin/env bash
set -euo pipefail

############################################
# === CONFIG  (from your request) ===
############################################
PROFILE=default
ACM=arn:aws:acm:us-east-1:150544707159:certificate/1a72b7c6-bf14-40d2-8e07-c2d2df84c70a
ALT_DOMAIN=fonts.juniorbay.com

ORIGIN_NAME=S3-jb-fonts
ORIGIN_DOMAIN=juniorbay.com         # If this is NOT an S3 REST endpoint, we'll use a Custom Origin
ORIGIN_PATH=/fonts
ORIGIN_TYPE=S3                      # S3 | CUSTOM  (we will auto-correct to CUSTOM if domain isn't S3 REST)

############################################
# === CONSTANTS / MANAGED POLICIES ===
############################################
# Managed response headers policy with CORS + security
RESP_CORS_SEC="eaab4381-ed33-4a86-88ca-d9558dc6cd63"   # CORS-with-preflight-and-SecurityHeadersPolicy
# Managed origin request policy for S3 CORS
ORIGIN_REQ_S3="88a5eaf4-2fd4-4709-b370-b4c650ea3fcf"   # CORS-S3Origin
# CloudFront Hosted Zone ID for Route53 ALIAS
CF_ZONE_ID="Z2FDTNDATAQYW2"

############################################
# === PRECHECKS ===
############################################
command -v aws >/dev/null || { echo "aws CLI not found"; exit 1; }
command -v jq  >/dev/null || { echo "jq not found"; exit 1; }

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text --profile "$PROFILE")"

workdir="$(mktemp -d)"; trap 'rm -rf "$workdir"' EXIT; cd "$workdir"

############################################
# === HELPERS ===
############################################
is_s3_rest=0
bucket_name=""
if [[ "$ORIGIN_DOMAIN" =~ ^([a-z0-9.-]+)\.s3([.-][a-z0-9-]+)?\.amazonaws\.com$ ]]; then
  is_s3_rest=1
  bucket_name="${BASH_REMATCH[1]}"
fi

origin_type_effective="$ORIGIN_TYPE"
if [[ "$ORIGIN_TYPE" == "S3" && $is_s3_rest -ne 1 ]]; then
  echo "→ ORIGIN_TYPE=S3 but ORIGIN_DOMAIN ($ORIGIN_DOMAIN) is not an S3 REST endpoint."
  echo "  Falling back to Custom Origin for safety."
  origin_type_effective="CUSTOM"
fi

############################################
# === Ensure cache policies exist ===
############################################
echo "→ Ensuring cache policies..."
# CSS-by-query (1h)
CSS_POLICY_ID="$(aws cloudfront list-cache-policies --type custom --profile "$PROFILE" \
  --query 'CachePolicyList.Items[?CachePolicy.CachePolicyConfig.Name==`FontsCSS-ByQuery-1h`].CachePolicy.Id' \
  --output text)"
if [[ -z "$CSS_POLICY_ID" || "$CSS_POLICY_ID" == "None" ]]; then
  CSS_POLICY_ID="$(aws cloudfront create-cache-policy --profile "$PROFILE" --output json \
    --cache-policy-config '{
      "Name":"FontsCSS-ByQuery-1h","Comment":"Cache font CSS by full query for 1h",
      "DefaultTTL":3600,"MaxTTL":86400,"MinTTL":0,
      "ParametersInCacheKeyAndForwardedToOrigin":{
        "EnableAcceptEncodingGzip":true,"EnableAcceptEncodingBrotli":true,
        "CookiesConfig":{"CookieBehavior":"none"},
        "HeadersConfig":{"HeaderBehavior":"none"},
        "QueryStringsConfig":{"QueryStringBehavior":"all"}
      }}' | jq -r '.CachePolicy.Id')"
fi

# Fonts long TTL (180d)
FONTS_POLICY_ID="$(aws cloudfront list-cache-policies --type custom --profile "$PROFILE" \
  --query 'CachePolicyList.Items[?CachePolicy.CachePolicyConfig.Name==`Fonts-180d`].CachePolicy.Id' \
  --output text)"
if [[ -z "$FONTS_POLICY_ID" || "$FONTS_POLICY_ID" == "None" ]]; then
  FONTS_POLICY_ID="$(aws cloudfront create-cache-policy --profile "$PROFILE" --output json \
    --cache-policy-config '{
      "Name":"Fonts-180d","Comment":"WOFF2 long TTL",
      "DefaultTTL":15552000,"MaxTTL":31536000,"MinTTL":0,
      "ParametersInCacheKeyAndForwardedToOrigin":{
        "EnableAcceptEncodingGzip":true,"EnableAcceptEncodingBrotli":true,
        "CookiesConfig":{"CookieBehavior":"none"},
        "HeadersConfig":{"HeaderBehavior":"none"},
        "QueryStringsConfig":{"QueryStringBehavior":"none"}
      }}' | jq -r '.CachePolicy.Id')"
fi

echo "   CSS policy:    $CSS_POLICY_ID"
echo "   WOFF2 policy:  $FONTS_POLICY_ID"

############################################
# === Prepare Origins JSON ===
############################################
if [[ "$origin_type_effective" == "S3" ]]; then
  # We'll attach OAC after create; for now include S3OriginConfig
  cat > origins.json <<JSON
{
  "Quantity": 1,
  "Items": [{
    "Id": "$ORIGIN_NAME",
    "DomainName": "$ORIGIN_DOMAIN",
    "OriginPath": "$ORIGIN_PATH",
    "S3OriginConfig": { "OriginAccessIdentity": "" },
    "ConnectionAttempts": 3,
    "ConnectionTimeout": 10,
    "OriginShield": { "Enabled": false }
  }]
}
JSON
else
# Custom origin (for non-S3 hostnames)
cat > origins.json <<JSON
{
  "Quantity": 1,
  "Items": [{
    "Id": "$ORIGIN_NAME",
    "DomainName": "$ORIGIN_DOMAIN",
    "OriginPath": "$ORIGIN_PATH",
    "CustomOriginConfig": {
      "HTTPPort": 80,
      "HTTPSPort": 443,
      "OriginProtocolPolicy": "https-only",
      "OriginSslProtocols": { "Quantity": 3, "Items": ["TLSv1.2","TLSv1.1","TLSv1"] },
      "OriginReadTimeout": 30,
      "OriginKeepaliveTimeout": 5
    },
    "ConnectionAttempts": 3,
    "ConnectionTimeout": 10,
    "OriginShield": { "Enabled": false }
  }]
}
JSON
fi

############################################
# === Build initial DistributionConfig ===
############################################
CALLER_REF="fonts-$(date +%s)"

cat > dist-config.json <<JSON
{
  "CallerReference": "$CALLER_REF",
  "Aliases": { "Quantity": 1, "Items": ["$ALT_DOMAIN"] },
  "DefaultRootObject": "",
  "Origins": $(cat origins.json),
  "DefaultCacheBehavior": {
    "TargetOriginId": "$ORIGIN_NAME",
    "ViewerProtocolPolicy": "redirect-to-https",
    "AllowedMethods": { "Quantity": 2, "Items": ["GET","HEAD"],
      "CachedMethods": { "Quantity": 2, "Items": ["GET","HEAD"] } },
    "Compress": true,
    "SmoothStreaming": false,
    "LambdaFunctionAssociations": { "Quantity": 0 },
    "FunctionAssociations": { "Quantity": 0 },
    "FieldLevelEncryptionId": "",
    "CachePolicyId": "$CSS_POLICY_ID",
    "ResponseHeadersPolicyId": "$RESP_CORS_SEC"
  },
  "CacheBehaviors": {
    "Quantity": 1,
    "Items": [{
      "PathPattern": "*.woff2",
      "TargetOriginId": "$ORIGIN_NAME",
      "ViewerProtocolPolicy": "redirect-to-https",
      "AllowedMethods": { "Quantity": 2, "Items": ["GET","HEAD"],
        "CachedMethods": { "Quantity": 2, "Items": ["GET","HEAD"] } },
      "Compress": true,
      "SmoothStreaming": false,
      "LambdaFunctionAssociations": { "Quantity": 0 },
      "FunctionAssociations": { "Quantity": 0 },
      "FieldLevelEncryptionId": "",
      "CachePolicyId": "$FONTS_POLICY_ID",
      "ResponseHeadersPolicyId": "$RESP_CORS_SEC"
      $( [[ "$origin_type_effective" == "S3" ]] && echo ', "OriginRequestPolicyId": "'$ORIGIN_REQ_S3'"' )
    }]
  },
  "CustomErrorResponses": { "Quantity": 0 },
  "Comment": "Fonts distribution for $ALT_DOMAIN",
  "Logging": { "Enabled": false, "IncludeCookies": false, "Bucket": "", "Prefix": "" },
  "PriceClass": "PriceClass_100",
  "Enabled": true,
  "ViewerCertificate": {
    "ACMCertificateArn": "$ACM",
    "SSLSupportMethod": "sni-only",
    "MinimumProtocolVersion": "TLSv1.2_2021",
    "Certificate": "$ACM",
    "CertificateSource": "acm",
    "CloudFrontDefaultCertificate": false
  },
  "Restrictions": { "GeoRestriction": { "RestrictionType": "none", "Quantity": 0 } },
  "HttpVersion": "http2",
  "IsIPV6Enabled": true
}
JSON

############################################
# === Create the distribution ===
############################################
echo "→ Creating CloudFront distribution for $ALT_DOMAIN ..."
CREATE_OUT="$(aws cloudfront create-distribution --distribution-config file://dist-config.json --profile "$PROFILE" 2>&1 || true)"

if echo "$CREATE_OUT" | grep -q '"Id"'; then
  echo "$CREATE_OUT" > create.json
  DIST_ID="$(jq -r '.Distribution.Id' create.json)"
  CF_DOMAIN="$(jq -r '.Distribution.DomainName' create.json)"
  ETAG="$(jq -r '.ETag' create.json)"
  echo "   Created: $DIST_ID ($CF_DOMAIN)"
else
  # If it failed because alias in use or already exists, try to find it
  echo "$CREATE_OUT"
  echo "→ Looking up an existing distribution with alias $ALT_DOMAIN ..."
  DIST_ID="$(aws cloudfront list-distributions --profile "$PROFILE" \
    --query "DistributionList.Items[?Aliases.Items && contains(Aliases.Items, '$ALT_DOMAIN')].Id | [0]" \
    --output text)"
  if [[ -z "$DIST_ID" || "$DIST_ID" == "None" ]]; then
    echo "!! Could not create or locate a distribution for $ALT_DOMAIN. Aborting."
    exit 1
  fi
  CF_DOMAIN="$(aws cloudfront get-distribution --id "$DIST_ID" --profile "$PROFILE" --query 'Distribution.DomainName' --output text)"
  ETAG="$(aws cloudfront get-distribution-config --id "$DIST_ID" --profile "$PROFILE" --query ETag --output text)"
  echo "   Found existing: $DIST_ID ($CF_DOMAIN)"
fi

############################################
# === If S3 REST origin, attach OAC ===
############################################
if [[ "$origin_type_effective" == "S3" ]]; then
  echo "→ Ensuring OAC for S3 origin..."
  OAC_NAME="OAC-$ALT_DOMAIN"
  OAC_ID="$(aws cloudfront list-origin-access-controls --profile "$PROFILE" --output json \
    | jq -r --arg name "$OAC_NAME" '.OriginAccessControlList.Items[]? | select(.Name==$name) | .Id' | head -n1)"
  if [[ -z "$OAC_ID" || "$OAC_ID" == "None" ]]; then
    OAC_ID="$(aws cloudfront create-origin-access-control --profile "$PROFILE" \
      --origin-access-control-config "{
        \"Name\":\"$OAC_NAME\",
        \"Description\":\"OAC for $ALT_DOMAIN\",
        \"SigningProtocol\":\"sigv4\",
        \"SigningBehavior\":\"always\",
        \"OriginAccessControlOriginType\":\"s3\"
      }" --query OriginAccessControl.Id --output text)"
    echo "   Created OAC: $OAC_ID"
  else
    echo "   Reusing OAC: $OAC_ID"
  fi

  aws cloudfront get-distribution-config --id "$DIST_ID" --profile "$PROFILE" > curr.json
  CUR_ETAG="$(jq -r '.ETag' curr.json)"
  jq '.DistributionConfig' curr.json > cfg.json

  jq --arg origin_id "$ORIGIN_NAME" --arg oac "$OAC_ID" '
    .Origins.Items |= map(
      if .Id == $origin_id then
        .OriginAccessControlId = $oac
        | (.S3OriginConfig.OriginAccessIdentity = "")
      else . end
    )
  ' cfg.json > cfg.oac.json

  aws cloudfront update-distribution \
    --id "$DIST_ID" \
    --if-match "$CUR_ETAG" \
    --distribution-config file://cfg.oac.json \
    --profile "$PROFILE" >/dev/null
  echo "   Attached OAC to origin."

  if [[ -n "$bucket_name" ]]; then
    echo "→ NOTE: Apply this bucket policy to allow ONLY this distribution:"
    DIST_ARN="arn:aws:cloudfront::${ACCOUNT_ID}:distribution/${DIST_ID}"
    cat > bucket-oac-policy.json <<JSON
{
  "Version": "2012-10-17",
  "Statement": [{
    "Sid": "AllowCloudFrontOACOnly",
    "Effect": "Allow",
    "Principal": { "Service": "cloudfront.amazonaws.com" },
    "Action": "s3:GetObject",
    "Resource": "arn:aws:s3:::$bucket_name/*",
    "Condition": { "StringEquals": { "AWS:SourceArn": "$DIST_ARN" } }
  }]
}
JSON
    echo "   File: $(pwd)/bucket-oac-policy.json"
    echo "   Apply with:"
    echo "     aws s3api put-bucket-policy --bucket '$bucket_name' --policy file://bucket-oac-policy.json --profile '$PROFILE'"
  else
    echo "→ Skipping bucket policy helper (couldn’t infer bucket name from ORIGIN_DOMAIN)."
  fi
fi

############################################
# === Route 53: create/update ALIAS ===
############################################
echo "→ Creating/Updating Route 53 ALIAS for $ALT_DOMAIN → $CF_DOMAIN ..."
# find the hosted zone for the base zone (e.g., juniorbay.com.)
BASE_ZONE="${ALT_DOMAIN#*.}."   # everything after first dot, plus trailing dot
HZ_ID="$(aws route53 list-hosted-zones-by-name --dns-name "$BASE_ZONE" --profile "$PROFILE" \
  --query 'HostedZones[?Name==`'"$BASE_ZONE"'` && Config.PrivateZone==`false`][0].Id' --output text)"

if [[ -z "$HZ_ID" || "$HZ_ID" == "None" ]]; then
  echo "!! Could not find a public hosted zone for $BASE_ZONE. Create the ALIAS manually:"
  echo "   Name: $ALT_DOMAIN  →  Alias to $CF_DOMAIN  (Zone ID: $CF_ZONE_ID)"
else
  # upsert alias A record
  cat > r53.json <<JSON
{
  "Comment": "Alias $ALT_DOMAIN → $CF_DOMAIN",
  "Changes": [{
    "Action": "UPSERT",
    "ResourceRecordSet": {
      "Name": "$ALT_DOMAIN",
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
    --change-batch file://r53.json \
    --profile "$PROFILE" >/dev/null
  echo "   Route 53 alias upserted."
fi

echo "✓ All set. Distribution ID: $DIST_ID"
echo "   Test once Deployed:"
echo "     # CSS (cached by query string)"
echo "     curl -I \"https://$ALT_DOMAIN/?family=Aileron:400,600&family=Quicksand:700&display=swap\""
echo "     # Font binary (long TTL + CORS)"
echo "     curl -I \"https://$ALT_DOMAIN/Aileron/Aileron-Regular.woff2\""

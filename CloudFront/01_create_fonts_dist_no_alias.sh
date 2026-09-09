#!/usr/bin/env bash
set -euo pipefail

# ========= CONFIG (edit if needed) =========
PROFILE=default
ALT_DOMAIN="fonts.juniorbay.com"   # only for logs (no aliases yet)
ORIGIN_NAME="S3-jb-fonts"
ORIGIN_DOMAIN="juniorbay.com"      # custom origin host (not S3 REST)
ORIGIN_PATH="/fonts"

# Managed response headers: CORS-with-preflight + Security
RESP_CORS_SEC="eaab4381-ed33-4a86-88ca-d9558dc6cd63"

# ========= PRECHECKS =========
command -v aws >/dev/null || { echo "aws CLI not found"; exit 1; }
command -v jq  >/dev/null || { echo "jq not found"; exit 1; }

tmpdir="$(mktemp -d)"; trap 'rm -rf "$tmpdir"' EXIT; cd "$tmpdir"

echo "→ Ensuring cache policies..."
# 1) CSS cached by full query string (1h)
CSS_POLICY_ID="$(aws cloudfront list-cache-policies --type custom --profile "$PROFILE" \
  --query 'CachePolicyList.Items[?CachePolicy.CachePolicyConfig.Name==`FontsCSS-ByQuery-1h`].CachePolicy.Id' \
  --output text)"
if [[ -z "$CSS_POLICY_ID" || "$CSS_POLICY_ID" == "None" ]]; then
  CSS_POLICY_ID="$(aws cloudfront create-cache-policy --profile "$PROFILE" --output json \
    --cache-policy-config '{
      "Name":"FontsCSS-ByQuery-1h","Comment":"Cache font CSS by full query",
      "DefaultTTL":3600,"MaxTTL":86400,"MinTTL":0,
      "ParametersInCacheKeyAndForwardedToOrigin":{
        "EnableAcceptEncodingGzip":true,"EnableAcceptEncodingBrotli":true,
        "CookiesConfig":{"CookieBehavior":"none"},
        "HeadersConfig":{"HeaderBehavior":"none"},
        "QueryStringsConfig":{"QueryStringBehavior":"all"}
      }}' | jq -r '.CachePolicy.Id')"
fi

# 2) WOFF2 long TTL (180d)
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

echo "   CSS policy:   $CSS_POLICY_ID"
echo "   WOFF2 policy: $FONTS_POLICY_ID"

# Build origins.json for a **custom origin** (juniorbay.com over HTTPS)
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
      "OriginSslProtocols": { "Quantity": 1, "Items": ["TLSv1.2"] },
      "OriginReadTimeout": 30,
      "OriginKeepaliveTimeout": 5
    },
    "ConnectionAttempts": 3,
    "ConnectionTimeout": 10,
    "OriginShield": { "Enabled": false }
  }]
}
JSON

# Use the **default CF certificate** for now (no aliases yet)
CALLER_REF="fonts-create-$(date +%s)"
cat > dist-config.json <<JSON
{
  "CallerReference": "$CALLER_REF",
  "Aliases": { "Quantity": 0 },
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
    }]
  },
  "CustomErrorResponses": { "Quantity": 0 },
  "Comment": "Fonts distribution (no alias yet) for $ALT_DOMAIN",
  "Logging": { "Enabled": false, "IncludeCookies": false, "Bucket": "", "Prefix": "" },
  "PriceClass": "PriceClass_100",
  "Enabled": true,
  "ViewerCertificate": {
    "CloudFrontDefaultCertificate": true,
    "MinimumProtocolVersion": "TLSv1.2_2021"
  },
  "Restrictions": { "GeoRestriction": { "RestrictionType": "none", "Quantity": 0 } },
  "HttpVersion": "http2",
  "IsIPV6Enabled": true
}
JSON

echo "→ Creating CloudFront distribution (no aliases) ..."
OUT="$(aws cloudfront create-distribution --distribution-config file://dist-config.json --profile "$PROFILE")"
DIST_ID="$(jq -r '.Distribution.Id' <<<"$OUT")"
CF_DOMAIN="$(jq -r '.Distribution.DomainName' <<<"$OUT")"

echo "✓ Created distribution: $DIST_ID"
echo "  CF Domain: $CF_DOMAIN"
echo "Next: run 02_request_txt_verification.sh to claim the alias."

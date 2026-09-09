# STEP 1 — trigger the alias move flow and capture the debug body
DIST=ESTJ95U0UEHYG
ALIAS=fonts.juniorbay.com
PROFILE=default

aws cloudfront associate-alias \
  --target-distribution-id "$DIST" \
  --alias "$ALIAS" \
  --profile "$PROFILE" \
  --output json --debug 1>/dev/null 2> /tmp/cf_alias_debug.txt || true

PROFILE=default
ALIAS=fonts.juniorbay.com

aws cloudfront list-distributions --profile $PROFILE \
  --query "DistributionList.Items[].{Id:Id, Aliases:Aliases.Items, Domain:DomainName}" --output json \
  | jq -r --arg a "$ALIAS" '
      map(select(.Aliases != null and (.Aliases | any(. == $a or test("^\\*\\.juniorbay\\.com$")))))'
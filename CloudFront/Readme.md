# 1) Create distro w/o alias
./01_create_fonts_dist_no_alias.sh
export DIST_ID=<output from step 1>

# 2) Attach cert first (required by CloudFront)
./02a_attach_cert_only.sh --dist-id "$DIST_ID" --alias fonts.juniorbay.com
# (optional) force a specific cert:
# ./02a_attach_cert_only.sh --dist-id "$DIST_ID" --alias fonts.juniorbay.com --acm arn:aws:acm:us-east-1:...:certificate/...

# 3) Request alias + auto-TXT if needed
./02_request_txt_verification.sh --dist-id "$DIST_ID" --apply-txt
# If it created the TXT, wait ~1–5 minutes, then run the same command again until it succeeds.

# 4) Finalize (adds alias to distro config + Route 53 ALIAS)
./03_attach_alias_and_cert.sh --dist-id "$DIST_ID" --alias fonts.juniorbay.com
# (optional) you can also pass --acm here to override which cert is configured

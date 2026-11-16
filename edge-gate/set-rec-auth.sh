#!/usr/bin/env bash
# Copy the recorder's Basic-auth login (BREC_HTTP_BASIC_USER / _PASS in the
# rec-recorder-1 container) into rec_auth for the rec.example.com sign-in page.
# Rerun after changing the recorder password; it signs every session out.
# The values never go into arguments, env vars of other processes, or logs.
set -euo pipefail
set +x
DEST=/opt/1panel/www/common/turnstile/rec_auth
CONTAINER=${1:-rec-recorder-1}

ENVS=$(sudo docker inspect "$CONTAINER" --format '{{range .Config.Env}}{{println .}}{{end}}')
U=$(printf '%s\n' "$ENVS" | sed -n 's/^BREC_HTTP_BASIC_USER=//p')
P=$(printf '%s\n' "$ENVS" | sed -n 's/^BREC_HTTP_BASIC_PASS=//p')
unset ENVS
if [ -z "$U" ] || [ -z "$P" ]; then echo "BREC_HTTP_BASIC_USER/PASS not set on $CONTAINER. Nothing stored."; exit 1; fi
if [[ "$U" == *:* || "$U" =~ [[:space:]] || "$P" =~ [[:space:]] ]]; then
  echo "Username has a colon, or a value has whitespace; the sign-in page cannot use it. Nothing stored."; exit 1
fi

UE=${U//\\/\\\\}; UE=${UE//\"/\\\"}; PE=${P//\\/\\\\}; PE=${PE//\"/\\\"}
CODE=$(printf 'user = "%s:%s"\n' "$UE" "$PE" | curl -s -o /dev/null -w '%{http_code}' -K - http://127.0.0.1:11419/)
if [ "$CODE" != "200" ]; then echo "Recorder answered $CODE to these credentials. Nothing stored."; exit 1; fi

sudo install -m 600 -o root -g root /dev/null "$DEST"
printf '%s:%s\n' "$U" "$P" | sudo tee "$DEST" >/dev/null
unset U P UE PE
echo "Saved to $DEST (root-only). Reloading OpenResty so workers pick it up."
sudo docker exec 1Panel-openresty-XXXX openresty -s reload

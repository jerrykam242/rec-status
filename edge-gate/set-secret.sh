#!/usr/bin/env bash
# Store the Turnstile secret key for sitekey YOUR_TURNSTILE_SITEKEY.
# The secret is typed hidden, checked against Siteverify via stdin, and written
# to a root-only file. It never goes into arguments, env vars, or logs.
set -euo pipefail
set +x
DEST=/opt/1panel/www/common/turnstile/secret

echo "Paste the Turnstile SECRET key (Cloudflare dashboard > Turnstile > widget > Settings),"
read -r -s -p "then press Enter (input is hidden): " TS_SECRET
echo
TS_SECRET="${TS_SECRET//[[:space:]]/}"
if [ -z "$TS_SECRET" ]; then echo "Empty input, nothing stored."; exit 1; fi

# A valid secret answers a dummy token with invalid-input-response, not invalid-input-secret.
RESULT=$(printf 'secret=%s&response=XXXX.DUMMY.TOKEN' "$TS_SECRET" \
  | curl -sS --max-time 10 -H 'Content-Type: application/x-www-form-urlencoded' \
      --data-binary @- https://challenges.cloudflare.com/turnstile/v0/siteverify)
if printf '%s' "$RESULT" | grep -q 'invalid-input-secret'; then
  echo "Cloudflare says this secret is invalid. Nothing stored."; exit 1
fi
if ! printf '%s' "$RESULT" | grep -q 'invalid-input-response'; then
  echo "Unexpected Siteverify reply, nothing stored: $RESULT"; exit 1
fi

sudo install -m 600 -o root -g root /dev/null "$DEST"
printf '%s\n' "$TS_SECRET" | sudo tee "$DEST" >/dev/null
unset TS_SECRET
echo "Secret verified with Cloudflare and saved to $DEST (root-only)."

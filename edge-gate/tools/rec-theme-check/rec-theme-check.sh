#!/bin/bash
# rec.example.com: keep the Carbon theme safe across recorder image updates.
# Runs hourly (rec-theme-check.timer). When the recorder container runs a different image than
# the last check (or with --force), it tests the theme against the new WebUI (check.py):
#   fits   -> theme on  (removes /opt/1panel/www/common/turnstile/rec-theme.off)
#   broken -> theme off (creates rec-theme.off; nginx then serves the recorder's original look)
# nginx checks that file per request, so no reload is needed. Results: journalctl -u rec-theme-check
#   rec-theme-check.sh --force   re-test now      (e.g. after editing theme.css)
#   rec-theme-check.sh --status  show the last result
set -u
T=/opt/1panel/www/common/turnstile
DIR=$T/tools/rec-theme-check
STATE=/var/lib/rec-theme-check
OFF=$T/rec-theme.off
IMG=rec-theme-check:local   # built from the Dockerfile in this folder
mkdir -p "$STATE"

if [ "${1:-}" = "--status" ]; then
  cat "$STATE/last" 2>/dev/null || echo "never checked"
  [ -e "$OFF" ] && echo "theme: OFF ($(cat "$OFF"))" || echo "theme: on"
  exit 0
fi

cur=$(docker inspect rec-recorder-1 --format '{{.Image}}' 2>/dev/null) || { echo "recorder container not running"; exit 0; }
if [ "${1:-}" != "--force" ] && [ "$cur" = "$(cat "$STATE/image" 2>/dev/null)" ]; then exit 0; fi

# A fresh container may still be starting.
for i in $(seq 1 30); do
  code=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:11419/ui/)
  [ "$code" != "000" ] && break; sleep 5
done

out=$(docker run --rm --network host --ipc=host -e REC_AUTH="$(cat $T/rec_auth)" \
  -v "$DIR":/check:ro -v $T/public/rec:/work/rec:ro "$IMG" python /check/check.py 2>&1)
rc=$?
echo "$out"
now=$(date -Is)
case $rc in
  0) rm -f "$OFF"
     echo "$cur" > "$STATE/image"
     echo "$now image ${cur:7:12}: theme fits, theme on" > "$STATE/last" ;;
  1) [[ "$out" == *"RESULT "* ]] || { echo "$now image ${cur:7:12}: check crashed, will retry" > "$STATE/last"; exit 0; }
     echo "$now: WebUI in image ${cur:7:12} no longer matches theme.css" > "$OFF"
     echo "$cur" > "$STATE/image"
     { echo "$now image ${cur:7:12}: theme does NOT fit, switched off. Failed:"; echo "$out" | grep '^FAIL'; } > "$STATE/last"
     echo "theme switched off" >&2; exit 1 ;;
  *) echo "$now image ${cur:7:12}: could not test (rc=$rc), will retry next hour" > "$STATE/last"
     exit 0 ;;   # image not recorded, so the next run tries again
esac

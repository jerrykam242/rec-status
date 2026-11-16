#!/bin/sh
# Stores the OpenList password of the worker's account (rec-request) in
# /etc/rec-status/request-worker.env without showing it, then checks that it logs in.
# usage: sudo /opt/rec-status/set-openlist-password.sh
set -eu
ENV=/etc/rec-status/request-worker.env
[ "$(id -u)" = 0 ] || { echo "run with sudo" >&2; exit 1; }
printf 'OpenList password for rec-request: '
stty -echo; IFS= read -r PW; stty echo; echo
[ -n "$PW" ] || { echo "empty, nothing changed" >&2; exit 1; }
PW="$PW" python3 -I - "$ENV" <<'PY'
import os, sys
path, pw = sys.argv[1], os.environ["PW"]
q = '"' + pw.replace("\\", "\\\\").replace('"', '\\"').replace("$", "\\$").replace("`", "\\`") + '"'
lines = open(path, encoding="utf-8").read().splitlines()
lines = [("OPENLIST_PASSWORD=" + q) if l.startswith("OPENLIST_PASSWORD=") else l for l in lines]
tmp = path + ".tmp"
with open(tmp, "w", encoding="utf-8") as f:
    f.write("\n".join(lines) + "\n")
os.chmod(tmp, 0o640)
os.chown(tmp, 0, __import__("grp").getgrnam("recstatus").gr_gid)
os.replace(tmp, path)
PY
unset PW
# Check the login (as the worker would), without printing the password.
set -a; . "$ENV"; set +a
python3 -I - <<'PY'
import json, os, urllib.request
req = urllib.request.Request(os.environ.get("OPENLIST_URL", "http://127.0.0.1:5244") + "/api/auth/login",
    data=json.dumps({"username": os.environ["OPENLIST_USER"], "password": os.environ["OPENLIST_PASSWORD"]}).encode(),
    headers={"Content-Type": "application/json"})
j = json.loads(urllib.request.urlopen(req, timeout=20).read())
print("OpenList login OK" if j.get("code") == 200 else "OpenList login FAILED: %s" % j.get("message"))
PY

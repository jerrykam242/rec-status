#!/usr/bin/env python3
"""rec-status agent: publishes BililiveRecorder's live state to the public status page.

Runs on the recorder host. Python 3 standard library only.

  * Polls the recorder's REST API (GET /api/room) every POLL_INTERVAL seconds.
  * Listens for the recorder's Webhook v2 (SessionStarted, SessionEnded, FileOpening,
    FileClosed, StreamStarted, StreamEnded) on WEBHOOK_BIND, keeps the last
    EVENT_LIMIT events (persisted in STATE_DIR) and re-polls at once when one arrives.
  * Pushes a trimmed snapshot to PUSH_URL whenever it changes, and at least every
    HEARTBEAT seconds so the page can tell the recorder is alive. Each push is signed:
        X-Ingest-Ts:  unix seconds
        X-Ingest-Sig: hex HMAC-SHA1(PUSH_KEY, ts + "." + body)

Only public facts leave this host: room ids, streamer names, titles, areas, live /
recording state, durations and sizes. No file paths, no credentials, no recorder URLs.

Configuration comes from the environment (see agent.env.example).
"""
import base64
import hashlib
import hmac
import http.client
import json
import logging
import os
import signal
import socket
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

log = logging.getLogger("rec-status")

REC_API = os.environ.get("REC_API", "http://127.0.0.1:11419").rstrip("/")
REC_AUTH = os.environ.get("REC_AUTH", "")  # "user:pass" of the recorder's Basic auth
PUSH_URL = os.environ["PUSH_URL"]
PUSH_KEY = os.environ["PUSH_KEY"].encode()
# Optional: connect straight to this origin IP instead of resolving PUSH_URL's host (skips the
# CDN; TLS is still verified against PUSH_URL's host name). The origin then needs PUSH_EDGE_KEY,
# the header value ESA would otherwise add.
PUSH_CONNECT = os.environ.get("PUSH_CONNECT", "")
PUSH_EDGE_KEY = os.environ.get("PUSH_EDGE_KEY", "")
WEBHOOK_BIND = os.environ.get("WEBHOOK_BIND", "172.19.0.1:2357")
WEBHOOK_TOKEN = os.environ["WEBHOOK_TOKEN"]
STATE_DIR = os.environ.get("STATE_DIR", "/var/lib/rec-status")
POLL_INTERVAL = float(os.environ.get("POLL_INTERVAL", "10"))
HEARTBEAT = float(os.environ.get("HEARTBEAT", "60"))
EVENT_LIMIT = int(os.environ.get("EVENT_LIMIT", "40"))

EVENT_TYPES = {"SessionStarted", "SessionEnded", "FileOpening", "FileClosed",
               "StreamStarted", "StreamEnded"}
# Shown on the page; FileOpening is only used to track sessions.
PUBLIC_EVENTS = EVENT_TYPES - {"FileOpening"}

wake = threading.Event()
lock = threading.Lock()
events = []        # newest first
seen_ids = []      # EventIds already handled (the recorder retries up to 3 times)
session_start = {}  # roomId -> ISO time the current recording session started


def now_iso():
    return datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


def load_state():
    global events, session_start
    try:
        with open(os.path.join(STATE_DIR, "state.json"), encoding="utf-8") as f:
            data = json.load(f)
        events = list(data.get("events", []))[:EVENT_LIMIT]
        session_start = {int(k): v for k, v in data.get("sessionStart", {}).items()}
        seen_ids.extend(e.get("id") for e in events if e.get("id"))
    except FileNotFoundError:
        pass
    except Exception as e:  # corrupt state should never stop the agent
        log.warning("ignoring unreadable state: %s", e)


def save_state():
    path = os.path.join(STATE_DIR, "state.json")
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump({"events": events, "sessionStart": session_start}, f, ensure_ascii=False)
    os.replace(tmp, path)


def to_iso(ts):
    """Recorder timestamps look like 2021-05-14T17:52:44.4960899+08:00 (7 fraction digits)."""
    if not isinstance(ts, str):
        return now_iso()
    try:
        head, _, rest = ts.partition(".")
        if rest:
            i = 0
            while i < len(rest) and rest[i].isdigit():
                i += 1
            ts = head + "." + rest[:min(i, 6)] + rest[i:]
        dt = datetime.fromisoformat(ts.replace("Z", "+00:00"))
        return dt.astimezone(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")
    except ValueError:
        return now_iso()


def handle_event(payload):
    etype = payload.get("EventType")
    eid = payload.get("EventId")
    data = payload.get("EventData") or {}
    if etype not in EVENT_TYPES or not isinstance(data, dict):
        return False
    with lock:
        if eid and eid in seen_ids:
            return True
        if eid:
            seen_ids.append(eid)
            del seen_ids[:-200]
        t = to_iso(payload.get("EventTimestamp"))
        room = int(data.get("RoomId") or 0)
        if etype == "SessionStarted":
            session_start[room] = t
        elif etype == "SessionEnded":
            session_start.pop(room, None)
        if etype in PUBLIC_EVENTS:
            ev = {
                "id": eid,
                "type": etype,
                "t": t,
                "roomId": room,
                "name": str(data.get("Name") or ""),
                "title": str(data.get("Title") or ""),
            }
            if etype == "FileClosed":
                ev["duration"] = round(float(data.get("Duration") or 0), 1)
                ev["size"] = int(data.get("FileSize") or 0)
            events.insert(0, ev)
            del events[EVENT_LIMIT:]
        save_state()
    log.info("webhook %s room %s", etype, data.get("RoomId"))
    wake.set()
    return True


class Hook(BaseHTTPRequestHandler):
    server_version = "rec-status"

    def log_message(self, fmt, *args):
        log.debug("http %s", fmt % args)

    def do_POST(self):
        if self.path != "/hook/" + WEBHOOK_TOKEN:
            self.send_error(404)
            return
        try:
            n = int(self.headers.get("Content-Length") or 0)
            if n <= 0 or n > 65536:
                raise ValueError("bad length")
            payload = json.loads(self.rfile.read(n))
            ok = handle_event(payload)
        except Exception as e:
            log.warning("bad webhook: %s", e)
            self.send_error(400)
            return
        self.send_response(204 if ok else 202)
        self.end_headers()

    def do_GET(self):
        self.send_error(404)


def serve_webhook():
    host, port = WEBHOOK_BIND.rsplit(":", 1)
    while True:
        try:
            srv = ThreadingHTTPServer((host, int(port)), Hook)
            break
        except OSError as e:  # the docker bridge may not exist yet at boot
            log.warning("webhook bind %s failed (%s); retrying in 10 s", WEBHOOK_BIND, e)
            time.sleep(10)
    log.info("webhook listening on %s", WEBHOOK_BIND)
    srv.serve_forever()


def fetch_rooms():
    req = urllib.request.Request(REC_API + "/api/room", headers={"Accept": "application/json"})
    if REC_AUTH:
        req.add_header("Authorization", "Basic " + base64.b64encode(REC_AUTH.encode()).decode())
    with urllib.request.urlopen(req, timeout=10) as r:
        return json.load(r)


def num(v):
    try:
        f = float(v)
        return f if f == f else 0.0  # NaN -> 0
    except (TypeError, ValueError):
        return 0.0


def snapshot(rooms):
    out = []
    now = time.time()
    for r in rooms:
        rid = int(r.get("roomId") or 0)
        stats = r.get("recordingStats") or {}
        item = {
            "roomId": rid,
            "shortId": int(r.get("shortId") or 0),
            "name": r.get("name") or "",
            "title": r.get("title") or "",
            "areaParent": r.get("areaNameParent") or "",
            "areaChild": r.get("areaNameChild") or "",
            "streaming": bool(r.get("streaming")),
            "recording": bool(r.get("recording")),
            "danmaku": bool(r.get("danmakuConnected")),
            "autoRecord": bool(r.get("autoRecord")),
        }
        if item["recording"]:
            dur = num(stats.get("sessionDuration")) / 1000.0  # milliseconds
            with lock:
                start = session_start.get(rid)
                if not start:  # agent started mid-session: derive it once and keep it
                    start = datetime.fromtimestamp(now - dur, timezone.utc).isoformat(
                        timespec="seconds").replace("+00:00", "Z")
                    session_start[rid] = start
            item["session"] = {
                "startedAt": start,
                "duration": round(dur, 1),
                "bytes": int(num(stats.get("totalOutputBytes"))),
                "mbps": round(num((r.get("ioStats") or {}).get("networkMbps")), 2),
            }
        else:
            with lock:
                session_start.pop(rid, None)
        out.append(item)
    # Recording first, then live, then the rest; stable by room id.
    out.sort(key=lambda x: (not x["recording"], not x["streaming"], x["roomId"]))
    return out


class _PinnedHTTPS(http.client.HTTPSConnection):
    """HTTPS to a fixed IP, with SNI and certificate checks for the URL's host name."""

    def __init__(self, host, ip, **kw):
        super().__init__(host, **kw)
        self._ip = ip

    def connect(self):
        sock = socket.create_connection((self._ip, self.port or 443), self.timeout)
        self.sock = self._context.wrap_socket(sock, server_hostname=self.host)


def push(body):
    ts = str(int(time.time()))
    sig = hmac.new(PUSH_KEY, (ts + ".").encode() + body, hashlib.sha1).hexdigest()
    headers = {
        "Content-Type": "application/json",
        "X-Ingest-Ts": ts,
        "X-Ingest-Sig": sig,
        "User-Agent": "rec-status-agent/1",
    }
    if PUSH_EDGE_KEY:
        headers["X-Live-Edge"] = PUSH_EDGE_KEY
    if PUSH_CONNECT:
        u = urllib.parse.urlsplit(PUSH_URL)
        conn = _PinnedHTTPS(u.hostname, PUSH_CONNECT, port=u.port or 443, timeout=15)
        try:
            conn.request("POST", u.path or "/", body=body, headers=headers)
            r = conn.getresponse()
            r.read()
            if r.status >= 300:
                raise OSError("HTTP %d" % r.status)
            return r.status
        finally:
            conn.close()
    req = urllib.request.Request(PUSH_URL, data=body, method="POST", headers=headers)
    with urllib.request.urlopen(req, timeout=15) as r:
        return r.status


def main():
    logging.basicConfig(level=os.environ.get("LOG_LEVEL", "INFO"),
                        format="%(levelname)s %(message)s")
    os.makedirs(STATE_DIR, exist_ok=True)
    load_state()
    threading.Thread(target=serve_webhook, daemon=True).start()
    signal.signal(signal.SIGTERM, lambda *_: os._exit(0))

    last_body_core = None
    last_push = 0.0
    recorder_ok = None
    while True:
        rooms, err = None, None
        try:
            rooms = snapshot(fetch_rooms())
        except (urllib.error.URLError, socket.timeout, ValueError, OSError) as e:
            err = str(e)
        if (err is None) != recorder_ok:
            recorder_ok = err is None
            log.info("recorder API %s", "reachable" if recorder_ok else "unreachable: " + err)

        with lock:
            core = {
                "recorderOnline": err is None,
                "rooms": rooms if rooms is not None else [],
                "events": events,
            }
            core_json = json.dumps(core, ensure_ascii=False, sort_keys=True)
        changed = core_json != last_body_core
        # Session durations tick every poll; only treat state changes as "changed".
        state_key = json.dumps([(r["roomId"], r["streaming"], r["recording"], r["title"],
                                 r["name"], r["danmaku"]) for r in core["rooms"]]
                               + [core["recorderOnline"], [e.get("id") for e in events]],
                               ensure_ascii=False)
        if changed and state_key == getattr(main, "_last_state", None):
            changed = time.time() - last_push >= 30  # refresh stats twice a minute
        if changed or time.time() - last_push >= HEARTBEAT:
            core["updatedAt"] = now_iso()
            core["pollInterval"] = POLL_INTERVAL
            core["heartbeat"] = HEARTBEAT
            body = json.dumps(core, ensure_ascii=False, separators=(",", ":")).encode()
            try:
                push(body)
                last_push = time.time()
                last_body_core = core_json
                main._last_state = state_key
                with lock:
                    save_state()
            except Exception as e:
                log.warning("push failed: %s", e)
        wake.wait(POLL_INTERVAL)
        if wake.is_set():
            wake.clear()
            time.sleep(1.5)  # let the recorder's own state settle after a webhook


if __name__ == "__main__":
    main()

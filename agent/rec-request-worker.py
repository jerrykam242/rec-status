#!/usr/bin/env python3
"""rec-request-worker: handles recording requests from the rec-status page.

Runs on the recorder host next to OpenList. Every POLL seconds it calls the status site's
signed endpoint POST /__agent/sync (HMAC-SHA1 over "ts.body" with PUSH_KEY, pinned to the origin
IP like rec-status-agent). It sends:
  - every ARCHIVE_EVERY seconds, the list of rooms/dates that have recordings (for the form);
  - status updates for the requests it worked on;
and gets back the requests to act on:
  - "new":       email the admin the request with signed 批准 / 拒绝 links  -> "notified"
  - "approved":  make sure the day folder is in the archive storage (OpenList copy,
                 missing files only),
                 create an OpenList share (code, expiry, access limit), email the admin
                 the link                                                      -> "shared"
                 (or "failed", with an email saying why)
Local progress is kept in STATE_DIR/requests.json so a crash or a lost reply never sends an
email twice or creates a second share. Only the standard library is used.
"""
import base64
import datetime
import hashlib
import hmac
import html
import http.client
import json
import logging
import os
import re
import secrets
import smtplib
import socket
import ssl
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from email.message import EmailMessage

E = os.environ
SYNC_URL = E["SYNC_URL"]                      # https://rec-status.example.com/__agent/sync
PUSH_KEY = E["PUSH_KEY"].encode()
PUSH_CONNECT = E.get("PUSH_CONNECT", "")      # origin IP (skips ESA, like the agent)
PUSH_EDGE_KEY = E.get("PUSH_EDGE_KEY", "")
OPENLIST = E.get("OPENLIST_URL", "http://127.0.0.1:5244").rstrip("/")
OL_USER = E.get("OPENLIST_USER", "")
OL_PASS = E.get("OPENLIST_PASSWORD", "")
OL_TOKEN = E.get("OPENLIST_TOKEN", "")         # tests only: a fixed token instead of user/password
LOCAL_ROOT = E.get("LOCAL_ROOT", "/local/openlist").rstrip("/")
# Main archive folder in OpenList: any storage provider mounted there (cloud drive, S3, NAS ...),
# where recordings are synced from LOCAL_ROOT. GDRIVE_ROOT is still read as an older name.
ARCHIVE_ROOT = (E.get("ARCHIVE_ROOT") or E.get("GDRIVE_ROOT") or "/Archive/录播").rstrip("/")
# Further archive folders with the same layout (';'-separated), e.g. older recordings.
EXTRA_ROOTS = [r.rstrip("/") for r in E.get("EXTRA_ROOTS", "").split(";") if r.strip()]
ARCHIVE_ROOTS = [ARCHIVE_ROOT] + EXTRA_ROOTS
SHARE_BASE = E.get("SHARE_BASE", "https://file.example.com").rstrip("/")
SHARE_DAYS = int(E.get("SHARE_DAYS", "7"))
SHARE_MAX_ACCESS = int(E.get("SHARE_MAX_ACCESS", "10"))
ADMIN_EMAIL = E["ADMIN_EMAIL"]
MAIL_MODE = E.get("MAIL_MODE", "none")        # graph | smtp | none (only publish the archive) | file (tests)
MAIL_FROM = E.get("MAIL_FROM", "")
GRAPH_TENANT = E.get("GRAPH_TENANT_ID", "")
GRAPH_CLIENT = E.get("GRAPH_CLIENT_ID", "")
GRAPH_SECRET = E.get("GRAPH_CLIENT_SECRET", "")
# Preferred over a secret: certificate sign-in. The private key stays on this host; only the
# public certificate is uploaded to the Entra app (Certificates & secrets).
GRAPH_CERT_FILE = E.get("GRAPH_CERT_FILE", "")
GRAPH_CERT_KEY = E.get("GRAPH_CERT_KEY", "")
SMTP_HOST = E.get("SMTP_HOST", "smtp.office365.com")
SMTP_PORT = int(E.get("SMTP_PORT", "587"))
SMTP_USER = E.get("SMTP_USER", MAIL_FROM)
SMTP_PASS = E.get("SMTP_PASSWORD", "")
STATE_DIR = E.get("STATE_DIR", "/var/lib/rec-status")
POLL = float(E.get("POLL", "10"))   # short: a visitor may be waiting on the page (request_wait)
ARCHIVE_EVERY = float(E.get("ARCHIVE_EVERY", "600"))
COPY_TIMEOUT = float(E.get("COPY_TIMEOUT", str(6 * 3600)))
ONCE = "--once" in sys.argv
CHECK_MAIL = "--check-mail" in sys.argv   # only fetch a Graph token (no email sent), then exit

CST = datetime.timezone(datetime.timedelta(hours=8))
STATE_FILE = os.path.join(STATE_DIR, "requests.json")
log = logging.getLogger("rec-request")
CONTACT = {"qq": "QQ", "email": "邮箱", "other": "其他"}


# ---------------------------------------------------------------- state
def load_state():
    try:
        with open(STATE_FILE, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def save_state(st):
    tmp = STATE_FILE + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(st, f, ensure_ascii=False)
    os.chmod(tmp, 0o600)
    os.replace(tmp, STATE_FILE)


# ---------------------------------------------------------------- status site
class _PinnedHTTPS(http.client.HTTPSConnection):
    """HTTPS to a fixed IP, with SNI and certificate checks for the URL's host name."""

    def __init__(self, host, ip, **kw):
        super().__init__(host, **kw)
        self._ip = ip

    def connect(self):
        sock = socket.create_connection((self._ip, self.port or 443), self.timeout)
        self.sock = self._context.wrap_socket(sock, server_hostname=self.host)


def sync(payload):
    body = json.dumps(payload, ensure_ascii=False).encode()
    ts = str(int(time.time()))
    sig = hmac.new(PUSH_KEY, (ts + ".").encode() + body, hashlib.sha1).hexdigest()
    headers = {"Content-Type": "application/json", "X-Ingest-Ts": ts, "X-Ingest-Sig": sig,
               "User-Agent": "rec-request-worker/1"}
    if PUSH_EDGE_KEY:
        headers["X-Live-Edge"] = PUSH_EDGE_KEY
    u = urllib.parse.urlsplit(SYNC_URL)
    if u.scheme == "https" and PUSH_CONNECT:
        conn = _PinnedHTTPS(u.hostname, PUSH_CONNECT, port=u.port or 443, timeout=20)
    elif u.scheme == "https":
        conn = http.client.HTTPSConnection(u.hostname, u.port or 443, timeout=20)
    else:
        conn = http.client.HTTPConnection(u.hostname, u.port or 80, timeout=20)
    try:
        conn.request("POST", u.path or "/", body=body, headers=headers)
        r = conn.getresponse()
        data = r.read()
        if r.status != 200:
            raise OSError("sync HTTP %d" % r.status)
        return json.loads(data)
    finally:
        conn.close()


# ---------------------------------------------------------------- OpenList
class OpenListError(Exception):
    pass


class OpenList:
    def __init__(self):
        self.token = OL_TOKEN or None

    def _call(self, method, path, body=None, auth=True):
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(OPENLIST + path, data=data, method=method)
        req.add_header("Content-Type", "application/json")
        if auth:
            req.add_header("Authorization", self.token or "")
        with urllib.request.urlopen(req, timeout=60) as r:
            j = json.loads(r.read())
        return j

    def call(self, method, path, body=None):
        if not self.token:
            self.login()
        j = self._call(method, path, body)
        if j.get("code") == 401:
            self.login()
            j = self._call(method, path, body)
        if j.get("code") != 200:
            raise OpenListError("%s %s: %s" % (method, path, j.get("message")))
        return j.get("data")

    def login(self):
        if OL_TOKEN:
            raise OpenListError("fixed OPENLIST_TOKEN rejected")
        j = self._call("POST", "/api/auth/login", {"username": OL_USER, "password": OL_PASS}, auth=False)
        if j.get("code") != 200:
            raise OpenListError("login failed: %s" % j.get("message"))
        self.token = j["data"]["token"]

    def ls(self, path, refresh=False):
        """Names -> is_dir for a folder, or None if it does not exist."""
        try:
            d = self.call("POST", "/api/fs/list", {"path": path, "refresh": refresh, "page": 1, "per_page": 0})
        except OpenListError as e:
            if "not found" in str(e).lower() or "object not found" in str(e).lower():
                return None
            raise
        return {o["name"]: bool(o.get("is_dir")) for o in (d or {}).get("content") or []}


ROOM_RE = re.compile(r"^(\d+)[-_](.+)$")          # '<roomId>-<name>' or '<roomId>_<name>'
DATE_DIR_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
VIDEO_EXT = (".flv", ".mp4", ".mkv", ".ts", ".m4v")
# Dates in loose file names: 录制-<room>-YYYYMMDD-HHMMSS…  or  …YYYY_MM_DD_HH_MM_SS…
FILE_DATE_RES = (re.compile(r"录制-\d+-(\d{4})(\d{2})(\d{2})-\d{6}"),
                 re.compile(r"(?:^|_)(\d{4})_(\d{2})_(\d{2})_\d{2}_\d{2}_\d{2}"))


def room_dirs(ol, root, refresh):
    """{roomId: (folder name, display name)} for room folders in root."""
    out = {}
    for name, is_dir in (ol.ls(root, refresh) or {}).items():
        m = ROOM_RE.match(name)
        if is_dir and m:
            out[m.group(1)] = (name, m.group(2))
    return out


def is_date(s):
    if not DATE_DIR_RE.match(s):
        return False
    try:
        datetime.date.fromisoformat(s)
        return True
    except ValueError:
        return False


def file_date(name):
    if not name.lower().endswith(VIDEO_EXT):
        return None
    for rx in FILE_DATE_RES:
        m = rx.search(name)
        if m:
            d = "%s-%s-%s" % m.groups()
            return d if is_date(d) else None
    return None


def room_items(ol, root, folder, refresh):
    """{date: [paths]} in one room folder: date folders, plus loose video files dated by name."""
    out = {}
    base = root + "/" + folder
    for name, is_dir in (ol.ls(base, refresh) or {}).items():
        d = name if (is_dir and is_date(name)) else (None if is_dir else file_date(name))
        if d:
            out.setdefault(d, []).append(base + "/" + name)
    return out


def build_index(ol, refresh, only_room=None):
    """{roomId: {"name":, "folders": {root: folder}, "dates": {date: [paths in the archive]},
    "local": {date}}} across ARCHIVE_ROOTS and LOCAL_ROOT."""
    rooms = {}
    for root in ARCHIVE_ROOTS + [LOCAL_ROOT]:
        for rid, (folder, disp) in room_dirs(ol, root, refresh).items():
            if only_room and rid != only_room:
                continue
            r = rooms.setdefault(rid, {"name": disp, "folders": {}, "dates": {}, "local": set()})
            if root == ARCHIVE_ROOT:
                r["name"] = disp          # the live recorder's own naming wins
            r["folders"][root] = folder
            for d, paths in room_items(ol, root, folder, refresh).items():
                if root == LOCAL_ROOT:
                    r["local"].add(d)
                else:
                    r["dates"].setdefault(d, []).extend(paths)
    return rooms


def build_archive(ol):
    """Rooms and dates (before today, Beijing time) that have recordings."""
    today = datetime.datetime.now(CST).date().isoformat()
    out = []
    for rid, r in build_index(ol, refresh=True).items():
        dates = sorted(d for d in set(r["dates"]) | r["local"] if d < today)
        if dates:
            out.append({"roomId": rid, "name": r["name"], "dates": dates})
    out.sort(key=lambda r: r["roomId"])
    return {"rooms": out}


# ---------------------------------------------------------------- mail
_graph_token = {"value": None, "exp": 0}


def _b64u(b):
    return base64.urlsafe_b64encode(b).rstrip(b"=").decode()


def _client_assertion(aud):
    """JWT signed with the certificate's private key (RS256, via openssl), for Entra ID."""
    with open(GRAPH_CERT_FILE, encoding="ascii") as f:
        pem = f.read()
    der = base64.b64decode("".join(l for l in pem.splitlines() if l and not l.startswith("-----")))
    header = {"alg": "RS256", "typ": "JWT", "x5t": _b64u(hashlib.sha1(der).digest()),
              "x5t#S256": _b64u(hashlib.sha256(der).digest())}
    now = int(time.time())
    claims = {"aud": aud, "iss": GRAPH_CLIENT, "sub": GRAPH_CLIENT, "jti": secrets.token_hex(16),
              "nbf": now - 60, "iat": now - 60, "exp": now + 600}
    signing_input = (_b64u(json.dumps(header, separators=(",", ":")).encode()) + "." +
                     _b64u(json.dumps(claims, separators=(",", ":")).encode()))
    sig = subprocess.run(["openssl", "dgst", "-sha256", "-sign", GRAPH_CERT_KEY],
                         input=signing_input.encode(), capture_output=True, check=True, timeout=30).stdout
    return signing_input + "." + _b64u(sig)


def _graph_access_token():
    if _graph_token["value"] and time.time() < _graph_token["exp"] - 120:
        return _graph_token["value"]
    url = "https://login.microsoftonline.com/%s/oauth2/v2.0/token" % urllib.parse.quote(GRAPH_TENANT)
    form = {"client_id": GRAPH_CLIENT, "scope": "https://graph.microsoft.com/.default",
            "grant_type": "client_credentials"}
    if GRAPH_CERT_KEY:
        form["client_assertion_type"] = "urn:ietf:params:oauth:client-assertion-type:jwt-bearer"
        form["client_assertion"] = _client_assertion(url)
    else:
        form["client_secret"] = GRAPH_SECRET
    data = urllib.parse.urlencode(form).encode()
    with urllib.request.urlopen(urllib.request.Request(url, data=data), timeout=30) as r:
        j = json.loads(r.read())
    _graph_token.update(value=j["access_token"], exp=time.time() + int(j.get("expires_in", 3600)))
    return _graph_token["value"]


def send_mail(subject, html_body, text_body):
    if MAIL_MODE == "graph":
        msg = {"message": {"subject": subject, "body": {"contentType": "HTML", "content": html_body},
                           "toRecipients": [{"emailAddress": {"address": ADMIN_EMAIL}}]},
               "saveToSentItems": False}   # no copies of request details left in the sender mailbox
        url = "https://graph.microsoft.com/v1.0/users/%s/sendMail" % urllib.parse.quote(MAIL_FROM)
        req = urllib.request.Request(url, data=json.dumps(msg).encode(), method="POST")
        req.add_header("Authorization", "Bearer " + _graph_access_token())
        req.add_header("Content-Type", "application/json")
        with urllib.request.urlopen(req, timeout=30) as r:
            if r.status not in (200, 202):
                raise OSError("Graph sendMail HTTP %d" % r.status)
    elif MAIL_MODE == "smtp":
        m = EmailMessage()
        m["Subject"], m["From"], m["To"] = subject, MAIL_FROM, ADMIN_EMAIL
        m.set_content(text_body)
        m.add_alternative(html_body, subtype="html")
        with smtplib.SMTP(SMTP_HOST, SMTP_PORT, timeout=30) as s:
            s.starttls(context=ssl.create_default_context())
            s.login(SMTP_USER, SMTP_PASS)
            s.send_message(m)
    else:  # file: for testing, write the message to STATE_DIR/outbox
        d = os.path.join(STATE_DIR, "outbox")
        os.makedirs(d, mode=0o700, exist_ok=True)
        name = "%d-%s.html" % (time.time() * 1000, secrets.token_hex(3))
        with open(os.path.join(d, name), "w", encoding="utf-8") as f:
            f.write("<!-- To: %s | Subject: %s -->\n%s" % (ADMIN_EMAIL, subject, html_body))
    log.info("mail sent (%s): %s", MAIL_MODE, subject)


def _rows(r, extra=()):
    rows = [("请求编号", r["id"]), ("称呼", r["name"]),
            ("直播间", "%s（%s）" % (r.get("roomName") or "", r["roomId"])), ("日期", r["date"]),
            ("联系方式", "%s：%s" % (CONTACT.get(r.get("contactType"), ""), r["contact"])),
            ("备注", r.get("note") or "—"),
            ("提交时间", datetime.datetime.fromtimestamp(r["created"], CST).strftime("%Y-%m-%d %H:%M") + "（北京时间）")]
    return rows + list(extra)


def _mail_html(title, intro, rows, buttons=()):
    tr = "".join(
        '<tr><td style="padding:8px 16px 8px 0;color:#525252;white-space:nowrap;vertical-align:top">%s</td>'
        '<td style="padding:8px 0;color:#161616">%s</td></tr>' % (html.escape(k), html.escape(str(v)))
        for k, v in rows)
    btn = "".join(
        '<a href="%s" style="display:inline-block;margin:0 8px 8px 0;padding:12px 24px;background:%s;'
        'color:#ffffff;text-decoration:none;font-size:14px">%s</a>' % (html.escape(u, quote=True), c, html.escape(t))
        for t, u, c in buttons)
    return ('<div style="font-family:\'IBM Plex Sans\',\'PingFang SC\',\'Microsoft YaHei\',Arial,sans-serif;'
            'font-size:14px;line-height:20px;color:#161616;max-width:600px">'
            '<h1 style="font-size:20px;font-weight:400;margin:0 0 16px">%s</h1><p style="margin:0 0 16px">%s</p>'
            '<table style="border-collapse:collapse;margin:0 0 24px">%s</table>%s'
            '<p style="margin:24px 0 0;color:#6f6f6f;font-size:12px">rec-status · 录播请求</p></div>'
            % (html.escape(title), html.escape(intro), tr, btn))


def _mail_text(intro, rows, links=()):
    return "\n".join([intro, ""] + ["%s：%s" % (k, v) for k, v in rows] + [""] + ["%s：%s" % l for l in links])


def mail_new(r):
    rows = _rows(r)
    exp = datetime.datetime.fromtimestamp(r["reviewExpires"], CST).strftime("%Y-%m-%d %H:%M")
    intro = "收到一个新的录播请求。审核链接有效至 %s（北京时间），打开后需再次确认。" % exp
    if r.get("waitUntil") and r["waitUntil"] > time.time():
        intro += ("申请人的页面会等待到 %s（北京时间）：在此之前批准，下载链接会直接显示给申请人；"
                  "之后批准则需要你转发链接。" % datetime.datetime.fromtimestamp(r["waitUntil"], CST).strftime("%H:%M"))
    send_mail("新录播请求 %s：%s %s" % (r["id"], r.get("roomName") or r["roomId"], r["date"]),
              _mail_html("新录播请求", intro, rows, [("批准", r["approveUrl"], "#0f62fe"), ("拒绝", r["denyUrl"], "#da1e28")]),
              _mail_text(intro, rows, [("批准", r["approveUrl"]), ("拒绝", r["denyUrl"])]))


def share_text(r, sh):
    """Plain text the admin can paste to the requester as it is (also shown on the waiting page)."""
    room = r.get("roomName") or r["roomId"]
    return "\n".join([
        "%s，你好！你申请的录播已经准备好了：" % r["name"],
        "",
        "直播间：%s（%s）" % (room, r["roomId"]),
        "日期：%s" % r["date"],
        "链接：%s" % sh["url"],
        "提取码：%s" % sh["pwd"],
        "有效期至：%s，最多 %d 次访问" % (sh["expiresText"], SHARE_MAX_ACCESS),
        "",
        "用浏览器打开链接，先完成人机验证，再输入提取码，即可查看文件列表并下载。"
        "同一网络 30 分钟内重复打开只计 1 次访问。",
        "录像仅供个人观看，请勿转发链接或二次上传。",
        "",
        "请求编号：%s" % r["id"],
    ])


def mail_shared(r, sh):
    rows = _rows(r, [("下载链接", sh["url"]), ("提取码", sh["pwd"]), ("有效期至", sh["expiresText"]),
                     ("访问次数上限", "%d 次" % SHARE_MAX_ACCESS)])
    shown = r.get("decided") and r.get("waitUntil") and r["decided"] <= r["waitUntil"]
    intro = ("下载链接已生成，并已显示在申请人的页面上；如申请人已离开页面，可将下方文字转发给申请人。" if shown
             else "下载链接已生成。可将下方文字直接转发给申请人。")
    text = share_text(r, sh)
    block = ('<p style="margin:0 0 8px;color:#525252">可直接转发给申请人：</p>'
             '<pre style="margin:0 0 24px;padding:16px;background:#f4f4f4;border-left:3px solid #0f62fe;'
             'white-space:pre-wrap;font-family:inherit;font-size:14px;line-height:22px;color:#161616">%s</pre>'
             % html.escape(text))
    body = _mail_html("录播链接已生成", intro, rows, [("打开下载链接", sh["url"], "#0f62fe")])
    body = body.replace('<p style="margin:24px 0 0;color:#6f6f6f;font-size:12px">', block + '<p style="margin:24px 0 0;color:#6f6f6f;font-size:12px">', 1)
    send_mail("录播链接已生成 %s：%s %s" % (r["id"], r.get("roomName") or r["roomId"], r["date"]),
              body, _mail_text(intro, rows) + "\n\n—— 可直接转发给申请人 ——\n\n" + text)


def mail_failed(r, why):
    rows = _rows(r, [("原因", why)])
    intro = "录播请求已批准，但处理失败，请手动处理。"
    send_mail("录播请求处理失败 %s" % r["id"], _mail_html("录播请求处理失败", intro, rows), _mail_text(intro, rows))


# ---------------------------------------------------------------- request processing
class Fail(Exception):
    """Permanent failure: the request is marked failed and the admin told why."""


def missing_files(ol, folder, date):
    """Files in the local day folder that the live archive (ARCHIVE_ROOT) lacks."""
    local = ol.ls("%s/%s/%s" % (LOCAL_ROOT, folder, date), refresh=True) or {}
    gd = ol.ls("%s/%s/%s" % (ARCHIVE_ROOT, folder, date), refresh=True) or {}
    return sorted({n for n, d in local.items() if not d} - {n for n, d in gd.items() if not d})


def copy_failures(ol, since):
    try:
        done = ol.call("GET", "/api/task/copy/done") or []
    except OpenListError:
        return []
    out = []
    for t in done:
        try:
            started = datetime.datetime.fromisoformat(str(t.get("start_time")).replace("Z", "+00:00")).timestamp()
        except ValueError:
            started = 0
        # tache states: 2 succeeded, 4 canceled, 7 failed. Only tasks started for this request count.
        if started >= since - 5 and t.get("state") in (4, 7):
            out.append(t.get("error") or t.get("name") or "copy failed")
    return out


def process(ol, r, loc):
    """Advance one approved request; returns the status to report, or None for no change yet."""
    date = r["date"]
    room = build_index(ol, refresh=False, only_room=r["roomId"]).get(r["roomId"])
    if not room:
        raise Fail("找不到该直播间的录像文件夹")
    local_folder = room["folders"].get(LOCAL_ROOT)
    # Recordings still only on this host: copy the day folder into the live archive first.
    if not loc.get("copied") and local_folder and date in room["local"]:
        missing = missing_files(ol, local_folder, date)
        if missing:
            folder = room["folders"].get(ARCHIVE_ROOT, local_folder)
            if not loc.get("copyStarted"):
                if ol.ls("%s/%s" % (ARCHIVE_ROOT, folder)) is None:
                    ol.call("POST", "/api/fs/mkdir", {"path": "%s/%s" % (ARCHIVE_ROOT, folder)})
                ol.call("POST", "/api/fs/copy", {
                    "src_dir": "%s/%s" % (LOCAL_ROOT, local_folder), "dst_dir": "%s/%s" % (ARCHIVE_ROOT, folder),
                    "names": [date], "merge": True, "skip_existing": True})
                loc["copyStarted"] = time.time()
                log.info("%s: copying %d file(s) to the archive", r["id"], len(missing))
            elif time.time() - loc["copyStarted"] > COPY_TIMEOUT:
                raise Fail("复制到存档存储超时（仍缺 %d 个文件）" % len(missing))
            else:
                undone = ol.call("GET", "/api/task/copy/undone") or []
                if not undone:
                    errs = copy_failures(ol, loc["copyStarted"])
                    if errs:
                        raise Fail("复制到存档存储失败：" + "; ".join(errs)[:200])
                    loc["copyStarted"] = None     # finished but files still missing: another pass
            return "processing"
    loc["copied"] = True
    if not loc.get("share"):
        room = build_index(ol, refresh=True, only_room=r["roomId"]).get(r["roomId"]) or room
        # One entry per name (a share lists items by name); ARCHIVE_ROOT comes first, so it wins.
        files, seen = [], set()
        for path in room["dates"].get(date, []):
            base = path.rsplit("/", 1)[-1]
            if base not in seen:
                seen.add(base)
                files.append(path)
        if not files:
            raise Fail("存档存储中没有该日期的录像文件")
        loc["files"] = files
        exp = datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(days=SHARE_DAYS)
        pwd = "".join(secrets.choice("abcdefghjkmnpqrstuvwxyz23456789") for _ in range(6))
        d = ol.call("POST", "/api/share/create", {
            "files": loc["files"],
            "expires": exp.strftime("%Y-%m-%dT%H:%M:%SZ"), "pwd": pwd,
            "max_accessed": SHARE_MAX_ACCESS, "remark": "rec-status %s" % r["id"]})
        loc["share"] = {
            "id": d["id"], "pwd": pwd, "url": "%s/@s/%s" % (SHARE_BASE, d["id"]), "expires": int(exp.timestamp()),
            "expiresText": exp.astimezone(CST).strftime("%Y-%m-%d %H:%M") + "（北京时间）"}
        log.info("%s: share %s created", r["id"], d["id"])
    if not loc.get("mailedShared"):
        mail_shared(r, loc["share"])
        loc["mailedShared"] = True
    return "shared"


def cleanup_shares(ol):
    """Delete this worker's shares once expired (privacy policy: share access records end with the link)."""
    now = datetime.datetime.now(datetime.timezone.utc)
    page = 1
    while True:
        d = ol.call("GET", "/api/share/list?page=%d&per_page=100" % page) or {}
        items = d.get("content") or []
        for sh in items:
            if not str(sh.get("remark") or "").startswith("rec-status "):
                continue
            try:
                exp = datetime.datetime.fromisoformat(str(sh.get("expires")).replace("Z", "+00:00"))
            except ValueError:
                continue
            if exp < now:
                ol.call("POST", "/api/share/delete?id=%s" % urllib.parse.quote(str(sh["id"])))
                log.info("expired share %s deleted", sh["id"])
        if len(items) < 100:
            return
        page += 1


def tick(ol, st, last_archive):
    payload = {"updates": st.get("pending", [])}
    archive = None
    if time.time() - last_archive >= ARCHIVE_EVERY:
        archive = build_archive(ol)
        try:
            cleanup_shares(ol)
        except Exception:
            log.exception("share cleanup failed; will retry")
        payload["archive"] = archive
    resp = sync(payload)
    st["pending"] = []
    reqs = st.setdefault("requests", {})
    updates = []
    if MAIL_MODE == "none":   # mail not set up yet: leave requests waiting
        if resp.get("requests"):
            log.warning("%d request(s) waiting; MAIL_MODE=none", len(resp["requests"]))
        save_state(st)
        return archive is not None
    for r in resp.get("requests", []):
        loc = reqs.setdefault(r["id"], {})
        try:
            if r["status"] == "new":
                if not loc.get("mailedNew"):
                    mail_new(r)
                    loc["mailedNew"] = True
                updates.append({"id": r["id"], "status": "notified"})
            elif r["status"] in ("approved", "processing"):
                new = process(ol, r, loc)
                if new == "shared":
                    sh = loc["share"]
                    updates.append({"id": r["id"], "status": "shared", "note": "share " + sh["id"],
                                    "share": {"url": sh["url"], "pwd": sh["pwd"], "maxAccess": SHARE_MAX_ACCESS,
                                              "expires": sh.get("expires") or int(time.time() + SHARE_DAYS * 86400)}})
                elif r["status"] == "approved":
                    updates.append({"id": r["id"], "status": "processing"})
        except Fail as e:
            log.warning("%s: failed: %s", r["id"], e)
            if not loc.get("mailedFailed"):
                try:
                    mail_failed(r, str(e))
                    loc["mailedFailed"] = True
                except Exception:
                    log.exception("%s: failure mail not sent", r["id"])
            updates.append({"id": r["id"], "status": "failed", "note": str(e)[:300]})
        except Exception:
            log.exception("%s: will retry", r["id"])
        save_state(st)
    # Forget local progress for requests the site no longer lists as active, after a while.
    active = {r["id"] for r in resp.get("requests", [])}
    for rid in list(reqs):
        if rid not in active:
            reqs[rid].setdefault("inactiveSince", time.time())
            if time.time() - reqs[rid]["inactiveSince"] > 40 * 86400:
                del reqs[rid]
        else:
            reqs[rid].pop("inactiveSince", None)
    if updates:
        st["pending"] = updates
        try:
            sync({"updates": updates})
            st["pending"] = []
        except Exception:
            log.exception("status update failed; will resend")
    save_state(st)
    return archive is not None


def main():
    logging.basicConfig(level=E.get("LOG_LEVEL", "INFO"), format="%(levelname)s %(message)s")
    if CHECK_MAIL:
        tok = _graph_access_token()
        claims = json.loads(base64.urlsafe_b64decode(tok.split(".")[1] + "==="))
        print("Graph token OK; roles:", claims.get("roles"), "app:", claims.get("app_displayname"))
        return
    os.makedirs(STATE_DIR, exist_ok=True)
    ol = OpenList()
    st = load_state()
    last_archive = 0.0
    while True:
        try:
            if tick(ol, st, last_archive):
                last_archive = time.time()
        except Exception:
            log.exception("tick failed")
        if ONCE:
            return
        time.sleep(POLL)


if __name__ == "__main__":
    main()

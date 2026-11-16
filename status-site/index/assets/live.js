// Live recorder status page: polls /api/status and renders it with Carbon components.
// All data goes into the page through textContent / attributes, never innerHTML.
(function () {
  "use strict";
  var POLL_MS = 10000;
  var $ = function (id) { return document.getElementById(id); };

  var state = { snap: null, receivedAt: 0, skew: 0, failures: 0 };

  var EVENT_LABEL = {
    StreamStarted: ["开播", "blue"],
    StreamEnded: ["下播", "gray"],
    SessionStarted: ["开始录制", "red"],
    SessionEnded: ["停止录制", "cool-gray"],
    FileClosed: ["文件已保存", "teal"]
  };

  // ---------- formatting ----------
  function pad(n) { return (n < 10 ? "0" : "") + n; }
  function hms(sec) {
    sec = Math.max(0, Math.floor(sec));
    var h = Math.floor(sec / 3600), m = Math.floor(sec % 3600 / 60), s = sec % 60;
    return (h ? h + ":" + pad(m) : m) + ":" + pad(s);
  }
  function longDuration(sec) {
    sec = Math.max(0, Math.round(sec));
    var h = Math.floor(sec / 3600), m = Math.floor(sec % 3600 / 60), s = sec % 60;
    if (h) return h + " 小时 " + m + " 分";
    if (m) return m + " 分 " + s + " 秒";
    return s + " 秒";
  }
  function bytes(n) {
    if (!n) return "0 B";
    var u = ["B", "KB", "MB", "GB", "TB"], i = 0;
    while (n >= 1024 && i < u.length - 1) { n /= 1024; i++; }
    return (i ? n.toFixed(n >= 100 ? 0 : n >= 10 ? 1 : 2) : n) + " " + u[i];
  }
  var timeFmt = new Intl.DateTimeFormat("zh-CN", { hour: "2-digit", minute: "2-digit", hour12: false });
  var dayFmt = new Intl.DateTimeFormat("zh-CN", { month: "numeric", day: "numeric" });
  var fullFmt = new Intl.DateTimeFormat("zh-CN", { dateStyle: "medium", timeStyle: "medium", hour12: false });
  function when(iso) {
    var d = new Date(iso);
    if (isNaN(d)) return "";
    var now = new Date();
    var sameDay = d.toDateString() === now.toDateString();
    var y = new Date(now); y.setDate(now.getDate() - 1);
    var prefix = sameDay ? "今天 " : d.toDateString() === y.toDateString() ? "昨天 " : dayFmt.format(d) + " ";
    return prefix + timeFmt.format(d);
  }
  function ago(sec) {
    sec = Math.max(0, Math.round(sec));
    if (sec < 10) return "刚刚";
    if (sec < 60) return sec + " 秒前";
    if (sec < 3600) return Math.floor(sec / 60) + " 分钟前";
    return Math.floor(sec / 3600) + " 小时前";
  }
  function serverNow() { return Date.now() / 1000 + state.skew; }

  // ---------- small DOM helpers ----------
  function el(tag, cls, text) {
    var e = document.createElement(tag);
    if (cls) e.className = cls;
    if (text != null) e.textContent = text;
    return e;
  }
  function tag(text, color, extra) {
    var t = el("span", "cds--tag cds--tag--sm cds--tag--" + color + (extra ? " " + extra : ""));
    t.appendChild(el("span", "cds--tag__label", text));
    return t;
  }
  function area(r) {
    return [r.areaParent, r.areaChild].filter(Boolean).join(" · ");
  }
  function liveUrl(r) { return "https://live.bilibili.com/" + (r.shortId || r.roomId); }

  // ---------- rendering ----------
  function renderHero(snap) {
    var rooms = snap ? snap.rooms : [];
    var rec = rooms.filter(function (r) { return r.recording; });
    var live = rooms.filter(function (r) { return r.streaming && !r.recording; });
    var h = $("headline"), sub = $("subline"), eyebrow = $("eyebrow");
    h.textContent = "";
    document.body.classList.toggle("is-recording", rec.length > 0);
    if (!snap) {
      h.textContent = "暂无状态数据";
      sub.textContent = "尚未收到录播机的状态信息。";
      eyebrow.textContent = "录制状态";
      return;
    }
    if (rec.length === 1) {
      var r = rec[0];
      eyebrow.textContent = "正在录制";
      h.appendChild(document.createTextNode(r.name || ("直播间 " + r.roomId)));
      sub.textContent = r.title ? "直播标题：" + r.title : "";
    } else if (rec.length > 1) {
      eyebrow.textContent = "正在录制";
      h.textContent = rec.map(function (r) { return r.name; }).join("、");
      sub.textContent = "共 " + rec.length + " 个直播间正在录制";
    } else if (live.length) {
      eyebrow.textContent = "直播中（未录制）";
      h.textContent = live.map(function (r) { return r.name; }).join("、");
      sub.textContent = "直播进行中，当前未进行录制。";
    } else {
      eyebrow.textContent = "待机";
      h.textContent = "当前无录制任务";
      sub.textContent = rooms.length ? "已监控 " + rooms.length + " 个直播间，开播后将自动录制。" : "尚未添加直播间。";
    }
  }

  function renderRooms(snap) {
    var list = $("rooms");
    var tpl = $("tpl-room");
    list.textContent = "";
    list.removeAttribute("aria-busy");
    var rooms = snap ? snap.rooms : [];
    var recN = rooms.filter(function (r) { return r.recording; }).length;
    var liveN = rooms.filter(function (r) { return r.streaming; }).length;
    $("rooms-meta").textContent = rooms.length ? "共 " + rooms.length + " 个 · 直播中 " + liveN + " 个 · 录制中 " + recN + " 个" : "";
    if (!rooms.length) {
      var empty = el("li", "cds--tile live-room live-room--empty", snap ? "尚未添加直播间。" : "正在获取数据");
      list.appendChild(empty);
      return;
    }
    rooms.forEach(function (r) {
      var node = tpl.content.firstElementChild.cloneNode(true);
      node.classList.toggle("live-room--recording", r.recording);
      node.classList.toggle("live-room--live", r.streaming && !r.recording);
      node.setAttribute("data-room", r.roomId);
      var tags = node.querySelector(".live-room__tags");
      if (r.recording) tags.appendChild(tag("录制中", "red", "live-tag-rec"));
      else if (r.streaming) tags.appendChild(tag("直播中", "blue"));
      else tags.appendChild(tag("未开播", "cool-gray"));
      if (area(r)) tags.appendChild(tag(area(r), "gray"));

      node.querySelector(".live-room__name").textContent = r.name || "直播间 " + r.roomId;
      var title = node.querySelector(".live-room__title");
      title.textContent = r.title || "（未设置标题）";
      title.title = r.title || "";

      var stats = node.querySelector(".live-room__stats");
      var note = node.querySelector(".live-room__note");
      if (r.recording && r.session) {
        stats.hidden = false;
        stats.querySelector('[data-k="elapsed"]').setAttribute("data-start", r.session.startedAt || "");
        stats.querySelector('[data-k="bytes"]').textContent = bytes(r.session.bytes);
        stats.querySelector('[data-k="mbps"]').textContent = r.session.mbps ? r.session.mbps.toFixed(1) + " Mbps" : "—";
        note.textContent = r.session.startedAt ? "录制开始时间：" + when(r.session.startedAt) : "";
      } else if (r.streaming) {
        note.textContent = r.autoRecord ? "已开播，即将开始录制。" : "已开播，该直播间未启用自动录制。";
      } else {
        note.textContent = r.autoRecord ? "已启用自动录制" : "未启用自动录制";
      }

      var link = node.querySelector(".live-room__link");
      link.href = liveUrl(r);
      link.querySelector("span").textContent = "直播间 " + (r.shortId || r.roomId);
      link.setAttribute("aria-label", "在新窗口中打开" + (r.name || "") + "的哔哩哔哩直播间");
      list.appendChild(node);
    });
    tick();
  }

  function renderEvents(snap) {
    var body = $("events");
    body.textContent = "";
    var events = (snap && snap.events) || [];
    if (!events.length) {
      var tr = el("tr");
      var td = el("td", "live-events__empty", snap ? "暂无记录。" : "—");
      td.colSpan = 4;
      tr.appendChild(td);
      body.appendChild(tr);
      return;
    }
    events.slice(0, 20).forEach(function (e) {
      var tr = el("tr");
      var t = el("td", "live-mono live-nowrap");
      var time = el("time", null, when(e.t));
      time.dateTime = e.t;
      time.title = fullFmt.format(new Date(e.t));
      t.appendChild(time);
      tr.appendChild(t);
      tr.appendChild(el("td", "live-nowrap", e.name || String(e.roomId)));
      var lab = EVENT_LABEL[e.type] || [e.type, "gray"];
      var c = el("td");
      c.appendChild(tag(lab[0], lab[1]));
      tr.appendChild(c);
      var detail = "";
      if (e.type === "FileClosed") detail = "时长 " + longDuration(e.duration || 0) + "，大小 " + bytes(e.size || 0);
      else detail = e.title || "";
      var d = el("td", "live-col-detail live-events__detail", detail);
      d.title = detail;
      tr.appendChild(d);
      body.appendChild(tr);
    });
  }

  function notice(kind, title, text) {
    var box = $("notice");
    box.textContent = "";
    if (!kind) return;
    var n = $("tpl-notice").content.firstElementChild.cloneNode(true);
    n.classList.add("cds--inline-notification--" + kind);
    if (kind === "error") n.setAttribute("role", "alert");
    n.querySelector(".cds--inline-notification__title").textContent = title;
    n.querySelector(".cds--inline-notification__subtitle").textContent = text;
    box.appendChild(n);
  }

  function renderHealth() {
    var snap = state.snap;
    if (state.failures >= 3 && !snap) {
      notice("error", "无法连接状态服务", "页面将自动重试。");
      return;
    }
    if (!snap) { notice(null); return; }
    var age = serverNow() - state.receivedAt;
    var limit = Math.max(180, (snap.heartbeat || 60) * 3);
    if (age > limit) {
      notice("warning", "状态信息可能已过期", "录播机已 " + ago(age).replace("前", "") + "未上报状态，以下为最后一次收到的数据。");
    } else if (snap.recorderOnline === false) {
      notice("error", "录播机无响应", "以下状态可能不准确。");
    } else if (state.failures >= 3) {
      notice("warning", "连接中断", "暂时无法刷新状态，页面将自动重试。");
    } else {
      notice(null);
    }
  }

  function renderFooter() {
    var p = $("updated");
    if (!state.snap) { p.textContent = state.failures ? "连接失败，正在重试" : "正在连接"; return; }
    p.textContent = "最后更新：" + ago(serverNow() - state.receivedAt) + " · 每 " + Math.round(POLL_MS / 1000) + " 秒刷新";
  }

  // Ticks every second: recording timers and "x 秒前".
  function tick() {
    var now = serverNow();
    var cells = document.querySelectorAll('[data-k="elapsed"][data-start]');
    for (var i = 0; i < cells.length; i++) {
      var s = Date.parse(cells[i].getAttribute("data-start"));
      cells[i].textContent = isNaN(s) ? "—" : hms(now - s / 1000);
    }
    renderFooter();
  }

  // ---------- polling ----------
  var timer = null;
  function poll() {
    clearTimeout(timer);
    fetch("/api/status", { credentials: "same-origin", cache: "no-store", headers: { Accept: "application/json" } })
      .then(function (res) {
        if (res.status === 401) {
          window.location.replace("/__gate/login");
          return null;
        }
        if (!res.ok) throw new Error("HTTP " + res.status);
        return res.json();
      })
      .then(function (j) {
        if (!j) return;
        state.failures = 0;
        state.skew = (j.serverTime || Date.now() / 1000) - Date.now() / 1000;
        var changed = JSON.stringify(j.data) !== JSON.stringify(state.snap);
        state.snap = j.data;
        state.receivedAt = j.receivedAt || 0;
        if (changed || !document.body.hasAttribute("data-ready")) {
          renderHero(state.snap);
          renderRooms(state.snap);
          renderEvents(state.snap);
          document.body.setAttribute("data-ready", "");
        }
        renderHealth();
        tick();
      })
      .catch(function () {
        state.failures++;
        renderHealth();
        renderFooter();
      })
      .then(function () {
        timer = setTimeout(poll, document.hidden ? POLL_MS * 3 : POLL_MS);
      });
  }
  document.addEventListener("visibilitychange", function () { if (!document.hidden) poll(); });

  // ---------- theme switch ----------
  var toggle = $("theme-toggle");
  function syncToggle() {
    var dark = document.documentElement.getAttribute("data-theme") === "g100";
    var label = dark ? "切换至浅色主题" : "切换至深色主题";
    toggle.setAttribute("aria-label", label);
    toggle.title = label;
  }
  toggle.addEventListener("click", function () {
    var next = document.documentElement.getAttribute("data-theme") === "g100" ? "white" : "g100";
    document.documentElement.setAttribute("data-theme", next);
    try { localStorage.setItem("live.theme", next); } catch (e) {}
    syncToggle();
  });
  syncToggle();

  setInterval(tick, 1000);
  poll();
})();

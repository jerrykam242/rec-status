// Recording request form: loads the rooms/dates that have recordings (/api/archive) and posts
// the request to /api/request. Text is set with textContent only.
(function () {
  "use strict";
  var form = document.getElementById("rq-form");
  if (!form) return;
  var el = function (id) { return document.getElementById(id); };
  var room = el("rq-room"), date = el("rq-date"), ctype = el("rq-ctype"), contact = el("rq-contact");
  var cal = el("rq-cal"), calBody = el("rq-cal-body"), calMonth = el("rq-cal-month");
  var calPrev = el("rq-cal-prev"), calNext = el("rq-cal-next"), picked = el("rq-date-picked");
  var submit = el("rq-submit"), result = el("rq-result");
  var archive = [];

  var CONTACT_HELP = { qq: "请填写 QQ 号码。", email: "请填写邮箱地址。", other: "请注明平台及账号，例如“微信：xxxx”。" };
  var ERRORS = {
    name: "请填写称呼（最多 40 个字符）。",
    room: "请选择直播间。",
    date: "请选择日期。",
    contact: "请填写有效的联系方式。",
    consent: "请勾选同意后再提交。",
    transfer: "请勾选同意个人信息出境后再提交。",
  };
  var SERVER_ERRORS = {
    "rate-limited": "提交过于频繁，请稍后再试。",
    "busy": "当前待处理的请求较多，请稍后再试。",
    "no-recording": "所选日期没有该直播间的录像，请刷新页面后重新选择。",
    "invalid": "表单内容有误，请检查后重新提交。",
    "origin": "请求被拒绝，请刷新页面后重试。",
  };

  function option(value, text) {
    var o = document.createElement("option");
    o.value = value; o.textContent = text;
    return o;
  }
  function fill(sel, items, placeholder) {
    sel.textContent = "";
    sel.appendChild(option("", placeholder));
    items.forEach(function (it) { sel.appendChild(option(it[0], it[1])); });
  }
  function weekday(d) {
    var w = ["日", "一", "二", "三", "四", "五", "六"][new Date(d + "T12:00:00+08:00").getUTCDay()];
    return d + "（周" + w + "）";
  }

  function setError(field, msg) {
    var item = form.querySelector('[data-field="' + field + '"]');
    if (!item) return;
    var input = item.querySelector("input, select, textarea");
    var err = el("rq-" + field + "-error");
    if (msg) {
      item.setAttribute("data-invalid", "");
      if (input) { input.setAttribute("aria-invalid", "true"); input.setAttribute("aria-describedby", "rq-" + field + "-error"); }
      if (input && input.classList.contains("cds--text-input")) input.classList.add("cds--text-input--invalid");
      if (err) err.textContent = msg;
    } else {
      item.removeAttribute("data-invalid");
      if (input) {
        input.removeAttribute("aria-invalid");
        if (el("rq-" + field + "-helper")) input.setAttribute("aria-describedby", "rq-" + field + "-helper"); else input.removeAttribute("aria-describedby");
        input.classList.remove("cds--text-input--invalid");
      }
      if (err) err.textContent = "";
    }
  }

  function showResult(kind, title, text) {
    result.textContent = "";
    if (!kind) return;
    var n = el("tpl-rq-result").content.firstElementChild.cloneNode(true);
    n.classList.add("cds--inline-notification--" + kind);
    if (kind === "error") n.setAttribute("role", "alert");
    if (kind === "success") {  // Carbon CheckmarkFilled
      n.querySelector(".cds--inline-notification__icon path").setAttribute("d",
        "M16,2A14,14,0,1,0,30,16,14,14,0,0,0,16,2ZM14,21.5908l-5-5L10.5906,15,14,18.4092,21.41,11l1.5957,1.5859Z");
    }
    n.querySelector(".cds--inline-notification__title").textContent = title;
    n.querySelector(".cds--inline-notification__subtitle").textContent = text;
    result.appendChild(n);
  }

  function toLogin(res) {
    if (res.status === 401) { window.location.replace("/__gate/login"); return true; }
    return false;
  }

  function loadArchive() {
    fetch("/api/archive", { credentials: "same-origin", cache: "no-store" })
      .then(function (res) {
        if (toLogin(res)) return null;
        if (!res.ok) throw new Error("http " + res.status);
        return res.json();
      })
      .then(function (data) {
        if (!data) return;
        archive = (data.rooms || []).filter(function (r) { return r && r.dates && r.dates.length; });
        if (!archive.length) {
          fill(room, [], "暂无可申请的录像");
          return;
        }
        fill(room, archive.map(function (r) { return [String(r.roomId), r.name + "（" + r.roomId + "）"]; }), "请选择直播间");
        room.disabled = false;
      })
      .catch(function () { fill(room, [], "加载失败，请刷新页面重试"); });
  }

  // ---------- calendar (dates with recordings are selectable) ----------
  var avail = {};        // "YYYY-MM-DD" -> true, for the chosen room
  var months = [];       // "YYYY-MM" with recordings, ascending
  var shown = "";        // month on screen, "YYYY-MM"
  var WD = ["日", "一", "二", "三", "四", "五", "六"];
  function pad(n) { return (n < 10 ? "0" : "") + n; }
  function ym(d) { return d.slice(0, 7); }
  function monthLabel(m) { return m.slice(0, 4) + " 年 " + Number(m.slice(5)) + " 月"; }

  function setDate(d) {
    date.value = d || "";
    picked.textContent = d ? "已选择：" + weekday(d) : "";
    setError("date", "");
    Array.prototype.forEach.call(calBody.querySelectorAll("button"), function (b) {
      b.setAttribute("aria-pressed", b.getAttribute("data-date") === date.value ? "true" : "false");
    });
  }

  function render(m, focusDate) {
    shown = m;
    calMonth.value = m;
    var idx = months.indexOf(m);
    calPrev.disabled = idx <= 0;
    calNext.disabled = idx < 0 || idx >= months.length - 1;
    calBody.textContent = "";
    var y = Number(m.slice(0, 4)), mo = Number(m.slice(5)) - 1;
    var first = new Date(Date.UTC(y, mo, 1)), days = new Date(Date.UTC(y, mo + 1, 0)).getUTCDate();
    var lead = (first.getUTCDay() + 6) % 7;          // weeks start on Monday
    var tabDate = (date.value && ym(date.value) === m) ? date.value : null;
    var row = null;
    for (var c = 0; c < lead + days; c++) {
      if (c % 7 === 0) { row = document.createElement("tr"); calBody.appendChild(row); }
      var td = document.createElement("td");
      if (c >= lead) {
        var day = c - lead + 1, d = m + "-" + pad(day);
        if (avail[d]) {
          var b = document.createElement("button");
          b.type = "button"; b.className = "live-cal__day"; b.textContent = day;
          b.setAttribute("data-date", d);
          b.setAttribute("aria-label", weekday(d) + "，有录像");
          b.setAttribute("aria-pressed", d === date.value ? "true" : "false");
          if (!tabDate) tabDate = d;
          b.tabIndex = d === tabDate ? 0 : -1;
          td.appendChild(b);
        } else {
          var sp = document.createElement("span");
          sp.className = "live-cal__day live-cal__day--off"; sp.textContent = day;
          sp.setAttribute("aria-hidden", "true");
          td.appendChild(sp);
        }
      }
      row.appendChild(td);
    }
    while (row && row.children.length < 7) row.appendChild(document.createElement("td"));
    if (focusDate) {
      var f = calBody.querySelector('[data-date="' + focusDate + '"]');
      if (f) f.focus();
    }
  }

  function step(d, dir) {         // next/previous date with recordings, across months
    var list = Object.keys(avail).sort(), k = list.indexOf(d);
    return list[k + dir] || null;
  }
  function moveTo(d) {
    if (!d) return;
    if (ym(d) !== shown) render(ym(d), d);
    else {
      Array.prototype.forEach.call(calBody.querySelectorAll("button"), function (b) { b.tabIndex = b.getAttribute("data-date") === d ? 0 : -1; });
      calBody.querySelector('[data-date="' + d + '"]').focus();
    }
  }

  calBody.addEventListener("click", function (ev) {
    var b = ev.target.closest("button[data-date]");
    if (b) setDate(b.getAttribute("data-date"));
  });
  calBody.addEventListener("keydown", function (ev) {
    var b = ev.target.closest("button[data-date]");
    if (!b) return;
    var d = b.getAttribute("data-date"), k = ev.key, to = null;
    if (k === "ArrowRight" || k === "ArrowDown") to = step(d, 1);
    else if (k === "ArrowLeft" || k === "ArrowUp") to = step(d, -1);
    else if (k === "PageDown" || k === "PageUp") {
      var mi = months.indexOf(shown) + (k === "PageDown" ? 1 : -1);
      if (months[mi]) { render(months[mi]); var fb = calBody.querySelector("button"); if (fb) fb.focus(); }
      ev.preventDefault(); return;
    } else return;
    ev.preventDefault();
    moveTo(to);
  });
  calPrev.addEventListener("click", function () { var m = months[months.indexOf(shown) - 1]; if (m) render(m); });
  calNext.addEventListener("click", function () { var m = months[months.indexOf(shown) + 1]; if (m) render(m); });
  calMonth.addEventListener("change", function () { if (calMonth.value) render(calMonth.value); });

  function resetCalendar(r) {
    avail = {}; months = []; setDate("");
    calMonth.textContent = "";
    if (!r) {
      cal.setAttribute("data-empty", "");
      calMonth.appendChild(option("", "请先选择直播间"));
      calMonth.disabled = calPrev.disabled = calNext.disabled = true;
      calBody.textContent = "";
      return;
    }
    cal.removeAttribute("data-empty");
    var count = {};
    r.dates.forEach(function (d) { avail[d] = true; count[ym(d)] = (count[ym(d)] || 0) + 1; });
    months = Object.keys(count).sort();
    months.forEach(function (m) { calMonth.appendChild(option(m, monthLabel(m) + "（" + count[m] + " 天）")); });
    calMonth.disabled = false;
    render(months[months.length - 1]);   // newest month first
  }

  room.addEventListener("change", function () {
    setError("room", "");
    resetCalendar(archive.filter(function (x) { return String(x.roomId) === room.value; })[0]);
  });
  ctype.addEventListener("change", function () {
    el("rq-contact-helper").textContent = CONTACT_HELP[ctype.value] || "";
    contact.setAttribute("inputmode", ctype.value === "qq" ? "numeric" : ctype.value === "email" ? "email" : "text");
    setError("contact", "");
  });
  ["name", "contact"].forEach(function (f) { el("rq-" + f).addEventListener("input", function () { setError(f, ""); }); });
  el("rq-consent").addEventListener("change", function () { setError("consent", ""); });
  el("rq-transfer").addEventListener("change", function () { setError("transfer", ""); });

  function validContact(t, v) {
    if (t === "qq") return /^[1-9][0-9]{4,11}$/.test(v);
    if (t === "email") return v.length <= 100 && /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(v);
    return v.length >= 2 && v.length <= 60;
  }

  form.addEventListener("submit", function (ev) {
    ev.preventDefault();
    showResult(null);
    var v = {
      name: el("rq-name").value.trim(),
      roomId: room.value,
      date: date.value,
      contactType: ctype.value,
      contact: contact.value.trim(),
      note: el("rq-note").value.trim(),
      consent: el("rq-consent").checked,
      consentTransfer: el("rq-transfer").checked,
    };
    var bad = {};
    if (!v.name || Array.from(v.name).length > 40) bad.name = ERRORS.name;
    if (!v.roomId) bad.room = ERRORS.room;
    if (!v.date) bad.date = ERRORS.date;
    if (!validContact(v.contactType, v.contact)) bad.contact = ERRORS.contact;
    if (!v.consent) bad.consent = ERRORS.consent;
    if (!v.consentTransfer) bad.transfer = ERRORS.transfer;
    ["name", "room", "date", "contact", "consent", "transfer"].forEach(function (f) { setError(f, bad[f] || ""); });
    var first = Object.keys(bad)[0];
    if (first) {
      var target = first === "date" ? (calBody.querySelector("button[tabindex='0']") || calMonth) : el("rq-" + first);
      if (target && !target.disabled) target.focus(); else room.focus();
      return;
    }

    submit.disabled = true;
    submit.textContent = "正在提交…";
    fetch("/api/request", {
      method: "POST", credentials: "same-origin", cache: "no-store",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(v),
    })
      .then(function (res) {
        if (toLogin(res)) return null;
        return res.json().catch(function () { return {}; }).then(function (j) { return { ok: res.ok, j: j }; });
      })
      .then(function (r) {
        if (!r) return;
        if (r.ok && r.j.ok) {
          var sentV = v;
          form.reset();
          resetCalendar(null);
          el("rq-contact-helper").textContent = CONTACT_HELP.qq;
          startWait(r.j, sentV);
          return;
        } else {
          showResult("error", "提交失败", SERVER_ERRORS[r.j.error] || "请稍后重试。");
        }
        result.scrollIntoView({ block: "nearest" });
      })
      .catch(function () { showResult("error", "提交失败", "网络连接异常，请稍后重试。"); })
      .then(function () { submit.disabled = false; submit.textContent = "提交请求"; });
  });

  // ---------- waiting for the decision (request_wait on the server, 5 min) ----------
  var wait = el("rq-wait");
  var waitTimer = null, pollTimer = null;

  function fmtLeft(s) { s = Math.max(0, Math.ceil(s)); return Math.floor(s / 60) + ":" + pad(s % 60); }
  function cst(ts) {
    try {
      return new Intl.DateTimeFormat("zh-CN", { timeZone: "Asia/Shanghai", year: "numeric", month: "2-digit", day: "2-digit",
        hour: "2-digit", minute: "2-digit", hour12: false }).format(new Date(ts * 1000)).replace(/\//g, "-") + "（北京时间）";
    } catch (e) { return new Date(ts * 1000).toISOString().slice(0, 16).replace("T", " ") + " UTC"; }
  }
  function shareText(info, sh) {
    return [
      info.name + "，你好！你申请的录播已经准备好了：", "",
      "直播间：" + (info.roomName || info.roomId) + "（" + info.roomId + "）",
      "日期：" + info.date,
      "链接：" + sh.url,
      "提取码：" + sh.pwd,
      "有效期至：" + cst(sh.expires) + "，最多 " + sh.maxAccess + " 次访问", "",
      "用浏览器打开链接，先完成人机验证，再输入提取码，即可查看文件列表并下载。同一网络 30 分钟内重复打开只计 1 次访问。",
      "录像仅供个人观看，请勿转发链接或二次上传。", "",
      "请求编号：" + info.id,
    ].join("\n");
  }

  function stopWait() {
    if (waitTimer) clearInterval(waitTimer);
    if (pollTimer) clearTimeout(pollTimer);
    waitTimer = pollTimer = null;
  }

  function again() {
    stopWait();
    wait.hidden = true;
    wait.textContent = "";
    form.hidden = false;
    showResult(null);
    el("rq-name").focus();
  }

  function finish(kind, title, text, extra) {
    stopWait();
    wait.textContent = "";
    var n = el("tpl-rq-done").content.firstElementChild.cloneNode(true);
    wait.appendChild(n);
    result.textContent = "";
    showResult(kind, title, text);
    n.querySelector(".live-wait__body").appendChild(result.firstElementChild);
    if (extra) n.querySelector(".live-wait__body").appendChild(extra);
    n.querySelector(".live-wait__again").addEventListener("click", again);
    var h = n.querySelector(".live-wait__body > *");
    if (h) { h.setAttribute("tabindex", "-1"); h.focus({ preventScroll: true }); }
    wait.scrollIntoView({ block: "nearest" });
  }

  function shareBlock(info, sh) {
    var b = el("tpl-rq-share").content.firstElementChild.cloneNode(true);
    var a = b.querySelector("[data-k=url]");
    a.href = sh.url; a.textContent = sh.url;
    b.querySelector("[data-k=pwd]").textContent = sh.pwd;
    b.querySelector("[data-k=expires]").textContent = cst(sh.expires);
    b.querySelector("[data-k=max]").textContent = sh.maxAccess + " 次（同一网络 30 分钟内只计 1 次）";
    var txt = shareText(info, sh);
    b.querySelector("[data-k=text]").textContent = txt;
    var copy = b.querySelector(".live-share__copy"), copied = b.querySelector(".live-share__copied");
    copy.addEventListener("click", function () {
      var done = function () { copied.textContent = "已复制。"; setTimeout(function () { copied.textContent = ""; }, 4000); };
      if (navigator.clipboard && navigator.clipboard.writeText) {
        navigator.clipboard.writeText(txt).then(done, function () { copied.textContent = "无法自动复制，请手动选择文字复制。"; });
      } else {
        copied.textContent = "无法自动复制，请手动选择文字复制。";
      }
    });
    return b;
  }

  function startWait(j, v) {
    var info = { id: j.id, name: v.name, roomId: v.roomId, date: v.date,
                 roomName: (archive.filter(function (x) { return String(x.roomId) === v.roomId; })[0] || {}).name };
    var total = j.wait || 300, deadline = Date.now() + total * 1000, watchEnd = Date.now() + 20 * 60 * 1000;
    var failures = 0;
    form.hidden = true;
    showResult(null);
    wait.textContent = "";
    var n = el("tpl-rq-wait").content.firstElementChild.cloneNode(true);
    wait.appendChild(n);
    wait.hidden = false;
    var title = n.querySelector(".live-wait__title"), text = n.querySelector(".live-wait__text");
    var left = n.querySelector(".live-wait__left"), bar = n.querySelector(".live-wait__fill"), meter = n.querySelector(".live-wait__bar");
    n.querySelector("[data-k=id]").textContent = j.id;
    title.setAttribute("tabindex", "-1");
    title.focus({ preventScroll: true });
    wait.scrollIntoView({ block: "nearest" });

    function tickClock() {
      var s = (deadline - Date.now()) / 1000;
      left.textContent = s > 0 ? "最长还需等待 " + fmtLeft(s) : "即将转为人工审核…";
      var pct = Math.min(100, Math.max(0, 100 - s / total * 100));
      bar.style.width = pct + "%";
      meter.setAttribute("aria-valuenow", String(Math.round(pct)));
    }
    tickClock();
    waitTimer = setInterval(tickClock, 1000);

    var manual = function (extraText) {
      finish("info", "需要人工审核",
        "我们需要进一步考虑你的申请，它已转为人工审核。审核完成后，我们会通过你留下的联系方式与你联系。" +
        (extraText || "") + "请求编号：" + j.id + "（请保留以便查询）。");
    };

    function poll() {
      fetch("/api/request/status?id=" + encodeURIComponent(j.id) + "&t=" + encodeURIComponent(j.ticket || ""),
            { credentials: "same-origin", cache: "no-store" })
        .then(function (res) { return res.json().catch(function () { return {}; }).then(function (b) { return { st: res.status, b: b }; }); })
        .then(function (r) {
          if (r.st === 403 || r.st === 404) return manual();
          if (!r.b.ok) throw new Error("bad");
          failures = 0;
          var s = r.b.state;
          if (typeof r.b.left === "number") deadline = Date.now() + r.b.left * 1000;
          if (s === "ready" && r.b.share) {
            finish("success", "申请已通过", "下载链接已生成。用浏览器打开链接，先完成人机验证，再输入提取码，即可查看文件列表并下载。" +
              "请在有效期内下载；请勿转发链接或二次上传。", shareBlock(info, r.b.share));
            return;
          }
          if (s === "denied") {
            finish("error", "申请未获批准", "本次申请未获批准。请求编号：" + j.id + "。");
            return;
          }
          if (s === "manual") return manual();
          if (s === "preparing") {
            title.textContent = "申请已通过，正在生成下载链接";
            text.textContent = "管理员已批准你的申请，系统正在准备文件和下载链接，请不要关闭此页面。";
            clearInterval(waitTimer); waitTimer = null;
            left.textContent = "当天的录像需要先上传到云端，可能需要几分钟。";
            bar.style.width = "100%";
            if (Date.now() > watchEnd) {
              return manual("链接仍在生成，完成后管理员会把链接发给你。");
            }
          }
          pollTimer = setTimeout(poll, 3000);
        })
        .catch(function () {
          failures += 1;
          if (failures > 20 && Date.now() > deadline) return manual();
          pollTimer = setTimeout(poll, 5000);
        });
    }
    pollTimer = setTimeout(poll, 2000);
  }

  loadArchive();
})();

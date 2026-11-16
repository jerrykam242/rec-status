/* Cloudflare Turnstile on the OpenList login page (file.example.com).
 * Mounts a widget above the login buttons and adds its token to the login
 * request as the X-Turnstile-Token header; nginx verifies it server-side.
 * SSO (Microsoft) sign-in: the same token is added to the popup URL as ?ts=,
 * and nginx requires it before the Microsoft round trip (file_gate.lua). */
(function () {
  "use strict";
  var SITEKEY = "YOUR_TURNSTILE_SITEKEY";
  var ACTION = "openlist-login";
  var LOGIN_RE = /\/api\/auth\/login(\/[a-z]*)?\/?(\?|#|$)/i;

  var widgetId = null;
  var box = null;
  var token = "";
  var apiReady = false;
  var retryAt = 0;

  // OpenList's login page accepts any window "message" whose data has a
  // `token` field as an SSO login token. Turnstile's iframe posts exactly such
  // messages, which made OpenList store the Turnstile token as its session and
  // bounce between / and /@login. Hide Cloudflare challenge messages from
  // every window message listener except Turnstile's own.
  var CF_ORIGIN = "https://challenges.cloudflare.com";
  var wrapped = new WeakMap();
  var wAdd = window.addEventListener;
  var wRemove = window.removeEventListener;
  window.addEventListener = function (type, fn, opts) {
    if (type === "message" && fn && !wrapped.has(fn)) {
      var stack = "";
      try { stack = String(new Error().stack || ""); } catch (e) {}
      if (stack.indexOf(CF_ORIGIN) === -1) {
        wrapped.set(fn, function (ev) {
          if (ev && ev.origin === CF_ORIGIN) return;
          return typeof fn === "function" ? fn.call(this, ev) : fn.handleEvent(ev);
        });
      }
    }
    var real = (type === "message" && fn && wrapped.get(fn)) || fn;
    return wAdd.call(this, type, real, opts);
  };
  window.removeEventListener = function (type, fn, opts) {
    var real = (type === "message" && fn && wrapped.get(fn)) || fn;
    return wRemove.call(this, type, real, opts);
  };

  function resetWidget() {
    token = "";
    if (widgetId !== null && window.turnstile) {
      try { window.turnstile.reset(widgetId); } catch (e) {}
    }
  }

  // Tokens are single-use: attach the current one to the login call, then reset.
  var xOpen = XMLHttpRequest.prototype.open;
  var xSend = XMLHttpRequest.prototype.send;
  XMLHttpRequest.prototype.open = function (method, url) {
    this.__tsLogin = LOGIN_RE.test(String(url));
    return xOpen.apply(this, arguments);
  };
  XMLHttpRequest.prototype.send = function () {
    if (this.__tsLogin) {
      if (token) this.setRequestHeader("X-Turnstile-Token", token);
      this.addEventListener("loadend", resetWidget);
    }
    return xSend.apply(this, arguments);
  };
  if (window.fetch) {
    var oFetch = window.fetch;
    window.fetch = function (input, init) {
      var url = typeof input === "string" ? input : (input && input.url) || "";
      if (LOGIN_RE.test(url) && token) {
        init = init || {};
        var h = new Headers(init.headers || (typeof input !== "string" && input.headers) || {});
        h.set("X-Turnstile-Token", token);
        init.headers = h;
        var p = oFetch.call(this, input, init);
        p.then(resetWidget, resetWidget);
        return p;
      }
      return oFetch.apply(this, arguments);
    };
  }

  // SSO sign-in opens /api/auth/sso?method=sso_get_token in a popup.
  // (Linking an account uses method=get_sso_id and is left alone.)
  var SSO_RE = /\/api\/auth\/sso\/?(\?|#|$)/i;
  var hintTimer = null;
  function needCheckHint() {
    if (!box || !box.isConnected) return;
    var hint = document.getElementById("site-turnstile-hint");
    if (!hint) {
      hint = document.createElement("div");
      hint.id = "site-turnstile-hint";
      hint.setAttribute("role", "alert");
      hint.style.cssText = "width:100%;text-align:center;font-size:14px;color:#e53e3e;margin-top:4px";
      box.parentElement.insertBefore(hint, box.nextSibling);
    }
    hint.textContent = "请先完成人机验证 / Please complete the security check first.";
    try { box.scrollIntoView({ block: "center", behavior: "smooth" }); } catch (e) {}
    clearTimeout(hintTimer);
    hintTimer = setTimeout(function () {
      if (hint.parentElement) hint.parentElement.removeChild(hint);
    }, 5000);
  }
  var oOpen = window.open;
  window.open = function (url) {
    var u = String(url == null ? "" : url);
    if (SSO_RE.test(u) && /[?&]method=sso_get_token(&|#|$)/i.test(u)) {
      if (!token) { needCheckHint(); return null; }
      var hash = "";
      var i = u.indexOf("#");
      if (i !== -1) { hash = u.slice(i); u = u.slice(0, i); }
      var args = Array.prototype.slice.call(arguments);
      args[0] = u + (u.indexOf("?") === -1 ? "?" : "&") + "ts=" + encodeURIComponent(token) + hash;
      var w = oOpen.apply(this, args);
      resetWidget();
      return w;
    }
    return oOpen.apply(this, arguments);
  };

  function loginCard() {
    var input = document.querySelector('input[name="password"], input[name="username"], input[name="otp"]');
    return input ? input.parentElement : null;
  }

  function mount() {
    if (!/\/@login\/?$/.test(location.pathname)) return;
    if (Date.now() < retryAt) return;
    if (!apiReady && !(window.turnstile && typeof window.turnstile.render === "function")) return;
    if (box && box.isConnected) return;
    var card = loginCard();
    if (!card) return;
    var btn = card.querySelector("button");
    if (!btn) return;
    var anchor = btn;
    while (anchor.parentElement && anchor.parentElement !== card) anchor = anchor.parentElement;
    if (anchor.parentElement !== card) return;

    if (widgetId !== null) {
      try { window.turnstile.remove(widgetId); } catch (e) {}
      widgetId = null;
    }
    token = "";
    box = document.createElement("div");
    box.id = "site-turnstile";
    box.style.cssText = "display:flex;justify-content:center;width:100%;min-height:65px";
    card.insertBefore(box, anchor);
    try {
      widgetId = window.turnstile.render(box, {
      sitekey: SITEKEY,
      action: ACTION,
      theme: "auto",
      size: "flexible",
      callback: function (t) { token = t; },
      "expired-callback": function () { token = ""; },
        "error-callback": function () { token = ""; }
      });
    } catch (e) {
      if (box.parentElement) box.parentElement.removeChild(box);
      box = null;
      widgetId = null;
      retryAt = Date.now() + 5000;
    }
  }

  window.__siteTurnstileReady = function () {
    apiReady = true;
    mount();
  };

  var s = document.createElement("script");
  s.src = "https://challenges.cloudflare.com/turnstile/v0/api.js?render=explicit&onload=__siteTurnstileReady";
  s.async = true;
  s.defer = true;
  document.head.appendChild(s);

  function watch() {
    new MutationObserver(mount).observe(document.body, { childList: true, subtree: true });
    setInterval(mount, 1000);
    mount();
  }
  if (document.body) watch();
  else document.addEventListener("DOMContentLoaded", watch);
})();

// Cookie notice (2026-11-16). Only strictly necessary cookies are used (sign-in, Turnstile,
// Cloudflare security), which need no consent under ePrivacy Art. 5(3) / PECR; this informs and
// links the privacy policy. The acknowledgement stays in localStorage.
(function () {
  "use strict";
  var KEY = "site.cookie-notice", VER = "2026-11-16";
  try { if (localStorage.getItem(KEY) === VER) return; } catch (e) { /* storage blocked: show it */ }
  function show() {
    if (document.getElementById("site-cookie")) return;
    var box = document.createElement("section");
    box.id = "site-cookie";
    box.setAttribute("aria-label", "Cookie 提示 / Cookie notice");
    box.style.cssText = "position:fixed;z-index:2147483000;right:16px;bottom:16px;left:16px;max-width:30rem;margin-left:auto;" +
      "display:flex;flex-wrap:wrap;align-items:center;gap:12px 16px;padding:16px;background:#393939;color:#fff;" +
      "box-shadow:0 2px 6px rgba(0,0,0,.3);font:14px/20px 'IBM Plex Sans','PingFang SC','Microsoft YaHei',system-ui,sans-serif";
    var p = document.createElement("p");
    p.style.cssText = "flex:1 1 16rem;margin:0";
    p.appendChild(document.createTextNode("本网站仅使用网站运行所严格必需的 Cookie，不使用任何分析、广告或跟踪 Cookie。 This website uses only strictly necessary cookies and does not use any analytics, advertising or tracking cookies. "));
    var a = document.createElement("a");
    a.href = "https://rec-status.example.com/privacy#cookies";
    a.target = "_blank";
    a.rel = "noopener";
    a.textContent = "隐私政策 / Privacy Policy";
    a.style.cssText = "color:#78a9ff;text-decoration:underline";
    p.appendChild(a);
    var b = document.createElement("button");
    b.type = "button";
    b.textContent = "确定 / OK";
    b.style.cssText = "flex:0 0 auto;min-height:40px;padding:0 16px;border:0;cursor:pointer;background:#0f62fe;color:#fff;font:inherit";
    b.addEventListener("click", function () {
      try { localStorage.setItem(KEY, VER); } catch (e) { /* ignore */ }
      box.remove();
    });
    box.appendChild(p);
    box.appendChild(b);
    document.body.appendChild(box);
  }
  if (document.body) show(); else document.addEventListener("DOMContentLoaded", show);
})();

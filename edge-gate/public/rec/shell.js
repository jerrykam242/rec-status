// rec.example.com: Carbon UI shell for the BililiveRecorder pages (see theme.css).
// nginx adds it to every recorder HTML page (sub_filter in sites/rec.conf):
//   - in <head> of /, /ui/, /file/, /player/ (with theme.css), so the theme is set before paint;
//   - before </html> everywhere, so other pages (Swagger, GraphiQL ...) keep a Sign out button.
// It only adds a header, a page title and a Sign out link; the recorder's own markup,
// scripts and requests are left alone.
(function () {
  if (window.top !== window) return;                            // not inside embeds/iframes
  if (location.pathname.indexOf("/__turnstile") === 0) return;  // not on the sign-in page
  if (window.__siteRecShell) return;                           // added twice on themed pages
  window.__siteRecShell = true;

  var KEY = "brec.theme";  // the WebUI's own setting: "0" (or unset) = dark, "1" = light
  var root = document.documentElement;
  var path = location.pathname;
  var page = path === "/" ? "home"
    : /^\/ui(\/|$)/.test(path) ? "ui"
    : /^\/file(\/|$)/.test(path) ? "file"
    : /^\/player(\/|$)/.test(path) ? "player" : "";
  var themed = !!page && !!document.querySelector('link[href*="/__turnstile/rec/theme.css"]');

  function readTheme() {
    try { return localStorage.getItem(KEY) === "1" ? "light" : "dark"; } catch (e) { return "dark"; }
  }
  if (themed) {
    root.setAttribute("data-rec-page", page);
    root.setAttribute("data-rec-theme", readTheme());
  }

  var LOGOUT = '<svg focusable="false" aria-hidden="true" viewBox="0 0 32 32"><path d="M6,30H18a2.0023,2.0023,0,0,0,2-2V25H18v3H6V4H18V7h2V4a2.0023,2.0023,0,0,0-2-2H6A2.0023,2.0023,0,0,0,4,4V28A2.0023,2.0023,0,0,0,6,30Z"/><polygon points="20.586 20.586 24.172 17 10 17 10 15 24.172 15 20.586 11.414 22 10 28 16 22 22 20.586 20.586"/></svg>';
  var ASLEEP = '<svg class="rec-only-dark" focusable="false" aria-hidden="true" viewBox="0 0 32 32"><path d="M13.5025,5.4136A15.0755,15.0755,0,0,0,25.096,23.6082a11.1134,11.1134,0,0,1-7.9749,3.3893c-.1385,0-.2782.0051-.4178,0A11.0944,11.0944,0,0,1,13.5025,5.4136M14.98,3a1.0024,1.0024,0,0,0-.1746.0156A13.0959,13.0959,0,0,0,16.63,28.9973c.1641.006.3282,0,.4909,0a13.0724,13.0724,0,0,0,10.702-5.5556,1.0094,1.0094,0,0,0-.7833-1.5644A13.08,13.08,0,0,1,15.8892,4.38,1.0149,1.0149,0,0,0,14.98,3Z"/></svg>';
  var LIGHT = '<svg class="rec-only-light" focusable="false" aria-hidden="true" viewBox="0 0 32 32"><rect x="15" y="2" width="2" height="5"/><rect x="21.6675" y="6.8536" width="4.958" height="1.9998" transform="translate(1.5191 19.3744) rotate(-45)"/><rect x="25" y="15" width="5" height="2"/><rect x="23.1466" y="21.6675" width="1.9998" height="4.958" transform="translate(-10.0018 24.1465) rotate(-45)"/><rect x="15" y="25" width="2" height="5"/><rect x="5.3745" y="23.1466" width="4.958" height="1.9998" transform="translate(-14.7739 12.6256) rotate(-45)"/><rect x="2" y="15" width="5" height="2"/><rect x="6.8536" y="5.3745" width="1.9998" height="4.958" transform="translate(-3.253 7.8535) rotate(-45)"/><path d="M16,12a4,4,0,1,1-4,4,4.0045,4.0045,0,0,1,4-4m0-2a6,6,0,1,0,6,6,6,6,0,0,0-6-6Z"/></svg>';

  function el(tag, attrs, html) {
    var e = document.createElement(tag);
    for (var k in attrs) e.setAttribute(k, attrs[k]);
    if (html) e.innerHTML = html;
    return e;
  }
  function signOutLink() {
    return el("a", { "class": "rec-shell__action", href: "/__turnstile/logout", title: "退出登录",
      "aria-label": "退出登录" }, LOGOUT);
  }

  // Carbon header for the static pages.
  function staticShell() {
    var header = el("header", { "class": "rec-shell", "aria-label": "mikufans录播姬" });
    header.appendChild(el("a", { "class": "rec-shell__name", href: "/" },
      '<img src="/__turnstile/rec/logo.svg" alt="" width="24" height="24"><span>mikufans录播姬</span>'));
    var nav = el("nav", { "class": "rec-shell__nav", "aria-label": "导航" });
    [["/ui/", "管理界面", "ui"], ["/file/", "文件", "file"], ["/player/", "播放器", "player"]].forEach(function (l) {
      var a = el("a", { href: l[0] });
      a.textContent = l[1];
      if (page === l[2]) a.setAttribute("aria-current", "page");
      nav.appendChild(a);
    });
    header.appendChild(nav);
    var actions = el("div", { "class": "rec-shell__actions" });
    var toggle = el("button", { type: "button", "class": "rec-shell__action", title: "切换浅色/深色",
      "aria-label": "切换浅色/深色" }, ASLEEP + LIGHT);
    toggle.addEventListener("click", function () {
      var next = root.getAttribute("data-rec-theme") === "light" ? "dark" : "light";
      root.setAttribute("data-rec-theme", next);
      try { localStorage.setItem(KEY, next === "light" ? "1" : "0"); } catch (e) { /* private mode */ }
    });
    actions.appendChild(toggle);
    actions.appendChild(signOutLink());
    header.appendChild(actions);
    document.body.insertBefore(header, document.body.firstChild);

    if (page === "file") fileHead();
  }

  // /file/: a page title and breadcrumb from the URL (the listing itself has neither).
  function fileHead() {
    var main = document.getElementById("main");
    if (!main) return;
    var parts = path.split("/").filter(Boolean);    // ["file", "dir", ...]
    var head = el("div", { "class": "rec-page-head" });
    var ol = el("ol", { "class": "rec-breadcrumb", "aria-label": "路径" });
    var href = "/";
    parts.forEach(function (p, i) {
      href += p + "/";
      var li = el("li");
      var name = i === 0 ? "录播文件" : decodeURIComponent(p);
      if (i === parts.length - 1) {
        var cur = el("span", { "aria-current": "page" });
        cur.textContent = name;
        li.appendChild(cur);
      } else {
        var a = el("a", { href: href });
        a.textContent = name;
        li.appendChild(a);
      }
      ol.appendChild(li);
    });
    var h1 = el("h1");
    h1.textContent = parts.length > 1 ? decodeURIComponent(parts[parts.length - 1]) : "录播文件浏览器";
    if (parts.length > 1) head.appendChild(ol);
    head.appendChild(h1);
    main.parentNode.insertBefore(head, main);
  }

  // WebUI: Sign out goes into the app's own header (re-added if Vue re-renders it).
  function uiShell() {
    function place() {
      var header = document.querySelector(".n-layout-header");
      if (!header || header.querySelector(".rec-shell__actions")) return;
      var actions = el("div", { "class": "rec-shell__actions" });
      actions.appendChild(signOutLink());
      header.appendChild(actions);
    }
    place();
    new MutationObserver(place).observe(document.body, { childList: true, subtree: true });
  }

  // Any other recorder page (Swagger, GraphiQL, ...): the floating Carbon button, in a
  // shadow root so the page's CSS cannot restyle it.
  function floatingSignOut() {
    if (document.getElementById("site-rec-signout")) return;
    var face = document.createElement("style");
    face.textContent = '@font-face{font-family:"Example Rec Sans";font-weight:400;font-style:normal;' +
      'font-display:swap;src:url("/__turnstile/rec/fonts/ibm-plex-sans-latin-400-normal.woff2") format("woff2")}';
    document.head.appendChild(face);
    var host = document.createElement("div");
    host.id = "site-rec-signout";
    var sr = host.attachShadow({ mode: "open" });
    sr.innerHTML =
      "<style>" +
      ":host{all:initial;position:fixed;right:16px;bottom:16px;z-index:2147483647}" +
      "a{display:inline-flex;align-items:center;gap:32px;box-sizing:border-box;min-height:40px;" +
      "padding:0 12px 0 15px;margin:0;border:1px solid transparent;border-radius:0;" +
      "font:400 14px/1.28572 'Example Rec Sans','IBM Plex Sans',system-ui,sans-serif;letter-spacing:.16px;" +
      "color:#fff;background:#393939;text-decoration:none;" +
      "transition:background 70ms cubic-bezier(0,0,.38,.9),box-shadow 70ms cubic-bezier(0,0,.38,.9);" +
      "-webkit-font-smoothing:antialiased}" +
      "a svg{flex:none;width:16px;height:16px;fill:currentColor}" +
      "a:hover{background:#474747}a:active{background:#6f6f6f}" +
      "a:focus{outline:none;border-color:#0f62fe;box-shadow:inset 0 0 0 1px #0f62fe,inset 0 0 0 2px #fff}" +
      "@media (prefers-reduced-motion:reduce){a{transition:none}}@media print{a{display:none}}" +
      "</style>" +
      '<a href="/__turnstile/logout" title="Sign out of rec.example.com">Sign out' + LOGOUT + "</a>";
    document.body.appendChild(host);
  }

  function mount() {
    if (!themed) floatingSignOut();
    else if (page === "ui") uiShell();
    else staticShell();
  }
  if (document.body) mount();
  else document.addEventListener("DOMContentLoaded", mount);
})();

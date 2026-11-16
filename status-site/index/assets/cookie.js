// Cookie notice. The sites use only strictly necessary cookies (sign-in and bot checks), which
// need no consent under ePrivacy Art. 5(3) / PECR, so this informs rather than asks: one
// "知道了" button, remembered in localStorage (never sent to the server).
(function () {
  "use strict";
  var KEY = "site.cookie-notice", VER = "2026-11-16";
  try { if (localStorage.getItem(KEY) === VER) return; } catch (e) { /* storage blocked: show it */ }
  function show() {
    var box = document.createElement("section");
    box.className = "live-cookie";
    box.setAttribute("aria-label", "Cookie 提示 / Cookie notice");
    var p = document.createElement("p");
    p.className = "live-cookie__text";
    p.appendChild(document.createTextNode("本网站仅使用网站运行所严格必需的 Cookie，不使用任何分析、广告或跟踪 Cookie。 This website uses only strictly necessary cookies and does not use any analytics, advertising or tracking cookies. "));
    var a = document.createElement("a");
    a.className = "live-cookie__link";
    a.href = "/privacy#cookies";
    a.textContent = "隐私政策 / Privacy Policy";
    p.appendChild(a);
    var b = document.createElement("button");
    b.type = "button";
    b.className = "live-cookie__btn";
    b.textContent = "确定 / OK";
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

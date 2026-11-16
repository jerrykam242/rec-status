// Live status sign-in: Cloudflare Turnstile in Non-interactive mode (since 2026-11-16; was the
// ESA AI captcha, which always needed a click). The widget runs by itself; its token is posted to
// /__gate/check, the server has it verified and sets the one-time entry pass, and the page moves
// on to "/" with nothing to click. The button only retries after an error.
(function () {
  "use strict";
  var form = document.getElementById("gate-form");
  var button = document.getElementById("gate-submit");
  var status = document.getElementById("captcha-status");
  var errBox = document.getElementById("gate-error");
  var errText = document.getElementById("gate-error-text");
  if (!form || !button) return;

  var token = null, sending = false;

  function setStatus(text, state) {
    status.textContent = text;
    if (state) status.setAttribute("data-state", state); else status.removeAttribute("data-state");
  }
  function showError(text) {
    errText.textContent = text;
    errBox.hidden = false;
  }
  function hideError() { errBox.hidden = true; }
  function reset() {
    token = null;
    if (window.turnstile) { try { window.turnstile.reset("#captcha-element"); } catch (e) { /* ignore */ } }
  }

  function send() {
    if (sending || !token) return;
    sending = true;
    button.disabled = true;
    hideError();
    setStatus("验证通过，正在进入…", "ok");
    fetch("/__gate/check", {
      method: "POST",
      credentials: "same-origin",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ token: token })
    }).then(function (res) {
      return res.json().catch(function () { return {}; }).then(function (data) {
        if (res.ok && data && data.ok) { window.location.replace(data.next || "/"); return; }
        throw new Error("验证没有通过，请重试。");
      });
    }).catch(function (e) {
      sending = false;
      button.disabled = false;
      setStatus("正在重新验证…", "error");
      showError(e && e.message && /[一-鿿]/.test(e.message) ? e.message : "网络错误，请重试。");
      reset();
    });
  }

  window.recStatusPass = function (t) { token = t; send(); };
  window.recStatusError = function () {
    setStatus("安全验证出错，请点击下方按钮重试。", "error");
    return true;
  };
  window.recStatusExpired = function () { token = null; reset(); };

  button.addEventListener("click", function () {
    if (token) { send(); return; }
    hideError();
    setStatus("正在验证，请稍候…");
    reset();
  });

  setStatus("正在自动验证，请稍候…");
  setTimeout(function () {
    if (!token && !sending && !window.turnstile) setStatus("安全验证组件加载失败，请检查网络后刷新页面。", "error");
  }, 10000);
})();

// rec.example.com sign-in (Carbon): the password visibility toggle, focus on the first
// problem after a failed sign-in, and a guard against double submits.
// Kept out of the HTML so the page's CSP needs no inline script.
(function () {
  var input = document.getElementById("password");
  var toggle = document.querySelector(".rec-toggle");
  if (input && toggle) {
    var show = toggle.querySelector(".rec-toggle__show");
    var hide = toggle.querySelector(".rec-toggle__hide");
    var set = function (visible) {
      input.type = visible ? "text" : "password";
      toggle.setAttribute("aria-label", visible ? "Hide password" : "Show password");
      toggle.setAttribute("aria-pressed", visible ? "true" : "false");
      show.style.display = visible ? "none" : "";
      hide.style.display = visible ? "" : "none";
    };
    set(false);
    toggle.hidden = false;
    toggle.addEventListener("click", function () { set(input.type === "password"); });
    // Never submit the password as visible text field state.
    input.form.addEventListener("submit", function () { set(false); });
  }

  var bad = document.querySelector('.cds--text-input[aria-invalid="true"]');
  if (bad) bad.focus();
  else {
    var note = document.querySelector('.rec-notification[role="alert"]');
    if (note) { note.setAttribute("tabindex", "-1"); note.focus(); }
  }

  var form = document.querySelector(".rec-form");
  var button = document.querySelector(".rec-submit");
  if (form && button) {
    form.addEventListener("submit", function (e) {
      if (form.dataset.sent) { e.preventDefault(); return; }
      form.dataset.sent = "1";
      setTimeout(function () { delete form.dataset.sent; }, 3000);
    });
  }
})();

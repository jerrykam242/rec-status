// rec.example.com: a "Sign out" button added to every recorder page by nginx
// (sub_filter in sites/rec.conf). It lives in a shadow root so the recorder's
// own CSS (WebUI, Swagger, GraphiQL ...) cannot restyle it, and vice versa.
(function () {
  if (window.top !== window) return;                       // not inside embeds/iframes
  if (location.pathname.indexOf("/__turnstile") === 0) return;  // not on the sign-in page
  if (document.getElementById("site-rec-signout")) return;

  var FONT = "/__turnstile/rec/fonts/ibm-plex-sans-latin-400-normal.woff2";
  // Carbon "logout" icon.
  var ICON = '<svg focusable="false" aria-hidden="true" width="16" height="16" viewBox="0 0 32 32">' +
    '<path d="M6,30H18a2.0023,2.0023,0,0,0,2-2V25H18v3H6V4H18V7h2V4a2.0023,2.0023,0,0,0-2-2H6A2.0023,2.0023,0,0,0,4,4V28A2.0023,2.0023,0,0,0,6,30Z"/>' +
    '<polygon points="20.586 20.586 24.172 17 10 17 10 15 24.172 15 20.586 11.414 22 10 28 16 22 22 20.586 20.586"/></svg>';

  function mount() {
    // @font-face only works at document level, under a name nobody else uses.
    var face = document.createElement("style");
    face.textContent = '@font-face{font-family:"Example Rec Sans";font-weight:400;font-style:normal;' +
      'font-display:swap;src:url("' + FONT + '") format("woff2")}';
    document.head.appendChild(face);

    var host = document.createElement("div");
    host.id = "site-rec-signout";
    var root = host.attachShadow({ mode: "open" });
    // Carbon secondary button, size md (40px), White theme colours, square corners.
    root.innerHTML =
      "<style>" +
      ":host{all:initial;position:fixed;right:16px;bottom:16px;z-index:2147483647}" +
      "a{display:inline-flex;align-items:center;gap:32px;box-sizing:border-box;min-height:40px;" +
      "padding:0 12px 0 15px;margin:0;border:1px solid transparent;border-radius:0;" +
      "font:400 14px/1.28572 'Example Rec Sans','IBM Plex Sans',system-ui,sans-serif;letter-spacing:.16px;" +
      "color:#fff;background:#393939;text-decoration:none;" +
      "transition:background 70ms cubic-bezier(0,0,.38,.9),box-shadow 70ms cubic-bezier(0,0,.38,.9);" +
      "-webkit-font-smoothing:antialiased}" +
      "a svg{flex:none;fill:currentColor}" +
      "a:hover{background:#474747}" +
      "a:active{background:#6f6f6f}" +
      "a:focus{outline:none;border-color:#0f62fe;box-shadow:inset 0 0 0 1px #0f62fe,inset 0 0 0 2px #fff}" +
      "@media (prefers-reduced-motion:reduce){a{transition:none}}" +
      "@media print{a{display:none}}" +
      "</style>" +
      '<a href="/__turnstile/logout" title="Sign out of rec.example.com">Sign out' + ICON + "</a>";
    document.body.appendChild(host);
  }

  if (document.body) mount();
  else document.addEventListener("DOMContentLoaded", mount);
})();

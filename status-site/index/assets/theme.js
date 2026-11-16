// Sets the colour theme before first paint: the visitor's choice (localStorage "live.theme"),
// else the system setting. White (light) or Gray 100 (dark), as in Carbon.
(function () {
  var t = null;
  try { t = localStorage.getItem("live.theme"); } catch (e) {}
  if (t !== "white" && t !== "g100") {
    t = window.matchMedia && window.matchMedia("(prefers-color-scheme: dark)").matches ? "g100" : "white";
  }
  document.documentElement.setAttribute("data-theme", t);
})();

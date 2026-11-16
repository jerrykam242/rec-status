// Section bar: marks the part of the page currently in view (aria-current="location").
(function () {
  "use strict";
  var links = Array.prototype.slice.call(document.querySelectorAll(".live-nav__link"));
  var sections = links.map(function (a) { return document.getElementById(a.getAttribute("href").slice(1)); });
  if (sections.some(function (s) { return !s; })) return;

  function mark(i) {
    links.forEach(function (a, j) {
      if (i === j) a.setAttribute("aria-current", "location"); else a.removeAttribute("aria-current");
    });
  }
  // The section in view is the last one whose top has reached the line just below the bars;
  // at the very bottom of the page the last section wins (it may be too short to reach that line).
  function update() {
    var line = 6 * 16 + 48, cur = 0;  // bars (6rem) + where a jump lands (1.5rem) + slack
    sections.forEach(function (s, i) { if (s.getBoundingClientRect().top <= line) cur = i; });
    var doc = document.documentElement;
    if (window.innerHeight + window.scrollY >= doc.scrollHeight - 2) cur = sections.length - 1;
    mark(cur);
  }
  var queued = false;
  function onScroll() {
    if (queued) return;
    queued = true;
    window.requestAnimationFrame(function () { queued = false; update(); });
  }
  links.forEach(function (a, i) { a.addEventListener("click", function () { mark(i); }); });
  window.addEventListener("scroll", onScroll, { passive: true });
  window.addEventListener("resize", onScroll);
  update();
})();

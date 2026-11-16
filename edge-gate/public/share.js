// Share-link check page (share_gate.lua): continue on its own once Turnstile has passed.
window.shareGateDone = function () {
  var f = document.getElementById("share-form");
  if (f && !f.dataset.sent) { f.dataset.sent = "1"; f.submit(); }
};

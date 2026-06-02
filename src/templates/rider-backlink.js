// When a race-report page is reached from a rider dossier (…?rider=<key>&name=<name>),
// inject a "← Back to <name>" link into the masthead. No-op when the params are absent,
// so direct visits, the index and the lookup page are unaffected.
(function () {
  var p = new URLSearchParams(location.search);
  var key = p.get("rider");
  if (!key) return;
  var name = p.get("name") || "rider";
  var hc = document.querySelector(".page-header .header-content");
  if (!hc) return;
  var a = document.createElement("a");
  a.className = "home-link";
  a.style.marginRight = "1.1em";
  a.href = "../riders.html#" + encodeURIComponent(key);
  a.textContent = "← Back to " + name;
  hc.insertBefore(a, hc.firstChild);
})();

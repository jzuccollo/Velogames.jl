document.addEventListener("DOMContentLoaded", function () {
  var toc = document.getElementById("toc");
  if (!toc) return;
  var headings = Array.prototype.slice.call(
    document.querySelectorAll("h2[id], h3[id]"),
  );
  var links = {};
  headings.forEach(function (h) {
    var a = document.createElement("a");
    a.href = "#" + h.id;
    a.textContent = h.textContent;
    if (h.tagName === "H3") a.className = "toc-h3";
    toc.appendChild(a);
    links[h.id] = a;
  });

  // Scroll-spy: highlight the last heading scrolled past the top of the viewport.
  function update() {
    var current = headings.length ? headings[0] : null;
    for (var i = 0; i < headings.length; i++) {
      if (headings[i].getBoundingClientRect().top <= 120) {
        current = headings[i];
      } else {
        break;
      }
    }
    headings.forEach(function (h) {
      links[h.id].classList.toggle("active", current && h.id === current.id);
    });
  }
  update();
  window.addEventListener("scroll", update, { passive: true });
  window.addEventListener("resize", update);
});

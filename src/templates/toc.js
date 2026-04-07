document.addEventListener("DOMContentLoaded", function () {
  var toc = document.getElementById("toc");
  if (!toc) return;
  var headings = document.querySelectorAll("h2[id], h3[id]");
  headings.forEach(function (h) {
    var a = document.createElement("a");
    a.href = "#" + h.id;
    a.textContent = h.textContent;
    if (h.tagName === "H3") a.className = "toc-h3";
    toc.appendChild(a);
  });
});

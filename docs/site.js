(function () {
  var REPO = "chiranjeebhub/NotchDeck";

  // Point the download buttons straight at the latest DMG.
  fetch("https://api.github.com/repos/" + REPO + "/releases/latest")
    .then(function (r) { return r.ok ? r.json() : null; })
    .then(function (rel) {
      if (!rel) return;
      var dmg = (rel.assets || []).filter(function (a) { return /\.dmg$/i.test(a.name); })[0];
      if (dmg) {
        ["download", "download2"].forEach(function (id) {
          var el = document.getElementById(id);
          if (el) el.href = dmg.browser_download_url;
        });
      }
      var v = document.getElementById("version");
      if (v && rel.tag_name) v.textContent = "Version " + rel.tag_name.replace(/^v/, "");
    })
    .catch(function () {});

  // Copy-to-clipboard buttons.
  document.querySelectorAll(".copy").forEach(function (btn) {
    btn.addEventListener("click", function () {
      var text = btn.getAttribute("data-copy");
      var done = function () {
        var label = btn.querySelector(".copy-label");
        btn.classList.add("copied");
        if (label) label.textContent = "Copied";
        setTimeout(function () {
          btn.classList.remove("copied");
          if (label) label.textContent = "Copy";
        }, 1600);
      };
      if (navigator.clipboard) navigator.clipboard.writeText(text).then(done, function () {});
    });
  });

  // Hero demo: the notch unfolds, then the tabs switch screenshots.
  var panel = document.querySelector(".panel");
  var tabs = document.querySelectorAll(".tab");
  var shots = document.querySelectorAll(".shot");
  var timer = null;

  function show(name) {
    shots.forEach(function (s) {
      var on = s.getAttribute("data-tab") === name;
      s.classList.toggle("active", on);
      if (on) panel.style.setProperty("--ar", s.getAttribute("width") + " / " + s.getAttribute("height"));
    });
    tabs.forEach(function (t) {
      var on = t.getAttribute("data-tab") === name;
      t.classList.toggle("active", on);
      t.setAttribute("aria-selected", on ? "true" : "false");
    });
  }

  tabs.forEach(function (t) {
    t.addEventListener("click", function () {
      clearInterval(timer);
      show(t.getAttribute("data-tab"));
    });
  });

  var demo = document.getElementById("demo");
  var order = ["home", "calendar", "tray", "dev"];
  var opened = false;
  function open() {
    if (opened) return;
    opened = true;
    setTimeout(function () { panel.classList.add("open"); }, 350);
    var i = 0;
    timer = setInterval(function () { i = (i + 1) % order.length; show(order[i]); }, 4200);
  }
  if ("IntersectionObserver" in window) {
    new IntersectionObserver(function (entries, obs) {
      if (entries[0].isIntersecting) { open(); obs.disconnect(); }
    }, { threshold: 0.15 }).observe(demo);
  } else {
    open();
  }

  // Keep the fake menu bar clock current.
  var clock = document.getElementById("clock");
  if (clock) {
    var d = new Date();
    clock.textContent = d.toLocaleDateString(undefined, { weekday: "short", day: "numeric", month: "short" }) + " " +
      d.toLocaleTimeString(undefined, { hour: "numeric", minute: "2-digit" });
  }
})();

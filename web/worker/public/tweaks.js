/* ============================================================================
   Shadowtype — Tweaks panel (vanilla). Lets you A/B the reserved CTA action
   color live, per the conversion research: reserve ONE high-contrast color for
   primary CTAs, then test. Persists via the host edit-mode protocol.
   ========================================================================== */
(function () {
  var defaults = window.__TWEAK_DEFAULTS || { ctaColor: "amber" };
  var isLight = document.body.classList.contains("theme-light");

  // [action, bright, deep, fg, glow] per option, tuned per theme.
  var PALETTES = isLight ? {
    amber:      ["#f59e0b", "#f5a623", "#d98a08", "#1a1200", "rgba(245,158,11,0.38)"],
    ink:        ["#1d1d1f", "#33333a", "#000000", "#ffffff", "rgba(0,0,0,0.40)"],
    green:      ["#16895a", "#1a9e5f", "#126e49", "#ffffff", "rgba(22,137,90,0.35)"],
    periwinkle: ["#6b4eff", "#8466ff", "#5634e0", "#ffffff", "rgba(107,78,255,0.32)"]
  } : {
    amber:      ["#f5a623", "#ffb13c", "#e0900f", "#1a1200", "rgba(245,166,35,0.40)"],
    ink:        ["#eef0f6", "#ffffff", "#cfd4e0", "#0a0b0e", "rgba(255,255,255,0.28)"],
    green:      ["#34c98a", "#5ee0a0", "#1f9e68", "#04130c", "rgba(94,224,160,0.40)"],
    periwinkle: ["#7c9cff", "#a6bcff", "#4b63c9", "#0a0b0e", "rgba(124,156,255,0.42)"]
  };

  function apply(key) {
    var p = PALETTES[key] || PALETTES.amber;
    var r = document.documentElement.style;
    r.setProperty("--action", p[0]);
    r.setProperty("--action-bright", p[1]);
    r.setProperty("--action-deep", p[2]);
    r.setProperty("--action-fg", p[3]);
    r.setProperty("--action-glow", p[4]);
  }
  apply(defaults.ctaColor);

  /* ---- panel UI -------------------------------------------------------- */
  var style = document.createElement("style");
  style.textContent =
    '.tw-panel{position:fixed;top:78px;right:16px;z-index:1000;width:248px;' +
    'background:rgba(16,18,24,0.96);backdrop-filter:blur(12px);color:#e8eaf0;' +
    'border:1px solid #2a2f3c;border-radius:14px;padding:14px;font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",system-ui,sans-serif;' +
    'box-shadow:0 24px 60px -20px rgba(0,0,0,0.7);display:none;}' +
    '.tw-panel.show{display:block;}' +
    '.tw-head{display:flex;align-items:center;justify-content:space-between;margin-bottom:4px;}' +
    '.tw-title{font-size:13px;font-weight:650;letter-spacing:-0.01em;}' +
    '.tw-x{appearance:none;background:transparent;border:0;color:#9aa0b0;font-size:18px;line-height:1;cursor:pointer;padding:2px 4px;border-radius:6px;}' +
    '.tw-x:hover{color:#fff;background:rgba(255,255,255,0.08);}' +
    '.tw-cap{font-size:11px;color:#8a90a0;line-height:1.45;margin-bottom:12px;}' +
    '.tw-label{font-size:11px;font-weight:600;text-transform:uppercase;letter-spacing:0.08em;color:#9aa0b0;margin-bottom:7px;}' +
    '.tw-seg{display:grid;grid-template-columns:1fr 1fr;gap:6px;}' +
    '.tw-opt{display:flex;align-items:center;gap:7px;font-size:12.5px;font-weight:540;color:#cdd2de;cursor:pointer;' +
    'background:#1c2029;border:1px solid #2a2f3c;border-radius:9px;padding:8px 9px;transition:border-color .15s,background .15s;}' +
    '.tw-opt:hover{border-color:#3a4150;}' +
    '.tw-opt.on{border-color:#6c7cff;background:#222838;color:#fff;}' +
    '.tw-sw{width:13px;height:13px;border-radius:50%;flex:none;box-shadow:0 0 0 1px rgba(255,255,255,0.12);}' +
    '.tw-note{font-size:10.5px;color:#787e8e;margin-top:11px;line-height:1.4;}';
  document.head.appendChild(style);

  var SW = {
    amber: "linear-gradient(180deg,#ffb13c,#f5a623)",
    ink: isLight ? "#1d1d1f" : "#eef0f6",
    green: "linear-gradient(180deg,#5ee0a0,#34c98a)",
    periwinkle: "linear-gradient(180deg,#a6bcff,#7c9cff)"
  };
  var LABELS = { amber: "Amber", ink: "Ink", green: "Green", periwinkle: "Periwinkle" };
  var ORDER = ["amber", "ink", "green", "periwinkle"];

  var panel = document.createElement("div");
  panel.className = "tw-panel";
  var opts = ORDER.map(function (k) {
    return '<button class="tw-opt" data-k="' + k + '"><span class="tw-sw" style="background:' + SW[k] + '"></span>' + LABELS[k] + '</button>';
  }).join("");
  panel.innerHTML =
    '<div class="tw-head"><span class="tw-title">Tweaks</span><button class="tw-x" aria-label="Close">\u00d7</button></div>' +
    '<div class="tw-cap">The conversion research: reserve one high-contrast color for primary CTAs, then A/B it for ~2 weeks.</div>' +
    '<div class="tw-label">Primary CTA color</div>' +
    '<div class="tw-seg">' + opts + '</div>' +
    '<div class="tw-note">Warm (amber) pops hardest on this neutral page; green leans \u201con-device / go\u201d. Picks persist.</div>';
  document.body.appendChild(panel);

  var current = defaults.ctaColor;
  function mark() {
    panel.querySelectorAll(".tw-opt").forEach(function (b) {
      b.classList.toggle("on", b.dataset.k === current);
    });
  }
  mark();

  panel.querySelectorAll(".tw-opt").forEach(function (b) {
    b.addEventListener("click", function () {
      current = b.dataset.k;
      apply(current);
      mark();
      window.parent.postMessage({ type: "__edit_mode_set_keys", edits: { ctaColor: current } }, "*");
    });
  });

  /* ---- host protocol: listener BEFORE announce ------------------------- */
  window.addEventListener("message", function (e) {
    var t = e.data && e.data.type;
    if (t === "__activate_edit_mode") panel.classList.add("show");
    else if (t === "__deactivate_edit_mode") panel.classList.remove("show");
  });
  panel.querySelector(".tw-x").addEventListener("click", function () {
    panel.classList.remove("show");
    window.parent.postMessage({ type: "__edit_mode_dismissed" }, "*");
  });
  window.parent.postMessage({ type: "__edit_mode_available" }, "*");
})();

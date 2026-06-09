/* ============================================================================
   Shadowtype hero demo — a live, self-contained ghost-text animation.
   Types a line, fades in a local-model suggestion, then visibly presses Tab to
   accept it word-by-word. Cycles through app contexts (Mail / Slack / code /
   Messages) and demonstrates the offline toggle. Fully progressive: if reduced
   motion is requested, it renders one completed scene and stops.
   ========================================================================== */
(function () {
  var typedEl   = document.getElementById("demo-typed");
  var ghostEl   = document.getElementById("demo-ghost");
  var caretEl   = document.getElementById("demo-caret");
  var keyEl     = document.getElementById("demo-key");
  var appName   = document.getElementById("demo-app-name");
  var net       = document.getElementById("demo-net");
  var netLabel  = document.getElementById("demo-net-label");
  var offlineEl = document.getElementById("demo-offline");
  if (!typedEl || !ghostEl) return;

  var scenes = [
    { app: "Mail",     typed: "Thanks for the update — I'll review the ", ghost: "draft and send notes by end of day." },
    { app: "Slack",    typed: "Hey team, just shipped the fix. Let me ",  ghost: "know if anything looks off on staging." },
    { app: "Code",     typed: "def parse_config(path):\n    return ",      ghost: "json.loads(Path(path).read_text())" },
    { app: "Messages", typed: "Looking forward to it — talk ",            ghost: "soon and have a great weekend!" }
  ];

  /* ---- offline toggle (user-controllable + auto-demonstrated) ---------- */
  var online = true;
  var userPinned = false; // once the user clicks, stop auto-toggling
  function setOnline(v) {
    online = v;
    if (net) { net.dataset.online = String(v); net.setAttribute("aria-pressed", String(v)); }
    if (netLabel) netLabel.textContent = v ? "Wi-Fi" : "Offline";
    if (offlineEl) offlineEl.classList.toggle("show", !v);
  }
  if (net) {
    net.addEventListener("click", function () {
      userPinned = true;
      setOnline(!online);
    });
  }

  var reduce = window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  if (reduce) {
    var s0 = scenes[0];
    appName.textContent = s0.app;
    typedEl.textContent = s0.typed;
    ghostEl.textContent = s0.ghost;
    return;
  }

  var sleep = function (ms) { return new Promise(function (r) { setTimeout(r, ms); }); };

  function pressKey() {
    if (!keyEl) return sleep(110);
    keyEl.classList.add("press");
    return sleep(120).then(function () { keyEl.classList.remove("press"); return sleep(40); });
  }

  async function typeOut(text) {
    typedEl.textContent = "";
    for (var i = 0; i < text.length; i++) {
      var ch = text[i];
      typedEl.textContent += ch;
      var d = 24 + Math.random() * 22;
      if (ch === " ") d = 50;
      else if (".,—!?:)".indexOf(ch) !== -1) d = 150;
      else if (ch === "\n") d = 220;
      await sleep(d);
    }
  }

  function fadeInGhost(text) {
    ghostEl.textContent = text;
    ghostEl.style.opacity = "0";
    return new Promise(function (resolve) {
      requestAnimationFrame(function () {
        ghostEl.style.transition = "opacity .45s ease";
        ghostEl.style.opacity = "1";
        setTimeout(resolve, 460);
      });
    });
  }

  async function acceptGhost(ghost) {
    // Split into word + trailing whitespace chunks; accept one per Tab press.
    var parts = ghost.match(/\S+\s*/g) || [ghost];
    var consumed = 0;
    for (var k = 0; k < parts.length; k++) {
      await pressKey();
      consumed += parts[k].length;
      typedEl.textContent += parts[k];
      ghostEl.textContent = ghost.slice(consumed);
      await sleep(230);
    }
  }

  async function run() {
    var i = 0;
    while (true) {
      var sc = scenes[i];
      if (appName) appName.textContent = sc.app;

      // reset
      typedEl.textContent = "";
      ghostEl.textContent = "";
      ghostEl.style.opacity = "1";
      await sleep(320);

      await typeOut(sc.typed);
      await sleep(360);
      await fadeInGhost(sc.ghost);
      await sleep(820);

      // On the Slack scene, auto-demonstrate that it still works offline.
      if (i === 1 && !userPinned) { setOnline(false); await sleep(620); }

      await acceptGhost(sc.ghost);
      await sleep(1500);

      if (!userPinned && !online) setOnline(true);
      i = (i + 1) % scenes.length;
    }
  }

  run();
})();

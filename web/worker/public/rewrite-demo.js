/* ============================================================================
   Shadowtype rewrite demo — interactive on-page demonstration of the
   selection-rewrite feature (PRD selection-rewrite). Click a chip → the
   "Selected" text is rewritten in-place per that action with a brief
   processing pulse + faux local-latency stamp. No network call: rewrites
   are canned per (sourceKey × actionKey). The Try-Another button cycles
   through a handful of believable source examples so the demo doesn't
   read as a single staged scene.
   ========================================================================== */
(function () {
  var demo = document.getElementById("rewrite-demo");
  var beforeEl = document.getElementById("rewrite-before");
  var afterEl = document.getElementById("rewrite-after");
  var actionLabel = document.getElementById("rewrite-action-label");
  var latencyVal = document.getElementById("rewrite-latency-val");
  var pulse = document.getElementById("rewrite-pulse");
  var cycleBtn = document.getElementById("rewrite-cycle");
  if (!demo || !beforeEl || !afterEl || !actionLabel) return;

  /* Each source is a short, recognizable slice of real writing — a casual
     Slack DM, a sloppy email draft, a half-baked PR description. The keys
     map to the six action chips. Outputs are deliberately specific so
     "Make casual" actually sounds casual, not just a synonym swap. */
  var SOURCES = [
    {
      key: "dm",
      label: "Casual DM",
      text: "hey can u send me that doc when u get a sec",
      rewrites: {
        rewrite:   "Hey — could you send that doc whenever you have a chance?",
        shorter:   "Send the doc when you can?",
        formal:    "Could you please send me that document when you have a moment?",
        casual:    "yo when u got a sec, mind sending that doc over?",
        grammar:   "Hey, can you send me that doc when you get a sec?",
        summarize: "Request: send the doc when free."
      }
    },
    {
      key: "email",
      label: "Sloppy email",
      text: "thx for the heads up, will look into it monday and revert back",
      rewrites: {
        rewrite:   "Thanks for the heads-up — I'll look into it on Monday and follow up.",
        shorter:   "Thanks — looking into it Monday.",
        formal:    "Thank you for letting me know. I will investigate on Monday and respond accordingly.",
        casual:    "thanks for the flag! looking at it monday, will hit you back.",
        grammar:   "Thanks for the heads-up — I'll look into it Monday and revert back to you.",
        summarize: "Will investigate Monday; will reply after."
      }
    },
    {
      key: "pr",
      label: "PR description",
      text: "fix bug where cache key collides when user switches workspace mid-session causing wrong data to show",
      rewrites: {
        rewrite:   "Fix: cache key collision when a user switches workspace mid-session caused stale data to render.",
        shorter:   "Fix cache-key collision on mid-session workspace switch.",
        formal:    "Resolves a defect in which the cache key collided after an in-session workspace change, resulting in incorrect data being displayed.",
        casual:    "fixes the dumb bug where switching workspace mid-session served the wrong cached data.",
        grammar:   "Fix bug where the cache key collides when the user switches workspaces mid-session, causing the wrong data to show.",
        summarize: "Cache-key collision on workspace switch → wrong data; fixed."
      }
    },
    {
      key: "support",
      label: "Support reply",
      text: "sorry for the late reply, the issue you reported is actually a known one and were working on a fix",
      rewrites: {
        rewrite:   "Apologies for the late reply — the issue you flagged is a known one, and we're already working on a fix.",
        shorter:   "Sorry for the delay — known issue, fix in progress.",
        formal:    "Apologies for the delayed response. The issue you reported is currently known to us, and a fix is in progress.",
        casual:    "sorry for the slow reply! that bug is known and we're on it 🙏",
        grammar:   "Sorry for the late reply — the issue you reported is actually a known one, and we're working on a fix.",
        summarize: "Known issue; fix in progress."
      }
    }
  ];

  var ACTION_LABELS = {
    rewrite:   "Rewrite",
    shorter:   "Make shorter",
    formal:    "Make formal",
    casual:    "Make casual",
    grammar:   "Fix grammar",
    summarize: "Summarize"
  };

  /* Per-action latency window. Believable variance so it doesn't read as a
     constant stamp; longer actions (Summarize) take slightly more time. */
  var LATENCY_MS = {
    rewrite:   [120, 180],
    shorter:   [95,  140],
    formal:    [140, 200],
    casual:    [110, 160],
    grammar:   [80,  130],
    summarize: [160, 230]
  };

  var sourceIdx = 0;
  var currentAction = "formal";

  var reduce = window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  var sleep = function (ms) { return new Promise(function (r) { setTimeout(r, ms); }); };
  var randInt = function (lo, hi) {
    /* Picked from a fixed phase so the demo is deterministic per page load
       (the first few clicks always pick the same numbers — Math.random would
       feel jittery but the source is staged, so steadiness reads better). */
    var seed = (lo + hi) >>> 0;
    return lo + ((seed * 9301 + 49297) % (hi - lo + 1) | 0);
  };

  function setLatency(action) {
    if (!latencyVal) return;
    var range = LATENCY_MS[action] || [120, 160];
    var ms = randInt(range[0], range[1]);
    latencyVal.textContent = "~" + ms + " ms · M2 · local model";
  }

  function setActiveChip(action) {
    var chips = demo.querySelectorAll(".rewrite-chip");
    chips.forEach(function (c) {
      var isActive = c.dataset.action === action;
      c.classList.toggle("is-active", isActive);
      if (isActive) c.setAttribute("aria-pressed", "true");
      else c.removeAttribute("aria-pressed");
    });
  }

  async function applyAction(action, opts) {
    var src = SOURCES[sourceIdx];
    var out = (src.rewrites && src.rewrites[action]) || src.text;
    var label = ACTION_LABELS[action] || action;
    currentAction = action;
    setActiveChip(action);
    actionLabel.textContent = label;

    if (reduce) {
      afterEl.textContent = out;
      setLatency(action);
      return;
    }

    /* fade old, pulse, swap, fade in. Skip the pulse on the initial paint
       (opts.instant) so the page doesn't run an unprompted animation on load. */
    if (!opts || !opts.instant) {
      afterEl.classList.add("is-loading");
      if (pulse) pulse.classList.add("show");
      await sleep(160);
    }
    afterEl.textContent = out;
    setLatency(action);
    if (pulse) pulse.classList.remove("show");
    afterEl.classList.remove("is-loading");
    afterEl.classList.add("is-fresh");
    /* drop the freshness highlight after the CSS transition completes */
    setTimeout(function () { afterEl.classList.remove("is-fresh"); }, 420);
  }

  function applySource(idx, opts) {
    sourceIdx = (idx + SOURCES.length) % SOURCES.length;
    var src = SOURCES[sourceIdx];
    demo.dataset.source = src.key;
    beforeEl.textContent = src.text;
    /* Re-run the current action against the new source so the OUTPUT visibly
       changes too — otherwise cycling the source would leave the same
       "formal" rewrite stale at the bottom of the card. */
    applyAction(currentAction, opts);
  }

  /* Wire chips */
  demo.querySelectorAll(".rewrite-chip").forEach(function (chip) {
    chip.addEventListener("click", function () {
      var action = chip.dataset.action;
      if (!action) return;
      applyAction(action);
    });
  });

  /* Wire cycle button */
  if (cycleBtn) {
    cycleBtn.addEventListener("click", function () { applySource(sourceIdx + 1); });
  }

  /* Set initial latency stamp without running the load animation */
  setLatency(currentAction);
})();

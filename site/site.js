/* Barback site: the live menu bar, plus a few small touches. No dependencies, no tracking. */
(() => {
  "use strict";

  const root = document.documentElement;
  root.classList.add("io");

  const $ = (sel, ctx = document) => ctx.querySelector(sel);
  const $$ = (sel, ctx = document) => Array.from(ctx.querySelectorAll(sel));
  const reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)");

  const mb = $("#menubar");
  if (!mb) return;
  const bar = $(".mb-bar", mb);
  const chevron = $("#mb-chevron");
  const groupHidden = $("#mb-hidden");
  const groupAlways = $("#mb-always");
  const fuse = $("#mb-fuse");
  const help = $("#mb-help");
  const timer = $("#mb-timer");
  const live = $("#mb-live");
  const keyB = $("#key-b");
  const keyOpt = $("#key-opt");
  const code = { obj: $("#code-obj"), num: $("#code-num"), com: $("#code-com") };

  const REHIDE_MS = 10000;
  const timerDefault = timer.textContent;

  let state = mb.dataset.state || "hidden";
  let pointerInBar = false;
  let altDown = false;
  let optLatched = false;
  let bKeyOn = true;
  let rehideAt = 0;
  let rehideTimer = 0;
  let ticker = 0;
  let fuseAnim = null;
  let demoTimers = [];

  /* What the separators are doing, in Barback's own terms. */
  const CODE = {
    hidden: ["hiddenSeparator", "10_000", "// hidden items pushed off-screen"],
    shown: ["hiddenSeparator", "14", "// back to a sliver: hidden items are out"],
    tucked: ["alwaysHiddenSeparator", "10_000", "// always-hidden items pushed off-screen"],
    all: ["alwaysHiddenSeparator", "14", "// everything’s out, always-hidden too"],
  };

  function say(text) {
    clearTimeout(say.t);
    live.textContent = "";
    say.t = setTimeout(() => { live.textContent = text; }, 50);
  }

  function flash(el) {
    el.classList.remove("flash");
    void el.offsetWidth;
    el.classList.add("flash");
  }

  function setGroup(el, visible) {
    el.setAttribute("aria-hidden", String(!visible));
    el.toggleAttribute("inert", !visible);
  }

  function message(prev, next, auto) {
    if (next === "hidden") return auto ? "Auto-rehide: menu bar items hidden again." : "Menu bar items hidden.";
    if (next === "all") return "All menu bar items shown, always-hidden ones too. They hide again in 10 seconds.";
    if (prev === "all") return "Always-hidden items tucked away. Hidden items are still showing.";
    return "Hidden menu bar items shown. They hide again in 10 seconds.";
  }

  function setState(next, { announce = true, rehide = true, auto = false } = {}) {
    const prev = state;
    if (next === prev) return;
    state = next;
    mb.dataset.state = next;
    chevron.setAttribute("aria-pressed", String(next !== "hidden"));
    setGroup(groupHidden, next !== "hidden");
    setGroup(groupAlways, next === "all");

    const [obj, num, com] = CODE[next === "shown" && prev === "all" ? "tucked" : next];
    code.obj.textContent = obj;
    code.num.textContent = num;
    code.com.textContent = com;
    flash(code.num);

    stopRehide();
    if (next !== "hidden" && rehide) startRehide();
    if (announce) say(message(prev, next, auto));
  }

  /* Auto-rehide: a 10-second fuse that waits while the pointer is in the menu bar. */
  function startRehide() {
    stopRehide();
    rehideAt = performance.now() + REHIDE_MS;
    rehideTimer = setTimeout(expire, REHIDE_MS);
    ticker = setInterval(tick, 250);
    tick();
    timer.classList.add("is-live");
    if (!reduceMotion.matches && fuse.animate) {
      fuseAnim = fuse.animate(
        [{ transform: "scaleX(1)" }, { transform: "scaleX(0)" }],
        { duration: REHIDE_MS, easing: "linear" }
      );
    }
  }

  function stopRehide() {
    clearTimeout(rehideTimer);
    clearInterval(ticker);
    rehideTimer = ticker = 0;
    if (fuseAnim) fuseAnim.cancel();
    fuseAnim = null;
    mb.classList.remove("is-waiting");
    timer.classList.remove("is-live", "is-wait");
    timer.textContent = timerDefault;
  }

  function tick() {
    const left = Math.max(0, Math.ceil((rehideAt - performance.now()) / 1000));
    timer.textContent = `Auto-rehide in ${left} s`;
  }

  function expire() {
    if (pointerInBar) {
      clearInterval(ticker);
      if (fuseAnim) fuseAnim.cancel();
      fuseAnim = null;
      mb.classList.add("is-waiting");
      timer.classList.remove("is-live");
      timer.classList.add("is-wait");
      timer.textContent = "Waiting: your pointer’s in the menu bar";
      rehideTimer = setTimeout(expire, 2000);
      return;
    }
    setState("hidden", { auto: true });
  }

  bar.addEventListener("pointerenter", () => { pointerInBar = true; });
  bar.addEventListener("pointerleave", () => {
    pointerInBar = false;
    if (mb.classList.contains("is-waiting")) {
      clearTimeout(rehideTimer);
      rehideTimer = setTimeout(expire, 700);
    }
  });

  /* Input: the chevron, Option (held or latched), B and ⌃⌥⌘B. */
  function cancelDemo() {
    demoTimers.forEach(clearTimeout);
    demoTimers = [];
  }

  function act(alt) {
    cancelDemo();
    const all = alt || optLatched;
    if (optLatched) setLatch(false);
    if (all) setState(state === "all" ? "hidden" : "all");
    else setState(state === "hidden" ? "shown" : "hidden");
  }

  function syncOpt() {
    mb.classList.toggle("is-opt", altDown || optLatched);
    keyOpt.classList.toggle("is-held", altDown);
  }

  function setLatch(on) {
    optLatched = on;
    keyOpt.setAttribute("aria-pressed", String(on));
    syncOpt();
  }

  function setAlt(down) {
    if (down === altDown) return;
    altDown = down;
    syncOpt();
  }

  function applyBKey(on) {
    bKeyOn = on;
    keyB.setAttribute("aria-pressed", String(on));
    keyB.title = on ? "Single-key shortcut is on (click to turn it off)" : "Single-key shortcut is off (click to turn it on)";
  }

  const isTyping = (el) => !!(el && el.closest && el.closest("input, textarea, select, [contenteditable]"));

  chevron.addEventListener("click", (e) => act(e.altKey));
  bar.addEventListener("pointermove", (e) => setAlt(e.altKey));

  keyOpt.addEventListener("click", () => {
    setLatch(!optLatched);
    say(optLatched ? "Option latched. The next click or B press shows always-hidden items too." : "Option released.");
  });

  keyB.addEventListener("click", () => {
    applyBKey(!bKeyOn);
    try { localStorage.setItem("barback-b", bKeyOn ? "on" : "off"); } catch (err) { /* storage may be blocked */ }
    say(bKeyOn ? "B key shortcut on." : "B key shortcut off. ⌃⌥⌘B still works.");
  });

  addEventListener("keydown", (e) => {
    if (e.key === "Alt") { setAlt(true); return; }
    if (e.code !== "KeyB" || e.repeat || e.isComposing) return;
    const hotkey = e.ctrlKey && e.altKey && e.metaKey && !e.shiftKey;
    const single = !e.ctrlKey && !e.altKey && !e.metaKey && !e.shiftKey && bKeyOn && !isTyping(e.target);
    if (hotkey || single) {
      e.preventDefault();
      act(false);
    }
  });
  addEventListener("keyup", (e) => { if (e.key === "Alt") setAlt(false); });
  addEventListener("blur", () => setAlt(false));

  /* First pour: show everything, tuck the always-hidden items, then the hidden ones. */
  function pourIn() {
    mb.removeAttribute("data-boot");
    mb.classList.add("is-pouring");
    setTimeout(() => mb.classList.remove("is-pouring"), 1800);
  }

  function runDemo() {
    mb.classList.add("is-instant");
    setState("all", { announce: false, rehide: false });
    void mb.offsetWidth;
    mb.classList.remove("is-instant");
    pourIn();
    demoTimers.push(setTimeout(() => setState("shown", { announce: false, rehide: false }), 1900));
    demoTimers.push(setTimeout(() => { setState("hidden", { announce: false }); demoTimers = []; }, 3200));
  }

  /* Copy buttons. */
  function legacyCopy(text) {
    const active = document.activeElement;
    const ta = document.createElement("textarea");
    ta.value = text;
    ta.setAttribute("readonly", "");
    ta.style.cssText = "position:fixed;top:0;left:0;opacity:0";
    document.body.append(ta);
    ta.select();
    let ok = false;
    try { ok = document.execCommand("copy"); } catch (err) { ok = false; }
    ta.remove();
    if (active && active.focus) active.focus();
    return ok;
  }

  $$("[data-copy]").forEach((btn) => {
    btn.hidden = false;
    btn.addEventListener("click", async () => {
      const text = btn.dataset.copy;
      let ok = false;
      try {
        await navigator.clipboard.writeText(text);
        ok = true;
      } catch (err) {
        ok = legacyCopy(text);
      }
      if (!ok) { say("Couldn’t copy. Select the command and press ⌘C."); return; }
      btn.textContent = "Copied";
      btn.classList.add("is-done");
      say("Install command copied.");
      clearTimeout(btn.copyTimer);
      btn.copyTimer = setTimeout(() => {
        btn.textContent = "Copy";
        btn.classList.remove("is-done");
      }, 2000);
    });
  });

  /* Reveal on scroll, print the receipt. */
  const receipt = $("#receipt");
  const reveals = $$(".reveal");
  if (receipt) $$(".r-lines > div", receipt).forEach((row, i) => row.style.setProperty("--n", i));
  if (!("IntersectionObserver" in window) || reduceMotion.matches) {
    reveals.forEach((el) => el.classList.add("is-in"));
    if (receipt) receipt.classList.add("is-printed");
  } else {
    const io = new IntersectionObserver((entries) => {
      entries.forEach((entry) => {
        if (!entry.isIntersecting) return;
        entry.target.classList.add(entry.target === receipt ? "is-printed" : "is-in");
        io.unobserve(entry.target);
      });
    }, { rootMargin: "0px 0px -10% 0px" });
    reveals.forEach((el) => io.observe(el));
    if (receipt) io.observe(receipt);
  }

  /* Scroll spy for the menu bar's menus. */
  if ("IntersectionObserver" in window) {
    const links = new Map();
    $$(".mb-menus a[href^='#']:not(.mb-app)").forEach((a) => {
      const section = document.getElementById(a.hash.slice(1));
      if (section) links.set(section, a);
    });
    const spy = new IntersectionObserver((entries) => {
      entries.forEach((entry) => {
        const link = links.get(entry.target);
        if (entry.isIntersecting) {
          links.forEach((a) => a.removeAttribute("aria-current"));
          link.setAttribute("aria-current", "true");
        } else {
          link.removeAttribute("aria-current");
        }
      });
    }, { rootMargin: "-45% 0px -50% 0px" });
    links.forEach((_, section) => spy.observe(section));
  }

  /* The clock, in the visitor's own locale. */
  const day = $("#mb-day");
  const time = $("#mb-time");
  const ampm = $("#mb-ampm");
  function clock() {
    const now = new Date();
    try {
      day.textContent = new Intl.DateTimeFormat(undefined, { weekday: "short" }).format(now);
      const parts = new Intl.DateTimeFormat(undefined, { hour: "numeric", minute: "2-digit" }).formatToParts(now);
      const period = parts.find((p) => p.type === "dayPeriod");
      time.textContent = parts.filter((p) => p.type !== "dayPeriod").map((p) => p.value).join("").trim();
      ampm.textContent = period ? period.value : "";
    } catch (err) { /* keep the static time */ }
    setTimeout(clock, (60 - now.getSeconds()) * 1000 - now.getMilliseconds() + 50);
  }

  /* Wake up. */
  try { applyBKey(localStorage.getItem("barback-b") !== "off"); } catch (err) { applyBKey(true); }
  chevron.disabled = false;
  help.hidden = false;
  clock();

  if (reduceMotion.matches) mb.removeAttribute("data-boot");
  else if (location.hash || window.scrollY > 40) pourIn();
  else runDemo();
})();

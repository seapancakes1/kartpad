// The controller page a phone opens from the QR code (KartPadPhoneControllers.inc.mm serves it). One
// file with its styles and script, so every way of running KartPad has it. It speaks the protocol in
// kartpad/network/phone_pad.h: the button bits below follow phone_pad::Button.
// Included by KartPadMacShell.mm before KartPadPhoneControllers.inc.mm.

static const char KPPhonePage[] = R"KPPHONE(<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no, viewport-fit=cover">
<meta name="apple-mobile-web-app-capable" content="yes">
<meta name="mobile-web-app-capable" content="yes">
<meta name="theme-color" content="#15171d">
<title>KartPad Controller</title>
<style>
:root { --accent: #8a8f9c; --bg: #15171d; --key: #262a33; --keyDown: #3a404c; --text: #f2f3f5; --dim: #9aa0ab; }
* { box-sizing: border-box; -webkit-tap-highlight-color: transparent; }
html, body { position: fixed; inset: 0; margin: 0; overflow: hidden; background: var(--bg); color: var(--text);
  font: 600 16px/1.2 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
  touch-action: none; overscroll-behavior: none; user-select: none; -webkit-user-select: none; -webkit-touch-callout: none; }
#pad { position: absolute; inset: 0; padding: env(safe-area-inset-top) env(safe-area-inset-right) env(safe-area-inset-bottom) env(safe-area-inset-left); }
.key { position: absolute; display: flex; align-items: center; justify-content: center; border-radius: 50%;
  background: var(--key); border: 2px solid rgba(255,255,255,.08); color: var(--text); letter-spacing: .04em; }
.key.down { background: var(--keyDown); transform: scale(.94); }
.key small { font-size: 11px; color: var(--dim); display: block; text-align: center; }
#a { width: 34vmin; height: 34vmin; right: calc(4vw + env(safe-area-inset-right)); bottom: 8vh; font-size: 13vmin;
  background: var(--accent); color: #111; border-color: rgba(0,0,0,.15); }
#a.down { filter: brightness(.82); }
#a.locked { background: #3ad0e6; box-shadow: 0 0 0 4px rgba(58,208,230,.35); }
#r { width: 26vmin; height: 26vmin; right: calc(4vw + 38vmin + env(safe-area-inset-right)); bottom: 6vh; border-radius: 30%; font-size: 4.2vmin; }
#l { width: 22vmin; height: 22vmin; right: calc(4vw + 6vmin + env(safe-area-inset-right)); bottom: calc(8vh + 38vmin); font-size: 4.2vmin; }
#b { width: 17vmin; height: 17vmin; right: calc(4vw + 42vmin + env(safe-area-inset-right)); bottom: calc(6vh + 30vmin); font-size: 7vmin; }
#up { width: 14vmin; height: 14vmin; right: calc(4vw + 44vmin + env(safe-area-inset-right)); bottom: calc(6vh + 50vmin); border-radius: 30%; font-size: 3.4vmin; }
.top { top: calc(3vmin + env(safe-area-inset-top)); height: 11vmin; min-height: 38px; border-radius: 99px; padding: 0 4vmin; font-size: 3.6vmin; }
#home { left: calc(3vw + env(safe-area-inset-left)); }
#start { left: calc(3vw + 22vmin + env(safe-area-inset-left)); }
#leave { right: calc(3vw + env(safe-area-inset-right)); background: transparent; color: var(--dim); }
#badge { position: absolute; top: calc(3vmin + env(safe-area-inset-top)); left: 50%; transform: translateX(-50%); display: flex; align-items: center; gap: 2vmin;
  padding: 0 4vmin; height: 11vmin; min-height: 38px; border-radius: 99px; background: var(--key); font-size: 4.4vmin; white-space: nowrap; }
#badge i { width: 2.6vmin; height: 2.6vmin; min-width: 9px; min-height: 9px; border-radius: 50%; background: #e5484d; }
#badge.live i { background: #30b85c; }
#badge b { color: var(--accent); }
#stickzone { position: absolute; left: 0; top: 16vmin; bottom: 0; width: 52vw; }
#base, #knob { position: absolute; border-radius: 50%; pointer-events: none; transform: translate(-50%, -50%); }
#base { width: 36vmin; height: 36vmin; border: 2px solid rgba(255,255,255,.14); background: rgba(255,255,255,.04); }
#knob { width: 17vmin; height: 17vmin; background: var(--accent); opacity: .9; }
#base.idle, #knob.idle { opacity: .35; }
#hint { position: absolute; left: 26vw; bottom: 5vh; transform: translateX(-50%); color: var(--dim); font-size: 3.4vmin; pointer-events: none; }
.sheet { position: absolute; inset: 0; display: flex; flex-direction: column; align-items: center; justify-content: center; gap: 4vmin;
  background: var(--bg); text-align: center; padding: 6vmin; z-index: 5; }
.sheet h1 { margin: 0; font-size: max(26px, 7vmin); }
.sheet p { margin: 0; color: var(--dim); font-weight: 500; max-width: 36em; }
.sheet button { font: inherit; font-size: max(20px, 5vmin); padding: 3vmin 12vmin; border-radius: 99px; border: 0; background: #f2b51e; color: #111; }
.hidden { display: none !important; }
#turn { display: none; z-index: 9; }
@media (orientation: portrait) { #turn.wanted { display: flex; } }
</style>
</head>
<body>
<div id="pad">
  <div id="stickzone"></div>
  <div id="base" class="idle"></div><div id="knob" class="idle"></div>
  <div id="hint">Steer: touch and drag anywhere here</div>
  <div class="key top" id="home" data-bit="4096">HOME</div>
  <div class="key top" id="start" data-bit="128">PAUSE</div>
  <div id="badge"><i></i><span id="who">Connecting…</span></div>
  <div class="key top" id="leave">Leave</div>
  <div class="key" id="up" data-bit="256"><span>TRICK<small>▲</small></span></div>
  <div class="key" id="b" data-bit="2">B</div>
  <div class="key" id="l" data-bit="16">ITEM</div>
  <div class="key" id="r" data-bit="32">DRIFT</div>
  <div class="key" id="a" data-bit="1">A</div>
</div>
<div class="sheet" id="join">
  <h1>KartPad</h1>
  <p>Use this phone as a controller. Hold it sideways.</p>
  <button id="joinButton">Join</button>
  <p id="joinNote"></p>
</div>
<div class="sheet hidden" id="message"><h1 id="messageTitle"></h1><p id="messageText"></p><button id="messageButton">Try Again</button></div>
<div class="sheet" id="turn"><h1>Turn your phone sideways</h1><p>The controller works in landscape.</p></div>
<script>
"use strict";
const $ = (id) => document.getElementById(id);
const key = location.hash.slice(1);
const tokenKey = "kartpad-phone-" + key;
let ws = null, joined = false, wanted = false, seq = 0, buttons = 0, stickX = 0, stickY = 0, lastSent = "";
let retry = 0, retryTimer = 0, failedInARow = 0, wakeLock = null, aLocked = false, aLockTimer = 0;

function store(name, value) { try { value == null ? sessionStorage.removeItem(name) : sessionStorage.setItem(name, value); } catch (e) {} }
function stored(name) { try { return sessionStorage.getItem(name); } catch (e) { return null; } }
function buzz(ms) { try { if (navigator.vibrate) navigator.vibrate(ms); } catch (e) {} }

function show(sheet) {
  for (const id of ["join", "message"]) $(id).classList.toggle("hidden", id !== sheet);
  $("turn").classList.toggle("wanted", sheet == null);
}
function message(title, text, button) {
  $("messageTitle").textContent = title;
  $("messageText").textContent = text;
  $("messageButton").textContent = button || "Try Again";
  show("message");
}

// ---- Sending: whenever anything changes, and every 50 ms so KartPad knows the phone is still there.
function send(force) {
  if (!ws || ws.readyState !== 1) return;
  const state = buttons + ":" + stickX + ":" + stickY;
  if (!force && state === lastSent) return;
  lastSent = state;
  const bytes = new Uint8Array(8);
  bytes[0] = 1; bytes[1] = seq = (seq + 1) & 255;
  bytes[2] = buttons & 255; bytes[3] = buttons >> 8;
  bytes[4] = stickX & 255; bytes[5] = stickY & 255;
  ws.send(bytes);
}
setInterval(() => send(true), 50);
function letGo() { buttons = 0; stickX = 0; stickY = 0; aLocked = false; clearTimeout(aLockTimer); render(); send(true); }

// ---- Connecting
function connect() {
  clearTimeout(retryTimer);
  if (ws) { ws.onclose = null; try { ws.close(); } catch (e) {} }
  const token = stored(tokenKey) || "";
  ws = new WebSocket("ws://" + location.host + "/ws?k=" + key + "&t=" + token);
  ws.binaryType = "arraybuffer";
  setLive(false, "Connecting…");
  ws.onopen = () => { retry = 0; failedInARow = 0; };
  ws.onmessage = (event) => {
    if (typeof event.data !== "string") return;
    let m; try { m = JSON.parse(event.data); } catch (e) { return; }
    if (m.t === "welcome") { store(tokenKey, m.token); joined = true; show(null); player(m.player); send(true); }
    else if (m.t === "player") player(m.player);
    else if (m.t === "color") document.documentElement.style.setProperty("--accent", m.rgb);
    else if (m.t === "rumble") buzz(m.on ? 4000 : 0);
    else if (m.t === "bye") goodbye(m.reason);
  };
  ws.onclose = () => {
    ws = null;
    if (!wanted) return;
    ++failedInARow;
    // Not even once, or gone for about a minute (KartPad quit, or restarted with a new link).
    if ((!joined && failedInARow >= 3) || failedInARow >= 15) {
      wanted = false;
      letGo();
      message("Can’t reach KartPad", "Make sure this phone is on the same Wi‑Fi as the Mac, then scan the code in KartPad again (Controls → Add Phone Controller…).");
      return;
    }
    setLive(false, "Reconnecting…");
    letGo();
    retryTimer = setTimeout(connect, Math.min(4000, 400 * Math.pow(2, retry++)));
  };
}
function goodbye(reason) {
  wanted = false;
  if (ws) { ws.onclose = null; ws.close(); ws = null; }
  letGo();
  if (reason === "full") message("Four phones are already playing", "Ask someone to leave, then try again.");
  else if (reason === "replaced") message("Opened somewhere else", "This controller is now in another tab or window.", "Use It Here");
  else if (reason === "left") { store(tokenKey, null); joined = false; show("join"); }
  else message("KartPad closed", "Open KartPad on the Mac and scan the code again.");
}
function setLive(live, text) { $("badge").classList.toggle("live", live); $("who").textContent = text; }
function player(n) {
  if (n >= 1) { $("who").innerHTML = "<b>P" + n + "</b>"; $("badge").classList.add("live"); }
  else { setLive(true, "Not playing"); document.documentElement.style.setProperty("--accent", "#8a8f9c"); }
}
async function keepAwake() {
  try { if (navigator.wakeLock && document.visibilityState === "visible") wakeLock = await navigator.wakeLock.request("screen"); } catch (e) {}
}
function start() {
  wanted = true; failedInARow = 0; retry = 0;
  keepAwake();
  try { if (document.documentElement.requestFullscreen) document.documentElement.requestFullscreen().catch(() => {}); } catch (e) {}
  show(null);
  connect();
}
$("joinButton").onclick = start;
$("messageButton").onclick = start;
$("leave").addEventListener("pointerdown", (e) => {
  e.stopPropagation();
  if (ws && ws.readyState === 1) ws.send(new Uint8Array([2]));
  else goodbye("left");
});
document.addEventListener("visibilitychange", () => {
  if (document.visibilityState === "hidden") {
    letGo();
    if (ws) { ws.onclose = null; ws.close(); ws = null; }
  } else if (wanted) { keepAwake(); connect(); }
});
if (!key) { $("joinButton").classList.add("hidden"); $("joinNote").textContent = "Scan the QR code in KartPad on the Mac: Controls → Add Phone Controller…"; }
show("join");

// ---- Touch: each finger is the stick or a button, and can slide from one button to another.
const keys = Array.from(document.querySelectorAll(".key[data-bit]"));
const fingers = new Map();  // pointerId → key element, or "stick"
let stick = null;           // {id, x, y}
function keyAt(x, y) {
  const el = document.elementFromPoint(x, y);
  return el && el.closest ? el.closest(".key[data-bit]") : null;
}
function radius() { return Math.min(innerWidth, innerHeight) * 0.18; }
function render() {
  let held = 0;
  for (const target of fingers.values()) if (typeof target !== "string") held |= Number(target.dataset.bit);
  if (aLocked) held |= 1;
  buttons = held;
  for (const k of keys) k.classList.toggle("down", (held & Number(k.dataset.bit)) !== 0 && !(k.id === "a" && aLocked && !fingersOn(k)));
  $("a").classList.toggle("locked", aLocked);
}
function fingersOn(k) { for (const t of fingers.values()) if (t === k) return true; return false; }
function placeStick(cx, cy, kx, ky, idle) {
  const base = $("base"), knob = $("knob");
  base.style.left = cx + "px"; base.style.top = cy + "px";
  knob.style.left = kx + "px"; knob.style.top = ky + "px";
  base.classList.toggle("idle", idle); knob.classList.toggle("idle", idle);
}
function restStick() {
  const zone = $("stickzone").getBoundingClientRect();
  const cx = zone.left + zone.width * 0.45, cy = zone.top + zone.height * 0.55;
  placeStick(cx, cy, cx, cy, true);
}
function pressA(down) {
  if (down) {
    if (aLocked) { aLocked = false; return false; }  // a tap while locked unlocks, and doesn't press
    clearTimeout(aLockTimer);
    aLockTimer = setTimeout(() => { if (fingersOn($("a"))) { aLocked = true; buzz(30); render(); send(); } }, 1000);
  } else clearTimeout(aLockTimer);
  return true;
}
document.addEventListener("pointerdown", (e) => {
  if (!joined) return;
  const k = keyAt(e.clientX, e.clientY);
  if (k) {
    if (k.id === "a" && !pressA(true)) { fingers.set(e.pointerId, "unlock"); render(); send(); return; }
    fingers.set(e.pointerId, k); buzz(8);
  } else if (!stick && e.clientX < innerWidth * 0.55 && e.clientY > innerHeight * 0.16) {
    stick = {id: e.pointerId, x: e.clientX, y: e.clientY};
    fingers.set(e.pointerId, "stick");
    placeStick(e.clientX, e.clientY, e.clientX, e.clientY, false);
  }
  render(); send();
});
document.addEventListener("pointermove", (e) => {
  const was = fingers.get(e.pointerId);
  if (was === undefined || was === "unlock") return;
  if (was === "stick") {
    let dx = e.clientX - stick.x, dy = e.clientY - stick.y;
    const r = radius(), d = Math.hypot(dx, dy);
    if (d > r) { dx *= r / d; dy *= r / d; }
    stickX = Math.round(dx / r * 127); stickY = Math.round(dy / r * 127);
    placeStick(stick.x, stick.y, stick.x + dx, stick.y + dy, false);
  } else {
    const k = keyAt(e.clientX, e.clientY);
    if (k && k !== was) {
      if (was.id === "a") pressA(false);
      if (k.id === "a" && !pressA(true)) return;
      fingers.set(e.pointerId, k); buzz(8);
    }
  }
  render(); send();
});
function lift(e) {
  const was = fingers.get(e.pointerId);
  if (was === undefined) return;
  fingers.delete(e.pointerId);
  if (was === "stick") { stick = null; stickX = 0; stickY = 0; restStick(); }
  else if (was !== "unlock" && was.id === "a") pressA(false);
  render(); send();
}
document.addEventListener("pointerup", lift);
document.addEventListener("pointercancel", lift);
for (const type of ["touchstart", "touchmove", "gesturestart", "dblclick", "contextmenu"])
  document.addEventListener(type, (e) => { if (e.target.tagName !== "BUTTON") e.preventDefault(); }, {passive: false});
addEventListener("resize", restStick);
restStick();
</script>
</body>
</html>
)KPPHONE";

// The helper page (/link) for the HTTPS controller page, which can't reach this Mac's plain-HTTP
// address itself: the controller page opens it in a second tab with its WebRTC offer and the
// phone's resume token after the #, it passes them to KartPad over /signal and the answer back to
// the controller page, then closes. {{CONTROLLER_ORIGIN}} is the only page it answers.
static const char KPPhoneHelperPage[] = R"KPHELPER(<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="theme-color" content="#15171d">
<title>Linking to KartPad</title>
<style>
  body { margin: 0; padding: 32px 20px; background: #15171d; color: #f2f3f5; text-align: center;
    font: 600 18px/1.4 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; }
  p { color: #9aa0ab; font-weight: 500; }
</style>
</head>
<body>
<h2>Linking to KartPad…</h2>
<p id="say">This tab closes by itself.</p>
<script>
"use strict";
const CONTROLLER_ORIGIN = "{{CONTROLLER_ORIGIN}}";
const f = new URLSearchParams(location.hash.slice(1));
const say = (text) => { document.getElementById("say").textContent = text; };
const unb64url = (s) => decodeURIComponent(escape(atob(s.replace(/-/g, "+").replace(/_/g, "/"))));
history.replaceState(null, "", location.pathname);  // keep the key out of the tab's history
let offer = "";
try { offer = unb64url(f.get("o") || ""); } catch (e) {}
if (!window.opener) say("This tab lost its link to the controller. Go back and tap Join again.");
else if (!offer) say("This link is incomplete. Go back and tap Join again.");
else {
  const ws = new WebSocket("ws://" + location.host + "/signal?k=" + (f.get("k") || ""));
  let answered = false;
  ws.onopen = () => ws.send("t=" + (f.get("t") || "") + "\n" + offer);
  ws.onmessage = (event) => {
    if (typeof event.data !== "string") return;
    answered = true;
    if (event.data.startsWith("error:")) {
      window.opener.postMessage({t: "link-error", why: event.data.slice(6)}, CONTROLLER_ORIGIN);
      say("KartPad couldn’t link this phone. Go back to try again.");
      return;
    }
    window.opener.postMessage({t: "answer", sdp: event.data}, CONTROLLER_ORIGIN);
    say("Linked. Going back…");
    setTimeout(() => window.close(), 250);
  };
  ws.onclose = () => { if (!answered) say("Couldn’t reach KartPad. Is it still open with this code on screen?"); };
}
</script>
</body>
</html>
)KPHELPER";

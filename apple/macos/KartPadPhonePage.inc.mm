// The pages KartPadPhoneControllers.inc.mm serves. The controller page itself is web/phone/index.html,
// the same page the tilt link opens over HTTPS; the build turns it into KPPhonePage
// (cmake/KartPadPhoneLink.cmake), so every way of running KartPad has it. Served from here it's
// touch only, over a WebSocket. Included by KartPadMacShell.mm before KartPadPhoneControllers.inc.mm.

#include "KartPadPhonePageHTML.inc"

// The helper page (/link) for the HTTPS controller page, which can't reach this Mac's plain-HTTP
// address itself: the controller page opens it in a second tab with its signal (its WebRTC offer,
// signed with the launch's key: phone_pad.h, "Joining") after the #, it passes that to KartPad over
// /signal and the answer back to the controller page, then closes. It never has the key.
// {{CONTROLLER_ORIGIN}} is the only page it answers; with each answer or error goes KartPad's
// protocol version, from its hello.
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
<p id="say"></p>
<script>
"use strict";
const CONTROLLER_ORIGIN = "{{CONTROLLER_ORIGIN}}";
const f = new URLSearchParams(location.hash.slice(1));
const say = (text) => { document.getElementById("say").textContent = text; };
const unb64url = (s) => decodeURIComponent(escape(atob(s.replace(/-/g, "+").replace(/_/g, "/"))));
history.replaceState(null, "", location.pathname);  // a reload mustn't send it again
let signal = "";
try { signal = unb64url(f.get("s") || ""); } catch (e) {}
if (!window.opener) say("This tab lost its link to the controller. Go back and tap Join again.");
else if (!signal) say("This link is incomplete. Go back and tap Join again.");
else {
  const ws = new WebSocket("ws://" + location.host + "/signal");
  let answered = false, version = 0;
  ws.onopen = () => ws.send(signal);
  ws.onmessage = (event) => {
    if (typeof event.data !== "string") return;
    if (event.data.startsWith("{")) {  // KartPad's hello
      try { version = JSON.parse(event.data).v || 0; } catch (e) {}
      return;
    }
    answered = true;
    if (event.data.startsWith("error:")) {
      window.opener.postMessage({t: "link-error", why: event.data.slice(6), v: version}, CONTROLLER_ORIGIN);
      say("KartPad couldn’t link this phone. Go back to try again.");
      return;
    }
    window.opener.postMessage({t: "answer", sdp: event.data, v: version}, CONTROLLER_ORIGIN);
    say("Linked. Going back…");
    setTimeout(() => window.close(), 250);
  };
  ws.onclose = () => { if (!answered) say("Couldn’t reach KartPad. Keep the code on screen and try again."); };
}
</script>
</body>
</html>
)KPHELPER";

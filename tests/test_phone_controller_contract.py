"""The phone controller page agrees with the Mac side: the same message bytes, race views, joining
and protocol version as phone_pad.h, the same tilt steering as KartPad's iPhone motion steering, the
routes the Mac serves, one page for both links (the Mac builds web/phone/index.html into the app), a
tilt page only where a build publishes one, and the phone link's archives in dependencies.lock.json."""
import hashlib
import hmac
import json
import os
import re
import shutil
import subprocess
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
HEADER = (ROOT / "runtime/include/kartpad/network/phone_pad.h").read_text()
PAGE = (ROOT / "web/phone/index.html").read_text()
MAC_PAGES = (ROOT / "apple/macos/KartPadPhonePage.inc.mm").read_text()
MAC = (ROOT / "apple/macos/KartPadPhoneControllers.inc.mm").read_text()
LINK_CMAKE = (ROOT / "cmake/KartPadPhoneLink.cmake").read_text()
IOS_MOTION = (ROOT / "apple/mobile/KartPadMotionSteering.mm").read_text()
HELPER_PAGE = MAC_PAGES.split('R"KPHELPER(')[1].split(')KPHELPER"')[0]
TESTS = (ROOT / "runtime/tests/phone_pad_tests.cpp").read_text()
LOCK = json.loads((ROOT / "dependencies.lock.json").read_text())
PRODUCTS = ROOT / "vendor/runtimes/macos/runtime/cmake/PublicProducts.cmake"
# The page's SHA-256, HMAC and join messages: everything from its "Joining" heading to the next one.
JOINING = "// ---- Joining" + PAGE.split("// ---- Joining")[1].split("// ----")[0]


def header_buttons():
    return {name: 1 << int(bit) for name, bit in re.findall(r"Button(\w+) = 1 << (\d+)", HEADER)}


class PhoneControllerContract(unittest.TestCase):
    def test_page_uses_the_headers_button_bits(self):
        bits = header_buttons()
        expected = {"a": bits["A"], "b": bits["B"], "l": bits["L"], "r": bits["R"], "up": bits["Up"],
                    "down": bits["Down"], "left": bits["Left"], "right": bits["Right"], "start": bits["Start"]}
        keys = {}
        for name, bit in re.findall(r'data-key="(\w+)" data-bit="(\d+)"', PAGE):
            self.assertEqual(keys.setdefault(name, int(bit)), int(bit), "every %s button sends the same bit" % name)
        self.assertEqual(keys, expected)
        # HOME is held rather than pressed; A+B and the seams press two buttons at once.
        self.assertIn("pressed |= %d" % bits["Home"], PAGE)
        self.assertIn('class="key round k-ab" data-bit="%d"' % (bits["A"] | bits["B"]), PAGE)
        self.assertIn('class="seam s-drift-a" data-bit="%d"' % (bits["R"] | bits["A"]), PAGE)
        self.assertIn('class="seam s-a-b" data-bit="%d"' % (bits["A"] | bits["B"]), PAGE)

    def test_item_aims_with_the_sticks_y(self):
        # Up on the stick is negative (SDL's way), as KartPad passes it on; full either way.
        self.assertIn("return share < 0.32 ? -127 : share > 0.68 ? 127 : 0;", PAGE)
        self.assertIn("y = itemAim() || y;", PAGE)
        self.assertIn("bytes[5] = y & 255", PAGE)

    def test_page_sends_the_headers_messages(self):
        self.assertIn("StateMessage = 1, LeaveMessage = 2, PingMessage = 3, DelayMessage = 4", HEADER)
        self.assertIn("StateMessageSize = 8, PingMessageSize = 3, DelayMessageSize = 3", HEADER)
        self.assertIn("new Uint8Array(8)", PAGE)
        self.assertIn("bytes[0] = 1;", PAGE)
        self.assertIn("new Uint8Array([2])", PAGE)
        self.assertIn("new Uint8Array([3, pingId & 255, pingId >> 8])", PAGE)
        self.assertIn("new Uint8Array([4, ms & 255, ms >> 8])", PAGE)

    def test_page_knows_every_race_view(self):
        names = re.search(r"RaceViewNames\[\] = \{([^}]*)\};", HEADER).group(1)
        views = re.findall(r'"(\w+)"', names)
        self.assertEqual(views, ["menus", "start", "race", "unknown", "fall"])
        self.assertIn("RaceView : uint8_t { Menus, Start, Race, Unknown, Fall }", HEADER)
        self.assertIn("[%s].includes(next)" % ", ".join('"%s"' % v for v in views), PAGE)
        self.assertIn('m.t === "race"', PAGE)

    def test_tilt_matches_iphone_motion_steering(self):
        dead = re.search(r"kDeadZone = ([\d.]+);", IOS_MOTION).group(1)
        lock = re.search(r"fullLock = ([\d.]+) / boundedSensitivity", IOS_MOTION).group(1)
        rearm = re.search(r"kRearmAcceleration = ([\d.]+);", IOS_MOTION).group(1)
        trigger = re.search(r"kTriggerAcceleration = ([\d.]+);", IOS_MOTION).group(1)
        cooldown = re.search(r"kCooldownSeconds = ([\d.]+);", IOS_MOTION).group(1)
        self.assertIn(f"DEAD_ZONE = {dead}, FULL_LOCK = {lock};", PAGE)
        self.assertIn(f"SHAKE_REARM = {rearm}, SHAKE_TRIGGER = {trigger}, SHAKE_COOLDOWN = {cooldown};", PAGE)
        self.assertIn("hypot(gravity.x, gravity.y) >= 0.08", IOS_MOTION)
        self.assertIn("Math.hypot(gx, gy) / G < 0.08", PAGE)

    def test_sensitivity_only_changes_steering(self):
        # The Sensitivity buttons set how far to tilt for full lock, not how hard a shake has to be.
        steering = PAGE.split("function steering(")[1].split("\n}\n")[0]
        shake = PAGE.split("function shake(")[1].split("\n}\n")[0]
        self.assertIn("prefs.sensitivity", steering)
        self.assertEqual(PAGE.count("prefs.sensitivity"), steering.count("prefs.sensitivity"))
        self.assertNotIn("prefs", shake)
        self.assertNotIn("sensitivity", re.search(r"KartPadShakeActionForSample\([^)]*\)", IOS_MOTION).group(0))

    def test_tilt_steers_from_gravity_not_raw_acceleration(self):
        # The raw accelerometer moves with every swing of the phone; gravity alone gives the angle.
        self.assertIn("gx = all.x - own.x;", PAGE)
        self.assertIn("gy = all.y - own.y;", PAGE)
        self.assertIn("Math.atan2(gy, gx)", PAGE)

    def test_webrtc_websocket_and_routes_line_up(self):
        self.assertIn('createDataChannel("pad", {ordered: false, maxRetransmits: 0})', PAGE)
        self.assertIn('createDataChannel("control")', PAGE)
        self.assertIn('name == "pad"', MAC)
        self.assertIn('name == "control"', MAC)
        self.assertIn('macOrigin + "/link#s=" + b64url(signalMessage(key, phoneId(), offer))', PAGE)
        self.assertIn('request.path == "/link"', MAC)
        self.assertIn('new WebSocket("ws://" + location.host + "/signal")', HELPER_PAGE)
        self.assertIn('unb64url(f.get("s") || "")', HELPER_PAGE)
        self.assertIn('request.path == "/signal"', MAC)
        self.assertIn("ws.send(signal)", HELPER_PAGE)
        self.assertIn("{{CONTROLLER_ORIGIN}}", HELPER_PAGE)
        self.assertIn('new WebSocket("ws://" + location.host + "/ws")', PAGE)
        self.assertIn('request.path == "/ws"', MAC)

    def test_the_key_never_crosses_the_network(self):
        # Neither page puts it in an address it fetches or in a message; the helper page never has it.
        self.assertNotIn("?k=", PAGE + HELPER_PAGE)
        self.assertNotIn('f.get("k")', HELPER_PAGE)
        self.assertNotIn("token", PAGE)
        self.assertNotIn("QueryValue", MAC)
        self.assertIn("ws.send(joinMessage(key, phoneId(), m.nonce))", PAGE)
        self.assertIn("kpp::HelloMessage(link->nonce)", MAC)
        self.assertIn('kpp::Proves(KPPhoneKey, kpp::JoinProven(join, link->nonce), join.proof)', MAC)
        self.assertIn('kpp::Proves(KPPhoneKey, kpp::SignalProven(signal), signal.proof)', MAC)
        self.assertIn("KPPhoneReplays.Fresh(signal.proof)", MAC)

    def test_one_protocol_version(self):
        version = re.search(r"inline constexpr int ProtocolVersion = (\d+);", HEADER).group(1)
        self.assertIn("const VERSION = %s;" % version, PAGE)
        self.assertIn("static_assert(ProtocolVersion == %s" % version, TESTS)
        # Either side turns the other away by version before anything else, and the page says which to update.
        self.assertIn('kpp::MessageVersion(text, "join")', MAC)
        self.assertIn('kpp::MessageVersion(text, "signal")', MAC)
        self.assertIn('if (m.v !== VERSION) mismatch(m.v);', PAGE)
        self.assertIn('if (event.data.why === "version") return mismatch(event.data.v);', PAGE)
        self.assertIn("version = JSON.parse(event.data).v || 0;", HELPER_PAGE)

    def test_every_goodbye_is_handled_by_the_page(self):
        sent = set(re.findall(r'(?:KPPhoneSendAway|KPPhoneLetGo)\([^;]*"(\w+)"\)', MAC))
        sent |= set(re.findall(r'kpp::ByeMessage\("(\w+)"\)', MAC))
        self.assertEqual(sent, {"full", "replaced", "left", "removed", "expired", "version", "closed"})
        handled = set(re.findall(r'reason === "(\w+)"', PAGE))
        self.assertTrue(sent - {"closed"} <= handled, sent - handled)  # "closed" is the page's last case
        for reason in sent:
            self.assertIn('"%s"' % reason, HEADER.split("inline std::string ByeMessage")[0].rsplit("// ----", 1)[1])

    @unittest.skipUnless(shutil.which("node"), "needs node to run the page's JavaScript")
    def test_page_hmac_matches_python_and_the_mac(self):
        cases = {
            "sha256": [os.urandom(n).hex() for n in list(range(0, 200)) + [1000, 4097, 16384]],
            "hmac": [[os.urandom(k).hex(), os.urandom(m).hex()] for k, m in [(0, 0), (20, 8), (64, 50), (65, 3), (131, 152), (32, 4000)]],
        }
        script = """
const lib = new Function(require("fs").readFileSync(0, "utf8") +
  "\\nreturn {sha256, hmacSha256, hex, joinMessage, signalMessage};")();
const cases = JSON.parse(process.argv[1]);
const bytes = (h) => Uint8Array.from(Buffer.from(h, "hex"));
console.log(JSON.stringify({
  sha256: cases.sha256.map((h) => lib.hex(lib.sha256(bytes(h)))),
  hmac: cases.hmac.map(([k, m]) => lib.hex(lib.hmacSha256(bytes(k), bytes(m)))),
  join: lib.joinMessage("00112233445566778899aabbccddeeff", "0123456789abcdef0123456789abcdef", "fedcba9876543210fedcba9876543210"),
  signal: lib.signalMessage("00112233445566778899aabbccddeeff", "0123456789abcdef0123456789abcdef", "v=0\\r\\no=- 1 2 IN IP4 127.0.0.1\\r\\n"),
}));
"""
        out = subprocess.run(["node", "-e", script, json.dumps(cases)], input=JOINING, capture_output=True, text=True,
                             check=True, timeout=60)
        result = json.loads(out.stdout)
        self.assertEqual(result["sha256"], [hashlib.sha256(bytes.fromhex(h)).hexdigest() for h in cases["sha256"]])
        self.assertEqual(result["hmac"], [hmac.new(bytes.fromhex(k), bytes.fromhex(m), hashlib.sha256).hexdigest()
                                          for k, m in cases["hmac"]])
        # The same join and signal phone_pad_tests.cpp checks the Mac's proofs on.
        join_proof = re.search(r'kJoinProof = "(\w+)"', TESTS).group(1)
        signal_proof = re.search(r'kSignalProof = "(\w+)"', TESTS).group(1)
        self.assertEqual(result["join"], "join 1 0123456789abcdef0123456789abcdef " + join_proof)
        self.assertEqual(result["signal"], "signal 1 0123456789abcdef0123456789abcdef " + signal_proof +
                         "\nv=0\r\no=- 1 2 IN IP4 127.0.0.1\r\n")
        key = b"00112233445566778899aabbccddeeff"
        self.assertEqual(join_proof, hmac.new(key, b"join 1 0123456789abcdef0123456789abcdef fedcba9876543210fedcba9876543210",
                                              hashlib.sha256).hexdigest())

    def test_the_mac_serves_the_same_page(self):
        self.assertIn('#include "KartPadPhonePageHTML.inc"', MAC_PAGES)
        self.assertNotIn("<!doctype html>\n<html", MAC_PAGES.split("KPHELPER")[0])
        self.assertIn("web/phone/index.html", LINK_CMAKE)
        self.assertIn("KartPadPhonePageHTML.inc", LINK_CMAKE)
        self.assertIn("static const char KPPhonePage[] = R", LINK_CMAKE)
        self.assertNotIn(')KPPAGE"', PAGE)
        self.assertIn('std::string_view(KPPhonePage, sizeof KPPhonePage - 1)', MAC)

    def test_no_stun_or_relay_servers(self):
        # Host candidates only: the link stays on the local network or doesn't happen.
        self.assertIn("new RTCPeerConnection({iceServers: []})", PAGE)
        self.assertIn("rtcConfiguration config{};", MAC)

    def test_tilt_page_is_a_build_setting(self):
        # No one's page is built in: a build says where it published web/phone, or phones get the
        # touch-only page the Mac serves.
        self.assertNotIn("github.io", MAC + MAC_PAGES)
        self.assertIn('set(KARTPAD_PHONE_PAGE_URL "" CACHE STRING', LINK_CMAKE)
        self.assertIn('MATCHES "^https://', LINK_CMAKE)
        self.assertIn('#define KARTPAD_PHONE_PAGE_URL ""', MAC)
        self.assertIn("KPPhoneDefaultPageURL = @KARTPAD_PHONE_PAGE_URL;", MAC)
        self.assertIn('if (![components.scheme isEqualToString:@"https"] || components.host.length == 0) return nil;', MAC)
        self.assertNotIn("KARTPAD_PHONE_WEBRTC", LINK_CMAKE)
        if PRODUCTS.exists():
            self.assertIn('"KARTPAD_PHONE_PAGE_URL=\\"${KARTPAD_PHONE_PAGE_URL}\\""', PRODUCTS.read_text())

    def test_the_phone_link_archives_are_locked(self):
        pins = dict(re.findall(r"URL (https://\S+)\n\s+URL_HASH SHA256=([0-9a-f]{64})", LINK_CMAKE))
        self.assertEqual(len(pins), 5)
        locked = {d["url"]: d["sha256"] for d in LOCK["dependencies"] if "url" in d}
        for url, sha256 in pins.items():
            self.assertEqual(locked.get(url), sha256, url)

    def test_input_is_taken_in_order_and_let_go_on_rejoining(self):
        self.assertIn("KPPhoneSessions.Update(phone, message.seq, message.state, KPPhoneNow())", MAC)
        join = MAC.split("static void KPPhoneJoin(")[1].split("\n}\n")[0]
        self.assertIn("KPPhoneApply(phone, {});", join)
        self.assertIn("if (state !== lastSent) repeats = secure ? 2 : 0;", PAGE)
        self.assertIn("bytes[1] = seq = (seq + 1) & 255;", PAGE)

    def test_bar_keys_act_when_let_go(self):
        # DeviceMotionEvent.requestPermission needs a user activation: a touch's pointerup, not its pointerdown.
        self.assertIn('if (bar) { fingers.set(e.pointerId, {kind: "bar", bits: 0, el: bar}); return; }', PAGE)
        self.assertIn('if (e.type === "pointerup" && inside(finger.el, e.clientX, e.clientY)) barKeys[finger.el.id]();', PAGE)
        self.assertNotIn("barKeys[bar.id]()", PAGE)

    def test_a_locked_screen_keeps_a_webrtc_link_but_not_its_buttons(self):
        silence = int(re.search(r"KPPhoneRtcSilenceMs = (\d+);", MAC).group(1))
        idle = int(re.search(r"IdleNeutralMs = (\d+);", HEADER).group(1))
        self.assertGreaterEqual(silence, 20000)
        self.assertLessEqual(idle, 1000)


if __name__ == "__main__":
    unittest.main()

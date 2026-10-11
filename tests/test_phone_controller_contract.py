"""The phone controller page agrees with the Mac side: the same message bytes and race views as
phone_pad.h, the same tilt steering as KartPad's iPhone motion steering, the routes the Mac serves,
and one page for both links (the Mac builds web/phone/index.html into the app)."""
import re
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
        self.assertIn('macOrigin + "/link#k="', PAGE)
        self.assertIn('request.path == "/link"', MAC)
        self.assertIn('"/signal?k="', HELPER_PAGE)
        self.assertIn('request.path == "/signal"', MAC)
        self.assertIn('ws.send("t=" + (f.get("t") || "") + "\\n" + offer)', HELPER_PAGE)
        self.assertIn("{{CONTROLLER_ORIGIN}}", HELPER_PAGE)
        self.assertIn('new WebSocket("ws://" + location.host + "/ws?k="', PAGE)
        self.assertIn('request.path == "/ws"', MAC)

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

    def test_tilt_page_is_the_default_and_https(self):
        url = re.search(r'KPPhoneDefaultPageURL = @"([^"]+)"', MAC).group(1)
        self.assertTrue(url.startswith("https://"), url)

    def test_a_locked_screen_keeps_a_webrtc_link_but_not_its_buttons(self):
        silence = int(re.search(r"KPPhoneRtcSilenceMs = (\d+);", MAC).group(1))
        idle = int(re.search(r"IdleNeutralMs = (\d+);", HEADER).group(1))
        self.assertGreaterEqual(silence, 20000)
        self.assertLessEqual(idle, 1000)


if __name__ == "__main__":
    unittest.main()

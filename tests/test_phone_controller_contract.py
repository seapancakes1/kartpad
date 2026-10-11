"""The phone controller pages agree with the Mac side: the same message bytes as phone_pad.h, the same
tilt steering as KartPad's iPhone motion steering, and the routes the Mac serves."""
import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
HEADER = (ROOT / "runtime/include/kartpad/network/phone_pad.h").read_text()
TILT_PAGE = (ROOT / "web/phone/index.html").read_text()
MAC_PAGES = (ROOT / "apple/macos/KartPadPhonePage.inc.mm").read_text()
MAC = (ROOT / "apple/macos/KartPadPhoneControllers.inc.mm").read_text()
IOS_MOTION = (ROOT / "apple/mobile/KartPadMotionSteering.mm").read_text()
TOUCH_PAGE = MAC_PAGES.split('R"KPPHONE(')[1].split(')KPPHONE"')[0]
HELPER_PAGE = MAC_PAGES.split('R"KPHELPER(')[1].split(')KPHELPER"')[0]


def header_buttons():
    return {name: 1 << int(bit) for name, bit in re.findall(r"Button(\w+) = 1 << (\d+)", HEADER)}


class PhoneControllerContract(unittest.TestCase):
    def test_pages_use_the_headers_button_bits(self):
        bits = header_buttons()
        expected = {"a": bits["A"], "b": bits["B"], "l": bits["L"], "r": bits["R"], "up": bits["Up"],
                    "start": bits["Start"], "home": bits["Home"]}
        for name, page in (("tilt", TILT_PAGE), ("touch", TOUCH_PAGE)):
            keys = dict(re.findall(r'id="(\w+)" data-bit="(\d+)"', page))
            self.assertEqual({k: int(v) for k, v in keys.items()}, expected, name)

    def test_pages_send_the_headers_messages(self):
        self.assertIn("StateMessage = 1, LeaveMessage = 2, PingMessage = 3", HEADER)
        self.assertIn("StateMessageSize = 8, PingMessageSize = 3", HEADER)
        for page in (TILT_PAGE, TOUCH_PAGE):
            self.assertIn("new Uint8Array(8)", page)
            self.assertIn("bytes[0] = 1;", page)
            self.assertIn("new Uint8Array([2])", page)
        self.assertIn("new Uint8Array([3, pingId & 255, pingId >> 8])", TILT_PAGE)

    def test_tilt_matches_iphone_motion_steering(self):
        dead = re.search(r"kDeadZone = ([\d.]+);", IOS_MOTION).group(1)
        lock = re.search(r"fullLock = ([\d.]+) / boundedSensitivity", IOS_MOTION).group(1)
        rearm = re.search(r"kRearmAcceleration = ([\d.]+);", IOS_MOTION).group(1)
        trigger = re.search(r"kTriggerAcceleration = ([\d.]+);", IOS_MOTION).group(1)
        cooldown = re.search(r"kCooldownSeconds = ([\d.]+);", IOS_MOTION).group(1)
        self.assertIn(f"DEAD_ZONE = {dead}, FULL_LOCK = {lock};", TILT_PAGE)
        self.assertIn(f"SHAKE_REARM = {rearm}, SHAKE_TRIGGER = {trigger}, SHAKE_COOLDOWN = {cooldown};", TILT_PAGE)
        self.assertIn("hypot(gravity.x, gravity.y) >= 0.08", IOS_MOTION)
        self.assertIn("Math.hypot(gx, gy) / G < 0.08", TILT_PAGE)

    def test_tilt_steers_from_gravity_not_raw_acceleration(self):
        # The raw accelerometer moves with every swing of the phone; gravity alone gives the angle.
        self.assertIn("gx = all.x - own.x;", TILT_PAGE)
        self.assertIn("gy = all.y - own.y;", TILT_PAGE)
        self.assertIn("Math.atan2(gy, gx)", TILT_PAGE)

    def test_webrtc_channels_and_routes_line_up(self):
        self.assertIn('createDataChannel("pad", {ordered: false, maxRetransmits: 0})', TILT_PAGE)
        self.assertIn('createDataChannel("control")', TILT_PAGE)
        self.assertIn('name == "pad"', MAC)
        self.assertIn('name == "control"', MAC)
        self.assertIn('macOrigin + "/link#k="', TILT_PAGE)
        self.assertIn('request.path == "/link"', MAC)
        self.assertIn('"/signal?k="', HELPER_PAGE)
        self.assertIn('request.path == "/signal"', MAC)
        self.assertIn('ws.send("t=" + (f.get("t") || "") + "\\n" + offer)', HELPER_PAGE)
        self.assertIn("{{CONTROLLER_ORIGIN}}", HELPER_PAGE)

    def test_no_stun_or_relay_servers(self):
        # Host candidates only: the link stays on the local network or doesn't happen.
        self.assertIn("new RTCPeerConnection({iceServers: []})", TILT_PAGE)
        self.assertIn("rtcConfiguration config{};", MAC)

    def test_tilt_page_is_the_default_and_https(self):
        url = re.search(r'KPPhoneDefaultPageURL = @"([^"]+)"', MAC).group(1)
        self.assertTrue(url.startswith("https://"), url)


if __name__ == "__main__":
    unittest.main()

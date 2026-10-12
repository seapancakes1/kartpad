from __future__ import annotations

import re
import subprocess
import unittest
from pathlib import Path


REPO = Path(__file__).resolve().parents[1]
MAC_SCREENS = ("KartPadOverlay", "KartPadUIGlyphs", "KartPadHints", "KartPadControllerArt", "KartPadHomeScreen",
               "KartPadControllersScreen", "KartPadReconnect", "KartPadGhostsScreen", "KartPadSettingsScreen")


def without_ios(text: str) -> str:
    """The Mac's view of a shared screen file: TARGET_OS_OSX true (unifdef, as the compiler sees it)."""
    result = subprocess.run(["unifdef", "-DTARGET_OS_OSX=1"], input=text, capture_output=True, text=True)
    if result.returncode not in (0, 1):
        raise AssertionError(result.stderr)
    return result.stdout


class IOSHomeContractTests(unittest.TestCase):
    def test_ios_builds_the_mac_screens_from_the_same_files(self) -> None:
        screens = (REPO / "apple/ios/KartPadScreens.mm").read_text()
        for name in MAC_SCREENS:
            self.assertIn(f'#include "../macos/{name}.inc.mm"', screens)
        cmake = (REPO / "vendor/runtimes/ios/runtime/cmake/PublicProducts.cmake").read_text()
        self.assertIn('"${MKW_KARTPAD_IOS_DIR}/KartPadScreens.mm"', cmake)

    def test_ios_blocks_leave_the_mac_text_alone(self) -> None:
        # Every iPhone and iPad difference in the shared screens sits behind TARGET_OS_OSX; with it
        # true nothing of iOS remains (the shim names, the iOS includes, the touch card).
        for name in MAC_SCREENS:
            text = (REPO / f"apple/macos/{name}.inc.mm").read_text()
            mac = without_ios(text)
            for trace in ("../ios/", "TARGET_OS_OSX", "KPOpenTouchCard", "KPScreensTouching", "UIColor"):
                self.assertNotIn(trace, mac, f"{name}: {trace}")

    def test_qa_hook_is_simulator_only(self) -> None:
        qa = (REPO / "apple/ios/KartPadScreensQA.inc.mm").read_text()
        body = qa.split("#if TARGET_OS_SIMULATOR", 1)[1].split("#else", 1)
        self.assertIn("KARTPAD_QA_DIR", body[0])
        self.assertNotIn("KARTPAD_QA_DIR", body[1])

    def test_home_opens_from_a_controller_and_menu_presses_keep_the_game_quiet(self) -> None:
        pads = (REPO / "apple/ios/KartPadScreensPads.inc.mm").read_text()
        self.assertIn("now - since < 1.0", pads)  # Menu held for a second
        self.assertIn("KPOpenHomeFromController();", pads)
        runtime = (REPO / "apple/ios/KartPadRuntimeOverlayHost.mm").read_text()
        read = runtime.split("extern \"C\" bool KartPadMobileReadClassicInputForPlayer(", 1)[1]
        self.assertIn("KartPadScreensMaskHeld(player, adapted.buttons)", read)

    def test_runtime_answers_what_the_screens_ask(self) -> None:
        overlay = (REPO / "vendor/runtimes/ios/runtime/src/settings_overlay.cpp").read_text()
        network = (REPO / "vendor/runtimes/ios/runtime/src/hle/net/network_core.cpp").read_text()
        wpad = (REPO / "vendor/runtimes/ios/runtime/src/hle/input/wpad.cpp").read_text()
        self.assertIn('extern "C" bool KartPadGameStarting()', overlay)
        self.assertIn('extern "C" bool Network_HLE_HasOpenSockets()', network)
        self.assertIn("KartPadMobileSetRumble(chan, command != 0)", wpad)
        glue = (REPO / "apple/ios/KartPadScreensGlue.inc.mm").read_text()
        self.assertIn('extern "C" void KartPadMobileSetRumble(uint32_t chan, bool on)', glue)

    def test_nintendo_layout_follows_the_printed_letters(self) -> None:
        controllers = (REPO / "apple/mobile/KartPadPhysicalControllers.mm").read_text()
        self.assertIn('[symbol hasPrefix:@"b."]', controllers)
        self.assertRegex(controllers, re.compile(r"nintendo \? pad\.buttonB : pad\.buttonA"))
        self.assertIn("KartPadControllerSlots _slots;", controllers)


if __name__ == "__main__":
    unittest.main()

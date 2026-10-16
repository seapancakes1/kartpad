"""KartPad's screens on Android (HOME, Controllers, Settings, Miis) over the game.

The screens hold the game through the runtime's event pump, take controllers as SDL sees them and
never take the key focus from SDL's surface (SDL reads gamepads there). These checks keep that true.
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "android/app/src/main"
SCREENS = APP / "java/dev/kartpad/android/screens"
RUNTIME = ROOT / "vendor/runtimes/android/runtime"


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


class AndroidHomeContract(unittest.TestCase):
    def test_runtime_pump_serves_the_screens_on_both_paths(self) -> None:
        events = read(RUNTIME / "include/aurora_events.h")
        self.assertIn('extern "C" void KartPadAndroidServiceHostScreens(const AuroraEvent* events) __attribute__((weak));', events)
        update = events[events.index("inline void UpdateAuroraAndProcessEvents()"):]
        update = update[: update.index("inline void ServicePendingAuroraEventsOnScheduler()")]
        self.assertIn("ServiceAndroidHostScreens(events);", update)
        pending = events[events.index("inline void ServicePendingAuroraEventsOnScheduler()"):]
        self.assertIn("ServiceAndroidHostScreens(events);", pending[: pending.index("\n}\n")])

    def test_hold_pumps_events_and_resyncs_the_retrace_clock(self) -> None:
        service = read(ROOT / "runtime/src/android/host_screens.cpp")
        hold = service[service.index("void Hold() {"):]
        hold = hold[: hold.index("\n}\n")]
        for needed in ("SetPausedForHost(true)", "aurora_update()", "ProcessAuroraEvents(events)",
                       "VI_HLE_ResyncAfterHostHold()", "SetPausedForHost(false)", "Network_HLE_HasOpenSockets()"):
            self.assertIn(needed, hold)
        self.assertIn("void VI_HLE_ResyncAfterHostHold()", read(RUNTIME / "src/hle/vi.cpp"))
        self.assertIn('extern "C" bool Network_HLE_HasOpenSockets()', read(RUNTIME / "src/hle/net/network_core.cpp"))
        self.assertIn('extern "C" bool KartPadGameStarting()', read(RUNTIME / "src/settings_overlay.cpp"))

    def test_pads_are_owned_not_disconnected_while_the_screens_are_open(self) -> None:
        service = read(ROOT / "runtime/src/android/host_screens.cpp")
        self.assertIn("set_standard_gamepads_host_owned", service)
        self.assertNotIn("set_standard_gamepads_active", service)
        aurora = read(ROOT / "vendor/runtimes/android/aurora-main/lib/input.cpp")
        self.assertIn("controller.m_quietButtons = controller.m_standardButtons;", aurora)
        self.assertIn("!g_standardGamepadsHostOwned.load(std::memory_order_acquire)", aurora)

    def test_screens_never_take_the_key_focus_from_sdl(self) -> None:
        overlay = read(SCREENS / "KPOverlay.kt")
        self.assertIn("isFocusable = false", overlay)
        self.assertIn("isFocusableInTouchMode = false", overlay)
        # A Dialog or PopupWindow would take the gamepads' key events away from SDL's surface.
        for path in SCREENS.glob("*.kt"):
            text = read(path)
            self.assertNotIn("PopupWindow", text, path.name)
            self.assertNotIn("AlertDialog", text, path.name)

    def test_keys_reach_the_screens_before_controller_routing(self) -> None:
        activity = read(APP / "java/dev/kartpad/android/KartPadActivity.kt")
        dispatch = activity[activity.index("override fun dispatchKeyEvent(event: KeyEvent): Boolean {"):]
        self.assertLess(dispatch.index("KartPadScreens.dispatchKey("), dispatch.index("KartPadControllerKeys.routes("))
        glue = read(SCREENS / "KartPadScreens.kt")
        self.assertIn("if (sdlReadsDevice && event.source and InputDevice.SOURCE_GAMEPAD == InputDevice.SOURCE_GAMEPAD) return false", glue)

    def test_qa_hook_is_debug_only(self) -> None:
        qa = read(SCREENS / "KartPadScreensQA.kt")
        self.assertIn("if (!BuildConfig.DEBUG || directory != null) return", qa)
        self.assertIn('File(activity.filesDir, "QA")', qa)

    def test_menu_button_opens_home(self) -> None:
        activity = read(APP / "java/dev/kartpad/android/KartPadActivity.kt")
        self.assertIn("KartPadScreens.toggleHome()", activity)
        self.assertIn("KartPadScreensSetup.install(this, mLayout)", activity)

    def test_restart_waits_for_the_game_process(self) -> None:
        chooser = read(APP / "java/dev/kartpad/android/KartPadLaunchActivity.kt")
        self.assertIn('File("/proc/$waitPid").exists()', chooser)
        activity = read(APP / "java/dev/kartpad/android/KartPadActivity.kt")
        self.assertIn("KartPadChooserActivity.EXTRA_WAIT_PID", activity)
        self.assertIn("KartPad/RequestedRuntimeProfile", activity)

    def test_screens_native_code_is_in_both_builds(self) -> None:
        cmake = read(APP / "cpp/CMakeLists.txt")
        game, fixture = cmake.split("else()\n  add_library(main SHARED", 1)
        self.assertIn("kartpad_screens_jni.cpp", game)
        self.assertIn("runtime/src/android/host_screens.cpp", game)
        self.assertIn("kartpad_screens_jni.cpp", fixture)
        self.assertIn("host_screens_fixture.cpp", fixture)
        self.assertNotIn("host_screens.cpp\"", fixture)

    def test_bundled_font_is_audited_and_credited(self) -> None:
        self.assertTrue((APP / "assets/fonts/Nunito.ttf").is_file())
        self.assertIn("SIL Open Font License", read(APP / "assets/ThirdPartyLicenses/Nunito.txt"))
        for script, prefix in (("scripts/audit-android-package.sh", "assets/"), ("scripts/audit-android-bundle.sh", "base/assets/")):
            text = read(ROOT / script)
            self.assertIn(f"{prefix}fonts/Nunito.ttf", text)
            self.assertIn(f"{prefix}ThirdPartyLicenses/Nunito.txt", text)
        self.assertIn("Nunito", read(ROOT / "THIRD_PARTY_NOTICES.md"))

    def test_pad_record_layout_matches_kotlin(self) -> None:
        header = read(ROOT / "runtime/include/kartpad/android/host_screens.hpp")
        self.assertIn("inline constexpr std::size_t kPadRecordBytes = 112;", header)
        model = read(SCREENS / "KPPadModel.kt")
        self.assertIn("internal const val RecordBytes = 112", model)
        # PadRecord's fields in order, and where Kotlin reads them.
        record = header[header.index("struct PadRecord {"):header.index("\n};", header.index("struct PadRecord {"))]
        fields = re.findall(r"^  (?:u?int\d+_t|char) (\w+)(?:\[\d+\])?", record, re.M)
        self.assertEqual(fields, ["instance", "player", "held", "pressed", "axes", "vendor", "product", "type", "labels", "flags",
                                  "guid", "name"])
        for read_at in ("buffer.getInt(at)", "getInt(at + 4)", "getInt(at + 8)", "getInt(at + 12)", "at + 16 + axis * 2",
                        "getShort(at + 28)", "getShort(at + 30)", "getInt(at + 32)", "at + 36 + it", "getInt(at + 40)",
                        "at + 44 + byte", "at + 60 + byte"):
            self.assertIn(read_at, model)


if __name__ == "__main__":
    unittest.main()

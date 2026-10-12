from __future__ import annotations

import pathlib
from runtime_sources import runtime_source, assert_runtime_staging
import unittest


REPO = pathlib.Path(__file__).resolve().parents[1]


class MacOSCursorVisibilityContractTests(unittest.TestCase):
    def test_runtime_hides_idle_cursor_but_keeps_it_for_overlays(self) -> None:
        source = runtime_source('macos', 'runtime/src/settings_overlay.cpp')
        self.assertIn("g_cursorAutoHideSeconds = c.cursorAutoHideSeconds.value_or(3);", source)
        self.assertIn("SDL_HideCursor();", source)
        self.assertIn("SDL_ShowCursor();", source)
        self.assertIn("UpdateCursorAutoHide();", source)
        # Without this ImGui re-shows the cursor on every frame.
        self.assertIn("ImGuiConfigFlags_NoMouseCursorChange", source)
        hide = source[source.index("void UpdateCursorAutoHide()"):]
        hide = hide[:hide.index("\n}\n")]
        for overlay in ("controller_mapping_wizard::IsActive()", "g_rebind.active",
                        "g_exitPromptOpen", "g_topBarVisible", "g_compatibilityVisible",
                        "KartPadControllersVisible()"):
            self.assertIn(overlay, hide)
        # Never (0) keeps the pointer visible.
        self.assertIn("g_cursorAutoHideSeconds > 0", hide)

    def test_settings_window_offers_cursor_auto_hide_choice(self) -> None:
        config = runtime_source('macos', 'runtime/include/runtime_config.h')
        self.assertIn('"video", "cursor_auto_hide_seconds"', config)
        settings = (REPO / "apple/macos/KartPadMacSettings.inc.mm").read_text()
        self.assertIn('@(c.cursorAutoHideSeconds.value_or(3))', settings)
        self.assertIn('label:@"Hide the mouse pointer" choices:@[@"Never",@"On controller input",', settings)
        self.assertIn("values:@[@0,@-1,@3,@5,@10]", settings)

    def test_controller_input_can_hide_the_pointer(self) -> None:
        config = runtime_source('macos', 'runtime/include/runtime_config.h')
        self.assertIn('"video", "cursor_hide_on_controller"', config)
        source = runtime_source('macos', 'runtime/src/settings_overlay.cpp')
        self.assertIn("g_cursorHideOnController = c.cursorHideOnController.value_or(false);", source)
        self.assertIn("IsControllerActivity(ev->sdl)", source)
        # Moving the mouse brings the pointer back.
        self.assertIn("g_controllerUsedSinceMouse = false;", source)

    def test_macos_runtime_preparation_applies_cursor_patch(self) -> None:
        prepare = (REPO / "scripts/prepare-g7-game-runtime.sh").read_text()
        assert_runtime_staging(self, 'macos')


if __name__ == "__main__":
    unittest.main()

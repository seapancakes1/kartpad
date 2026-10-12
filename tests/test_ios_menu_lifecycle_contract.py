from __future__ import annotations

import unittest
from pathlib import Path


REPO = Path(__file__).resolve().parents[1]


class IOSMenuLifecycleContractTests(unittest.TestCase):
    def test_menu_uses_one_capsule_configuration_for_all_states(self) -> None:
        source = (REPO / "apple/ios/KartPadMenuButton.h").read_text()
        self.assertIn("UIButtonConfigurationCornerStyleCapsule", source)
        self.assertIn("configuration.image = image;", source)
        self.assertIn("button.automaticallyUpdatesConfiguration = NO;", source)
        self.assertIn("background.strokeWidth = 1.0;", source)

    def test_shell_and_runtime_apply_the_menu_configuration(self) -> None:
        shell = (REPO / "apple/ios/KartPadShellViewController.mm").read_text()
        runtime = (REPO / "apple/ios/KartPadRuntimeOverlayHost.mm").read_text()
        self.assertIn("KartPadConfigureMenuButton(KartPadFindMenuButton(_overlay));", shell)
        self.assertIn("KartPadConfigureMenuButton(menuButton);", runtime)

    def test_menu_button_opens_home_and_its_menu_never_shows(self) -> None:
        runtime = (REPO / "apple/ios/KartPadRuntimeOverlayHost.mm").read_text()
        layout = runtime.split("- (void)layoutSubviews {", 1)[1].split("\n}\n", 1)[0]
        # A tap opens HOME (KartPadScreens.mm), which holds the game and has everything the old
        # drop-down had; SunPad's own menu, set again on every refresh, is cleared each layout.
        self.assertIn("menuButton.showsMenuAsPrimaryAction = NO;", layout)
        self.assertIn("@selector(kartPadOpenHome)", layout)
        self.assertIn("UIControlEventPrimaryActionTriggered", layout)
        self.assertIn("menuButton.menu = nil;", layout)
        self.assertNotIn("UIMenu menuWithTitle", runtime)
        self.assertIn("- (void)kartPadOpenHome { KartPadScreensToggleHome(); }", runtime)

    def test_home_and_settings_reach_everything_the_menu_had(self) -> None:
        screens = (REPO / "apple/ios/KartPadScreens.mm").read_text()
        for screen in ("KartPadOverlay", "KartPadHomeScreen", "KartPadControllersScreen", "KartPadGhostsScreen",
                       "KartPadSettingsScreen", "KartPadReconnect"):
            self.assertIn(f'#include "../macos/{screen}.inc.mm"', screens)
        rows = (REPO / "apple/ios/KartPadScreensSettingsRows.inc.mm").read_text()
        for host in ("screensShowMultiplayer", "screensShowMotionSteering", "screensShowShakeTricks",
                     "screensShowButtonMapping", "screensShowTouchControls", "screensManageSaves",
                     "screensManageRetroRewind", "screensManageGameData", "screensShowPrivateServer",
                     "screensShowWiiRemoteInfo", "screensReportProblem", "screensReturnToLauncher",
                     "screensSetFPSCounterSize", "renderScale", "aspectRatioMode", "showFPSCounter",
                     "setAlternateIconName", "KPMakeMiisScreen()", "KPMakeGhostsScreen()"):
            self.assertIn(host, rows)
        # The game holds still under the screens, as it does under the KartPad menu.
        hold = runtime_hold = (REPO / "apple/ios/KartPadRuntimeOverlayHost.mm").read_text()
        hold = hold.split("- (void)runScreensHold {", 1)[1].split("\n}\n", 1)[0]
        self.assertIn("SetPausedForHost(true)", hold)
        self.assertIn("while (KartPadScreensHoldGame())", hold)
        self.assertIn("SetPausedForHost(false)", hold)
        self.assertIn("KartPadScreensQuietHeldButtons();", hold)
        self.assertIn("[gRuntimeOverlayHost runScreensHold];", runtime_hold)

    def test_inherited_refresh_cannot_restore_the_sunpad_menu(self) -> None:
        runtime = (REPO / "apple/ios/KartPadRuntimeOverlayHost.mm").read_text()
        refresh = runtime.split("- (void)refreshMenuButton {", 1)[1].split(
            "- (void)layoutSubviews {", 1
        )[0]
        self.assertIn("[super refreshMenuButton];", refresh)
        self.assertIn("[self setNeedsLayout];", refresh)
        self.assertIn("[self layoutIfNeeded];", refresh)
        self.assertIn("menuButton.menu = nil;", runtime)

    def test_foreground_reasserts_overlay_attachment_and_z_order(self) -> None:
        shell = (REPO / "apple/ios/KartPadShellViewController.mm").read_text()
        runtime = (REPO / "apple/ios/KartPadRuntimeOverlayHost.mm").read_text()
        self.assertIn("_overlay.superview != self.view", shell)
        self.assertGreaterEqual(shell.count("bringSubviewToFront"), 3)
        self.assertIn("- (void)reattachOverlayIfNeeded", runtime)
        self.assertIn("[self reattachOverlayIfNeeded];", runtime)
        self.assertIn("[weakSelf reattachOverlayIfNeeded];", runtime)
        self.assertIn("_overlay.superview != container", runtime)
        self.assertIn("[container bringSubviewToFront:_overlay];", runtime)

    def test_screenshot_reasserts_persistent_menu_button(self) -> None:
        runtime = (REPO / "apple/ios/KartPadRuntimeOverlayHost.mm").read_text()
        self.assertIn("UIApplicationUserDidTakeScreenshotNotification", runtime)
        self.assertIn("- (void)userDidTakeScreenshot:", runtime)
        handler = runtime.split("- (void)userDidTakeScreenshot:", 1)[1].split(
            "- (void)showMotionSteering", 1
        )[0]
        self.assertGreaterEqual(handler.count("reattachOverlayIfNeeded"), 2)
        self.assertIn("menuButton.hidden = NO;", runtime)
        self.assertIn("menuButton.alpha = 1.0;", runtime)


if __name__ == "__main__":
    unittest.main()

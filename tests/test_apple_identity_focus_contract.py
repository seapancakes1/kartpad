import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


class AppleIdentityFocusTests(unittest.TestCase):
    def test_sdl_fix_is_scoped_idempotent_and_fails_on_unknown_source(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / 'src/video/uikit/SDL_uikitviewcontroller.m'
            source.parent.mkdir(parents=True)
            source.write_text('selector:@selector(textFieldTextDidChange:)\n'
                              '                   name:UITextFieldTextDidChangeNotification\n'
                              '                 object:nil];')
            command = ['cmake', f'-Dsdl_SOURCE_DIR={root}', '-P',
                       str(ROOT / 'cmake/PatchSDLUIKitTextFocus.cmake')]
            subprocess.run(command, check=True, capture_output=True)
            patched = source.read_bytes()
            self.assertIn(b'object:textField]', patched)
            subprocess.run(command, check=True, capture_output=True)
            self.assertEqual(patched, source.read_bytes())
            source.write_text('changed upstream observer')
            self.assertNotEqual(subprocess.run(command, capture_output=True).returncode, 0)

    def test_identity_is_prominent_and_pending_edits_are_explicit(self):
        ios = (ROOT / 'apple/ios/KartPadRuntimeOverlayHost.mm').read_text()
        mac = (ROOT / 'apple/macos/KartPadMacShell.mm').read_text()
        mac_screen = (ROOT / 'apple/macos/KartPadMiisScreen.inc.mm').read_text()
        mac_window = (ROOT / 'apple/macos/KartPadMacMiis.inc.mm').read_text()
        browser = (ROOT / 'apple/shared/KartPadMiiBrowser.inc.mm').read_text()
        # Miis are a tile of their own on HOME, on every Apple device.
        self.assertIn('@"Miis", nil);', (ROOT / 'apple/macos/KartPadHomeScreen.inc.mm').read_text())
        self.assertIn('#include "../macos/KartPadHomeScreen.inc.mm"', (ROOT / 'apple/ios/KartPadScreens.mm').read_text())
        # Every shell opens the shared Miis screen for names and licenses: HOME › Miis on
        # iPhone/iPad, and Player > Miis (in the game window or its own window) on the Mac.
        ios_glue = (ROOT / 'apple/ios/KartPadScreensGlue.inc.mm').read_text()
        ios_manager = ios_glue.split('@implementation KPMiisScreen', 1)[1].split('@end', 1)[0]
        self.assertIn('KartPadMakeMiiBrowser()', ios_manager)
        self.assertIn('@selector(showMiis:)', mac)
        self.assertIn('#include "KartPadMiisScreen.inc.mm"', mac)
        self.assertIn('#include "KartPadMacMiis.inc.mm"', mac)
        self.assertIn('KartPadMakeMiiBrowser()', mac_screen)
        self.assertIn('KartPadMakeMiiBrowser()', mac_window)
        # That screen stages each edit for the next launch rather than writing the live files...
        for stage in ('KartPadStagePlayerName(', 'KartPadStageLicenseRename(',
                      'KartPadStageLicenseDeletion(', 'KartPadStageLicenseMii('):
            self.assertIn(stage, browser)
        # ...marks each license with an edit waiting...
        pending = browser.split('static NSString *KPLicensePending(', 1)[1].split('\n}\n', 1)[0]
        for label in ('@"Rename pending"', '@"Deletion pending"', '@"Mii change pending"'):
            self.assertIn(label, pending)
        self.assertIn('KPLicensePending(license)', browser)
        # ...and counts what waits for the next launch, with the restart that applies it.
        self.assertIn('@"%lu changes are waiting for the next launch."', browser)
        self.assertIn('@"A change is waiting for the next launch."', browser)
        self.assertIn('KartPadPendingMiiChangeCount()', browser)
        self.assertIn('KPMiiRestartAdvice(count)', browser)


if __name__ == '__main__':
    unittest.main()

// Button setup on iPhone and iPad (in place of the Mac's KPRemapScreen, which edits Aurora's
// GameCube mappings): the app's controller button mapping, which every controller shares. Included
// by apple/macos/KartPadControllersScreen.inc.mm.

static void KPSetUpButtons(KPPadDevice *device) {
  (void)device;
  [KPHost() screensShowButtonMapping];
}

// The Mac's vibration strength per controller; iOS controllers don't vibrate for the game.
static void KPChooseVibration(KPPadDevice *device) { (void)device; }

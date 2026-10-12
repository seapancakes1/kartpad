// The controllers driving KartPad's screens on iPhone and iPad, as the Mac's reader does
// (apple/macos/KartPadMacMiis.inc.mm): every connected controller counts. The D-pad or left stick
// moves, A and B confirm and go back (on Nintendo's own pads, A on the right), X and Y, LB and RB,
// and Menu. Directions repeat while held; buttons already down when a screen opens aren't presses
// for it. While the screens are closed, holding Menu for a second opens HOME (a short press stays
// the game's pause), and the HOME button opens it at once where iOS lets it through.
// Included by KartPadScreensGlue.inc.mm.

static constexpr uint32_t KPMiiPadDirections =
    1u << KartPadMiiPadUp | 1u << KartPadMiiPadDown | 1u << KartPadMiiPadLeft | 1u << KartPadMiiPadRight;
static NSTimer *KPPadTimer;
static uint32_t KPPadHeld;
static bool KPPadQuiet, KPPadOwned;
static NSTimeInterval KPPadRepeatAt;

// The screens take the pads while one is open and no sheet of UIKit's is over it (a sheet can't be
// worked with a controller). The Mii screens have their own handling (KartPadMiiGamepad.inc.mm).
static bool KPPadScreensTakePads() {
  if (!KPOverlay().active) return false;
  UIViewController *root = KPGameWindow().rootViewController;
  return root != nil && root.presentedViewController == nil;
}
static bool KPPadWindowsVisible() { return KPPadScreensTakePads() || KartPadMiiWindowsVisible(); }

// What every controller holds now, as menu buttons; which controller pressed something new, and the
// right stick across (which turns a Mii in the editor).
static uint32_t KPPadRead(bool *anyHeld, SDL_JoystickID *pressedBy, float *turn, bool *home, bool *menu) {
  static NSMutableDictionary<NSNumber *, NSNumber *> *before = [NSMutableDictionary dictionary];
  NSMutableDictionary<NSNumber *, NSNumber *> *now = [NSMutableDictionary dictionary];
  uint32_t held = 0;
  *anyHeld = *home = *menu = false;
  *pressedBy = 0;
  float turnX = 0;
  for (KPPadDevice *device in KPControllerRoster.shared.devices) {
    GCController *controller = device.controller;
    if (controller == nil) continue;
    float axes[SDL_GAMEPAD_AXIS_COUNT];
    const uint64_t buttons = KPSDLButtonsFor(controller, axes);
    const KPPadFace face = KPPadFaceButtons(device.gamepad);
    uint32_t mine = 0;
    auto down = [&](SDL_GamepadButton button) { return ((buttons >> button) & 1) != 0; };
    auto set = [&](KartPadMiiPadButton button, bool on) { if (on) mine |= 1u << button; };
    *anyHeld |= buttons != 0;
    // The stick moves along its stronger axis once past half way (SDL's y runs down).
    const float x = axes[SDL_GAMEPAD_AXIS_LEFTX], y = axes[SDL_GAMEPAD_AXIS_LEFTY];
    const bool horizontal = std::fabs(x) >= std::fabs(y), tilted = std::max(std::fabs(x), std::fabs(y)) > 0.5f;
    *anyHeld |= tilted;
    if (std::fabs(axes[SDL_GAMEPAD_AXIS_RIGHTX]) > std::fabs(turnX)) turnX = axes[SDL_GAMEPAD_AXIS_RIGHTX];
    set(KartPadMiiPadUp, down(SDL_GAMEPAD_BUTTON_DPAD_UP) || (tilted && !horizontal && y < 0));
    set(KartPadMiiPadDown, down(SDL_GAMEPAD_BUTTON_DPAD_DOWN) || (tilted && !horizontal && y > 0));
    set(KartPadMiiPadLeft, down(SDL_GAMEPAD_BUTTON_DPAD_LEFT) || (tilted && horizontal && x < 0));
    set(KartPadMiiPadRight, down(SDL_GAMEPAD_BUTTON_DPAD_RIGHT) || (tilted && horizontal && x > 0));
    set(KartPadMiiPadConfirm, down(face.a));
    set(KartPadMiiPadBack, down(face.b));
    set(KartPadMiiPadUndo, down(face.x));
    set(KartPadMiiPadRedo, down(face.y));
    set(KartPadMiiPadPreviousTab, down(SDL_GAMEPAD_BUTTON_LEFT_SHOULDER));
    set(KartPadMiiPadNextTab, down(SDL_GAMEPAD_BUTTON_RIGHT_SHOULDER));
    set(KartPadMiiPadStart, down(SDL_GAMEPAD_BUTTON_START));
    *home |= down(SDL_GAMEPAD_BUTTON_GUIDE);
    *menu |= down(SDL_GAMEPAD_BUTTON_START);
    held |= mine;
    NSNumber *identifier = @(device.joystick);
    if (mine & ~before[identifier].unsignedIntValue) *pressedBy = device.joystick;
    now[identifier] = @(mine);
  }
  [before setDictionary:now];
  // Past a dead zone, scaled from there to full tilt.
  constexpr float deadZone = 0.25f;
  const float past = std::clamp((std::fabs(turnX) - deadZone) / (1 - deadZone), 0.0f, 1.0f);
  *turn = turnX < 0 ? -past : past;
  return held;
}

// Each press runs from its own turn of the run loop, so one that opens a screen or a sheet doesn't
// run inside the reader.
static void KPPadSend(KartPadMiiPadButton button, BOOL down) {
  dispatch_async(dispatch_get_main_queue(), ^{
    @autoreleasepool {
      if (KPPadScreensTakePads()) {
        if (down) KPScreensPadUsed();
        KPOverlayPadPress(button, down);
      } else if (KartPadMiiWindowsVisible()) {
        KartPadMiiPadPress(button, down);
      }
    }
  });
}

// Holding Menu for a second opens HOME; the HOME button opens it at once. Not again until let go.
static void KPPadHomeButtons(bool home, bool menu) {
  static NSTimeInterval since;
  static bool latched;
  if (!home && !menu) {
    since = 0;
    latched = false;
    return;
  }
  if (latched) return;
  if (KPOverlay().active || KartPadMiiWindowsVisible() || KPPadListening || KartPadGameStarting() ||
      UIApplication.sharedApplication.applicationState != UIApplicationStateActive) {
    latched = true;
    return;
  }
  const NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
  if (since == 0) since = now;
  if (!home && now - since < 1.0) return;
  latched = true;
  since = 0;
  AppendSessionLine(@"home=opened-from-controller");
  dispatch_async(dispatch_get_main_queue(), ^{
    KPScreensPadUsed();
    KPOpenHomeFromController();
  });
}

static void KPPadPoll() {
  const NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
  const bool visible = KPPadWindowsVisible();
  bool anyHeld = false, home = false, menu = false;
  SDL_JoystickID pressedBy = 0;
  float turn = 0;
  const uint32_t held = KPPadRead(&anyHeld, &pressedBy, &turn, &home, &menu);
  if (!visible) KPPadHomeButtons(home, menu);
  if (KPPadListening) KPPadQuiet = true;
  else if (!anyHeld) KPPadQuiet = false;
  // Buttons already down when a screen opens aren't presses for it, and don't repeat.
  if (visible && !KPPadOwned) {
    KPPadRepeatAt = DBL_MAX;
    KPPadQuiet = anyHeld;
  }
  const bool listening = KPPadOwned && visible && !KPPadQuiet;
  const uint32_t pressed = listening ? held & ~KPPadHeld : 0;
  const uint32_t released = listening ? KPPadHeld & ~held : 0;
  uint32_t fire = pressed;
  if (pressed & KPMiiPadDirections) {
    KPPadRepeatAt = now + 0.4;
  } else if (listening && (held & KPMiiPadDirections) && now >= KPPadRepeatAt) {
    fire |= held & KPMiiPadDirections;
    KPPadRepeatAt = now + 0.11;
  }
  KPPadHeld = held;
  if (pressedBy) KPPadLastPresser = pressedBy;
  KPPadOwned = visible;
  if (!visible) return;
  static NSTimeInterval turnedAt;
  if (listening && turn != 0 && KartPadMiiWindowsVisible()) KartPadMiiPadTurn(turn, now - turnedAt);
  turnedAt = now;
  for (int button = 0; button < KartPadMiiPadButtonCount; ++button) {
    if (fire & (1u << button)) KPPadSend((KartPadMiiPadButton)button, YES);
    if (button == KartPadMiiPadConfirm && (released & (1u << button))) KPPadSend(KartPadMiiPadConfirm, NO);
  }
}

// While a screen or a Mii screen is open the reader runs by itself, 60 times a second, in every run
// loop mode (the game's held loop, UIKit's tracking); otherwise the game loop calls it each frame.
static void KPPadStartTimer() {
  if (KPPadTimer != nil) return;
  KPPadTimer = [NSTimer timerWithTimeInterval:1.0 / 60 repeats:YES block:^(NSTimer *timer) {
    (void)timer;
    @autoreleasepool {
      KPPadPoll();
      if (!KPPadWindowsVisible() && !KPOverlay().active) {
        [KPPadTimer invalidate];
        KPPadTimer = nil;
      }
    }
  }];
  [NSRunLoop.mainRunLoop addTimer:KPPadTimer forMode:NSRunLoopCommonModes];
}

static void KPPadFrameTick() {
  if (KPPadTimer != nil) return;
  if (KPPadWindowsVisible() || KPOverlay().active) {
    KPPadStartTimer();
    return;
  }
  KPPadPoll();
}

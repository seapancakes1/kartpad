// Live drawings of controllers for the Controllers and button-setup screens: one friendly rounded
// body per kind (sticks offset like an Xbox or Pro Controller, side by side like a PlayStation
// controller, a GameCube controller's big A, a Wii Remote, a keyboard), lit as the player presses.
// Buttons are drawn by position with plain letters; no maker's logos or symbols. Everything is in a
// 200 × 124 unit box scaled to fit. Included by KartPadMacShell.mm after the overlay.

struct KPArtState {
  uint64_t buttons = 0;            // SDL gamepad buttons held (bits)
  float axes[SDL_GAMEPAD_AXIS_COUNT] = {};
  uint64_t highlight = 0;          // buttons to pulse (the ones bound to an action being set up)
  CGFloat pulse = 0;               // 0…1
  unsigned accent = 0x1b9ad5;      // the player's colour
};

// Where each button sits, in art units, and how the body is shaped.
enum class KPArtLayout { Offset, Symmetric, Nintendo, GameCube, JoyCon, WiiRemote, Keyboard };
static KPArtLayout KPArtLayoutFor(KPPadFamily family) {
  switch (family) {
    case KPFamilyPlayStation: return KPArtLayout::Symmetric;
    case KPFamilySwitch: return KPArtLayout::Nintendo;
    case KPFamilyGameCube: return KPArtLayout::GameCube;
    case KPFamilyJoyCon: return KPArtLayout::JoyCon;
    case KPFamilyWiiRemote: return KPArtLayout::WiiRemote;
    case KPFamilyKeyboard: return KPArtLayout::Keyboard;
    default: return KPArtLayout::Offset;
  }
}

static bool KPArtHeld(const KPArtState &state, int button) { return (state.buttons >> button) & 1; }

// A round button: lit with the player's colour while held, pulsing while it's the one being set up.
static void KPArtButton(CGContextRef c, const KPArtState &state, int button, CGPoint at, CGFloat radius, NSString *label,
                        bool dark) {
  const bool held = button >= 0 && KPArtHeld(state, button);
  const bool marked = button >= 0 && ((state.highlight >> button) & 1);
  const CGRect r = CGRectMake(at.x - radius, at.y - radius, radius * 2, radius * 2);
  if (marked) {
    KPSetInk(c, state.accent, 0.25 + 0.45 * state.pulse);
    CGContextFillEllipseInRect(c, CGRectInset(r, -3 - 2 * state.pulse, -3 - 2 * state.pulse));
  }
  KPSetInk(c, 0x000000, 0.18);
  CGContextFillEllipseInRect(c, CGRectOffset(r, 0, 1.2));
  KPSetInk(c, held ? state.accent : dark ? 0x4a5359 : 0xf4f7f8);
  CGContextFillEllipseInRect(c, r);
  KPSetInk(c, held ? KPP->accentLedge : dark ? 0x6b757b : 0xa9b4ba);
  CGContextSetLineWidth(c, 1.1);
  CGContextStrokeEllipseInRect(c, CGRectInset(r, 0.55, 0.55));
  if (label.length)
    KPTextWeight(label, CGRectMake(r.origin.x - 4, at.y - radius * 0.72, r.size.width + 8, radius * 1.6), radius * 1.05,
                 held ? 0xffffff : dark ? 0xdfe5e8 : 0x59646a, NSFontWeightBold);
}

static void KPArtPill(CGContextRef c, const KPArtState &state, int button, CGRect r, bool dark) {
  const bool held = button >= 0 && KPArtHeld(state, button);
  const bool marked = button >= 0 && ((state.highlight >> button) & 1);
  if (marked) KPFill(c, CGRectInset(r, -2.5, -2.5), state.accent, r.size.height, 0.25 + 0.45 * state.pulse);
  KPFill(c, r, held ? state.accent : dark ? 0x4a5359 : 0xe3e9ec, r.size.height / 2);
  KPStroke(c, r, held ? KPP->accentLedge : dark ? 0x6b757b : 0xa9b4ba, 1, r.size.height / 2);
}

// A stick: a recessed well, the cap following the stick, lit while clicked.
static void KPArtStick(CGContextRef c, const KPArtState &state, int click, int axisX, CGPoint at, CGFloat radius, bool dark) {
  const bool held = KPArtHeld(state, click), marked = (state.highlight >> click) & 1;
  const CGRect well = CGRectMake(at.x - radius, at.y - radius, radius * 2, radius * 2);
  KPSetInk(c, dark ? 0x1b1f22 : 0xc9d2d7);
  CGContextFillEllipseInRect(c, well);
  const CGFloat x = std::clamp(state.axes[axisX], -1.f, 1.f), y = std::clamp(state.axes[axisX + 1], -1.f, 1.f);
  const CGFloat cap = radius * 0.72;
  const CGPoint centre = CGPointMake(at.x + x * radius * 0.42, at.y + y * radius * 0.42);
  const CGRect capRect = CGRectMake(centre.x - cap, centre.y - cap, cap * 2, cap * 2);
  if (marked) {
    KPSetInk(c, state.accent, 0.25 + 0.45 * state.pulse);
    CGContextFillEllipseInRect(c, CGRectInset(capRect, -3, -3));
  }
  KPSetInk(c, 0x000000, 0.22);
  CGContextFillEllipseInRect(c, CGRectOffset(capRect, 0, 1.5));
  KPSetInk(c, held ? state.accent : dark ? 0x5a646a : 0xffffff);
  CGContextFillEllipseInRect(c, capRect);
  KPSetInk(c, dark ? 0x77828a : 0x9aa6ad);
  CGContextSetLineWidth(c, 1.2);
  CGContextStrokeEllipseInRect(c, capRect);
  CGContextStrokeEllipseInRect(c, CGRectInset(capRect, cap * 0.32, cap * 0.32));
}

static void KPArtDpad(CGContextRef c, const KPArtState &state, CGPoint at, CGFloat size, bool dark) {
  const CGFloat arm = size * 0.36, half = size / 2;
  struct Arm { int button; CGRect r; };
  const Arm arms[] = {
    {SDL_GAMEPAD_BUTTON_DPAD_UP, CGRectMake(at.x - arm / 2, at.y - half, arm, half - arm / 2 + 1)},
    {SDL_GAMEPAD_BUTTON_DPAD_DOWN, CGRectMake(at.x - arm / 2, at.y + arm / 2 - 1, arm, half - arm / 2 + 1)},
    {SDL_GAMEPAD_BUTTON_DPAD_LEFT, CGRectMake(at.x - half, at.y - arm / 2, half - arm / 2 + 1, arm)},
    {SDL_GAMEPAD_BUTTON_DPAD_RIGHT, CGRectMake(at.x + arm / 2 - 1, at.y - arm / 2, half - arm / 2 + 1, arm)},
  };
  KPFill(c, CGRectMake(at.x - arm / 2, at.y - half + 1.2, arm, size), 0x000000, 2.5, 0.18);
  KPFill(c, CGRectMake(at.x - half, at.y - arm / 2 + 1.2, size, arm), 0x000000, 2.5, 0.18);
  for (const Arm &a : arms) {
    const bool marked = (state.highlight >> a.button) & 1;
    if (marked) KPFill(c, CGRectInset(a.r, -2, -2), state.accent, 3, 0.25 + 0.45 * state.pulse);
  }
  KPFill(c, CGRectMake(at.x - arm / 2, at.y - half, arm, size), dark ? 0x4a5359 : 0xe9eef0, 2.5);
  KPFill(c, CGRectMake(at.x - half, at.y - arm / 2, size, arm), dark ? 0x4a5359 : 0xe9eef0, 2.5);
  for (const Arm &a : arms)
    if (KPArtHeld(state, a.button)) KPFill(c, a.r, state.accent, 2.5);
  KPSetInk(c, dark ? 0x6b757b : 0xa9b4ba);
  CGContextSetLineWidth(c, 1);
  CGMutablePathRef cross = CGPathCreateMutable();
  CGPathAddRoundedRect(cross, nullptr, CGRectMake(at.x - arm / 2, at.y - half, arm, size), 2.5, 2.5);
  CGPathAddRoundedRect(cross, nullptr, CGRectMake(at.x - half, at.y - arm / 2, size, arm), 2.5, 2.5);
  CGContextAddPath(c, cross);
  CGContextStrokePath(c);
  CGPathRelease(cross);
}

// Shoulder buttons and triggers along the top; triggers fill as they're pulled.
static void KPArtShoulders(CGContextRef c, const KPArtState &state, CGFloat leftX, CGFloat rightX, CGFloat y, bool dark,
                           NSString *leftLabel, NSString *rightLabel) {
  for (int side = 0; side < 2; ++side) {
    const CGFloat x = side ? rightX : leftX;
    const float pull = std::clamp(state.axes[side ? SDL_GAMEPAD_AXIS_RIGHT_TRIGGER : SDL_GAMEPAD_AXIS_LEFT_TRIGGER], 0.f, 1.f);
    const CGRect trigger = CGRectMake(x - 17, y - 15, 34, 13);
    KPFill(c, trigger, dark ? 0x3a4248 : 0xd4dce0, 6);
    if (pull > 0.02) KPFill(c, CGRectMake(trigger.origin.x, trigger.origin.y, trigger.size.width * pull, trigger.size.height), state.accent, 6);
    KPStroke(c, trigger, dark ? 0x6b757b : 0xa9b4ba, 1, 6);
    KPArtPill(c, state, side ? SDL_GAMEPAD_BUTTON_RIGHT_SHOULDER : SDL_GAMEPAD_BUTTON_LEFT_SHOULDER,
              CGRectMake(x - 21, y - 4, 42, 10), dark);
    KPTextWeight(side ? rightLabel : leftLabel, CGRectMake(x - 21, y - 15.5, 42, 12), 8.5, dark ? 0xc3cbd0 : 0x6a747a,
                 NSFontWeightBold);
  }
}

static CGPathRef KPArtBodyPath(KPArtLayout layout) {
  CGMutablePathRef p = CGPathCreateMutable();
  if (layout == KPArtLayout::GameCube) {
    CGPathMoveToPoint(p, nullptr, 52, 20);
    CGPathAddLineToPoint(p, nullptr, 148, 20);
    CGPathAddCurveToPoint(p, nullptr, 182, 20, 194, 46, 192, 74);
    CGPathAddCurveToPoint(p, nullptr, 190, 104, 170, 118, 152, 112);
    CGPathAddCurveToPoint(p, nullptr, 140, 108, 134, 92, 122, 90);
    CGPathAddLineToPoint(p, nullptr, 78, 90);
    CGPathAddCurveToPoint(p, nullptr, 66, 92, 60, 108, 48, 112);
    CGPathAddCurveToPoint(p, nullptr, 30, 118, 10, 104, 8, 74);
    CGPathAddCurveToPoint(p, nullptr, 6, 46, 18, 20, 52, 20);
  } else {
    CGPathMoveToPoint(p, nullptr, 50, 22);
    CGPathAddLineToPoint(p, nullptr, 150, 22);
    CGPathAddCurveToPoint(p, nullptr, 178, 22, 188, 40, 194, 70);
    CGPathAddCurveToPoint(p, nullptr, 200, 102, 186, 120, 166, 118);
    CGPathAddCurveToPoint(p, nullptr, 150, 116, 140, 96, 128, 88);
    CGPathAddLineToPoint(p, nullptr, 72, 88);
    CGPathAddCurveToPoint(p, nullptr, 60, 96, 50, 116, 34, 118);
    CGPathAddCurveToPoint(p, nullptr, 14, 120, 0, 102, 6, 70);
    CGPathAddCurveToPoint(p, nullptr, 12, 40, 22, 22, 50, 22);
  }
  CGPathCloseSubpath(p);
  return p;
}

static void KPArtBody(CGContextRef c, CGPathRef body, bool dark) {
  CGContextSaveGState(c);
  CGContextSetShadowWithColor(c, CGSizeMake(0, 3), 6, [NSColor colorWithWhite:0 alpha:dark ? 0.5 : 0.22].CGColor);
  CGContextAddPath(c, body);
  KPSetInk(c, dark ? 0x30373c : 0xffffff);
  CGContextFillPath(c);
  CGContextRestoreGState(c);
  // A soft sheen across the top.
  CGContextSaveGState(c);
  CGContextAddPath(c, body);
  CGContextClip(c);
  const CGRect box = CGPathGetBoundingBox(body);
  KPGradientFill(c, CGRectMake(box.origin.x, box.origin.y, box.size.width, box.size.height), 0,
                 dark ? 0x3b4348 : 0xffffff, dark ? 0x262c30 : 0xe4eaed);
  CGContextRestoreGState(c);
  CGContextAddPath(c, body);
  KPSetInk(c, dark ? 0x59636a : 0xa3afb6);
  CGContextSetLineWidth(c, 1.6);
  CGContextStrokePath(c);
}

static void KPArtKeyboard(CGContextRef c, const KPArtState &state, bool dark) {
  // A small keyboard with the keys the game uses lit as they're pressed.
  int keyCount = 0;
  const bool *keys = SDL_GetKeyboardState(&keyCount);
  auto down = [&](SDL_Scancode code) { return (int)code < keyCount && keys[code]; };
  const CGRect plate = CGRectMake(4, 20, 192, 86);
  CGContextSaveGState(c);
  CGContextSetShadowWithColor(c, CGSizeMake(0, 3), 6, [NSColor colorWithWhite:0 alpha:dark ? 0.5 : 0.22].CGColor);
  KPFill(c, plate, dark ? 0x30373c : 0xffffff, 10);
  CGContextRestoreGState(c);
  KPStroke(c, plate, dark ? 0x59636a : 0xa3afb6, 1.4, 10);
  struct Key { SDL_Scancode code; CGFloat x, y, w; const char *label; bool game; };
  const Key keyset[] = {
    {SDL_SCANCODE_Q, 14, 30, 13, "Q", true}, {SDL_SCANCODE_W, 29, 30, 13, "W", true}, {SDL_SCANCODE_E, 44, 30, 13, "E", true},
    {SDL_SCANCODE_R, 59, 30, 13, "R", false}, {SDL_SCANCODE_T, 74, 30, 13, "T", false},
    {SDL_SCANCODE_U, 104, 30, 13, "U", true}, {SDL_SCANCODE_I, 119, 30, 13, "I", true},
    {SDL_SCANCODE_BACKSPACE, 160, 30, 26, "⌫", true},
    {SDL_SCANCODE_A, 18, 46, 13, "A", true}, {SDL_SCANCODE_S, 33, 46, 13, "S", true}, {SDL_SCANCODE_D, 48, 46, 13, "D", true},
    {SDL_SCANCODE_J, 108, 46, 13, "J", true}, {SDL_SCANCODE_K, 123, 46, 13, "K", true}, {SDL_SCANCODE_L, 138, 46, 13, "L", true},
    {SDL_SCANCODE_RETURN, 160, 46, 26, "⏎", true},
    {SDL_SCANCODE_LSHIFT, 10, 62, 26, "⇧", true}, {SDL_SCANCODE_M, 120, 62, 13, "M", true},
    {SDL_SCANCODE_UP, 160, 62, 13, "↑", true},
    {SDL_SCANCODE_LCTRL, 10, 78, 18, "⌃", true}, {SDL_SCANCODE_LALT, 30, 78, 18, "⌥", true},
    {SDL_SCANCODE_SPACE, 52, 78, 80, "", true},
    {SDL_SCANCODE_LEFT, 145, 78, 13, "←", true}, {SDL_SCANCODE_DOWN, 160, 78, 13, "↓", true},
    {SDL_SCANCODE_RIGHT, 175, 78, 13, "→", true},
  };
  for (const Key &key : keyset) {
    const CGRect r = CGRectMake(key.x, key.y, key.w, 13);
    const bool held = down(key.code);
    KPFill(c, CGRectOffset(r, 0, 1), 0x000000, 3, 0.15);
    KPFill(c, r, held ? state.accent : key.game ? (dark ? 0x4a5359 : 0xeef2f4) : (dark ? 0x3a4146 : 0xf7f9fa), 3);
    KPStroke(c, r, held ? KPP->accentLedge : dark ? 0x6b757b : 0xb3bdc3, 0.9, 3);
    KPTextWeight(@(key.label), CGRectMake(r.origin.x, r.origin.y + 1.2, r.size.width, 11), 8,
                 held ? 0xffffff : key.game ? (dark ? 0xe6ebee : 0x3a4348) : (dark ? 0x7d878d : 0xa3adb3), NSFontWeightBold);
  }
}

static void KPArtWiiRemote(CGContextRef c, const KPArtState &state, bool dark, bool nunchuk) {
  // Held sideways, as for racing: the D-pad on the left, 1 and 2 on the right.
  const CGRect remote = CGRectMake(10, 46, 180, 40);
  CGContextSaveGState(c);
  CGContextSetShadowWithColor(c, CGSizeMake(0, 3), 6, [NSColor colorWithWhite:0 alpha:dark ? 0.5 : 0.22].CGColor);
  KPFill(c, remote, dark ? 0x30373c : 0xffffff, 18);
  CGContextRestoreGState(c);
  KPStroke(c, remote, dark ? 0x59636a : 0xa3afb6, 1.5, 18);
  KPArtDpad(c, state, CGPointMake(40, 66), 26, dark);
  KPArtButton(c, state, SDL_GAMEPAD_BUTTON_EAST, CGPointMake(76, 66), 8.5, @"A", dark);
  KPArtPill(c, state, SDL_GAMEPAD_BUTTON_BACK, CGRectMake(96, 62, 12, 8), dark);
  KPArtButton(c, state, SDL_GAMEPAD_BUTTON_GUIDE, CGPointMake(118, 66), 5, nil, dark);
  KPArtPill(c, state, SDL_GAMEPAD_BUTTON_START, CGRectMake(128, 62, 12, 8), dark);
  KPArtButton(c, state, SDL_GAMEPAD_BUTTON_WEST, CGPointMake(156, 66), 7.5, @"1", dark);
  KPArtButton(c, state, SDL_GAMEPAD_BUTTON_NORTH, CGPointMake(176, 66), 7.5, @"2", dark);
  if (nunchuk) {
    const CGRect chuk = CGRectMake(70, 6, 60, 32);
    KPFill(c, chuk, dark ? 0x30373c : 0xffffff, 16);
    KPStroke(c, chuk, dark ? 0x59636a : 0xa3afb6, 1.4, 16);
    KPArtStick(c, state, SDL_GAMEPAD_BUTTON_LEFT_STICK, SDL_GAMEPAD_AXIS_LEFTX, CGPointMake(88, 22), 11, dark);
    KPArtPill(c, state, SDL_GAMEPAD_BUTTON_LEFT_SHOULDER, CGRectMake(108, 12, 16, 8), dark);
    KPArtPill(c, state, -1, CGRectMake(106, 23, 20, 9), dark);
  }
  // The player LEDs along the bottom edge.
  for (int i = 0; i < 4; ++i) KPFill(c, CGRectMake(70 + i * 16, 80, 8, 3), 0x8fd3f3, 1.5, 0.8);
}

static void KPDrawControllerArt(CGContextRef c, CGRect r, KPPadFamily family, const KPArtState &state, NSString *systemName = nil) {
  const bool dark = KPP == &KPDarkPalette;
  const KPArtLayout layout = KPArtLayoutFor(family);
  CGContextSaveGState(c);
  const CGFloat s = std::min(r.size.width / 200, r.size.height / 124);
  CGContextTranslateCTM(c, r.origin.x + (r.size.width - 200 * s) / 2, r.origin.y + (r.size.height - 124 * s) / 2);
  CGContextScaleCTM(c, s, s);
  if (layout == KPArtLayout::Keyboard) {
    KPArtKeyboard(c, state, dark);
    CGContextRestoreGState(c);
    return;
  }
  if (layout == KPArtLayout::WiiRemote) {
    KPArtWiiRemote(c, state, dark, [systemName containsString:@"Nunchuk"]);
    CGContextRestoreGState(c);
    return;
  }
  if (layout == KPArtLayout::JoyCon) {
    // Two halves with a gap, as a pair.
    for (int side = 0; side < 2; ++side) {
      const CGRect half = CGRectMake(side ? 104 : 26, 18, 70, 96);
      CGContextSaveGState(c);
      CGContextSetShadowWithColor(c, CGSizeMake(0, 3), 6, [NSColor colorWithWhite:0 alpha:dark ? 0.5 : 0.22].CGColor);
      KPFill(c, half, dark ? 0x30373c : 0xffffff, 26);
      CGContextRestoreGState(c);
      KPStroke(c, half, dark ? 0x59636a : 0xa3afb6, 1.5, 26);
    }
    KPArtStick(c, state, SDL_GAMEPAD_BUTTON_LEFT_STICK, SDL_GAMEPAD_AXIS_LEFTX, CGPointMake(61, 46), 13, dark);
    KPArtDpad(c, state, CGPointMake(61, 84), 26, dark);
    KPArtButton(c, state, SDL_GAMEPAD_BUTTON_NORTH, CGPointMake(139, 34), 7, @"X", dark);
    KPArtButton(c, state, SDL_GAMEPAD_BUTTON_WEST, CGPointMake(127, 46), 7, @"Y", dark);
    KPArtButton(c, state, SDL_GAMEPAD_BUTTON_EAST, CGPointMake(151, 46), 7, @"A", dark);
    KPArtButton(c, state, SDL_GAMEPAD_BUTTON_SOUTH, CGPointMake(139, 58), 7, @"B", dark);
    KPArtStick(c, state, SDL_GAMEPAD_BUTTON_RIGHT_STICK, SDL_GAMEPAD_AXIS_RIGHTX, CGPointMake(139, 86), 13, dark);
    KPArtPill(c, state, SDL_GAMEPAD_BUTTON_LEFT_SHOULDER, CGRectMake(36, 12, 40, 9), dark);
    KPArtPill(c, state, SDL_GAMEPAD_BUTTON_RIGHT_SHOULDER, CGRectMake(124, 12, 40, 9), dark);
    CGContextRestoreGState(c);
    return;
  }
  CGPathRef body = KPArtBodyPath(layout);
  if (layout == KPArtLayout::GameCube) {
    KPArtShoulders(c, state, 44, 156, 22, dark, @"L", @"R");
  } else {
    NSString *left = layout == KPArtLayout::Symmetric ? @"L1" : layout == KPArtLayout::Nintendo ? @"L" : @"LB";
    NSString *right = layout == KPArtLayout::Symmetric ? @"R1" : layout == KPArtLayout::Nintendo ? @"R" : @"RB";
    KPArtShoulders(c, state, 46, 154, 24, dark, left, right);
  }
  KPArtBody(c, body, dark);
  CGPathRelease(body);
  switch (layout) {
    case KPArtLayout::Symmetric: {
      KPArtDpad(c, state, CGPointMake(46, 50), 28, dark);
      KPArtButton(c, state, SDL_GAMEPAD_BUTTON_NORTH, CGPointMake(154, 37), 7.5, nil, dark);
      KPArtButton(c, state, SDL_GAMEPAD_BUTTON_WEST, CGPointMake(141, 50), 7.5, nil, dark);
      KPArtButton(c, state, SDL_GAMEPAD_BUTTON_EAST, CGPointMake(167, 50), 7.5, nil, dark);
      KPArtButton(c, state, SDL_GAMEPAD_BUTTON_SOUTH, CGPointMake(154, 63), 7.5, nil, dark);
      KPFill(c, CGRectMake(78, 30, 44, 24), dark ? 0x3a4248 : 0xedf1f3, 5);
      KPStroke(c, CGRectMake(78, 30, 44, 24), dark ? 0x6b757b : 0xb3bdc3, 1, 5);
      KPArtPill(c, state, SDL_GAMEPAD_BUTTON_BACK, CGRectMake(66, 32, 8, 12), dark);
      KPArtPill(c, state, SDL_GAMEPAD_BUTTON_START, CGRectMake(126, 32, 8, 12), dark);
      KPArtButton(c, state, SDL_GAMEPAD_BUTTON_GUIDE, CGPointMake(100, 68), 5.5, nil, dark);
      KPArtStick(c, state, SDL_GAMEPAD_BUTTON_LEFT_STICK, SDL_GAMEPAD_AXIS_LEFTX, CGPointMake(74, 80), 13, dark);
      KPArtStick(c, state, SDL_GAMEPAD_BUTTON_RIGHT_STICK, SDL_GAMEPAD_AXIS_RIGHTX, CGPointMake(126, 80), 13, dark);
      break;
    }
    case KPArtLayout::GameCube: {
      KPArtStick(c, state, SDL_GAMEPAD_BUTTON_LEFT_STICK, SDL_GAMEPAD_AXIS_LEFTX, CGPointMake(42, 50), 14, dark);
      KPArtDpad(c, state, CGPointMake(70, 82), 20, dark);
      KPArtButton(c, state, SDL_GAMEPAD_BUTTON_SOUTH, CGPointMake(154, 52), 11, @"A", dark);
      KPArtButton(c, state, SDL_GAMEPAD_BUTTON_EAST, CGPointMake(134, 64), 6.5, @"B", dark);
      KPArtButton(c, state, SDL_GAMEPAD_BUTTON_WEST, CGPointMake(174, 46), 6.5, @"X", dark);
      KPArtButton(c, state, SDL_GAMEPAD_BUTTON_NORTH, CGPointMake(150, 32), 6.5, @"Y", dark);
      KPArtPill(c, state, SDL_GAMEPAD_BUTTON_START, CGRectMake(94, 48, 12, 8), dark);
      KPArtStick(c, state, SDL_GAMEPAD_BUTTON_RIGHT_STICK, SDL_GAMEPAD_AXIS_RIGHTX, CGPointMake(128, 86), 10, dark);
      break;
    }
    default: {
      // Offset sticks (Xbox-style and Pro Controller). The Pro Controller's face buttons read B A Y X
      // by position (south, east, west, north).
      const bool nintendo = layout == KPArtLayout::Nintendo;
      KPArtStick(c, state, SDL_GAMEPAD_BUTTON_LEFT_STICK, SDL_GAMEPAD_AXIS_LEFTX, CGPointMake(46, 50), 13.5, dark);
      KPArtDpad(c, state, CGPointMake(74, 80), 24, dark);
      KPArtButton(c, state, SDL_GAMEPAD_BUTTON_NORTH, CGPointMake(154, 37), 7.5, nintendo ? @"X" : @"Y", dark);
      KPArtButton(c, state, SDL_GAMEPAD_BUTTON_WEST, CGPointMake(141, 50), 7.5, nintendo ? @"Y" : @"X", dark);
      KPArtButton(c, state, SDL_GAMEPAD_BUTTON_EAST, CGPointMake(167, 50), 7.5, nintendo ? @"A" : @"B", dark);
      KPArtButton(c, state, SDL_GAMEPAD_BUTTON_SOUTH, CGPointMake(154, 63), 7.5, nintendo ? @"B" : @"A", dark);
      KPArtPill(c, state, SDL_GAMEPAD_BUTTON_BACK, CGRectMake(82, 44, 11, 7), dark);
      KPArtPill(c, state, SDL_GAMEPAD_BUTTON_START, CGRectMake(107, 44, 11, 7), dark);
      KPArtButton(c, state, SDL_GAMEPAD_BUTTON_GUIDE, CGPointMake(100, 32), 6.5, nil, dark);
      KPArtStick(c, state, SDL_GAMEPAD_BUTTON_RIGHT_STICK, SDL_GAMEPAD_AXIS_RIGHTX, CGPointMake(128, 80), 12.5, dark);
      break;
    }
  }
  CGContextRestoreGState(c);
}

static KPArtState KPArtStateFor(KPPadDevice *device, unsigned accent) {
  KPArtState state;
  state.accent = accent;
  if (device == nil) return state;
  if (!device.isKeyboard) {
    state.buttons = device.buttons;
    for (int axis = 0; axis < SDL_GAMEPAD_AXIS_COUNT; ++axis) state.axes[axis] = device->axes[axis];
  }
  return state;
}

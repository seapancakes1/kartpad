// The button hints along the bottom of a screen ("Ⓐ Select  Ⓑ Back"), drawn as the controller in hand
// labels its buttons: ✕ ○ □ △ on a PlayStation pad, the physical letters on a Switch pad (whose A is
// where an Xbox pad has B), A B 1 2 on a Wii Remote, and return / esc keycaps on the keyboard. A
// remapped pad shows the buttons it now confirms and goes back with. The hints follow whichever
// controller was used last, and every screen redraws when that changes what they'd show.

struct KPHint {
  KartPadMiiPadButton button;
  NSString *text;
  KartPadMiiPadButton also = KartPadMiiPadButtonCount;  // a second button shown with the first (L / R)
};
static constexpr KartPadMiiPadButton KPNoButton = KartPadMiiPadButtonCount;

// The controller the screens' hints are for: the last one used, else a connected pad, else the keyboard.
static KPPadDevice *KPHintDevice() {
  KPControllerRoster *roster = KPControllerRoster.shared;
  if (roster.lastActive) return roster.lastActive;
  for (KPPadDevice *device in roster.devices)
    if (!device.isKeyboard) return device;
  return roster.devices.firstObject;
}
// The pad someone joins with ("Press A to join"): the last pad used, else any connected one (nil: none).
static KPPadDevice *KPJoinDevice() {
  KPPadDevice *last = KPControllerRoster.shared.lastActive;
  if (last && !last.isKeyboard) return last;
  for (KPPadDevice *device in KPControllerRoster.shared.devices)
    if (!device.isKeyboard) return device;
  return nil;
}

// What the device's button for a menu input is called: "A", "Cross", "LB", "return". nil when it has
// none (the keyboard has no X or Y for menus; a Wii Remote no shoulder buttons). No device: an Xbox
// layout, the usual one.
static NSString *KPHintLabel(KPPadDevice *device, KartPadMiiPadButton button) {
  if (device.isKeyboard) {
    switch (button) {
      case KartPadMiiPadConfirm: return @"return";
      case KartPadMiiPadBack: return @"esc";
      case KartPadMiiPadPreviousTab: case KartPadMiiPadNextTab: return @"tab";
      case KartPadMiiPadLeft: return @"Left";
      case KartPadMiiPadRight: return @"Right";
      default: return nil;
    }
  }
  SDL_Gamepad *pad = device.gamepad;
  const KPPadFace buttons = pad ? KPPadFaceButtons(pad)
                               : KPPadFace{SDL_GAMEPAD_BUTTON_SOUTH, SDL_GAMEPAD_BUTTON_EAST, SDL_GAMEPAD_BUTTON_WEST, SDL_GAMEPAD_BUTTON_NORTH};
  const SDL_GamepadButton confirm = buttons.a, back = buttons.b;
  const BOOL nintendo = device.family == KPFamilySwitch || device.family == KPFamilyJoyCon;
  // X and Y in menus are the game's X and Y, unless confirm or back took them (KPMiiPadRead).
  auto face = [&](SDL_GamepadButton native) -> NSString * {
    return native == confirm || native == back ? nil : KPButtonLabel(pad, native);
  };
  switch (button) {
    case KartPadMiiPadConfirm: return KPButtonLabel(pad, confirm);
    case KartPadMiiPadBack: return KPButtonLabel(pad, back);
    case KartPadMiiPadUndo: return face(buttons.x);
    case KartPadMiiPadRedo: return face(buttons.y);
    case KartPadMiiPadPreviousTab:
      return device.family == KPFamilyWiiRemote ? nil : nintendo ? @"L" : KPButtonLabel(pad, SDL_GAMEPAD_BUTTON_LEFT_SHOULDER);
    case KartPadMiiPadNextTab:
      return device.family == KPFamilyWiiRemote ? nil : nintendo ? @"R" : KPButtonLabel(pad, SDL_GAMEPAD_BUTTON_RIGHT_SHOULDER);
    case KartPadMiiPadStart:
      return device.family == KPFamilyWiiRemote || nintendo ? @"+"
           : device.family == KPFamilyGameCube              ? @"Start"
                                                            : KPButtonLabel(pad, SDL_GAMEPAD_BUTTON_START);
    case KartPadMiiPadLeft: return @"Left";
    case KartPadMiiPadRight: return @"Right";
    default: return nil;
  }
}
static BOOL KPHintIsShape(NSString *label) {
  return [label isEqualToString:@"Cross"] || [label isEqualToString:@"Circle"] || [label isEqualToString:@"Square"] ||
         [label isEqualToString:@"Triangle"];
}
// The button in running text ("Press A to join", "Press ✕ to join").
static NSString *KPButtonWord(KPPadDevice *device, KartPadMiiPadButton button) {
  NSString *label = KPHintLabel(device, button) ?: @"A";
  NSDictionary *shapes = @{@"Cross": @"✕", @"Circle": @"○", @"Square": @"□", @"Triangle": @"△"};
  return shapes[label] ?: label;
}

// A filled round badge with a letter or a PlayStation shape, a keycap for a word, arrows for left/right.
static CGFloat KPHintBadgeWidth(NSString *label, CGFloat size) {
  const CGFloat round = std::round(size * 1.4);
  if ([label isEqualToString:@"Left"] || [label isEqualToString:@"Right"]) return std::round(size * 0.9);
  if (label.length <= 1 || KPHintIsShape(label)) return round;
  return std::max(round, std::ceil(KPTextSize(label, size * 0.78, NSFontWeightSemibold).width) + size * 0.8);
}
// hole is the colour of the letter or shape on a round badge (the panel behind, by default).
static void KPDrawHintBadge(CGContextRef c, NSString *label, CGRect r, CGFloat size, unsigned ink, unsigned hole = ~0u) {
  KPSetInk(c, ink);
  if ([label isEqualToString:@"Left"] || [label isEqualToString:@"Right"]) {
    const BOOL left = [label isEqualToString:@"Left"];
    const CGFloat h = size * 0.62, w = size * 0.5, x = CGRectGetMidX(r) + (left ? w / 2 : -w / 2), y = CGRectGetMidY(r);
    CGContextMoveToPoint(c, x, y - h / 2);
    CGContextAddLineToPoint(c, x + (left ? -w : w), y);
    CGContextAddLineToPoint(c, x, y + h / 2);
    CGContextClosePath(c);
    CGContextFillPath(c);
    return;
  }
  if (hole == ~0u) hole = KPP->panel;
  if (label.length <= 1 || KPHintIsShape(label)) {
    CGContextFillEllipseInRect(c, r);
    KPSetInk(c, hole);
    CGContextSetLineWidth(c, std::max<CGFloat>(1.5, size * 0.11));
    CGContextSetLineCap(c, kCGLineCapRound);
    CGContextSetLineJoin(c, kCGLineJoinRound);
    const CGRect in = CGRectInset(r, r.size.width * 0.3, r.size.height * 0.3);
    if ([label isEqualToString:@"Cross"]) {
      KPLine(c, in.origin.x, in.origin.y, CGRectGetMaxX(in), CGRectGetMaxY(in));
      KPLine(c, CGRectGetMaxX(in), in.origin.y, in.origin.x, CGRectGetMaxY(in));
    } else if ([label isEqualToString:@"Circle"]) {
      CGContextStrokeEllipseInRect(c, in);
    } else if ([label isEqualToString:@"Square"]) {
      CGContextStrokeRect(c, CGRectInset(in, 0.5, 0.5));
    } else if ([label isEqualToString:@"Triangle"]) {
      const CGRect t = CGRectOffset(in, 0, -in.size.height * 0.06);
      CGContextMoveToPoint(c, CGRectGetMidX(t), t.origin.y);
      CGContextAddLineToPoint(c, CGRectGetMaxX(t), CGRectGetMaxY(t));
      CGContextAddLineToPoint(c, t.origin.x, CGRectGetMaxY(t));
      CGContextClosePath(c);
      CGContextStrokePath(c);
    } else {
      KPCentredLabel(c, label, r, size * 0.8, hole, NSFontWeightBold);
    }
    return;
  }
  KPStroke(c, r, ink, 1.5, size * 0.36);
  KPCentredLabel(c, label, r, size * 0.78, ink, NSFontWeightSemibold);
}

// Draws the hints in one line in r, from the side align says. Hints the device has no button for are
// left out; one with no button is plain text.
static void KPDrawHints(CGContextRef c, CGRect r, const std::vector<KPHint> &hints, CGFloat size, NSTextAlignment align,
                        KPPadDevice *device = nil, unsigned ink = 0) {
#if !TARGET_OS_OSX
  if (KPScreensTouching) return;  // worked by touch: no controller to show buttons for
#endif
  if (device == nil) device = KPHintDevice();
  if (ink == 0) ink = KPP->secondaryText;
  struct Piece { NSString *first, *second, *text; CGFloat width; };
  std::vector<Piece> pieces;
  const CGFloat gap = size * 0.4, badge = std::round(size * 1.4);
  CGFloat total = 0;
  for (const KPHint &hint : hints) {
    NSString *first = hint.button == KPNoButton ? nil : KPHintLabel(device, hint.button);
    NSString *second = hint.also == KPNoButton ? nil : KPHintLabel(device, hint.also);
    if (hint.button != KPNoButton && first == nil) continue;
    if ([second isEqualToString:first]) second = nil;  // the keyboard's tab does both
    CGFloat width = std::ceil(KPTextSize(hint.text, size, NSFontWeightMedium).width);
    if (first) width += KPHintBadgeWidth(first, size) + gap;
    if (second) width += KPHintBadgeWidth(second, size) + size * 0.25;
    total += width + (pieces.empty() ? 0 : size * 1.6);
    pieces.push_back({first, second, hint.text, width});
  }
  CGFloat x = align == NSTextAlignmentRight ? CGRectGetMaxX(r) - total
            : align == NSTextAlignmentCenter ? CGRectGetMidX(r) - total / 2 : r.origin.x;
  const CGFloat mid = CGRectGetMidY(r);
  for (const Piece &piece : pieces) {
    for (NSString *label : {piece.first, piece.second}) {
      if (label == nil) continue;
      const CGFloat w = KPHintBadgeWidth(label, size);
      KPDrawHintBadge(c, label, CGRectMake(x, mid - badge / 2, w, badge), size, ink);
      x += w + (label == piece.first && piece.second ? size * 0.25 : gap);
    }
    KPTextWeight(piece.text, CGRectMake(x, mid - size * 0.66, CGRectGetMaxX(r) - x, size * 1.4), size, ink, NSFontWeightMedium,
                 NSTextAlignmentLeft);
    x += std::ceil(KPTextSize(piece.text, size, NSFontWeightMedium).width) + size * 1.6;
  }
}

static void KPRedrawUIViews(NSView *view) {
  if ([view isKindOfClass:KPUIView.class]) view.needsDisplay = YES;
  for (NSView *child in view.subviews) KPRedrawUIViews(child);
}
// The roster calls this when the last-used controller changes. Screens redraw only when that changes
// the buttons their hints show.
static void KPHintDeviceChanged() {
  static NSString *shown;
  KPPadDevice *device = KPHintDevice(), *join = KPJoinDevice();
  NSMutableArray *labels = [NSMutableArray array];
  for (int button = 0; button < KartPadMiiPadButtonCount; ++button) {
    [labels addObject:KPHintLabel(device, (KartPadMiiPadButton)button) ?: @"-"];
    [labels addObject:KPHintLabel(join, (KartPadMiiPadButton)button) ?: @"-"];
  }
  NSString *now = [labels componentsJoinedByString:@" "];
  if ([now isEqualToString:shown]) return;
  shown = now;
  for (NSWindow *window in NSApp.windows)
    if (window.visible && window.contentView) KPRedrawUIViews(window.contentView);
}

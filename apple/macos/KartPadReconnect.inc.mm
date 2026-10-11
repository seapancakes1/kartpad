// A player's controller disconnecting mid-game holds the game still until it's back, as a console
// does: a card over the dimmed game with each player waiting, their Mii and controller, and it closes
// by itself once every one of them has a controller again. Meanwhile a controller that isn't playing
// can take the player with A, and Continue carries on without. A phone counts once it has been away
// for a second (its page reloading, the phone locking); it keeps its player while away, so it's
// back as soon as it reconnects. Online the race can't wait, so there it's only the toast.
// Included by KartPadMacShell.mm after KartPadControllersScreen.inc.mm.

// A phone's pad while the phone itself is away (its link dropped and it's holding its player).
static BOOL KPDeviceAway(KPPadDevice *device) {
  if (device == nil || device.isKeyboard || !SDL_IsJoystickVirtual(device.joystick)) return NO;
  if (![device.systemName hasPrefix:@"Phone "]) return NO;
  const int phone = [device.systemName substringFromIndex:6].intValue - 1;
  return phone >= 0 && phone < kpp::MaxPhones && !KPPhoneLinked[phone].load();
}

@interface KPReconnectScreen : KPScreen <KPRosterListener>
@property(nonatomic, strong) NSMutableArray<NSNumber *> *waiting;           // players, in the order they dropped
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, NSString *> *names;  // the controller each one had
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, NSData *> *miis;
@property(nonatomic, strong) NSMutableSet<NSNumber *> *back;
@property(nonatomic, strong) NSMutableArray<KPUIView *> *tiles;
@property(nonatomic, strong) KPUIButton *controllers, *carryOn;
@property(nonatomic) NSTimeInterval closeAt;
@property(nonatomic) CGFloat pulse;
- (void)addSlot:(int)slot name:(NSString *)name mii:(NSData *)mii;
@end

@implementation KPReconnectScreen

- (instancetype)initWithFrame:(NSRect)frame {
  if ((self = [super initWithFrame:frame])) {
    _waiting = [NSMutableArray array];
    _names = [NSMutableDictionary dictionary];
    _miis = [NSMutableDictionary dictionary];
    _back = [NSMutableSet set];
    _tiles = [NSMutableArray array];
  }
  return self;
}

- (CGRect)card {
  const CGRect s = self.safe;
  return CGRectMake(s.origin.x + 200, s.origin.y + 120, 880, 480);
}

- (void)build {
  self.solid = NO;
  self.title = @"Controller disconnected";
  __weak KPReconnectScreen *weakSelf = self;
  self.controllers = [self button:CGRectZero face:^(CGContextRef c, CGRect r, KPUIState state) {
    KPDrawPill(c, r, state, KPStyle::Plain, KPUIGlyph::Pad, @"Controllers");
  } action:^{
    // On top, so this card is back underneath afterwards (and closes if everyone's back by then).
    KPReconnectScreen *screen = weakSelf;
    int slot = -1;
    for (NSNumber *waiting in screen.waiting)
      if (slot < 0 && ![screen.back containsObject:waiting]) slot = waiting.intValue;
    [KPOverlay() present:KPMakeControllersScreenFor(slot)];
  }];
  self.controllers.label = @"Controllers";
  self.carryOn = [self button:CGRectZero face:^(CGContextRef c, CGRect r, KPUIState state) {
    KPDrawPill(c, r, state, KPStyle::Primary, KPUIGlyph::Play, @"Continue");
  } action:^{ [KPOverlay() pop]; }];
  self.carryOn.label = @"Continue";
  self.carryOn.sound = KPUISound::Close;
  [KPControllerRoster.shared.listeners addObject:self];
}

- (void)layoutDesign {
  const CGRect card = self.card;
  // The waiting players, centred in a row.
  while (self.tiles.count < self.waiting.count) {
    const NSUInteger index = self.tiles.count;
    __weak KPReconnectScreen *weakSelf = self;
    KPUIView *tile = [[KPUIView alloc] initWithFrame:NSZeroRect];
    tile.paint = ^(CGContextRef c, CGSize size) { [weakSelf drawTile:index context:c size:size]; };
    [self.tiles addObject:tile];
  }
  const CGFloat width = 184, gap = 18, total = self.waiting.count * width + (self.waiting.count - 1) * gap;
  CGFloat x = std::round(CGRectGetMidX(card) - total / 2);
  for (NSUInteger i = 0; i < self.tiles.count; ++i) {
    [self place:self.tiles[i] at:CGRectMake(x, card.origin.y + 132, width, 220)];
    x += width + gap;
  }
  const CGFloat bottom = CGRectGetMaxY(card) - 32 - 64;
  [self place:self.carryOn at:CGRectMake(CGRectGetMaxX(card) - 40 - 220, bottom, 220, 64)];
  [self place:self.controllers at:CGRectMake(CGRectGetMaxX(card) - 40 - 220 - 18 - 240, bottom, 240, 64)];
}

- (KPUIButton *)initialFocus { return self.carryOn; }

- (void)willAppear {
  // Once, not again on coming back from Controllers.
  if (!self.waiting.count) KPUIPlay(KPUISound::Dialog);
  [KPControllerRoster.shared.listeners addObject:self];
  [self check];
}
- (void)willDisappear { [KPControllerRoster.shared.listeners removeObject:self]; }

- (void)addSlot:(int)slot name:(NSString *)name mii:(NSData *)mii {
  if ([self.waiting containsObject:@(slot)]) {
    [self.back removeObject:@(slot)];
  } else {
    [self.waiting addObject:@(slot)];
  }
  self.names[@(slot)] = name;
  if (mii) self.miis[@(slot)] = mii;
  self.closeAt = 0;
  AppendSessionLine([NSString stringWithFormat:@"controllerDropped=%@; player=%d", name, slot + 1]);
  [self relayout];
}

- (void)rosterChanged { [self check]; }

- (void)tick {
  [KPControllerRoster.shared refresh];
  self.pulse = 0.5 + 0.5 * sin(NSProcessInfo.processInfo.systemUptime * 5);
  [self check];
  for (NSView *tile in self.tiles) tile.needsDisplay = YES;
  if (self.closeAt > 0 && NSProcessInfo.processInfo.systemUptime >= self.closeAt && KPOverlay().top == self) [KPOverlay() pop];
}

// Who's back: a player with a controller again (not the keyboard stepping in, not a phone still away).
- (void)check {
  KPControllerRoster *roster = KPControllerRoster.shared;
  BOOL changed = NO;
  for (NSNumber *slot in self.waiting) {
    KPPadDevice *device = [roster deviceInSlot:slot.intValue];
    const BOOL here = device != nil && !device.isKeyboard && !KPDeviceAway(device);
    if (here == [self.back containsObject:slot]) continue;
    changed = YES;
    if (here) {
      [self.back addObject:slot];
      [roster identify:device];
      AppendSessionLine([NSString stringWithFormat:@"controllerBack=%@; player=%d", device.name, slot.intValue + 1]);
    } else {
      [self.back removeObject:slot];
    }
  }
  if (!changed) return;
  const BOOL everyone = self.back.count == self.waiting.count;
  KPUIPlay(everyone ? KPUISound::Saved : KPUISound::Confirm);
  // A moment to see it, then back to the game.
  self.closeAt = everyone ? NSProcessInfo.processInfo.systemUptime + 0.9 : 0;
  self.needsDisplay = YES;
}

// A with a controller that isn't playing takes the first player still waiting.
- (BOOL)handle:(KartPadMiiPadButton)button {
  if (button != KartPadMiiPadConfirm) return NO;
  KPPadDevice *presser = KPPresser();
  if (presser == nil || presser.isKeyboard || presser.slot >= 0) return NO;
  for (NSNumber *slot in self.waiting) {
    if ([self.back containsObject:slot]) continue;
    [KPControllerRoster.shared move:presser toSlot:slot.intValue];
    [self check];
    return YES;
  }
  return NO;
}

- (void)drawDesign:(CGContextRef)c size:(CGSize)size {
  KPFill(c, CGRectMake(0, 0, size.width, size.height), 0x000000, 0, 0.35);
  const CGRect card = self.card;
  CGContextSaveGState(c);
  CGContextSetShadowWithColor(c, CGSizeMake(0, 10), 30, [NSColor colorWithWhite:0 alpha:0.35].CGColor);
  KPFill(c, card, KPP->panel, 28);
  CGContextRestoreGState(c);
  KPStroke(c, card, KPP->panelStroke, 1.5, 28);
  const NSUInteger count = self.waiting.count;
  NSString *heading = count == 1 ? [NSString stringWithFormat:@"%@'s controller disconnected", KPPlayerName(self.waiting.firstObject.intValue)]
                                 : @"Controllers disconnected";
  if (count && self.back.count == count) heading = count == 1 ? @"Controller reconnected" : @"Controllers reconnected";
  KPTextWeight(heading, CGRectMake(card.origin.x + 40, card.origin.y + 30, card.size.width - 80, 44), 31, KPP->text, NSFontWeightBold,
               NSTextAlignmentLeft);
  if (self.back.count == count) return;
  NSString *press = KPButtonWord(KPJoinDevice(), KartPadMiiPadConfirm);
  KPTextWeight([NSString stringWithFormat:@"Reconnect it, or press %@ on another controller.", press],
               CGRectMake(card.origin.x + 40, card.origin.y + 82, card.size.width - 80, 28), 21, KPP->secondaryText,
               NSFontWeightRegular, NSTextAlignmentLeft);
}

- (void)drawTile:(NSUInteger)index context:(CGContextRef)c size:(CGSize)size {
  if (index >= self.waiting.count) return;
  NSNumber *slot = self.waiting[index];
  const int player = slot.intValue;
  const BOOL back = [self.back containsObject:slot];
  const CGRect r = CGRectMake(0, 0, size.width, size.height);
  const unsigned color = KPPlayerColors[player];
  KPFill(c, r, KPP->well, 20, 0.7);
  KPStroke(c, CGRectInset(r, 1, 1), back ? color : KPP->buttonStroke, back ? 3 : 2, 19);
  CGContextSaveGState(c);
  CGPathRef clip = CGPathCreateWithRoundedRect(r, 20, 20, nullptr);
  CGContextAddPath(c, clip);
  CGContextClip(c);
  CGPathRelease(clip);
  KPGradientFill(c, CGRectMake(0, 0, size.width, 46), 0, color, KPPlayerDarkColors[player]);
  CGContextRestoreGState(c);
  KPTextWeight(KPPlayerName(player), CGRectMake(16, 9, size.width - 32, 28), 21, KPPlayerInk[player], NSFontWeightHeavy,
               NSTextAlignmentLeft);
  const CGRect well = CGRectMake(size.width / 2 - 44, 58, 88, 88);
  NSData *mii = self.miis[slot];
  __weak KPReconnectScreen *weakSelf = self;
  NSImage *portrait = mii ? KartPadMiiPortrait(mii, ^{ for (NSView *tile in weakSelf.tiles) tile.needsDisplay = YES; }) : nil;
  CGContextSaveGState(c);
  if (!back) CGContextSetAlpha(c, 0.55);
  KPDrawMiiWell(c, well, portrait, color, NO);
  CGContextRestoreGState(c);
  KPTextWeight(self.names[slot] ?: @"Controller", CGRectMake(10, 152, size.width - 20, 24), 16, KPP->secondaryText, NSFontWeightMedium);
  if (back) {
    KPDrawGlyph(c, KPUIGlyph::Check, CGRectMake(size.width / 2 - 38, 180, 26, 26), color);
    KPTextWeight(@"Back", CGRectMake(size.width / 2 - 8, 180, 60, 26), 19, KPP->text, NSFontWeightBold, NSTextAlignmentLeft);
  } else {
    KPTextWeight(@"Waiting…", CGRectMake(10, 180, size.width - 20, 26), 19, KPP->accentBottom, NSFontWeightSemibold);
    // Three dots breathing under it.
    for (int dot = 0; dot < 3; ++dot) {
      const CGFloat phase = 0.5 + 0.5 * sin(NSProcessInfo.processInfo.systemUptime * 5 - dot * 0.9);
      KPFill(c, CGRectMake(size.width / 2 - 17 + dot * 14, 208, 6, 6), KPP->accentBottom, 3, 0.25 + 0.75 * phase);
    }
  }
}

@end

static BOOL KPReconnectShowing() { return [KPOverlay().top isKindOfClass:KPReconnectScreen.class]; }

// Whether losing a player's controller now holds the game: not while the game is starting or online,
// while KartPad's other screens are open (HOME's players show it already), or in the background.
static BOOL KPReconnectWanted(int slot) {
  if (slot < 0 || slot >= KPPlayerCount) return NO;
  if (KartPadGameStarting() || Network_HLE_HasOpenSockets() || KPGameWindow() == nil) return NO;
  if (!NSApp.active && !KPUIBackgroundAutomation()) return NO;
  return KPReconnectShowing() || (!KPOverlay().active && !KartPadMiiWindowsVisible());
}

static void KPControllerDropped(int slot, NSString *name, NSData *mii) {
  if (!KPReconnectWanted(slot)) return;
  // The roster can be refreshed from the game loop, inside a guest fiber; AppKit opens screens on the next turn.
  dispatch_async(dispatch_get_main_queue(), ^{
    if (!KPReconnectWanted(slot)) return;
    KPOverlayController *overlay = KPOverlay();
    if (KPReconnectShowing()) {
      [(KPReconnectScreen *)overlay.top addSlot:slot name:name mii:mii];
      return;
    }
    KPReconnectScreen *screen = [[KPReconnectScreen alloc] initWithFrame:NSZeroRect];
    [overlay present:screen];
    [screen addSlot:slot name:name mii:mii];
  });
}

// Phones keep their pad while away, so the roster never sees them go: watch their links instead.
static void KPReconnectPhonesTick() {
  if (!KPPhoneStarted.load(std::memory_order_relaxed)) return;
  static NSTimeInterval last;
  static std::array<NSTimeInterval, kpp::MaxPhones> awaySince{};
  static std::array<bool, kpp::MaxPhones> told{};
  const NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
  if (now - last < 0.25) return;
  last = now;
  std::array<bool, kpp::MaxPhones> seen{};
  for (const KPPhoneEntry &entry : [KPPhoneServer.shared entries]) {
    const int phone = entry.phone;
    seen[phone] = true;
    if (entry.linked || entry.player <= 0) {
      awaySince[phone] = 0;
      told[phone] = false;
      continue;
    }
    if (awaySince[phone] == 0) awaySince[phone] = now;
    // A second's grace: a phone that left on purpose is let go within it.
    if (told[phone] || now - awaySince[phone] < 1) continue;
    told[phone] = true;
    KPControllerRoster *roster = KPControllerRoster.shared;
    KPPadDevice *device = [roster deviceInSlot:entry.player - 1];
    KPControllerDropped(entry.player - 1, [NSString stringWithFormat:@"Phone %d", phone + 1], [roster miiFor:device]);
  }
  for (int phone = 0; phone < kpp::MaxPhones; ++phone)
    if (!seen[phone]) awaySince[phone] = 0, told[phone] = false;
}

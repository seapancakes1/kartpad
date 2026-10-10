// Controllers: who plays with which controller, at a glance. Four player cards in the game's player
// colours, each with its Mii, a live drawing of the controller (it lights up as you press) and its
// battery; the controllers that aren't playing wait in a tray below. Press anything on a controller
// and its card bounces, so "which one is mine?" answers itself. A controller that isn't playing joins
// with A. X picks a card up to move it to another player, Y makes a controller buzz and flash. Each
// card's menu sets up buttons, chooses a Mii or takes the controller out.
// Also here: button setup (KPRemapScreen), choosing a Mii (KPMiiPickerScreen) and connecting a new
// controller (KPConnectScreen). Included by KartPadMacShell.mm after KartPadHomeScreen.inc.mm.

static void KPSetUpButtons(KPPadDevice *device);
static void KPChooseMii(KPPadDevice *device);
static KPScreen *KPMakeConnectScreen();

// Which controller made the latest press: a pad (by joystick), or the keyboard.
static KPPadDevice *KPPresser() {
  if (KPOverlay().keyboardInput) return [KPControllerRoster.shared deviceWithIdentifier:@"keyboard"];
  if (KPPadLastPresser == 0) return nil;
  return [KPControllerRoster.shared deviceWithIdentifier:[NSString stringWithFormat:@"sdl:%u", KPPadLastPresser]];
}

static NSString *KPPlayerName(int slot) { return [NSString stringWithFormat:@"Player %d", slot + 1]; }

@interface KPControllersScreen : KPScreen <KPRosterListener>
@property(nonatomic) int focusSlot;
@property(nonatomic, strong) NSMutableArray<KPUIButton *> *cards, *chips;
@property(nonatomic, strong) KPUIButton *connect, *done;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *seenInput;
// The controller picked up to move (X), and where its card is now.
@property(nonatomic, strong) KPPadDevice *grabbed;
@property(nonatomic) CGFloat pulse;
@end

@implementation KPControllersScreen

- (void)build {
  self.solid = YES;
  self.title = @"Controllers";
  self.seenInput = [NSMutableDictionary dictionary];
  __weak KPControllersScreen *weakSelf = self;
  self.connect = [self button:CGRectZero face:^(CGContextRef c, CGRect r, KPUIState state) {
    KPDrawPill(c, r, state, KPStyle::Primary, KPUIGlyph::Plus, @"Connect a Controller");
  } action:^{ [KPOverlay() present:KPMakeConnectScreen()]; }];
  self.connect.label = @"Connect a controller";
  self.done = [self button:CGRectZero face:^(CGContextRef c, CGRect r, KPUIState state) {
    KPDrawPill(c, r, state, KPStyle::Plain, KPUIGlyph::Check, @"Done");
  } action:^{ [KPOverlay() pop]; }];
  self.done.label = @"Done";
  self.done.sound = KPUISound::Close;
  self.cards = [NSMutableArray array];
  for (int slot = 0; slot < KPPlayerCount; ++slot) {
    KPUIButton *card = [self button:CGRectZero face:^(CGContextRef c, CGRect r, KPUIState state) {
      [weakSelf drawCard:slot context:c in:r state:state];
    } action:^{ [weakSelf openCard:slot]; }];
    card.tag2 = slot;
    card.radius = 20;
    card.focusScale = 1.025;
    card.label = KPPlayerName(slot);
    [self.cards addObject:card];
  }
  self.chips = [NSMutableArray array];
  KPControllerRoster *roster = KPControllerRoster.shared;
  roster.quiet = YES;
  [roster.listeners addObject:self];
  [roster refresh];
}

- (void)layoutDesign {
  const CGRect s = self.safe;
  [self place:self.done at:CGRectMake(CGRectGetMaxX(s) - 56 - 150, s.origin.y + 30, 150, 60)];
  [self place:self.connect at:CGRectMake(CGRectGetMaxX(s) - 56 - 150 - 18 - 330, s.origin.y + 30, 330, 60)];
  const CGFloat width = 278, gap = 20, x0 = s.origin.x + (1280 - (4 * width + 3 * gap)) / 2;
  for (KPUIButton *card in self.cards)
    [self place:card at:CGRectMake(x0 + card.tag2 * (width + gap), s.origin.y + 120, width, 396)];
  [self layoutChips];
}

// The tray: controllers connected but not playing, keyboard included.
- (void)layoutChips {
  const CGRect s = self.safe;
  NSMutableArray<KPPadDevice *> *resting = [NSMutableArray array];
  for (KPPadDevice *device in KPControllerRoster.shared.devices)
    if (device.slot < 0) [resting addObject:device];
  while (self.chips.count > resting.count) {
    [self.chips.lastObject removeFromSuperview];
    [self.chips removeLastObject];
  }
  __weak KPControllersScreen *weakSelf = self;
  while (self.chips.count < resting.count) {
    const NSUInteger index = self.chips.count;
    KPUIButton *chip = [self button:CGRectZero face:^(CGContextRef c, CGRect r, KPUIState state) {
      [weakSelf drawChip:index context:c in:r state:state];
    } action:^{ [weakSelf openChip:index]; }];
    chip.tag2 = (NSInteger)index;
    chip.radius = 16;
    [self.chips addObject:chip];
  }
  const CGFloat width = 262, gap = 16, x0 = s.origin.x + (1280 - (4 * 278 + 3 * 20)) / 2;
  for (NSUInteger i = 0; i < self.chips.count; ++i) {
    KPUIButton *chip = self.chips[i];
    chip.tagObject = resting[i];
    chip.label = [NSString stringWithFormat:@"%@, not playing", resting[i].name];
    chip.hidden = i >= 4;
    [self place:chip at:CGRectMake(x0 + i * (width + gap), s.origin.y + 568, width, 76)];
    chip.needsDisplay = YES;
  }
}

- (KPUIButton *)initialFocus {
  if (self.focusSlot >= 0 && self.focusSlot < KPPlayerCount) return self.cards[self.focusSlot];
  KPPadDevice *presser = KPControllerRoster.shared.lastActive;
  if (presser.slot >= 0) return self.cards[presser.slot];
  return self.cards.firstObject;
}

- (void)willDisappear {
  KPControllerRoster.shared.quiet = NO;
  if (self.grabbed) self.grabbed = nil;
}

- (void)willAppear {
  KPControllerRoster.shared.quiet = YES;
  [KPControllerRoster.shared.listeners addObject:self];
}

- (void)rosterChanged {
  [self layoutChips];
  for (KPUIButton *card in self.cards) card.needsDisplay = YES;
}

// Live: the drawings follow the controllers, and a card bounces when its controller is used.
- (void)tick {
  KPControllerRoster *roster = KPControllerRoster.shared;
  [roster refresh];
  self.pulse = 0.5 + 0.5 * sin(NSProcessInfo.processInfo.systemUptime * 6);
  for (KPPadDevice *device in roster.devices) {
    NSNumber *seen = self.seenInput[device.identifier];
    if (device.lastInput > 0 && (seen == nil || seen.doubleValue < device.lastInput)) {
      if (seen != nil) [self bounce:device];
      self.seenInput[device.identifier] = @(device.lastInput);
    }
  }
  for (KPUIButton *card in self.cards) card.needsDisplay = YES;
  for (KPUIButton *chip in self.chips) chip.needsDisplay = YES;
}

- (KPUIButton *)viewFor:(KPPadDevice *)device {
  if (device.slot >= 0) return self.cards[device.slot];
  for (KPUIButton *chip in self.chips)
    if (chip.tagObject == device) return chip;
  return nil;
}

- (void)bounce:(KPPadDevice *)device {
  KPUIButton *view = [self viewFor:device];
  if (view == nil || device == self.grabbed) return;
  [view springTo:1.06];
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.12 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
    [view springTo:view.focused ? view.focusScale : 1];
  });
}

- (void)celebrate:(KPPadDevice *)device {
  [KPControllerRoster.shared identify:device];
  KPUIPlay(KPUISound::Saved);
  dispatch_async(dispatch_get_main_queue(), ^{
    KPUIButton *view = [self viewFor:device];
    KPUIWobble(view);
    [view springTo:1.1];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
      [view springTo:view.focused ? view.focusScale : 1];
    });
  });
}

#pragma mark Input

- (BOOL)handle:(KartPadMiiPadButton)button {
  KPControllerRoster *roster = KPControllerRoster.shared;
  KPUIButton *focus = self.focus;
  // Moving a card: left and right carry it to the next player; A or B puts it down.
  if (self.grabbed) {
    if (button == KartPadMiiPadLeft || button == KartPadMiiPadRight) {
      const int from = self.grabbed.slot, to = from + (button == KartPadMiiPadLeft ? -1 : 1);
      if (to < 0 || to >= KPPlayerCount) {
        KPUIPlay(KPUISound::Reject);
        return YES;
      }
      [roster move:self.grabbed toSlot:to];
      KPUIPlay(button == KartPadMiiPadLeft ? KPUISound::Left : KPUISound::Right);
      [KPOverlay() focus:self.cards[to] sound:NO];
      [self.cards[to] springTo:1.07];
      for (KPUIButton *card in self.cards) card.needsDisplay = YES;
      return YES;
    }
    if (button == KartPadMiiPadConfirm || button == KartPadMiiPadBack || button == KartPadMiiPadUndo) {
      KPPadDevice *dropped = self.grabbed;
      self.grabbed = nil;
      KPUIPlay(KPUISound::Saved);
      KPUIButton *card = dropped.slot >= 0 ? self.cards[dropped.slot] : nil;
      [card springTo:card.focusScale];
      [roster identify:dropped];
      for (KPUIButton *each in self.cards) each.needsDisplay = YES;
      return YES;
    }
    return YES;
  }
  // A controller that isn't playing joins with A: on the focused empty card, else the first free one.
  if (button == KartPadMiiPadConfirm) {
    KPPadDevice *presser = KPPresser();
    if (presser != nil && presser.slot < 0 && !presser.isKeyboard) {
      int slot = [self.cards containsObject:focus] && ![roster deviceInSlot:(int)focus.tag2] ? (int)focus.tag2 : -1;
      for (int i = 0; slot < 0 && i < KPPlayerCount; ++i)
        if (![roster deviceInSlot:i]) slot = i;
      if (slot < 0) {
        KPUIPlay(KPUISound::Reject);
        [KPOverlay() toast:@"All four players have a controller" detail:@"Take one out first, from its card." stripe:0
                      icon:^(CGContextRef c, CGRect r) { KPDrawGlyph(c, KPUIGlyph::Pad, r, KPP->secondaryText); } image:nil];
        return YES;
      }
      [roster move:presser toSlot:slot];
      [KPOverlay() focus:self.cards[slot] sound:NO];
      [self celebrate:presser];
      return YES;
    }
  }
  KPPadDevice *device = [self.cards containsObject:focus] ? [roster deviceInSlot:(int)focus.tag2] : focus.tagObject;
  if (button == KartPadMiiPadUndo && device && device.slot >= 0) {  // X: pick the card up
    self.grabbed = device;
    KPUIPlay(KPUISound::Press);
    [self.cards[device.slot] springTo:1.07];
    for (KPUIButton *card in self.cards) card.needsDisplay = YES;
    return YES;
  }
  if (button == KartPadMiiPadRedo && device) {  // Y: find it
    [roster identify:device];
    KPUIPlay(KPUISound::Confirm);
    KPUIWobble([self viewFor:device]);
    return YES;
  }
  return NO;
}

#pragma mark Menus

- (void)openCard:(int)slot {
  KPControllerRoster *roster = KPControllerRoster.shared;
  KPPadDevice *device = [roster deviceInSlot:slot];
  KPMenuScreen *menu = [[KPMenuScreen alloc] initWithFrame:NSZeroRect];
  menu.stripe = KPPlayerColors[slot];
  __weak KPControllersScreen *weakSelf = self;
  if (device == nil) {
    menu.heading = [NSString stringWithFormat:@"Who plays as %@?", KPPlayerName(slot)];
    menu.message = @"Or press A on the controller you want to use.";
    for (KPPadDevice *resting in roster.devices) {
      if (resting.slot >= 0) continue;
      [menu add:[NSString stringWithFormat:@"Use %@", resting.name] detail:nil
          glyph:(int)(resting.isKeyboard ? KPUIGlyph::Keyboard : resting.family == KPFamilyWiiRemote ? KPUIGlyph::WiiRemote : KPUIGlyph::Pad)
        enabled:YES run:^{
          [roster move:resting toSlot:slot];
          [weakSelf celebrate:resting];
        }];
    }
    [menu add:@"Connect a new controller" detail:@"Pair one with this Mac" glyph:(int)KPUIGlyph::Bluetooth enabled:YES
          run:^{ [KPOverlay() present:KPMakeConnectScreen()]; }];
  } else {
    NSDictionary *mii = [roster miiRecordFor:device];
    menu.heading = [NSString stringWithFormat:@"%@ · %@", KPPlayerName(slot), mii[@"name"] ?: device.name];
    if (!device.isKeyboard)
      [menu add:@"Find it" detail:@"It buzzes and its light flashes" glyph:(int)KPUIGlyph::Find enabled:YES run:^{
        [roster identify:device];
        KPUIWobble([weakSelf viewFor:device]);
      }];
    [menu add:@"Set up buttons" detail:@"Choose what each button does" glyph:(int)KPUIGlyph::Buttons enabled:YES
          run:^{ KPSetUpButtons(device); }];
    [menu add:mii ? @"Change Mii" : @"Choose a Mii" detail:@"Shows who's holding it" glyph:(int)KPUIGlyph::Mii enabled:YES
          run:^{ KPChooseMii(device); }];
    [menu add:@"Move to another player" detail:@"Or pick the card up with X" glyph:(int)KPUIGlyph::Move enabled:YES run:^{
      KPControllersScreen *screen = weakSelf;
      screen.grabbed = device;
      [screen.cards[device.slot] springTo:1.07];
      for (KPUIButton *card in screen.cards) card.needsDisplay = YES;
    }];
    [menu add:@"Stop playing" detail:@"It waits in Not Playing" glyph:(int)KPUIGlyph::Close enabled:YES run:^{
      [roster move:device toSlot:-1];
      KPUIPlay(KPUISound::PagePrevious);
    }];
  }
  [KPOverlay() present:menu];
}

- (void)openChip:(NSUInteger)index {
  if (index >= self.chips.count) return;
  KPPadDevice *device = self.chips[index].tagObject;
  if (device == nil) return;
  KPControllerRoster *roster = KPControllerRoster.shared;
  KPMenuScreen *menu = [[KPMenuScreen alloc] initWithFrame:NSZeroRect];
  menu.heading = [NSString stringWithFormat:@"Play with %@", device.name];
  __weak KPControllersScreen *weakSelf = self;
  for (int slot = 0; slot < KPPlayerCount; ++slot) {
    KPPadDevice *occupant = [roster deviceInSlot:slot];
    NSString *detail = occupant ? [NSString stringWithFormat:@"%@ stops playing", occupant.name] : @"Free";
    [menu add:[NSString stringWithFormat:@"As %@", KPPlayerName(slot)] detail:detail glyph:-1 enabled:YES run:^{
      [roster move:device toSlot:slot];
      KPControllersScreen *screen = weakSelf;
      [KPOverlay() focus:screen.cards[slot] sound:NO];
      [screen celebrate:device];
    }];
  }
  if (!device.isKeyboard)
    [menu add:@"Find it" detail:@"It buzzes and its light flashes" glyph:(int)KPUIGlyph::Find enabled:YES
          run:^{ [roster identify:device]; }];
  [KPOverlay() present:menu];
}

- (void)back {
  if (self.grabbed) {
    [self handle:KartPadMiiPadBack];
    return;
  }
  [super back];
}

#pragma mark Drawing

- (void)drawDesign:(CGContextRef)c size:(CGSize)size {
  [super drawDesign:c size:size];
  const CGRect s = self.safe;
  KPTextWeight(@"Controllers", CGRectMake(s.origin.x + 56, s.origin.y + 26, 600, 50), 38, KPP->text, NSFontWeightBold,
               NSTextAlignmentLeft);
  NSString *subtitle = self.grabbed
      ? [NSString stringWithFormat:@"Moving %@ — ◀ ▶ to choose a player, A to put it down", self.grabbed.name]
      : @"Press any button on a controller to see which one it is.";
  KPTextWeight(subtitle, CGRectMake(s.origin.x + 58, s.origin.y + 78, 760, 26), 18, self.grabbed ? KPP->accentBottom : KPP->secondaryText,
               NSFontWeightMedium, NSTextAlignmentLeft);
  NSInteger resting = 0;
  for (KPPadDevice *device in KPControllerRoster.shared.devices)
    if (device.slot < 0) ++resting;
  KPTextWeight(resting ? @"Not playing" : @"Not playing — every connected controller has a player",
               CGRectMake(s.origin.x + 58, s.origin.y + 536, 800, 26), 18, KPP->secondaryText, NSFontWeightSemibold,
               NSTextAlignmentLeft);
  NSString *hint = @"Ⓐ Options    Ⓧ Move    Ⓨ Find    Ⓑ Back";
  KPTextWeight(hint, CGRectMake(s.origin.x + 56, s.origin.y + 670, 1168, 26), 16, KPP->secondaryText, NSFontWeightMedium,
               NSTextAlignmentRight);
  KPTextWeight(@"Miis here help you tell controllers apart. Pick racers and licenses in the game.",
               CGRectMake(s.origin.x + 58, s.origin.y + 670, 760, 26), 15, KPP->secondaryText, NSFontWeightRegular,
               NSTextAlignmentLeft);
}

- (void)drawCard:(int)slot context:(CGContextRef)c in:(CGRect)r state:(KPUIState)state {
  KPControllerRoster *roster = KPControllerRoster.shared;
  KPPadDevice *device = [roster deviceInSlot:slot];
  const unsigned color = KPPlayerColors[slot];
  const BOOL grabbed = device != nil && device == self.grabbed;
  const CGFloat dy = state.pressed ? 2 : 0;
  if (device == nil) {
    KPFill(c, r, KPP->panel, 20, 0.6);
    CGContextSaveGState(c);
    const CGFloat dash[] = {9, 7};
    CGContextSetLineDash(c, 0, dash, 2);
    KPStroke(c, CGRectInset(r, 1, 1), KPP->buttonStroke, 2.2, 19);
    CGContextRestoreGState(c);
  } else {
    if (grabbed) {
      CGContextSaveGState(c);
      CGContextSetShadowWithColor(c, CGSizeMake(0, 14), 26, [NSColor colorWithWhite:0 alpha:0.35].CGColor);
      KPFill(c, r, KPP->panel, 20);
      CGContextRestoreGState(c);
    }
    KPButtonFace(c, r, KPStyle::Card, NO, YES, state.pressed, state.focused && !grabbed);
  }
  // The player's colour cap, with the number and the controller's lights.
  const CGRect face = CGRectMake(r.origin.x, r.origin.y + dy, r.size.width, r.size.height - 3);
  CGContextSaveGState(c);
  CGPathRef clip = CGPathCreateWithRoundedRect(face, 20, 20, nullptr);
  CGContextAddPath(c, clip);
  CGContextClip(c);
  CGPathRelease(clip);
  KPGradientFill(c, CGRectMake(r.origin.x, r.origin.y + dy, r.size.width, 58), 0, color, KPPlayerDarkColors[slot]);
  if (device == nil) KPFill(c, CGRectMake(r.origin.x, r.origin.y + dy, r.size.width, 58), KPP->panel, 0, 0.55);
  CGContextRestoreGState(c);
  const unsigned ink = device ? KPPlayerInk[slot] : KPP->secondaryText;
  KPTextWeight(KPPlayerName(slot), CGRectMake(r.origin.x + 22, r.origin.y + 13 + dy, 170, 32), 24, ink, NSFontWeightHeavy,
               NSTextAlignmentLeft);
  for (int pip = 0; pip < 4; ++pip) {
    const CGRect light = CGRectMake(CGRectGetMaxX(r) - 22 - (4 - pip) * 17 + 4, r.origin.y + 23 + dy, 12, 12);
    KPFill(c, light, pip == slot ? (device ? 0x8fe9ff : KPP->secondaryText) : 0x000000, 3, pip == slot ? 1 : 0.2);
  }
  if (device == nil) {
    KPDrawGlyph(c, KPUIGlyph::Plus, CGRectMake(CGRectGetMidX(r) - 34, r.origin.y + 112 + dy, 68, 68), KPP->buttonStroke);
    KPTextWeight(@"No controller", CGRectMake(r.origin.x + 10, r.origin.y + 206 + dy, r.size.width - 20, 30), 22, KPP->secondaryText,
                 NSFontWeightSemibold);
    KPTextWeight(@"Press A on a controller that isn't playing, or choose one here.",
                 CGRectMake(r.origin.x + 26, r.origin.y + 242 + dy, r.size.width - 52, 70), 16, KPP->secondaryText,
                 NSFontWeightRegular);
    return;
  }
  // Mii.
  NSDictionary *mii = [roster miiRecordFor:device];
  NSImage *portrait = KPPortraitFor(device, self.cards[slot]);
  const CGRect well = CGRectMake(CGRectGetMidX(r) - 58, r.origin.y + 72 + dy, 116, 116);
  KPDrawMiiWell(c, well, portrait, color, NO);
  KPTextWeight(mii[@"name"] ?: @"No Mii yet", CGRectMake(r.origin.x + 12, r.origin.y + 194 + dy, r.size.width - 24, 30), 21,
               mii ? KPP->text : KPP->secondaryText, NSFontWeightSemibold);
  // The controller, live.
  KPArtState art = KPArtStateFor(device, color);
  KPDrawControllerArt(c, CGRectMake(r.origin.x + 20, r.origin.y + 232 + dy, r.size.width - 40, 116), device.family, art,
                      device.systemName);
  KPTextWeight(device.name, CGRectMake(r.origin.x + 20, r.origin.y + 356 + dy, r.size.width - 80, 24), 16, KPP->secondaryText,
               NSFontWeightMedium, NSTextAlignmentLeft);
  KPDrawBattery(c, CGRectMake(CGRectGetMaxX(r) - 56, r.origin.y + 354 + dy, 34, 26), device);
  if (grabbed) {
    // Arrows either side while it's being moved.
    CGContextSaveGState(c);
    CGContextSetAlpha(c, 0.55 + 0.45 * self.pulse);
    if (slot > 0) KPDrawGlyph(c, KPUIGlyph::Back, CGRectMake(r.origin.x - 6, CGRectGetMidY(r) - 22, 44, 44), KPP->accentBottom);
    if (slot < KPPlayerCount - 1)
      KPDrawGlyph(c, KPUIGlyph::Chevron, CGRectMake(CGRectGetMaxX(r) - 38, CGRectGetMidY(r) - 22, 44, 44), KPP->accentBottom);
    CGContextRestoreGState(c);
    KPStroke(c, CGRectInset(r, -4, -4), KPP->accentTop, 4, 24);
  }
}

- (void)drawChip:(NSUInteger)index context:(CGContextRef)c in:(CGRect)r state:(KPUIState)state {
  if (index >= self.chips.count) return;
  KPPadDevice *device = self.chips[index].tagObject;
  if (device == nil) return;
  KPButtonFace(c, r, KPStyle::Plain, NO, YES, state.pressed, state.focused);
  const CGFloat dy = state.pressed ? 2 : 0;
  KPArtState art = KPArtStateFor(device, KPP->accentBottom);
  KPDrawControllerArt(c, CGRectMake(r.origin.x + 10, r.origin.y + 8 + dy, 92, r.size.height - 19), device.family, art, device.systemName);
  KPTextWeight(device.name, CGRectMake(r.origin.x + 110, r.origin.y + 12 + dy, r.size.width - 120, 26), 18, KPP->text,
               NSFontWeightSemibold, NSTextAlignmentLeft);
  KPTextWeight(device.isKeyboard ? @"Drives menus" : @"Press A to join", CGRectMake(r.origin.x + 110, r.origin.y + 40 + dy, r.size.width - 150, 22),
               15, KPP->secondaryText, NSFontWeightRegular, NSTextAlignmentLeft);
  KPDrawBattery(c, CGRectMake(CGRectGetMaxX(r) - 44, r.origin.y + 38 + dy, 30, 24), device);
}

@end

static KPControllersScreen *KPMakeControllersScreen(int focusSlot) {
  KPControllersScreen *screen = [[KPControllersScreen alloc] initWithFrame:NSZeroRect];
  screen.focusSlot = focusSlot;
  return screen;
}

#pragma mark Button setup

// The twelve things a controller does in the game, in the game's words, as the GameCube buttons
// Mario Kart Wii reads.
static NSArray<NSString *> *KPActionTitles() {
  return @[@"Accelerate · OK", @"Brake · Back", @"X", @"Y", @"Pause", @"Look behind", @"Use item", @"Drift · Hop",
           @"Trick · D-pad up", @"D-pad down", @"D-pad left", @"D-pad right"];
}
// The keyboard as the game starts it (runtime pad.cpp ConfigureDefaultKeyboardPort).
static const SDL_Scancode KPDefaultKeys[12] = {
  SDL_SCANCODE_RETURN, SDL_SCANCODE_BACKSPACE, SDL_SCANCODE_Q, SDL_SCANCODE_E, SDL_SCANCODE_SPACE, SDL_SCANCODE_LSHIFT,
  SDL_SCANCODE_LCTRL, SDL_SCANCODE_LALT, SDL_SCANCODE_UP, SDL_SCANCODE_DOWN, SDL_SCANCODE_LEFT, SDL_SCANCODE_RIGHT};

@interface KPRemapScreen : KPScreen
@property(nonatomic, strong) KPPadDevice *device;
@property(nonatomic, strong) NSMutableArray<KPUIButton *> *rows;
@property(nonatomic, strong) KPUIButton *reset, *done;
@property(nonatomic, strong) KPUIView *art;
@property(nonatomic) NSInteger capturing;  // action index, -1 when not listening
@property(nonatomic) BOOL alternate, armed;
@property(nonatomic) NSTimeInterval captureStarted;
@property(nonatomic, copy) NSString *status;
@end

@implementation KPRemapScreen

- (int)port { return self.device.slot; }

- (uint32_t)binding:(NSInteger)action alternate:(BOOL)alternate {
  const int port = self.port;
  if (port < 0) return PAD_NATIVE_BUTTON_INVALID;
  unsigned count = 0;
  PADButtonMapping *mappings = alternate ? PADGetAltButtonMappings(port, &count) : PADGetButtonMappings(port, &count);
  for (unsigned i = 0; mappings && i < count; ++i)
    if (mappings[i].padButton == KPButtons[action]) return mappings[i].nativeButton;
  return PAD_NATIVE_BUTTON_INVALID;
}

- (int)keyBinding:(NSInteger)action {
  const int port = self.port;
  u32 count = 0;
  PADKeyButtonBinding *keys = port >= 0 ? PADGetKeyButtonBindings(port, &count) : nullptr;
  for (u32 i = 0; keys && i < count; ++i)
    if (keys[i].padButton == KPButtons[action]) return keys[i].scancode;
  return -1;
}

- (NSString *)label:(NSInteger)action alternate:(BOOL)alternate {
  if (self.device.isKeyboard) {
    if (alternate) return nil;
    const int key = [self keyBinding:action];
    if (key < 0) return @"—";
    const char *name = SDL_GetScancodeName((SDL_Scancode)key);
    return name && *name ? @(name) : @"Key";
  }
  const uint32_t native = [self binding:action alternate:alternate];
  if (native == PAD_NATIVE_BUTTON_INVALID) {
    if (!alternate && (action == 6 || action == 7)) return action == 6 ? @"LT (analog)" : @"RT (analog)";
    return alternate ? nil : @"—";
  }
  return KPButtonLabel(self.device.gamepad, (int)native);
}

- (void)build {
  self.solid = YES;
  self.capturing = -1;
  __weak KPRemapScreen *weakSelf = self;
  self.rows = [NSMutableArray array];
  NSArray *titles = KPActionTitles();
  for (NSInteger i = 0; i < 12; ++i) {
    KPUIButton *row = [self button:CGRectZero face:^(CGContextRef c, CGRect r, KPUIState state) {
      KPRemapScreen *screen = weakSelf;
      const BOOL listening = screen.capturing == i;
      KPButtonFace(c, r, KPStyle::Plain, listening, state.enabled, state.pressed, state.focused);
      const CGFloat dy = state.pressed ? 2 : 0;
      KPTextWeight(titles[i], CGRectMake(r.origin.x + 18, CGRectGetMidY(r) - 13 + dy, 260, 26), 18, KPP->text, NSFontWeightSemibold,
                   NSTextAlignmentLeft);
      NSString *primary = listening && !screen.alternate ? @"Press…" : [screen label:i alternate:NO];
      NSString *second = listening && screen.alternate ? @"Press…" : [screen label:i alternate:YES];
      CGFloat x = CGRectGetMaxX(r) - 14;
      for (NSString *chip in @[second ?: @"", primary ?: @""]) {
        if (!chip.length) continue;
        const CGFloat w = std::max<CGFloat>(64, KPTextSize(chip, 16, NSFontWeightBold).width + 26);
        x -= w;
        const CGRect pill = CGRectMake(x, CGRectGetMidY(r) - 15 + dy, w, 28);
        const BOOL live = [chip isEqualToString:@"Press…"];
        KPFill(c, pill, live ? KPP->accentBottom : KPP->well, 14);
        KPStroke(c, pill, live ? KPP->accentLedge : KPP->buttonStroke, 1, 14);
        KPTextWeight(chip, CGRectMake(pill.origin.x, pill.origin.y + 4, w, 22), 16, live ? 0xffffff : KPP->text, NSFontWeightBold);
        x -= 8;
      }
    } action:^{ [weakSelf listen:i alternate:NO]; }];
    row.tag2 = i;
    row.radius = 10;
    row.margin = 5;
    row.focusScale = 1.01;
    row.label = titles[i];
    [self.rows addObject:row];
  }
  self.reset = [self button:CGRectZero face:^(CGContextRef c, CGRect r, KPUIState state) {
    KPDrawPill(c, r, state, KPStyle::Plain, KPUIGlyph::Restart, @"Reset to Default");
  } action:^{ [weakSelf askToReset]; }];
  self.done = [self button:CGRectZero face:^(CGContextRef c, CGRect r, KPUIState state) {
    KPDrawPill(c, r, state, KPStyle::Primary, KPUIGlyph::Check, @"Done");
  } action:^{ [KPOverlay() pop]; }];
  self.done.sound = KPUISound::Saved;
  self.art = [[KPUIView alloc] initWithFrame:NSZeroRect];
  self.art.paint = ^(CGContextRef c, CGSize size) {
    KPRemapScreen *screen = weakSelf;
    KPPadDevice *device = screen.device;
    if (device == nil) return;
    KPArtState state = KPArtStateFor(device, device.slot >= 0 ? KPPlayerColors[device.slot] : KPP->accentBottom);
    // The buttons bound to the action in focus pulse.
    const NSInteger action = screen.capturing >= 0 ? -1 : screen.focus.tag2;
    if (!device.isKeyboard && action >= 0 && action < 12 && [screen.rows containsObject:screen.focus]) {
      for (BOOL alternate : {NO, YES}) {
        const uint32_t native = [screen binding:action alternate:alternate];
        if (native < SDL_GAMEPAD_BUTTON_COUNT) state.highlight |= 1ull << native;
      }
      state.pulse = 0.5 + 0.5 * sin(NSProcessInfo.processInfo.systemUptime * 5);
    }
    KPDrawControllerArt(c, CGRectMake(0, 0, size.width, size.height), device.family, state, device.systemName);
  };
  [self addSubview:self.art];
}

- (void)layoutDesign {
  const CGRect s = self.safe;
  for (KPUIButton *row in self.rows)
    [self place:row at:CGRectMake(s.origin.x + 52, s.origin.y + 118 + row.tag2 * 46, 600, 42)];
  [self place:self.art at:CGRectMake(s.origin.x + 690, s.origin.y + 150, 540, 330)];
  [self place:self.reset at:CGRectMake(s.origin.x + 690, s.origin.y + 590, 290, 60)];
  [self place:self.done at:CGRectMake(CGRectGetMaxX(s) - 52 - 170, s.origin.y + 590, 170, 60)];
}

- (KPUIButton *)initialFocus { return self.rows.firstObject; }

- (void)listen:(NSInteger)action alternate:(BOOL)alternate {
  if (self.port < 0) {
    KPUIPlay(KPUISound::Reject);
    self.status = @"Give this controller a player first (on its card).";
    self.needsDisplay = YES;
    return;
  }
  self.capturing = action;
  self.alternate = alternate;
  self.armed = NO;
  self.captureStarted = NSProcessInfo.processInfo.systemUptime;
  self.status = nil;
  if (!self.device.isKeyboard) {
    // The shell's reader goes quiet while Controllers listens, so this press can't also move the focus.
    KPControllers().selectedID = self.device.joystick;
    KPControllers().capture = action;
    KPControllers().captureAlternate = alternate;
  }
  KPUIPlay(KPUISound::Open);
  for (KPUIButton *row in self.rows) row.needsDisplay = YES;
  self.needsDisplay = YES;
}

- (void)stopListening:(NSString *)status sound:(KPUISound)sound {
  self.capturing = -1;
  KPControllers().capture = -1;
  self.status = status;
  KPUIPlay(sound);
  for (KPUIButton *row in self.rows) row.needsDisplay = YES;
  self.needsDisplay = YES;
}

- (void)tick {
  [KPControllerRoster.shared refresh];
  self.art.needsDisplay = YES;
  if (self.capturing < 0 || self.device.isKeyboard) return;
  if (NSProcessInfo.processInfo.systemUptime - self.captureStarted > 8) {
    [self stopListening:@"Nothing pressed, so nothing changed." sound:KPUISound::Close];
    return;
  }
  SDL_Gamepad *pad = self.device.gamepad;
  if (pad == nullptr) {
    [self stopListening:@"The controller went away." sound:KPUISound::Reject];
    return;
  }
  // Wait for everything to be let go, then take the next button or trigger.
  int pressed = -1;
  for (int button = 0; button < SDL_GAMEPAD_BUTTON_COUNT; ++button) {
    if (button == SDL_GAMEPAD_BUTTON_GUIDE) continue;
    if (SDL_GetGamepadButton(pad, (SDL_GamepadButton)button)) pressed = button;
  }
  bool triggersUp = true;
  for (int side = 0; side < 2; ++side) {
    const int value = SDL_GetGamepadAxis(pad, side ? SDL_GAMEPAD_AXIS_RIGHT_TRIGGER : SDL_GAMEPAD_AXIS_LEFT_TRIGGER);
    if (value > 2000) triggersUp = false;
    if (value > 20000) pressed = (int)(side ? kartpad::binding::RightTrigger : kartpad::binding::LeftTrigger);
  }
  if (!self.armed) {
    if (pressed < 0 && triggersUp) self.armed = YES;
    return;
  }
  if (pressed < 0) return;
  KPControllers().selectedID = self.device.joystick;
  KPControllers().capture = self.capturing;
  KPControllers().captureAlternate = self.alternate;
  [KPControllers() bind:(uint32_t)pressed];
  [KPControllers() save:nil];
  NSString *title = KPActionTitles()[self.capturing];
  [self stopListening:[NSString stringWithFormat:@"%@ is now %@.", title, KPButtonLabel(pad, pressed)] sound:KPUISound::Saved];
}

// The keyboard listens for a key instead.
- (BOOL)takesKey:(NSEvent *)event {
  if (self.capturing < 0 || !self.device.isKeyboard || event.type != NSEventTypeKeyDown || event.isARepeat) return NO;
  if (event.keyCode == kVK_Escape) {
    [self stopListening:@"Nothing changed." sound:KPUISound::Close];
    return YES;
  }
  const SDL_Scancode code = KPMacPhysicalScancode(event.keyCode, KBGetLayoutType(LMGetKbdType()) == kKeyboardISO);
  if (code <= SDL_SCANCODE_UNKNOWN || self.port < 0) return YES;
  PADSetKeyButtonBinding(self.port, {code, KPButtons[self.capturing]});
  PADSetKeyboardActive(self.port, TRUE);
  const char *name = SDL_GetScancodeName(code);
  [self stopListening:[NSString stringWithFormat:@"%@ is now %s.", KPActionTitles()[self.capturing], name ?: "that key"]
                sound:KPUISound::Saved];
  return YES;
}

// X sets a second button for the action (either works).
- (BOOL)handle:(KartPadMiiPadButton)button {
  if (self.capturing >= 0) {
    if (button == KartPadMiiPadBack && (KPOverlay().keyboardInput || self.device.isKeyboard))
      [self stopListening:@"Nothing changed." sound:KPUISound::Close];
    return YES;
  }
  if (button == KartPadMiiPadUndo && [self.rows containsObject:self.focus] && !self.device.isKeyboard) {
    [self listen:self.focus.tag2 alternate:YES];
    return YES;
  }
  return NO;
}

- (void)askToReset {
  KPPadDevice *device = self.device;
  KPAsk(@"Reset the buttons?", [NSString stringWithFormat:@"%@ goes back to the buttons it started with.", device.name],
        @[@"Reset", @"Cancel"], 1, 0, ^(NSInteger choice) {
          if (choice != 0 || device.slot < 0) return;
          if (device.isKeyboard) {
            for (int i = 0; i < 12; ++i) PADSetKeyButtonBinding(device.slot, {KPDefaultKeys[i], KPButtons[i]});
            PADSetKeyboardActive(device.slot, TRUE);
          } else {
            KPControllers().selectedID = device.joystick;
            [KPControllers() reset:nil];
            [KPControllers() save:nil];
          }
          self.status = @"Back to the default buttons.";
          KPUIPlay(KPUISound::PagePrevious);
          for (KPUIButton *row in self.rows) row.needsDisplay = YES;
        });
}

- (void)back {
  if (self.capturing >= 0) {
    [self stopListening:@"Nothing changed." sound:KPUISound::Close];
    return;
  }
  [super back];
}

- (void)drawDesign:(CGContextRef)c size:(CGSize)size {
  [super drawDesign:c size:size];
  const CGRect s = self.safe;
  KPPadDevice *device = self.device;
  NSString *who = device.slot >= 0 ? [NSString stringWithFormat:@"%@ · %@", KPPlayerName(device.slot), device.name] : device.name;
  if (device.slot >= 0) KPFill(c, CGRectMake(s.origin.x + 52, s.origin.y + 34, 8, 40), KPPlayerColors[device.slot], 4);
  KPTextWeight(@"Buttons", CGRectMake(s.origin.x + 72, s.origin.y + 26, 400, 50), 36, KPP->text, NSFontWeightBold, NSTextAlignmentLeft);
  KPTextWeight(who, CGRectMake(s.origin.x + 74, s.origin.y + 76, 700, 26), 18, KPP->secondaryText, NSFontWeightMedium, NSTextAlignmentLeft);
  NSString *line;
  unsigned ink = KPP->secondaryText;
  if (self.capturing >= 0) {
    const NSInteger left = std::max<NSInteger>(0, 8 - (NSInteger)(NSProcessInfo.processInfo.systemUptime - self.captureStarted));
    line = [NSString stringWithFormat:@"Press the %@ you want for %@  (%ld)", device.isKeyboard ? @"key" : @"button",
            KPActionTitles()[self.capturing], (long)left];
    ink = KPP->accentBottom;
  } else {
    line = self.status ?: (device.isKeyboard ? @"Ⓐ Change the key    Ⓑ Back" : @"Ⓐ Change    Ⓧ Add a second button    Ⓑ Back");
  }
  KPTextWeight(line, CGRectMake(s.origin.x + 690, s.origin.y + 500, 540, 56), 20, ink, NSFontWeightSemibold);
  if (device.isKeyboard)
    KPTextWeight(@"Steer with W A S D. Esc opens HOME.", CGRectMake(s.origin.x + 690, s.origin.y + 118, 540, 26), 16,
                 KPP->secondaryText, NSFontWeightMedium);
}
@end

static void KPSetUpButtons(KPPadDevice *device) {
  if (device == nil) return;
  KPRemapScreen *screen = [[KPRemapScreen alloc] initWithFrame:NSZeroRect];
  screen.device = device;
  [KPOverlay() present:screen];
}

#pragma mark Choosing a Mii

@interface KPMiiPickerScreen : KPScreen
@property(nonatomic, strong) KPPadDevice *device;
@property(nonatomic, copy) NSArray<NSDictionary *> *records;
@property(nonatomic, strong) NSMutableArray<KPUIButton *> *tiles;
@property(nonatomic) NSInteger page;
@end

@implementation KPMiiPickerScreen
static constexpr NSInteger KPMiiPickerColumns = 6, KPMiiPickerRows = 3;
- (void)build {
  self.solid = YES;
  self.records = KartPadMiiRecords(nil);
  self.tiles = [NSMutableArray array];
  __weak KPMiiPickerScreen *weakSelf = self;
  for (NSInteger i = 0; i < KPMiiPickerColumns * KPMiiPickerRows; ++i) {
    KPUIButton *tile = [self button:CGRectZero face:^(CGContextRef c, CGRect r, KPUIState state) {
      [weakSelf drawTile:i context:c in:r state:state];
    } action:^{ [weakSelf choose:i]; }];
    tile.tag2 = i;
    tile.radius = 16;
    [self.tiles addObject:tile];
  }
}
- (NSInteger)perPage { return KPMiiPickerColumns * KPMiiPickerRows; }
// Index 0 on the first page is "No Mii".
- (NSDictionary *)recordAt:(NSInteger)tile {
  const NSInteger index = self.page * self.perPage + tile - 1;
  return index >= 0 && index < (NSInteger)self.records.count ? self.records[index] : nil;
}
- (NSInteger)pages { return std::max<NSInteger>(1, (self.records.count + 1 + self.perPage - 1) / self.perPage); }
- (void)layoutDesign {
  const CGRect s = self.safe;
  const CGFloat w = 176, h = 160, gap = 16, x0 = s.origin.x + (1280 - (KPMiiPickerColumns * w + (KPMiiPickerColumns - 1) * gap)) / 2;
  for (KPUIButton *tile in self.tiles) {
    const NSInteger i = tile.tag2, index = self.page * self.perPage + i;
    tile.hidden = index > (NSInteger)self.records.count;
    [self place:tile at:CGRectMake(x0 + (i % KPMiiPickerColumns) * (w + gap), s.origin.y + 124 + (i / KPMiiPickerColumns) * (h + gap), w, h)];
    tile.needsDisplay = YES;
  }
}
- (void)drawTile:(NSInteger)i context:(CGContextRef)c in:(CGRect)r state:(KPUIState)state {
  KPButtonFace(c, r, KPStyle::Tile, NO, YES, state.pressed, state.focused);
  const CGFloat dy = state.pressed ? 2 : 0;
  const BOOL none = self.page == 0 && i == 0;
  NSDictionary *record = none ? nil : [self recordAt:i];
  const CGRect well = CGRectMake(CGRectGetMidX(r) - 50, r.origin.y + 12 + dy, 100, 100);
  if (none) {
    KPFill(c, well, KPLightPalette.well, 22);
    KPDrawGlyph(c, KPUIGlyph::Close, CGRectInset(well, 30, 30), KPP->buttonStroke);
    KPTextWeight(@"No Mii", CGRectMake(r.origin.x + 6, r.origin.y + 118 + dy, r.size.width - 12, 26), 18, KPP->secondaryText,
                 NSFontWeightSemibold);
    return;
  }
  if (record == nil) return;
  __weak KPUIButton *tile = self.tiles[i];
  NSImage *portrait = KartPadMiiPortrait(record[@"mii"], ^{ tile.needsDisplay = YES; });
  KPDrawMiiWell(c, well, portrait, KPFavoriteColorHex(record), NO);
  KPTextWeight(record[@"name"], CGRectMake(r.origin.x + 6, r.origin.y + 118 + dy, r.size.width - 12, 26), 18, KPP->text,
               NSFontWeightSemibold);
}
- (void)choose:(NSInteger)i {
  NSDictionary *record = self.page == 0 && i == 0 ? nil : [self recordAt:i];
  [KPControllerRoster.shared setMii:record forDevice:self.device];
  KPUIPlay(record ? KPUISound::NewMii : KPUISound::PagePrevious);
  [KPOverlay() pop];
}
- (BOOL)handle:(KartPadMiiPadButton)button {
  if (button == KartPadMiiPadNextTab || button == KartPadMiiPadPreviousTab) {
    const NSInteger next = self.page + (button == KartPadMiiPadNextTab ? 1 : -1);
    if (next < 0 || next >= self.pages) {
      KPUIPlay(KPUISound::Reject);
      return YES;
    }
    self.page = next;
    KPUIPlay(button == KartPadMiiPadNextTab ? KPUISound::PageNext : KPUISound::PagePrevious);
    [self layoutDesign];
    [KPOverlay() focus:self.tiles.firstObject sound:NO];
    self.needsDisplay = YES;
    return YES;
  }
  return NO;
}
- (KPUIButton *)initialFocus {
  NSDictionary *current = [KPControllerRoster.shared miiRecordFor:self.device];
  if (current) {
    const NSInteger index = (NSInteger)[self.records indexOfObject:current] + 1;
    if (index > 0 && index < self.perPage) return self.tiles[index];
  }
  return self.tiles.firstObject;
}
- (void)drawDesign:(CGContextRef)c size:(CGSize)size {
  [super drawDesign:c size:size];
  const CGRect s = self.safe;
  KPTextWeight(@"Choose a Mii", CGRectMake(s.origin.x + 56, s.origin.y + 26, 600, 50), 36, KPP->text, NSFontWeightBold, NSTextAlignmentLeft);
  NSString *who = self.device.slot >= 0 ? [NSString stringWithFormat:@"For %@ · %@", KPPlayerName(self.device.slot), self.device.name]
                                        : [NSString stringWithFormat:@"For %@", self.device.name];
  KPTextWeight(who, CGRectMake(s.origin.x + 58, s.origin.y + 76, 700, 26), 18, KPP->secondaryText, NSFontWeightMedium, NSTextAlignmentLeft);
  if (self.pages > 1)
    KPTextWeight([NSString stringWithFormat:@"Page %ld of %ld    LB / RB to turn", (long)self.page + 1, (long)self.pages],
                 CGRectMake(s.origin.x + 56, s.origin.y + 670, 1168, 26), 16, KPP->secondaryText, NSFontWeightMedium, NSTextAlignmentRight);
  if (!self.records.count)
    KPTextWeight(@"There are no Miis yet. Make one in HOME › Miis.", CGRectMake(s.origin.x + 56, s.origin.y + 320, 1168, 30), 20,
                 KPP->secondaryText, NSFontWeightMedium);
}
@end

static void KPChooseMii(KPPadDevice *device) {
  KPMiiPickerScreen *screen = [[KPMiiPickerScreen alloc] initWithFrame:NSZeroRect];
  screen.device = device;
  [KPOverlay() present:screen];
}

#pragma mark Connecting a controller

// Pairing, one kind of controller at a time: how to put it in pairing mode, then (for most) the
// Mac's Bluetooth settings, which KartPad watches so the new controller shows up and is celebrated.
// Wii Remotes pair right here.
enum class KPPairKind { Xbox, PlayStation, Switch, WiiRemote, Other };

@interface KPConnectScreen : KPScreen <KPRosterListener>
@property(nonatomic) KPPairKind kind;
@property(nonatomic) BOOL choosing;  // the first step: which kind
@property(nonatomic, strong) NSMutableArray<KPUIButton *> *kinds;
@property(nonatomic, strong) KPUIButton *primary, *done;
@property(nonatomic, copy) NSString *status;
@property(nonatomic) BOOL busy;
@property(nonatomic, strong) NSSet<NSString *> *before;
@property(nonatomic, strong) KPPadDevice *arrived;
@end

@implementation KPConnectScreen
static NSString *KPPairTitle(KPPairKind kind) {
  switch (kind) {
    case KPPairKind::Xbox: return @"Xbox controller";
    case KPPairKind::PlayStation: return @"PlayStation controller";
    case KPPairKind::Switch: return @"Pro Controller or Joy\u2011Con";
    case KPPairKind::WiiRemote: return @"Wii Remote";
    case KPPairKind::Other: return @"Another controller";
  }
  return @"Controller";
}
static KPPadFamily KPPairFamily(KPPairKind kind) {
  switch (kind) {
    case KPPairKind::Xbox: return KPFamilyXbox;
    case KPPairKind::PlayStation: return KPFamilyPlayStation;
    case KPPairKind::Switch: return KPFamilySwitch;
    case KPPairKind::WiiRemote: return KPFamilyWiiRemote;
    case KPPairKind::Other: return KPFamilyGeneric;
  }
  return KPFamilyGeneric;
}
static NSString *KPPairSteps(KPPairKind kind) {
  switch (kind) {
    case KPPairKind::Xbox:
      return @"1. Turn the controller on.\n2. Hold the small pair button on its top edge until the Xbox button flashes quickly.\n3. In Bluetooth settings, click Connect next to Xbox Wireless Controller.";
    case KPPairKind::PlayStation:
      return @"1. Hold the Share (or Create) button and the PS button together until the light flashes.\n2. In Bluetooth settings, click Connect next to the controller.";
    case KPPairKind::Switch:
      return @"1. Hold the small sync button on the top edge (on a Joy\u2011Con, its rail) until the lights run back and forth.\n2. In Bluetooth settings, click Connect next to it.";
    case KPPairKind::WiiRemote:
      return @"1. Open the battery cover and press the small red SYNC button.\n2. KartPad finds it and pairs it — no settings needed.\n3. Attach the Nunchuk any time.";
    case KPPairKind::Other:
      return @"1. Put the controller in pairing mode (usually: hold its pair button for a few seconds).\n2. In Bluetooth settings, click Connect next to it.\nA USB controller just needs plugging in.";
  }
  return @"";
}
- (void)build {
  self.solid = YES;
  self.choosing = YES;
  __weak KPConnectScreen *weakSelf = self;
  self.kinds = [NSMutableArray array];
  const KPPairKind kinds[] = {KPPairKind::Xbox, KPPairKind::PlayStation, KPPairKind::Switch, KPPairKind::WiiRemote, KPPairKind::Other};
  for (KPPairKind kind : kinds) {
    KPUIButton *tile = [self button:CGRectZero face:^(CGContextRef c, CGRect r, KPUIState state) {
      KPButtonFace(c, r, KPStyle::Card, NO, YES, state.pressed, state.focused);
      const CGFloat dy = state.pressed ? 2 : 0;
      KPArtState art;
      art.accent = KPP->accentBottom;
      KPDrawControllerArt(c, CGRectMake(r.origin.x + 18, r.origin.y + 20 + dy, r.size.width - 36, 120), KPPairFamily(kind), art);
      KPTextWeight(KPPairTitle(kind), CGRectMake(r.origin.x + 10, r.origin.y + 160 + dy, r.size.width - 20, 56), 20, KPP->text,
                   NSFontWeightSemibold);
    } action:^{ [weakSelf chooseKind:kind]; }];
    tile.tag2 = (NSInteger)kind;
    tile.radius = 18;
    tile.label = KPPairTitle(kind);
    [self.kinds addObject:tile];
  }
  self.primary = [self button:CGRectZero face:^(CGContextRef c, CGRect r, KPUIState state) {
    KPConnectScreen *screen = weakSelf;
    const BOOL wii = screen.kind == KPPairKind::WiiRemote;
    KPDrawPill(c, r, state, KPStyle::Primary, wii ? KPUIGlyph::Find : KPUIGlyph::Bluetooth,
               wii ? (screen.busy ? @"Searching…" : @"Search Again") : @"Open Bluetooth Settings");
  } action:^{ [weakSelf primaryAction]; }];
  self.done = [self button:CGRectZero face:^(CGContextRef c, CGRect r, KPUIState state) {
    KPDrawPill(c, r, state, KPStyle::Plain, KPUIGlyph::Check, @"Done");
  } action:^{ [KPOverlay() pop]; }];
  [KPControllerRoster.shared.listeners addObject:self];
}
- (void)layoutDesign {
  const CGRect s = self.safe;
  const CGFloat w = 222, gap = 18, x0 = s.origin.x + (1280 - (5 * w + 4 * gap)) / 2;
  for (KPUIButton *tile in self.kinds) {
    tile.hidden = !self.choosing;
    [self place:tile at:CGRectMake(x0 + tile.tag2 * (w + gap), s.origin.y + 180, w, 236)];
  }
  self.primary.hidden = self.choosing;
  [self place:self.primary at:CGRectMake(s.origin.x + 700, s.origin.y + 560, 330, 64)];
  [self place:self.done at:CGRectMake(CGRectGetMaxX(s) - 56 - 170, self.choosing ? s.origin.y + 590 : s.origin.y + 560, 170, 64)];
}
- (KPUIButton *)initialFocus { return self.choosing ? self.kinds.firstObject : self.primary; }
- (void)chooseKind:(KPPairKind)kind {
  self.kind = kind;
  self.choosing = NO;
  self.arrived = nil;
  NSMutableSet *ids = [NSMutableSet set];
  for (KPPadDevice *device in KPControllerRoster.shared.devices) [ids addObject:device.identifier];
  self.before = ids;
  self.status = kind == KPPairKind::WiiRemote ? @"Getting Bluetooth ready…" : @"Waiting for the controller to connect…";
  [self layoutDesign];
  [KPOverlay() focus:self.primary sound:NO];
  self.needsDisplay = YES;
  if (kind == KPPairKind::WiiRemote) [self pairWiiRemote];
}
- (void)pairWiiRemote {
  self.busy = YES;
  __weak KPConnectScreen *weakSelf = self;
  KartPadBeginWiimotePairing(^(NSString *message, BOOL busy) {
    KPConnectScreen *screen = weakSelf;
    screen.status = message;
    screen.busy = busy;
    screen.needsDisplay = YES;
    screen.primary.needsDisplay = YES;
  });
  self.primary.needsDisplay = YES;
}
- (void)primaryAction {
  if (self.kind == KPPairKind::WiiRemote) {
    if (!self.busy) [self pairWiiRemote];
    return;
  }
  NSURL *settings = [NSURL URLWithString:@"x-apple.systempreferences:com.apple.BluetoothSettings"];
  if (![NSWorkspace.sharedWorkspace openURL:settings])
    [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:@"x-apple.systempreferences:com.apple.preferences.Bluetooth"]];
  // Background events, so KartPad notices the controller while Settings is in front.
  SDL_SetHint(SDL_HINT_JOYSTICK_ALLOW_BACKGROUND_EVENTS, "1");
  self.status = @"Waiting for the controller to connect… KartPad comes back by itself.";
  self.needsDisplay = YES;
}
- (void)rosterChanged {
  if (self.choosing || self.arrived) return;
  for (KPPadDevice *device in KPControllerRoster.shared.devices) {
    if (device.isKeyboard || [self.before containsObject:device.identifier]) continue;
    self.arrived = device;
    // A new controller with no player takes the first free one.
    KPControllerRoster *roster = KPControllerRoster.shared;
    if (device.slot < 0)
      for (int slot = 0; slot < KPPlayerCount; ++slot)
        if (![roster deviceInSlot:slot]) {
          [roster move:device toSlot:slot];
          break;
        }
    self.status = device.slot >= 0 ? [NSString stringWithFormat:@"%@ connected — it's %@!", device.name, KPPlayerName(device.slot)]
                                   : [NSString stringWithFormat:@"%@ connected!", device.name];
    self.busy = NO;
    [roster identify:device];
    KPUIPlay(KPUISound::Saved);
    if (!KPUIBackgroundAutomation()) {
      [NSApp activateIgnoringOtherApps:YES];
      [KPGameWindow() makeKeyAndOrderFront:nil];
    }
    [KPOverlay() focus:self.done sound:NO];
    self.needsDisplay = YES;
    return;
  }
}
- (void)tick {
  [KPControllerRoster.shared refresh];
  self.needsDisplay = YES;
}
- (void)willDisappear {
  KartPadCancelWiimotePairing();
  [KPControllerRoster.shared.listeners removeObject:self];
  SDL_SetHint(SDL_HINT_JOYSTICK_ALLOW_BACKGROUND_EVENTS, "0");
}
- (void)back {
  if (!self.choosing && !self.arrived) {
    KartPadCancelWiimotePairing();
    self.choosing = YES;
    self.busy = NO;
    [self layoutDesign];
    [KPOverlay() focus:self.kinds[(NSInteger)self.kind] sound:NO];
    KPUIPlay(KPUISound::Close);
    self.needsDisplay = YES;
    return;
  }
  [super back];
}
- (void)drawDesign:(CGContextRef)c size:(CGSize)size {
  [super drawDesign:c size:size];
  const CGRect s = self.safe;
  KPTextWeight(@"Connect a Controller", CGRectMake(s.origin.x + 56, s.origin.y + 26, 800, 50), 36, KPP->text, NSFontWeightBold,
               NSTextAlignmentLeft);
  if (self.choosing) {
    KPTextWeight(@"Which kind is it?", CGRectMake(s.origin.x + 58, s.origin.y + 78, 760, 26), 18, KPP->secondaryText,
                 NSFontWeightMedium, NSTextAlignmentLeft);
    KPTextWeight(@"Controllers you've connected before come back on their own: just turn them on.",
                 CGRectMake(s.origin.x + 56, s.origin.y + 460, 1168, 30), 18, KPP->secondaryText, NSFontWeightRegular);
    return;
  }
  KPTextWeight(KPPairTitle(self.kind), CGRectMake(s.origin.x + 58, s.origin.y + 78, 760, 26), 18, KPP->secondaryText,
               NSFontWeightMedium, NSTextAlignmentLeft);
  // The controller, big, with the steps beside it.
  KPArtState art;
  art.accent = KPP->accentBottom;
  KPPadDevice *arrived = self.arrived;
  if (arrived) art = KPArtStateFor(arrived, arrived.slot >= 0 ? KPPlayerColors[arrived.slot] : KPP->accentBottom);
  KPCard(c, CGRectMake(s.origin.x + 56, s.origin.y + 130, 580, 380), 24);
  KPDrawControllerArt(c, CGRectMake(s.origin.x + 96, s.origin.y + 170, 500, 300), arrived ? arrived.family : KPPairFamily(self.kind), art,
                      arrived.systemName);
  KPTextWeight(KPPairSteps(self.kind), CGRectMake(s.origin.x + 700, s.origin.y + 140, 524, 260), 21, KPP->text, NSFontWeightMedium,
               NSTextAlignmentLeft);
  const unsigned ink = arrived ? 0x22843f : KPP->accentBottom;
  if (self.status.length) {
    if (arrived) KPDrawGlyph(c, KPUIGlyph::Check, CGRectMake(s.origin.x + 700, s.origin.y + 440, 36, 36), ink);
    KPTextWeight(self.status, CGRectMake(s.origin.x + (arrived ? 748 : 700), s.origin.y + 438, 476, 100), 20, ink, NSFontWeightSemibold,
                 NSTextAlignmentLeft);
  }
}
@end

static KPScreen *KPMakeConnectScreen() { return [[KPConnectScreen alloc] initWithFrame:NSZeroRect]; }

// Controllers: who plays with which controller, at a glance. Four player cards in the game's player
// colours, each with its Mii, a live drawing of the controller (it lights up as you press) and its
// battery; the controllers that aren't playing wait in a tray below. Press anything on a controller
// and its card bounces, so "which one is mine?" answers itself. A controller that isn't playing joins
// with A, and Y makes a controller buzz and flash.
// Players change controllers by pressing on the controller they want, the way consoles do it:
// "Change controller" on a card (or A on an empty one) waits for A on the controller that should be
// that player; Player Order has everyone press A in turn, the first press becoming Player 1. Each
// card's menu also sets up buttons, chooses a Mii or takes the controller out.
// Also here: button setup (KPRemapScreen), choosing a Mii (KPMiiPickerScreen) and connecting a new
// controller (KPConnectScreen). Included by KartPadMacShell.mm after KartPadHomeScreen.inc.mm.

static void KPSetUpButtons(KPPadDevice *device);
static void KPChooseMii(KPPadDevice *device);
static void KPChooseVibration(KPPadDevice *device);
static KPScreen *KPMakeConnectScreen();

// Which controller made the latest press: a pad (by joystick), or the keyboard.
static KPPadDevice *KPPresser() {
  if (KPOverlay().keyboardInput) return [KPControllerRoster.shared deviceWithIdentifier:@"keyboard"];
  if (KPPadLastPresser == 0) return nil;
  return [KPControllerRoster.shared deviceWithIdentifier:[NSString stringWithFormat:@"sdl:%u", KPPadLastPresser]];
}

// What a card or chip shows of its controller (which one, what it's pressing, its battery), so a
// tick redraws only the ones that changed rather than the whole window.
static uint64_t KPDeviceLook(KPPadDevice *device) {
  if (device == nil) return 0;
  uint64_t look = 0xcbf29ce484222325ull;
  auto mix = [&look](uint64_t value) { look = (look ^ value) * 0x100000001b3ull; };
  mix((uint64_t)(uintptr_t)(__bridge void *)device);
  mix(device.buttons);
  for (int axis = 0; axis < SDL_GAMEPAD_AXIS_COUNT; ++axis) mix((uint64_t)std::lround(device->axes[axis] * 64));
  mix((uint64_t)(device.battery + 1) << 2 | (device.charging ? 2 : 0) | (device.wired ? 1 : 0));
  return look;
}

// Choosing controllers by pressing on them: one player at a time, or everyone in order.
typedef NS_ENUM(NSInteger, KPControllersMode) { KPControllersBrowsing, KPControllersAssigning, KPControllersOrdering };
// The presses those listen for, from each controller.
enum : unsigned { KPPressConfirm = 1, KPPressBack = 2, KPPressStart = 4 };

@interface KPControllersScreen : KPScreen <KPRosterListener>
@property(nonatomic) int focusSlot;
// Opened from an empty player on HOME: straight to choosing its controller.
@property(nonatomic) BOOL assignOnOpen;
@property(nonatomic, strong) NSMutableArray<KPUIButton *> *cards, *chips;
@property(nonatomic, strong) KPUIButton *order, *connect, *done;
// While controllers are being chosen by pressing: Use Keyboard (one player), Done (everyone), Cancel.
@property(nonatomic, strong) KPUIButton *useKeyboard, *finish, *cancel;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *seenInput;
@property(nonatomic) KPControllersMode mode;
@property(nonatomic) int target;                                  // assigning: the player choosing a controller
@property(nonatomic, strong) NSMutableArray<KPPadDevice *> *ordered;  // ordering: who has pressed, in order
@property(nonatomic, strong) NSDictionary<NSString *, NSNumber *> *before;  // ordering: who played as whom, for Cancel
@property(nonatomic, strong) id keyboardPin;                      // ordering: the keyboard's setting, for Cancel
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, NSNumber *> *held;  // each controller's A, B and Start
@property(nonatomic) NSTimeInterval lastPress, finishAt;
@property(nonatomic) CGFloat pulse;
- (void)device:(KPPadDevice *)device pressed:(unsigned)press;
@end

@implementation KPControllersScreen {
  // What each card and chip showed when it last drew (KPDeviceLook and the like).
  std::array<uint64_t, KPPlayerCount> _cardLooks;
  std::vector<uint64_t> _chipLooks;
}

- (void)build {
  self.solid = YES;
  self.title = @"Controllers";
  self.seenInput = [NSMutableDictionary dictionary];
  __weak KPControllersScreen *weakSelf = self;
  self.order = [self button:CGRectZero face:^(CGContextRef c, CGRect r, KPUIState state) {
    // Disabled (no pads): the whole pill fades, its word and icon too.
    CGContextSaveGState(c);
    if (!state.enabled) CGContextSetAlpha(c, 0.42);
    KPDrawPill(c, r, {state.focused, state.pressed, YES}, KPStyle::Plain, KPUIGlyph::Order, @"Player Order");
    CGContextRestoreGState(c);
  } action:^{ [weakSelf beginOrdering]; }];
  self.order.label = @"Player Order";
  self.connect = [self button:CGRectZero face:^(CGContextRef c, CGRect r, KPUIState state) {
    KPDrawPill(c, r, state, KPStyle::Plain, KPUIGlyph::Plus, @"Connect");
  } action:^{ [KPOverlay() present:KPMakeConnectScreen()]; }];
  self.connect.label = @"Connect a controller";
  self.done = [self button:CGRectZero face:^(CGContextRef c, CGRect r, KPUIState state) {
    KPDrawPill(c, r, state, KPStyle::Primary, KPUIGlyph::Check, @"Done");
  } action:^{ [KPOverlay() pop]; }];
  self.done.label = @"Done";
  self.done.sound = KPUISound::Close;
  self.useKeyboard = [self button:CGRectZero face:^(CGContextRef c, CGRect r, KPUIState state) {
    KPDrawPill(c, r, state, KPStyle::Plain, KPUIGlyph::Keyboard, @"Use Keyboard");
  } action:^{
    KPControllersScreen *screen = weakSelf;
    [screen device:[KPControllerRoster.shared deviceWithIdentifier:@"keyboard"] pressed:KPPressConfirm];
  }];
  self.useKeyboard.label = @"Use Keyboard";
  self.useKeyboard.sound = KPUISound::Count;
  self.finish = [self button:CGRectZero face:^(CGContextRef c, CGRect r, KPUIState state) {
    KPDrawPill(c, r, state, KPStyle::Primary, KPUIGlyph::Check, @"Done");
  } action:^{ [weakSelf endOrdering:YES]; }];
  self.finish.label = @"Done";
  self.finish.sound = KPUISound::Count;
  self.cancel = [self button:CGRectZero face:^(CGContextRef c, CGRect r, KPUIState state) {
    KPDrawPill(c, r, state, KPStyle::Plain, KPUIGlyph::Close, @"Cancel");
  } action:^{ [weakSelf cancelChoosing]; }];
  self.cancel.label = @"Cancel";
  self.cancel.sound = KPUISound::Count;
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
  const BOOL browsing = self.mode == KPControllersBrowsing;
  // The buttons along the top: what the screen does, or (choosing by pressing) how to stop.
  self.order.hidden = self.connect.hidden = self.done.hidden = !browsing;
  self.useKeyboard.hidden = self.mode != KPControllersAssigning ||
                            [KPControllerRoster.shared deviceInSlot:self.target].isKeyboard;
  self.finish.hidden = self.mode != KPControllersOrdering;
  self.cancel.hidden = browsing;
  const CGFloat right = CGRectGetMaxX(s) - 56, y = s.origin.y + 30;
  [self place:self.done at:CGRectMake(right - 150, y, 150, 60)];
  [self place:self.connect at:CGRectMake(right - 150 - 16 - 200, y, 200, 60)];
  [self place:self.order at:CGRectMake(right - 150 - 16 - 200 - 16 - 250, y, 250, 60)];
  [self place:self.cancel at:CGRectMake(right - 170, y, 170, 60)];
  [self place:self.useKeyboard at:CGRectMake(right - 170 - 16 - 250, y, 250, 60)];
  [self place:self.finish at:CGRectMake(right - 170 - 16 - 170, y, 170, 60)];
  // While choosing by pressing, the cards and tray only show what's happening.
  for (KPUIButton *card in self.cards) card.enabled = browsing;
  NSInteger pads = 0;
  for (KPPadDevice *device in KPControllerRoster.shared.devices) pads += !device.isKeyboard;
  self.order.enabled = pads > 0;
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
    chip.enabled = self.mode == KPControllersBrowsing;
    [self place:chip at:CGRectMake(x0 + i * (width + gap), s.origin.y + 568, width, 76)];
    chip.needsDisplay = YES;
  }
}

- (KPUIButton *)initialFocus {
  if (self.mode == KPControllersAssigning) return self.useKeyboard.hidden ? self.cancel : self.useKeyboard;
  if (self.mode == KPControllersOrdering) return self.finish;
  if (self.focusSlot >= 0 && self.focusSlot < KPPlayerCount) return self.cards[self.focusSlot];
  KPPadDevice *presser = KPControllerRoster.shared.lastActive;
  if (presser.slot >= 0) return self.cards[presser.slot];
  return self.cards.firstObject;
}

- (void)willDisappear {
  KPControllerRoster.shared.quiet = NO;
  if (self.mode == KPControllersOrdering) [self endOrdering:NO];
  else if (self.mode == KPControllersAssigning) [self stopChoosing];
}

- (void)willAppear {
  KPControllerRoster.shared.quiet = YES;
  [KPControllerRoster.shared.listeners addObject:self];
}

- (void)didAppear {
  if (!self.assignOnOpen) return;
  self.assignOnOpen = NO;
  if (self.focusSlot >= 0 && self.focusSlot < KPPlayerCount && ![KPControllerRoster.shared deviceInSlot:self.focusSlot])
    [self beginAssigning:self.focusSlot];
}

- (void)rosterChanged {
  [self layoutDesign];
  for (KPUIButton *card in self.cards) card.needsDisplay = YES;
  self.needsDisplay = YES;  // "Not playing" over the tray
}

// What a card shows: its controller, or, choosing by pressing, the player waiting (the next one
// breathing with the pulse).
- (uint64_t)cardLook:(int)slot {
  const BOOL waiting = (self.mode == KPControllersAssigning && slot == self.target) ||
                       (self.mode == KPControllersOrdering && slot >= (int)self.ordered.count);
  if (!waiting) return KPDeviceLook([KPControllerRoster.shared deviceInSlot:slot]) ^ (uint64_t)self.mode;
  const BOOL next = self.mode == KPControllersAssigning || (slot == (int)self.ordered.count && self.finishAt == 0);
  return 0x5741495400000000ull | (uint64_t)next << 16 | (next ? (uint64_t)std::lround(self.pulse * 40) : 0);
}

// Live: the drawings follow the controllers, and a card bounces when its controller is used. Only
// what changed redraws: the background and titles stay as they are.
- (void)tick {
  KPControllerRoster *roster = KPControllerRoster.shared;
  [roster refresh];
  self.pulse = 0.5 + 0.5 * sin(NSProcessInfo.processInfo.systemUptime * 6);
  for (KPPadDevice *device in roster.devices) {
    NSNumber *seen = self.seenInput[device.identifier];
    if (device.lastInput > 0 && (seen == nil || seen.doubleValue < device.lastInput)) {
      if (seen != nil && self.mode == KPControllersBrowsing) [self bounce:device];
      self.seenInput[device.identifier] = @(device.lastInput);
    }
  }
  if (self.mode != KPControllersBrowsing) [self listen];
  for (KPUIButton *card in self.cards) {
    const uint64_t look = [self cardLook:(int)card.tag2];
    if (look == _cardLooks[card.tag2]) continue;
    _cardLooks[card.tag2] = look;
    card.needsDisplay = YES;
  }
  _chipLooks.resize(self.chips.count);
  for (NSUInteger i = 0; i < self.chips.count; ++i) {
    const uint64_t look = KPDeviceLook(self.chips[i].tagObject);
    if (look == _chipLooks[i]) continue;
    _chipLooks[i] = look;
    self.chips[i].needsDisplay = YES;
  }
}

- (KPUIButton *)viewFor:(KPPadDevice *)device {
  if (device.slot >= 0) return self.cards[device.slot];
  for (KPUIButton *chip in self.chips)
    if (chip.tagObject == device) return chip;
  return nil;
}

- (void)bounce:(KPPadDevice *)device {
  KPUIButton *view = [self viewFor:device];
  if (view == nil) return;
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

#pragma mark Choosing by pressing

- (void)startListening {
  KPPadListening = true;
  self.held = nil;
  self.lastPress = NSProcessInfo.processInfo.systemUptime;
  self.finishAt = 0;
  [self listen];  // what's held now isn't a press
  [self layoutDesign];
  [KPOverlay() focus:[self initialFocus] sound:NO];
  self.needsDisplay = YES;
}

- (void)stopChoosing {
  self.mode = KPControllersBrowsing;
  KPPadListening = false;
  [self layoutDesign];
  self.needsDisplay = YES;
}

// One player: the next controller to press A becomes theirs.
- (void)beginAssigning:(int)slot {
  self.mode = KPControllersAssigning;
  self.target = slot;
  KPUIPlay(KPUISound::Open);
  [self startListening];
}

// Everyone: each controller to press A takes the next player, from Player 1.
- (void)beginOrdering {
  KPControllerRoster *roster = KPControllerRoster.shared;
  NSMutableDictionary *before = [NSMutableDictionary dictionary];
  for (KPPadDevice *device in roster.devices) before[device.identifier] = @(device.slot);
  self.before = before;
  self.keyboardPin = [NSUserDefaults.standardUserDefaults objectForKey:KPKeyboardPlayerKey];
  self.ordered = [NSMutableArray array];
  self.mode = KPControllersOrdering;
  KPUIPlay(KPUISound::Open);
  [self startListening];
}

// Done: the order stands, and controllers that didn't press stop playing (the keyboard keeps its
// setting). Cancelled: everyone goes back where they were.
- (void)endOrdering:(BOOL)keep {
  if (self.mode != KPControllersOrdering) return;
  KPControllerRoster *roster = KPControllerRoster.shared;
  if (keep && self.ordered.count) {
    for (KPPadDevice *device in roster.devices.copy)
      if (!device.isKeyboard && device.slot >= 0 && ![self.ordered containsObject:device]) [roster move:device toSlot:-1];
    KPUIPlay(KPUISound::Saved);
  } else {
    for (KPPadDevice *device in roster.devices.copy) {
      NSNumber *slot = self.before[device.identifier];
      if (slot != nil && slot.intValue != device.slot) [roster move:device toSlot:slot.intValue];
    }
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if (self.keyboardPin) [defaults setObject:self.keyboardPin forKey:KPKeyboardPlayerKey];
    else [defaults removeObjectForKey:KPKeyboardPlayerKey];
    [roster refresh];
    KPUIPlay(KPUISound::Close);
  }
  const int focus = self.ordered.count ? self.ordered.firstObject.slot : 0;
  self.ordered = nil;
  [self stopChoosing];
  [KPOverlay() focus:self.cards[std::clamp(focus, 0, KPPlayerCount - 1)] sound:NO];
}

- (void)cancelChoosing {
  if (self.mode == KPControllersOrdering) {
    [self endOrdering:NO];
    return;
  }
  const int slot = self.target;
  [self stopChoosing];
  KPUIPlay(KPUISound::Close);
  [KPOverlay() focus:self.cards[slot] sound:NO];
}

// Each controller's A, B and Start, read here (the shared reader keeps quiet meanwhile, so these
// presses don't also move the focus). Two players pressing at once both count.
- (void)listen {
  const BOOL first = self.held == nil;
  NSMutableDictionary<NSNumber *, NSNumber *> *now = [NSMutableDictionary dictionary];
  NSMutableArray<NSArray *> *presses = [NSMutableArray array];
  int count = 0;
  SDL_JoystickID *ids = SDL_GetGamepads(&count);
  for (int i = 0; i < count; ++i) {
    SDL_Gamepad *pad = SDL_GetGamepadFromID(ids[i]);
    if (pad == nullptr) continue;
    SDL_GamepadButton confirm, back;
    KPPadConfirmBack(pad, &confirm, &back);
    const unsigned down = (SDL_GetGamepadButton(pad, confirm) ? KPPressConfirm : 0) | (SDL_GetGamepadButton(pad, back) ? KPPressBack : 0) |
                          (SDL_GetGamepadButton(pad, SDL_GAMEPAD_BUTTON_START) ? KPPressStart : 0);
    now[@(ids[i])] = @(down);
    NSNumber *was = self.held[@(ids[i])];
    if (first || was == nil) continue;  // already down when listening began, or just connected
    const unsigned pressed = down & ~was.unsignedIntValue;
    if (pressed) [presses addObject:@[@(ids[i]), @(pressed)]];
  }
  SDL_free(ids);
  self.held = now;
  for (NSArray *press in presses) {
    if (self.mode == KPControllersBrowsing) break;
    KPPadDevice *device = [KPControllerRoster.shared deviceWithIdentifier:[NSString stringWithFormat:@"sdl:%@", press[0]]];
    if (device) [self device:device pressed:[press[1] unsignedIntValue]];
  }
  if (first) return;
  const NSTimeInterval time = NSProcessInfo.processInfo.systemUptime;
  if (self.mode == KPControllersOrdering && self.finishAt > 0 && time >= self.finishAt) [self endOrdering:YES];
  else if (self.mode == KPControllersAssigning && time - self.lastPress > 20) [self cancelChoosing];
  else if (self.mode == KPControllersOrdering && time - self.lastPress > 60) [self endOrdering:self.ordered.count > 0];
}

// A press from one controller while choosing (the keyboard comes through Use Keyboard).
- (void)device:(KPPadDevice *)device pressed:(unsigned)press {
  KPControllerRoster *roster = KPControllerRoster.shared;
  if (device == nil || self.mode == KPControllersBrowsing) return;
  self.lastPress = NSProcessInfo.processInfo.systemUptime;
  if (press & KPPressBack) {
    [self cancelChoosing];
    return;
  }
  if (self.mode == KPControllersAssigning) {
    if (!(press & KPPressConfirm)) return;
    const int slot = self.target;
    [roster move:device toSlot:slot];
    [self stopChoosing];
    [KPOverlay() focus:self.cards[slot] sound:NO];
    [self celebrate:device];
    return;
  }
  if (press & KPPressStart) {
    [self endOrdering:YES];
    return;
  }
  if (!(press & KPPressConfirm) || self.finishAt > 0) return;
  if ([self.ordered containsObject:device]) {
    KPUIWobble([self viewFor:device]);
    KPUIPlay(KPUISound::Same);
    return;
  }
  const int slot = (int)self.ordered.count;
  [self.ordered addObject:device];
  [roster move:device toSlot:slot];
  [self celebrate:device];
  // Everyone's in (every connected controller, or four players): a moment to see it, then done.
  NSInteger pads = 0;
  for (KPPadDevice *each in roster.devices) pads += !each.isKeyboard;
  if (self.ordered.count >= std::min<NSInteger>(pads, KPPlayerCount))
    self.finishAt = NSProcessInfo.processInfo.systemUptime + 1.1;
  self.needsDisplay = YES;  // "Next: Player 3"
}

#pragma mark Input

- (BOOL)handle:(KartPadMiiPadButton)button {
  KPControllerRoster *roster = KPControllerRoster.shared;
  if (self.mode != KPControllersBrowsing) {
    if (button == KartPadMiiPadBack) {
      [self cancelChoosing];
      return YES;
    }
    return button == KartPadMiiPadUndo || button == KartPadMiiPadRedo;
  }
  KPUIButton *focus = self.focus;
  // A controller that isn't playing joins with A: on the focused empty card, else the first free one.
  if (button == KartPadMiiPadConfirm) {
    KPPadDevice *presser = KPPresser();
    if (presser != nil && presser.slot < 0 && !presser.isKeyboard) {
      int slot = [self.cards containsObject:focus] && ![roster deviceInSlot:(int)focus.tag2] ? (int)focus.tag2 : -1;
      for (int i = 0; slot < 0 && i < KPPlayerCount; ++i)
        if (![roster deviceInSlot:i]) slot = i;
      if (slot < 0) {
        KPUIPlay(KPUISound::Reject);
        [KPOverlay() toast:@"All four players have a controller" detail:@"Use Change controller on a card to swap." stripe:0
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
  if (button == KartPadMiiPadUndo && device && !device.isKeyboard) {  // X: find it, as on HOME
    [roster identify:device];
    KPUIPlay(KPUISound::Confirm);
    KPUIWobble([self viewFor:device]);
    return YES;
  }
  return NO;
}

#pragma mark Menus

- (void)openCard:(int)slot {
  if (self.mode != KPControllersBrowsing) return;
  KPControllerRoster *roster = KPControllerRoster.shared;
  KPPadDevice *device = [roster deviceInSlot:slot];
  // An empty player takes whichever controller presses A next.
  if (device == nil) {
    [self beginAssigning:slot];
    return;
  }
  KPMenuScreen *menu = [[KPMenuScreen alloc] initWithFrame:NSZeroRect];
  __weak KPControllersScreen *weakSelf = self;
  NSDictionary *mii = [roster miiRecordFor:device];
  menu.heading = [NSString stringWithFormat:@"%@ · %@", KPPlayerName(slot), mii[@"name"] ?: device.name];
  [menu add:@"Change controller" detail:nil glyph:(int)KPUIGlyph::Swap enabled:YES run:^{ [weakSelf beginAssigning:slot]; }];
  [menu add:@"Set up buttons" detail:nil glyph:(int)KPUIGlyph::Buttons enabled:YES run:^{ KPSetUpButtons(device); }];
  [menu add:mii ? @"Change Mii" : @"Choose a Mii" detail:nil glyph:(int)KPUIGlyph::Mii enabled:YES run:^{ KPChooseMii(device); }];
  if (device.canRumble)
    [menu add:@"Vibration" detail:KPVibrationNames()[KPVibrationFor(device.profileKey)] glyph:(int)KPUIGlyph::Pad enabled:YES
          run:^{ KPChooseVibration(device); }];
  if (!device.isKeyboard)
    [menu add:@"Find" detail:nil glyph:(int)KPUIGlyph::Find enabled:YES run:^{
      [roster identify:device];
      KPUIWobble([weakSelf viewFor:device]);
    }];
  [menu add:@"Stop playing" detail:nil glyph:(int)KPUIGlyph::Close enabled:YES run:^{
    [roster move:device toSlot:-1];
    if (!device.isKeyboard) [roster.benched addObject:device.identifier];
    KPUIPlay(KPUISound::PagePrevious);
  }];
  [KPOverlay() present:menu];
}

- (void)openChip:(NSUInteger)index {
  if (index >= self.chips.count || self.mode != KPControllersBrowsing) return;
  KPPadDevice *device = self.chips[index].tagObject;
  if (device == nil) return;
  KPControllerRoster *roster = KPControllerRoster.shared;
  KPMenuScreen *menu = [[KPMenuScreen alloc] initWithFrame:NSZeroRect];
  menu.heading = [NSString stringWithFormat:@"Play with %@", device.name];
  __weak KPControllersScreen *weakSelf = self;
  for (int slot = 0; slot < KPPlayerCount; ++slot) {
    KPPadDevice *occupant = [roster deviceInSlot:slot];
    NSString *detail = occupant ? [NSString stringWithFormat:@"Instead of %@", occupant.name] : nil;
    [menu add:KPPlayerName(slot) detail:detail glyph:-1 enabled:YES run:^{
      [roster move:device toSlot:slot];
      KPControllersScreen *screen = weakSelf;
      [KPOverlay() focus:screen.cards[slot] sound:NO];
      [screen celebrate:device];
    }];
  }
  if (!device.isKeyboard)
    [menu add:@"Find" detail:nil glyph:(int)KPUIGlyph::Find enabled:YES
          run:^{ [roster identify:device]; }];
  [KPOverlay() present:menu];
}

- (void)back {
  if (self.mode != KPControllersBrowsing) {
    [self cancelChoosing];
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
  NSString *subtitle = @"Press a button to find your card.";
  NSString *const press = KPButtonWord(KPJoinDevice(), KartPadMiiPadConfirm);
  std::vector<KPHint> hints = {{KartPadMiiPadConfirm, @"Options"}, {KartPadMiiPadUndo, @"Find"}, {KartPadMiiPadBack, @"Back"}};
  unsigned ink = KPP->secondaryText;
  if (self.mode == KPControllersAssigning) {
    subtitle = [NSString stringWithFormat:@"Press %@ on the controller for %@.", press, KPPlayerName(self.target)];
    hints = {{KartPadMiiPadBack, @"Cancel"}};
    ink = KPP->accentBottom;
  } else if (self.mode == KPControllersOrdering) {
    const NSUInteger next = self.ordered.count;
    subtitle = next == 0 ? [NSString stringWithFormat:@"Everyone press %@ in turn. The first is Player 1.", press]
             : next < (NSUInteger)KPPlayerCount && self.finishAt == 0 ? [NSString stringWithFormat:@"Next: %@", KPPlayerName((int)next)]
                                                                   : @"Everyone\u2019s in";
    hints = {{KartPadMiiPadStart, @"Done"}, {KartPadMiiPadBack, @"Cancel"}};
    ink = KPP->accentBottom;
  }
  KPTextWeight(subtitle, CGRectMake(s.origin.x + 58, s.origin.y + 78, 640, 26), 18, ink, NSFontWeightMedium, NSTextAlignmentLeft);
  NSInteger resting = 0;
  for (KPPadDevice *device in KPControllerRoster.shared.devices)
    if (device.slot < 0) ++resting;
  if (resting)
    KPTextWeight(@"Not playing", CGRectMake(s.origin.x + 58, s.origin.y + 536, 800, 26), 18, KPP->secondaryText, NSFontWeightSemibold,
                 NSTextAlignmentLeft);
  KPDrawHints(c, CGRectMake(s.origin.x + 56, s.origin.y + 670, 1168, 26), hints, 16, NSTextAlignmentRight);
}

// A player waiting for a controller while choosing by pressing: the one being chosen pulses.
- (void)drawWaiting:(int)slot context:(CGContextRef)c in:(CGRect)r next:(BOOL)next {
  const unsigned color = KPPlayerColors[slot];
  KPFill(c, r, KPP->panel, 20, next ? 0.95 : 0.5);
  CGContextSaveGState(c);
  const CGFloat dash[] = {9, 7};
  CGContextSetLineDash(c, 0, dash, 2);
  KPStroke(c, CGRectInset(r, 1, 1), next ? color : KPP->buttonStroke, next ? 3 : 2.2, 19);
  CGContextRestoreGState(c);
  CGContextSaveGState(c);
  CGPathRef clip = CGPathCreateWithRoundedRect(r, 20, 20, nullptr);
  CGContextAddPath(c, clip);
  CGContextClip(c);
  CGPathRelease(clip);
  KPGradientFill(c, CGRectMake(r.origin.x, r.origin.y, r.size.width, 58), 0, color, KPPlayerDarkColors[slot]);
  if (!next) KPFill(c, CGRectMake(r.origin.x, r.origin.y, r.size.width, 58), KPP->panel, 0, 0.55);
  CGContextRestoreGState(c);
  KPTextWeight(KPPlayerName(slot), CGRectMake(r.origin.x + 22, r.origin.y + 13, 200, 32), 24, next ? KPPlayerInk[slot] : KPP->secondaryText,
               NSFontWeightHeavy, NSTextAlignmentLeft);
  if (!next) return;
  // A big A button, breathing.
  const CGFloat size = 92 + 10 * self.pulse;
  const CGRect button = CGRectMake(CGRectGetMidX(r) - size / 2, r.origin.y + 150 - size / 2 + 10, size, size);
  KPSetInk(c, color, 0.25 + 0.2 * self.pulse);
  CGContextFillEllipseInRect(c, CGRectInset(button, -14, -14));
  KPSetInk(c, color);
  CGContextFillEllipseInRect(c, button);
  // Labelled as the pad in hand labels it (✕ on a PlayStation pad).
  NSString *label = KPHintLabel(KPJoinDevice(), KartPadMiiPadConfirm);
  if (KPHintIsShape(label)) {
    KPDrawHintBadge(c, label, CGRectInset(button, size * 0.12, size * 0.12), size * 0.55, color, KPPlayerInk[slot]);
  } else {
    const CGFloat type = label.length <= 2 ? size * 0.5 : size * 0.24;
    KPCentredLabel(c, label, button, type, KPPlayerInk[slot], NSFontWeightHeavy);
  }
  // Which controller is in the subtitle above.
  KPTextWeight([@"Press " stringByAppendingString:KPButtonWord(KPJoinDevice(), KartPadMiiPadConfirm)],
               CGRectMake(r.origin.x + 10, r.origin.y + 236, r.size.width - 20, 32), 24, KPP->text, NSFontWeightBold);
}

- (void)drawCard:(int)slot context:(CGContextRef)c in:(CGRect)r state:(KPUIState)state {
  KPControllerRoster *roster = KPControllerRoster.shared;
  KPPadDevice *device = [roster deviceInSlot:slot];
  // Choosing by pressing: the player being chosen waits for A; while ordering, so do those after.
  if (self.mode == KPControllersAssigning && slot == self.target) {
    [self drawWaiting:slot context:c in:r next:YES];
    return;
  }
  if (self.mode == KPControllersOrdering && slot >= (int)self.ordered.count) {
    [self drawWaiting:slot context:c in:r next:slot == (int)self.ordered.count && self.finishAt == 0];
    return;
  }
  // The others step back meanwhile.
  CGContextSaveGState(c);
  if (self.mode == KPControllersAssigning) CGContextSetAlpha(c, 0.45);
  [self drawPlayer:slot device:device context:c in:r state:state];
  CGContextRestoreGState(c);
}

- (void)drawPlayer:(int)slot device:(KPPadDevice *)device context:(CGContextRef)c in:(CGRect)r state:(KPUIState)state {
  const unsigned color = KPPlayerColors[slot];
  const CGFloat dy = state.pressed ? 2 : 0;
  if (device == nil) {
    KPFill(c, r, KPP->panel, 20, 0.6);
    CGContextSaveGState(c);
    const CGFloat dash[] = {9, 7};
    CGContextSetLineDash(c, 0, dash, 2);
    KPStroke(c, CGRectInset(r, 1, 1), KPP->buttonStroke, 2.2, 19);
    CGContextRestoreGState(c);
  } else {
    KPButtonFace(c, r, KPStyle::Card, NO, YES, state.pressed, state.focused);
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
    // The player's own light: lit with a controller, dim without one.
    KPFill(c, light, pip == slot ? 0x8fe9ff : 0x000000, 3, pip == slot ? (device ? 1 : 0.4) : 0.2);
  }
  if (device == nil) {
    KPDrawGlyph(c, KPUIGlyph::Plus, CGRectMake(CGRectGetMidX(r) - 34, r.origin.y + 112 + dy, 68, 68), KPP->buttonStroke);
    KPTextWeight(@"No controller", CGRectMake(r.origin.x + 10, r.origin.y + 206 + dy, r.size.width - 20, 30), 22, KPP->secondaryText,
                 NSFontWeightSemibold);
    KPTextWeight([NSString stringWithFormat:@"Press %@ to join", KPButtonWord(KPJoinDevice(), KartPadMiiPadConfirm)],
                 CGRectMake(r.origin.x + 26, r.origin.y + 242 + dy, r.size.width - 52, 30), 16,
                 KPP->secondaryText, NSFontWeightRegular);
    return;
  }
  // Mii.
  KPControllerRoster *roster = KPControllerRoster.shared;
  NSDictionary *mii = [roster miiRecordFor:device];
  NSImage *portrait = KPPortraitFor(device, self.cards[slot]);
  const CGRect well = CGRectMake(CGRectGetMidX(r) - 58, r.origin.y + 72 + dy, 116, 116);
  KPDrawMiiWell(c, well, portrait, color, NO);
  if (mii[@"name"])
    KPTextWeight(mii[@"name"], CGRectMake(r.origin.x + 12, r.origin.y + 194 + dy, r.size.width - 24, 30), 21, KPP->text,
                 NSFontWeightSemibold);
  // The controller, live.
  KPArtState art = KPArtStateFor(device, color);
  KPDrawControllerArt(c, CGRectMake(r.origin.x + 20, r.origin.y + 232 + dy, r.size.width - 40, 116), device.family, art,
                      device.systemName);
  KPTextWeight(device.name, CGRectMake(r.origin.x + 20, r.origin.y + 356 + dy, r.size.width - 80, 24), 16, KPP->secondaryText,
               NSFontWeightMedium, NSTextAlignmentLeft);
  KPDrawBattery(c, CGRectMake(CGRectGetMaxX(r) - 56, r.origin.y + 354 + dy, 34, 26), device);
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
  KPTextWeight(device.isKeyboard ? @"Menus only" : [NSString stringWithFormat:@"Press %@ to join", KPButtonWord(device, KartPadMiiPadConfirm)],
               CGRectMake(r.origin.x + 110, r.origin.y + 40 + dy, r.size.width - 150, 22),
               15, KPP->secondaryText, NSFontWeightRegular, NSTextAlignmentLeft);
  KPDrawBattery(c, CGRectMake(CGRectGetMaxX(r) - 44, r.origin.y + 38 + dy, 30, 24), device);
}

@end

static KPControllersScreen *KPMakeControllersScreen(int focusSlot) {
  KPControllersScreen *screen = [[KPControllersScreen alloc] initWithFrame:NSZeroRect];
  screen.focusSlot = focusSlot;
  return screen;
}

// From HOME's players: an empty player opens straight to choosing its controller.
static KPScreen *KPMakeControllersScreenFor(int slot) {
  KPControllersScreen *screen = KPMakeControllersScreen(slot);
  screen.assignOnOpen = YES;
  return screen;
}

#pragma mark Button setup

// The twelve things a controller does in the game, in Control Reference's words (KartPadMacShell.mm),
// as the GameCube buttons Mario Kart Wii reads (KPButtons).
static NSArray<NSString *> *KPActionTitles() {
  return @[@"Accelerate · confirm", @"Brake · reverse · back", @"X button", @"Y button", @"Start · pause", @"Look behind",
           @"Use item", @"Drift · manual hop", @"Trick · D-pad up", @"D-pad down", @"D-pad left", @"D-pad right"];
}
// The keyboard as Player 1 is a Classic Controller instead (runtime kpad.cpp): its fourteen buttons
// (kpad.cpp's kClassicButton bits), with the keys the runtime gives each.
static constexpr uint32_t KPClassicButtons[14] = {0x0010, 0x0040, 0x0200, 0x2000, 0x0008, 0x0020, 0x0400,
                                                 0x1000, 0x0080, 0x0004, 0x0001, 0x4000, 0x0002, 0x8000};
static NSArray<NSString *> *KPClassicActionTitles() {
  return @[@"Accelerate · confirm", @"Brake · reverse · back", @"Drift · manual hop", @"Use item", @"Look behind",
           @"Y button", @"Start · pause", @"Select · minus", @"ZL button", @"ZR button", @"Trick · D-pad up", @"D-pad down",
           @"D-pad left", @"D-pad right"];
}
// The keys bound to a Classic button, the named keys (return, delete) before letters.
static std::vector<int> KPClassicKeys(uint32_t button) {
  std::vector<int> keys, letters;
  for (int code = 0; code < SDL_SCANCODE_COUNT; ++code)
    if (KartPadKeyboardClassicButtons(code) & button)
      (code >= SDL_SCANCODE_A && code <= SDL_SCANCODE_Z ? letters : keys).push_back(code);
  keys.insert(keys.end(), letters.begin(), letters.end());
  return keys;
}
// A key as a Mac keyboard labels it.
static NSString *KPKeyName(int code) {
  switch (code) {
    case SDL_SCANCODE_RETURN: return @"Return";
    case SDL_SCANCODE_BACKSPACE: return @"Delete";
    case SDL_SCANCODE_ESCAPE: return @"esc";
    case SDL_SCANCODE_LCTRL: return @"Left Control";
    case SDL_SCANCODE_RCTRL: return @"Right Control";
    case SDL_SCANCODE_LALT: return @"Left Option";
    case SDL_SCANCODE_RALT: return @"Right Option";
    case SDL_SCANCODE_LGUI: return @"Left Command";
    case SDL_SCANCODE_RGUI: return @"Right Command";
    case SDL_SCANCODE_UP: return @"Up Arrow";
    case SDL_SCANCODE_DOWN: return @"Down Arrow";
    case SDL_SCANCODE_LEFT: return @"Left Arrow";
    case SDL_SCANCODE_RIGHT: return @"Right Arrow";
    default: {
      const char *name = SDL_GetScancodeName((SDL_Scancode)code);
      return name && *name ? @(name) : @"Key";
    }
  }
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
// The keyboard as Player 1 is the game's Classic Controller, with its own keys; anywhere else a
// controller is a GameCube controller.
- (BOOL)classic { return self.device.isKeyboard && self.device.slot == 0; }
- (NSArray<NSString *> *)titles { return self.classic ? KPClassicActionTitles() : KPActionTitles(); }

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
  if (self.classic) {
    const std::vector<int> keys = KPClassicKeys(KPClassicButtons[action]);
    if (alternate) return keys.size() > 1 ? KPKeyName(keys[1]) : nil;
    return keys.empty() ? @"—" : KPKeyName(keys[0]);
  }
  if (self.device.isKeyboard) {
    if (alternate) return nil;
    const int key = [self keyBinding:action];
    return key < 0 ? @"—" : KPKeyName(key);
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
  // As many rows as the Classic Controller has buttons; a GameCube controller uses the first twelve.
  for (NSInteger i = 0; i < (NSInteger)std::size(KPClassicButtons); ++i) {
    KPUIButton *row = [self button:CGRectZero face:^(CGContextRef c, CGRect r, KPUIState state) {
      KPRemapScreen *screen = weakSelf;
      NSArray<NSString *> *titles = screen.titles;
      if (i >= (NSInteger)titles.count) return;
      const BOOL listening = screen.capturing == i;
      KPButtonFace(c, r, KPStyle::Plain, listening, state.enabled, state.pressed, state.focused);
      const CGFloat dy = state.pressed ? 2 : 0;
      KPTextWeight(titles[i], CGRectMake(r.origin.x + 18, CGRectGetMidY(r) - 13 + dy, 260, 26), 18, KPP->text, NSFontWeightSemibold,
                   NSTextAlignmentLeft);
      NSString *primary = listening && !screen.alternate ? @"Press…" : [screen label:i alternate:NO];
      NSString *second = listening && screen.alternate ? @"Press…" : [screen label:i alternate:YES];
      // The Classic Controller's keys past the first two (B has three to start with).
      NSString *third = nil;
      if (screen.classic) {
        const std::vector<int> keys = KPClassicKeys(KPClassicButtons[i]);
        if (keys.size() > 2) third = KPKeyName(keys[2]);
      }
      CGFloat x = CGRectGetMaxX(r) - 14;
      for (NSString *chip in @[third ?: @"", second ?: @"", primary ?: @""]) {
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
    [self.rows addObject:row];
  }
  self.reset = [self button:CGRectZero face:^(CGContextRef c, CGRect r, KPUIState state) {
    KPDrawPill(c, r, state, KPStyle::Plain, KPUIGlyph::Restart, @"Reset");
  } action:^{ [weakSelf askToReset]; }];
  self.reset.label = @"Reset";
  self.done = [self button:CGRectZero face:^(CGContextRef c, CGRect r, KPUIState state) {
    KPDrawPill(c, r, state, KPStyle::Primary, KPUIGlyph::Check, @"Done");
  } action:^{ [KPOverlay() pop]; }];
  self.done.label = @"Done";
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
  // Fourteen Classic Controller rows sit closer than twelve GameCube ones.
  NSArray<NSString *> *titles = self.titles;
  const CGFloat pitch = titles.count > 12 ? 40 : 46;
  for (KPUIButton *row in self.rows) {
    row.hidden = row.tag2 >= (NSInteger)titles.count;
    if (row.hidden) continue;
    row.label = titles[row.tag2];
    [self place:row at:CGRectMake(s.origin.x + 52, s.origin.y + 118 + row.tag2 * pitch, 600, pitch - 4)];
  }
  [self place:self.art at:CGRectMake(s.origin.x + 690, s.origin.y + 150, 540, 330)];
  [self place:self.reset at:CGRectMake(s.origin.x + 690, s.origin.y + 590, 290, 60)];
  [self place:self.done at:CGRectMake(CGRectGetMaxX(s) - 52 - 170, s.origin.y + 590, 170, 60)];
}

- (KPUIButton *)initialFocus { return self.rows.firstObject; }

- (void)listen:(NSInteger)action alternate:(BOOL)alternate {
  if (self.port < 0) {
    KPUIPlay(KPUISound::Reject);
    self.status = @"Give this controller a player first.";
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
    [self stopListening:@"Nothing changed." sound:KPUISound::Close];
    return;
  }
  SDL_Gamepad *pad = self.device.gamepad;
  if (pad == nullptr) {
    [self stopListening:@"The controller disconnected." sound:KPUISound::Reject];
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
  NSString *title = self.titles[self.capturing];
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
  if (self.classic) {
    // The key takes the button's first (or, with X, second) key's place; the others keep it.
    const uint32_t button = KPClassicButtons[self.capturing];
    const std::vector<int> keys = KPClassicKeys(button);
    const size_t replaced = self.alternate ? 1 : 0;
    if (replaced < keys.size() && keys[replaced] != (int)code)
      KartPadSetKeyboardClassicButtons(keys[replaced], KartPadKeyboardClassicButtons(keys[replaced]) & ~button);
    KartPadSetKeyboardClassicButtons(code, KartPadKeyboardClassicButtons(code) | button);
    KPSaveKeyboardClassicKeys();
  } else {
    PADSetKeyButtonBinding(self.port, {code, KPButtons[self.capturing]});
    PADSetKeyboardActive(self.port, TRUE);
  }
  [self stopListening:[NSString stringWithFormat:@"%@ is now %@.", self.titles[self.capturing], KPKeyName(code)]
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
  if (button == KartPadMiiPadUndo && [self.rows containsObject:self.focus] && (!self.device.isKeyboard || self.classic)) {
    [self listen:self.focus.tag2 alternate:YES];
    return YES;
  }
  return NO;
}

- (void)askToReset {
  KPPadDevice *device = self.device;
  const BOOL classic = self.classic;
  KPAsk(@"Reset the Buttons?", [NSString stringWithFormat:@"%@ goes back to its standard buttons.", device.name],
        @[@"Reset", @"Cancel"], 1, 0, ^(NSInteger choice) {
          if (choice != 0 || device.slot < 0) return;
          if (classic) {
            for (int code = 0; code < SDL_SCANCODE_COUNT; ++code)
              KartPadSetKeyboardClassicButtons(code, KartPadDefaultKeyboardClassicButtons(code));
            KPSaveKeyboardClassicKeys();
          } else if (device.isKeyboard) {
            for (int i = 0; i < 12; ++i) PADSetKeyButtonBinding(device.slot, {KPDefaultKeys[i], KPButtons[i]});
            PADSetKeyboardActive(device.slot, TRUE);
          } else {
            KPControllers().selectedID = device.joystick;
            [KPControllers() reset:nil];
            [KPControllers() save:nil];
          }
          self.status = @"Back to the standard buttons.";
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
// Closed or covered (HOME, another screen) while listening: stop, or the pads stay quiet for it.
- (void)willDisappear {
  if (self.capturing < 0) return;
  self.capturing = -1;
  KPControllers().capture = -1;
  self.status = nil;
}

- (void)drawDesign:(CGContextRef)c size:(CGSize)size {
  [super drawDesign:c size:size];
  const CGRect s = self.safe;
  KPPadDevice *device = self.device;
  NSString *who = device.slot >= 0 ? [NSString stringWithFormat:@"%@ · %@", KPPlayerName(device.slot), device.name] : device.name;
  // The keyboard's keys differ by player: say which controller it is.
  if (device.isKeyboard && device.slot >= 0)
    who = [who stringByAppendingString:self.classic ? @" (Classic Controller)" : @" (GameCube controller)"];
  if (device.slot >= 0) KPFill(c, CGRectMake(s.origin.x + 52, s.origin.y + 34, 8, 40), KPPlayerColors[device.slot], 4);
  KPTextWeight(@"Buttons", CGRectMake(s.origin.x + 72, s.origin.y + 26, 400, 50), 36, KPP->text, NSFontWeightBold, NSTextAlignmentLeft);
  KPTextWeight(who, CGRectMake(s.origin.x + 74, s.origin.y + 76, 700, 26), 18, KPP->secondaryText, NSFontWeightMedium, NSTextAlignmentLeft);
  const CGRect lineRect = CGRectMake(s.origin.x + 690, s.origin.y + 500, 540, 56);
  if (self.capturing >= 0) {
    const NSInteger left = std::max<NSInteger>(0, 8 - (NSInteger)(NSProcessInfo.processInfo.systemUptime - self.captureStarted));
    KPTextWeight([NSString stringWithFormat:@"Press a %@ for %@ (%ld)", device.isKeyboard ? @"key" : @"button",
                  self.titles[self.capturing], (long)left], lineRect, 20, KPP->accentBottom, NSFontWeightSemibold);
  } else if (self.status) {
    KPTextWeight(self.status, lineRect, 20, KPP->secondaryText, NSFontWeightSemibold);
  } else {
    // The buttons of the controller being set up, whichever was used last.
    KPDrawHints(c, CGRectMake(lineRect.origin.x, lineRect.origin.y, lineRect.size.width, 28),
                {{KartPadMiiPadConfirm, @"Change"}, {KartPadMiiPadUndo, @"Add a second button"}, {KartPadMiiPadBack, @"Back"}}, 18,
                NSTextAlignmentCenter, device);
  }
  if (device.isKeyboard)
    KPTextWeight(@"Steer with W A S D. esc opens HOME.", CGRectMake(s.origin.x + 690, s.origin.y + 118, 540, 26), 16,
                 KPP->secondaryText, NSFontWeightMedium);
}
@end

// A controller's own vibration, kept for it by profile key (KPSetControllerVibration). The new
// strength buzzes the controller once.
static void KPChooseVibration(KPPadDevice *device) {
  KPMenuScreen *menu = [[KPMenuScreen alloc] initWithFrame:NSZeroRect];
  menu.heading = [NSString stringWithFormat:@"Vibration · %@", device.name];
  menu.chosen = KPVibrationFor(device.profileKey);
  menu.chosenGlyph = (int)KPUIGlyph::Check;
  NSString *profileKey = device.profileKey;
  const SDL_JoystickID joystick = device.joystick;
  [KPVibrationNames() enumerateObjectsUsingBlock:^(NSString *name, NSUInteger index, BOOL *) {
    [menu add:name detail:nil glyph:-1 enabled:YES run:^{
      KPSetControllerVibration(profileKey, (NSInteger)index);
      AppendSessionLine([NSString stringWithFormat:@"controllerVibration=%@; level=%lu", device.name, (unsigned long)index]);
      const float strength = KPVibrationStrengths()[index].floatValue;
      if (SDL_Gamepad *pad = SDL_GetGamepadFromID(joystick); pad && strength > 0) {
        const auto level = static_cast<Uint16>(std::lround(strength * 65535.0f));
        SDL_RumbleGamepad(pad, level, level, 400);
      }
    }];
  }];
  [KPOverlay() present:menu];
}

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
@property(nonatomic, strong) KPUIButton *cancel;
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
  self.cancel = [self button:CGRectZero face:^(CGContextRef c, CGRect r, KPUIState state) {
    KPDrawPill(c, r, state, KPStyle::Plain, KPUIGlyph::Close, @"Cancel");
  } action:^{ [KPOverlay() pop]; }];
  self.cancel.label = @"Cancel";
  self.cancel.sound = KPUISound::Close;
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
  [self place:self.cancel at:CGRectMake(CGRectGetMaxX(s) - 56 - 170, s.origin.y + 30, 170, 60)];
  for (KPUIButton *tile in self.tiles) {
    const NSInteger i = tile.tag2, index = self.page * self.perPage + i;
    tile.hidden = index > (NSInteger)self.records.count;
    tile.label = self.page == 0 && i == 0 ? @"No Mii" : [self recordAt:i][@"name"];
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
  NSString *who = self.device.slot >= 0 ? [NSString stringWithFormat:@"%@ · %@", KPPlayerName(self.device.slot), self.device.name]
                                        : self.device.name;
  KPTextWeight(who, CGRectMake(s.origin.x + 58, s.origin.y + 76, 700, 26), 18, KPP->secondaryText, NSFontWeightMedium, NSTextAlignmentLeft);
  std::vector<KPHint> hints = {{KartPadMiiPadConfirm, @"Choose"}, {KartPadMiiPadBack, @"Cancel"}};
  if (self.pages > 1) {
    hints.insert(hints.begin() + 1, {KartPadMiiPadPreviousTab, @"Turn page", KartPadMiiPadNextTab});
    KPTextWeight([NSString stringWithFormat:@"Page %ld of %ld", (long)self.page + 1, (long)self.pages],
                 CGRectMake(s.origin.x + 56, s.origin.y + 670, 400, 26), 16, KPP->secondaryText, NSFontWeightMedium, NSTextAlignmentLeft);
  }
  KPDrawHints(c, CGRectMake(s.origin.x + 56, s.origin.y + 670, 1168, 26), hints, 16, NSTextAlignmentRight);
  if (!self.records.count)
    KPTextWeight(@"No Miis yet. Make one in HOME › Miis.", CGRectMake(s.origin.x + 56, s.origin.y + 320, 1168, 30), 20,
                 KPP->secondaryText, NSFontWeightMedium);
}
@end

static void KPChooseMii(KPPadDevice *device) {
  KPMiiPickerScreen *screen = [[KPMiiPickerScreen alloc] initWithFrame:NSZeroRect];
  screen.device = device;
  [KPOverlay() present:screen];
}

#pragma mark Connecting a controller

// Pairing: what's being connected, then KartPad finds it and pairs it right here
// (KartPadWiimotePairing.mm), and celebrates when it shows up. Every controller but the Wii Remote
// pairs the same way, so they share one page, with how to put each brand in pairing mode. Newer
// Xbox controllers use Bluetooth LE, which KartPad can't pair, so the page also offers the Mac's
// Bluetooth settings, which KartPad watches the same way.
enum class KPPairKind { Controller, WiiRemote, Phone };

@interface KPConnectScreen : KPScreen <KPRosterListener>
@property(nonatomic) KPPairKind kind;
@property(nonatomic) BOOL choosing;  // the first step: which kind
@property(nonatomic, strong) NSMutableArray<KPUIButton *> *kinds;
@property(nonatomic, strong) KPUIButton *primary, *settings, *done;
@property(nonatomic, copy) NSString *status;
@property(nonatomic) BOOL busy;
@property(nonatomic, strong) NSSet<NSString *> *before;
// The same controllers by what survives SDL reopening them (KPPadDevice.stableKey): a Wii Remote
// that comes back under a new SDL ID isn't a new arrival.
@property(nonatomic, strong) NSSet<NSString *> *beforeKeys;
@property(nonatomic, strong) KPPadDevice *arrived;
// Bluetooth Settings turned on SDL's background events; this is what they were, for when it closes.
@property(nonatomic, copy) NSString *previousBackgroundHint;
@property(nonatomic) BOOL backgroundHintOwned;
// What the page last drew of what changes by itself (the new controller's drawing, the phones).
@property(nonatomic) uint64_t shownLook;
@property(nonatomic, strong) NSMutableArray<KPUIButton *> *removes;  // Phone: Remove, one per phone listed
@end

@implementation KPConnectScreen
static NSString *KPPairTitle(KPPairKind kind) {
  switch (kind) {
    case KPPairKind::Controller: return @"Controller";
    case KPPairKind::WiiRemote: return @"Wii Remote";
    case KPPairKind::Phone: return @"Phone";
  }
  return @"Controller";
}
static NSString *KPPairSteps(KPPairKind kind) {
  switch (kind) {
    case KPPairKind::Controller: return @"Put it in pairing mode.";
    case KPPairKind::WiiRemote:
      return @"Open the battery cover and press the red SYNC button.";
    case KPPairKind::Phone:
      return @"1. Join this Mac\u2019s Wi\u2011Fi.\n2. Scan the code with each phone\u2019s camera (up to four).\n3. Tap Join.";
  }
  return @"";
}
// Pairing mode for each brand, on the Controller page.
static const struct {
  NSString *brand, *how;
} KPPairModes[] = {
    {@"PlayStation", @"Hold Create (or Share) and PS until the light flashes."},
    {@"Switch", @"Hold the sync button (on a Joy\u2011Con, the rail) until the lights run."},
    {@"Xbox", @"Hold the pair button until it flashes fast. Newer ones pair in Bluetooth Settings."},
    {@"Others", @"Usually: hold the pair button. USB controllers just plug in."},
};
- (void)build {
  self.solid = YES;
  self.choosing = YES;
  __weak KPConnectScreen *weakSelf = self;
  self.kinds = [NSMutableArray array];
  const KPPairKind kinds[] = {KPPairKind::Controller, KPPairKind::WiiRemote, KPPairKind::Phone};
  for (KPPairKind kind : kinds) {
    KPUIButton *tile = [self button:CGRectZero face:^(CGContextRef c, CGRect r, KPUIState state) {
      KPButtonFace(c, r, KPStyle::Card, NO, YES, state.pressed, state.focused);
      const CGFloat dy = state.pressed ? 2 : 0;
      KPArtState art;
      art.accent = KPP->accentBottom;
      const CGRect artRect = CGRectMake(r.origin.x + 18, r.origin.y + 20 + dy, r.size.width - 36, 120);
      if (kind == KPPairKind::Phone) KPDrawPhoneArt(c, CGRectInset(artRect, 6, 18), art.accent);
      else KPDrawControllerArt(c, artRect, kind == KPPairKind::WiiRemote ? KPFamilyWiiRemote : KPFamilyGeneric, art);
      KPTextWeight(KPPairTitle(kind), CGRectMake(r.origin.x + 10, r.origin.y + 168 + dy, r.size.width - 20, 30), 21, KPP->text,
                   NSFontWeightSemibold);
    } action:^{ [weakSelf chooseKind:kind]; }];
    tile.tag2 = (NSInteger)kind;
    tile.radius = 18;
    tile.label = KPPairTitle(kind);
    [self.kinds addObject:tile];
  }
  self.primary = [self button:CGRectZero face:^(CGContextRef c, CGRect r, KPUIState state) {
    KPDrawPill(c, r, state, KPStyle::Primary, KPUIGlyph::Search, weakSelf.busy ? @"Searching…" : @"Search Again");
  } action:^{ [weakSelf primaryAction]; }];
  self.primary.label = @"Search Again";
  self.removes = [NSMutableArray array];
  for (int row = 0; row < kpp::MaxPhones; ++row) {
    KPUIButton *remove = [self button:CGRectZero face:^(CGContextRef c, CGRect r, KPUIState state) {
      KPDrawPill(c, r, state, KPStyle::Plain, KPUIGlyph::Close, @"Remove");
    } action:^{ [weakSelf removePhoneRow:row]; }];
    remove.label = @"Remove";
    remove.hidden = YES;
    [self.removes addObject:remove];
  }
  self.settings = [self button:CGRectZero face:^(CGContextRef c, CGRect r, KPUIState state) {
    KPDrawPill(c, r, state, KPStyle::Plain, KPUIGlyph::Bluetooth, @"Bluetooth Settings");
  } action:^{ [weakSelf openBluetoothSettings]; }];
  self.settings.label = @"Bluetooth Settings";
  self.done = [self button:CGRectZero face:^(CGContextRef c, CGRect r, KPUIState state) {
    KPDrawPill(c, r, state, KPStyle::Primary, KPUIGlyph::Check, @"Done");
  } action:^{ [KPOverlay() pop]; }];
  self.done.label = @"Done";
  self.done.sound = KPUISound::Close;
  [KPControllerRoster.shared.listeners addObject:self];
}
- (void)layoutDesign {
  const CGRect s = self.safe;
  const CGFloat w = 260, gap = 24, count = self.kinds.count, x0 = s.origin.x + (1280 - (count * w + (count - 1) * gap)) / 2;
  for (KPUIButton *tile in self.kinds) {
    tile.hidden = !self.choosing;
    [self place:tile at:CGRectMake(x0 + tile.tag2 * (w + gap), s.origin.y + 180, w, 236)];
  }
  self.primary.hidden = self.choosing || self.kind == KPPairKind::Phone;
  [self placeRemoves];
  self.settings.hidden = self.choosing || self.kind != KPPairKind::Controller;
  // Right to left: Done, Search Again, Bluetooth Settings.
  const CGFloat doneX = CGRectGetMaxX(s) - 56 - 170, primaryX = doneX - 16 - 270;
  [self place:self.primary at:CGRectMake(primaryX, s.origin.y + 560, 270, 64)];
  [self place:self.settings at:CGRectMake(primaryX - 16 - 290, s.origin.y + 560, 290, 64)];
  [self place:self.done at:CGRectMake(doneX, self.choosing ? s.origin.y + 590 : s.origin.y + 560, 170, 64)];
}
// Phones: a Remove beside each phone in the list (drawPhoneJoin).
static constexpr CGFloat KPPhoneListTop = 300, KPPhoneRowHeight = 58;
- (void)placeRemoves {
  const CGRect s = self.safe;
  const std::vector<KPPhoneEntry> phones =
      self.kind == KPPairKind::Phone && !self.choosing ? KPPhoneServer.shared.entries : std::vector<KPPhoneEntry>{};
  for (NSUInteger row = 0; row < self.removes.count; ++row) {
    KPUIButton *remove = self.removes[row];
    const BOOL shown = row < phones.size();
    if (!shown && !remove.hidden && remove.focused) [KPOverlay() focus:self.done sound:NO];
    remove.hidden = !shown;
    if (!shown) continue;
    remove.tag2 = phones[row].phone;
    [self place:remove at:CGRectMake(CGRectGetMaxX(s) - 56 - 150, s.origin.y + KPPhoneListTop + row * KPPhoneRowHeight + 4, 150, 46)];
  }
}
- (void)removePhoneRow:(int)row {
  [KPPhoneServer.shared sendAway:(int)self.removes[row].tag2];
  KPUIPlay(KPUISound::Close);
}
- (KPUIButton *)initialFocus { return self.choosing ? self.kinds.firstObject : self.kind == KPPairKind::Phone ? self.done : self.primary; }
- (void)chooseKind:(KPPairKind)kind {
  self.kind = kind;
  self.choosing = NO;
  self.arrived = nil;
  NSMutableSet *ids = [NSMutableSet set], *keys = [NSMutableSet set];
  for (KPPadDevice *device in KPControllerRoster.shared.devices) {
    [ids addObject:device.identifier];
    if (device.stableKey) [keys addObject:device.stableKey];
  }
  self.before = ids;
  self.beforeKeys = keys;
  self.status = kind == KPPairKind::WiiRemote ? @"Getting Bluetooth ready…"
              : kind == KPPairKind::Phone       ? @"Waiting for a phone…"
                                                : @"Looking for it…";
  if (kind == KPPairKind::Phone) [KPPhoneServer.shared start];
  [self layoutDesign];
  [KPOverlay() focus:self.initialFocus sound:NO];
  self.needsDisplay = YES;
  if (kind == KPPairKind::WiiRemote) [self pairWiiRemote];
  else if (kind == KPPairKind::Controller) [self pairGamepad];
}
- (void)pairGamepad {
  // Automated checks don't search: it can bring up macOS's Bluetooth permission prompt.
  if (KPUIBackgroundAutomation()) return;
  self.busy = YES;
  __weak KPConnectScreen *weakSelf = self;
  KartPadBeginGamepadPairing(^(NSString *message, BOOL busy) {
    KPConnectScreen *screen = weakSelf;
    screen.status = message;
    screen.busy = busy;
    screen.needsDisplay = YES;
    screen.primary.needsDisplay = YES;
  }, ^(NSString *line) { AppendSessionLine([@"controllerPairing=" stringByAppendingString:line]); });
  self.primary.needsDisplay = YES;
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
  if (!self.busy) [self pairGamepad];
}
- (void)openBluetoothSettings {
  // Settings pairs it from here on; two pairings of one controller at once can trip each other.
  KartPadCancelGamepadPairing();
  self.busy = NO;
  self.primary.needsDisplay = YES;
  NSURL *settings = [NSURL URLWithString:@"x-apple.systempreferences:com.apple.BluetoothSettings"];
  if (![NSWorkspace.sharedWorkspace openURL:settings])
    [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:@"x-apple.systempreferences:com.apple.preferences.Bluetooth"]];
  // Background events, so KartPad notices the controller while Settings is in front. What they were
  // comes back when this page closes.
  if (!self.backgroundHintOwned) {
    const char *hint = SDL_GetHint(SDL_HINT_JOYSTICK_ALLOW_BACKGROUND_EVENTS);
    self.previousBackgroundHint = hint ? @(hint) : nil;
    self.backgroundHintOwned = YES;
  }
  SDL_SetHint(SDL_HINT_JOYSTICK_ALLOW_BACKGROUND_EVENTS, "1");
  self.status = @"Waiting for the controller…";
  self.needsDisplay = YES;
}
- (void)rosterChanged {
  const BOOL phone = self.kind == KPPairKind::Phone;
  [self placeRemoves];
  // Phones keep coming: the code stays up and each new one is announced in turn.
  if (self.choosing || (self.arrived && !phone)) return;
  for (KPPadDevice *device in KPControllerRoster.shared.devices) {
    if (device.isKeyboard || [self.before containsObject:device.identifier] ||
        (device.stableKey && [self.beforeKeys containsObject:device.stableKey]))
      continue;
    self.before = [self.before setByAddingObject:device.identifier];
    self.arrived = device;
    KartPadCancelGamepadPairing();
    // A new controller with no player takes the first free one.
    KPControllerRoster *roster = KPControllerRoster.shared;
    if (device.slot < 0)
      for (int slot = 0; slot < KPPlayerCount; ++slot)
        if (![roster deviceInSlot:slot]) {
          [roster move:device toSlot:slot];
          break;
        }
    self.status = device.slot >= 0 ? [NSString stringWithFormat:@"%@as %@", phone ? [device.name stringByAppendingString:@" joined "]
                                                                                       : @"Connected ", KPPlayerName(device.slot)]
                                   : [NSString stringWithFormat:@"%@ connected", device.name];
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
// The page redraws for what changes by itself only when it has: the new controller's live drawing,
// and on the Phone page the link and the phones. (The status redraws it as it changes.)
- (void)tick {
  [KPControllerRoster.shared refresh];
  [self placeRemoves];
  uint64_t look = KPDeviceLook(self.arrived);
  if (self.kind == KPPairKind::Phone && !self.choosing) {
    KPPhoneServer *server = KPPhoneServer.shared;
    look ^= (uint64_t)server.joinURL.hash * 31 + server.problem.hash;
    for (const KPPhoneEntry &phone : server.entries)
      look = look * 0x100000001b3ull ^ ((uint64_t)phone.phone << 40 | (uint64_t)(phone.player & 0xff) << 32 |
                                        (uint64_t)phone.linked << 31 | (uint32_t)phone.delayMs);
  }
  if (look == self.shownLook) return;
  self.shownLook = look;
  self.needsDisplay = YES;
}
- (void)willAppear {
  [super willAppear];
  if (self.kind == KPPairKind::Phone && !self.choosing) [KPPhoneServer.shared start];
}
- (void)willDisappear {
  if (self.kind == KPPairKind::Phone && !self.choosing) [KPPhoneServer.shared stopIfUnused];
  KartPadCancelWiimotePairing();
  KartPadCancelGamepadPairing();
  [KPControllerRoster.shared.listeners removeObject:self];
  if (self.backgroundHintOwned) {
    if (self.previousBackgroundHint) SDL_SetHint(SDL_HINT_JOYSTICK_ALLOW_BACKGROUND_EVENTS, self.previousBackgroundHint.UTF8String);
    else SDL_ResetHint(SDL_HINT_JOYSTICK_ALLOW_BACKGROUND_EVENTS);
    self.backgroundHintOwned = NO;
  }
}
- (void)back {
  if (!self.choosing && !self.arrived) {
    KartPadCancelWiimotePairing();
    KartPadCancelGamepadPairing();
    if (self.kind == KPPairKind::Phone) [KPPhoneServer.shared stopIfUnused];
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
  KPTextWeight(!self.choosing && self.kind == KPPairKind::Phone ? @"Connect a Phone" : @"Connect a Controller",
               CGRectMake(s.origin.x + 56, s.origin.y + 26, 800, 50), 36, KPP->text, NSFontWeightBold, NSTextAlignmentLeft);
  if (self.choosing) {
    KPTextWeight(@"What are you connecting?", CGRectMake(s.origin.x + 58, s.origin.y + 78, 760, 26), 18, KPP->secondaryText,
                 NSFontWeightMedium, NSTextAlignmentLeft);
    KPTextWeight(@"Already paired? Turn it on.",
                 CGRectMake(s.origin.x + 56, s.origin.y + 460, 1168, 30), 18, KPP->secondaryText, NSFontWeightRegular);
    return;
  }
  // "Controller" under "Connect a Controller" says nothing; which ones does. The Phone page says it in its title.
  if (self.kind != KPPairKind::Phone)
    KPTextWeight(self.kind == KPPairKind::Controller ? @"PlayStation, Switch, Xbox and more" : KPPairTitle(self.kind),
                 CGRectMake(s.origin.x + 58, s.origin.y + 78, 760, 26), 18, KPP->secondaryText, NSFontWeightMedium, NSTextAlignmentLeft);
  // The controller, big, with the steps beside it.
  KPArtState art;
  art.accent = KPP->accentBottom;
  KPPadDevice *arrived = self.arrived;
  if (arrived) art = KPArtStateFor(arrived, arrived.slot >= 0 ? KPPlayerColors[arrived.slot] : KPP->accentBottom);
  KPCard(c, CGRectMake(s.origin.x + 56, s.origin.y + 130, 580, 380), 24);
  if (self.kind == KPPairKind::Phone) {
    [self drawPhoneJoin:c];
    return;
  }
  const KPPadFamily family = arrived ? arrived.family : self.kind == KPPairKind::WiiRemote ? KPFamilyWiiRemote : KPFamilyGeneric;
  KPDrawControllerArt(c, CGRectMake(s.origin.x + 96, s.origin.y + 170, 500, 300), family, art, arrived.systemName);
  KPTextWeight(KPPairSteps(self.kind), CGRectMake(s.origin.x + 700, s.origin.y + 140, 524, 260), 21, KPP->text, NSFontWeightMedium,
               NSTextAlignmentLeft);
  if (self.kind == KPPairKind::Controller) {
    CGFloat y = s.origin.y + 196;
    for (const auto &mode : KPPairModes) {
      KPTextWeight(mode.brand, CGRectMake(s.origin.x + 700, y, 130, 52), 18, KPP->text, NSFontWeightSemibold, NSTextAlignmentLeft);
      KPTextWeight(mode.how, CGRectMake(s.origin.x + 836, y, 388, 52), 18, KPP->secondaryText, NSFontWeightRegular, NSTextAlignmentLeft);
      y += 58;
    }
  }
  const unsigned ink = arrived ? 0x22843f : KPP->accentBottom;
  if (self.status.length) {
    if (arrived) KPDrawGlyph(c, KPUIGlyph::Check, CGRectMake(s.origin.x + 700, s.origin.y + 440, 36, 36), ink);
    KPTextWeight(self.status, CGRectMake(s.origin.x + (arrived ? 748 : 700), s.origin.y + 438, 476, 100), 20, ink, NSFontWeightSemibold,
                 NSTextAlignmentLeft);
  }
}
// The link as a QR code where the controller would be, the steps beside it, and the phones that have
// joined, each with its player, how quick its link is, and Remove. There's no address to type: the
// link carries this launch's key. It opens the page with tilt, or the touch-only one the Mac serves
// when no tilt page is set or Offline phones is on.
- (void)drawPhoneJoin:(CGContextRef)c {
  const CGRect s = self.safe;
  KPPhoneServer *server = KPPhoneServer.shared;
  NSString *url = server.joinURL;
  const CGRect code = CGRectMake(s.origin.x + 56 + (580 - 340) / 2, s.origin.y + 150, 340, 340);
  if (url) {
    [server drawCode:url in:c rect:code];
  } else {
    KPFill(c, code, KPP->panel, 18);
    KPTextWeight(server.problem ?: @"", CGRectInset(code, 30, 130), 20, KPP->secondaryText, NSFontWeightMedium);
  }
  KPTextWeight(KPPairSteps(self.kind), CGRectMake(s.origin.x + 700, s.origin.y + 140, 524, 150), 21, KPP->text, NSFontWeightMedium,
               NSTextAlignmentLeft);
  const std::vector<KPPhoneEntry> phones = server.entries;
  if (phones.empty()) {
    KPTextWeight(@"Waiting for a phone…", CGRectMake(s.origin.x + 700, s.origin.y + KPPhoneListTop + 12, 524, 30), 20, KPP->accentBottom,
                 NSFontWeightSemibold, NSTextAlignmentLeft);
    return;
  }
  CGFloat y = s.origin.y + KPPhoneListTop;
  for (const KPPhoneEntry &phone : phones) {
    KPSetInk(c, phone.player > 0 ? KPPlayerColors[phone.player - 1] : KPP->switchOff);
    CGContextFillEllipseInRect(c, CGRectMake(s.origin.x + 702, y + 16, 22, 22));
    KPTextWeight(phone.player > 0 ? KPPlayerName(phone.player - 1) : @"Not playing", CGRectMake(s.origin.x + 738, y + 2, 300, 28), 20,
                 KPP->text, NSFontWeightSemibold, NSTextAlignmentLeft);
    NSString *detail = !phone.linked        ? [NSString stringWithFormat:@"Phone %d · Away", phone.phone + 1]
                       : phone.delayMs > 0 ? [NSString stringWithFormat:@"Phone %d · %d ms", phone.phone + 1, phone.delayMs]
                                           : [NSString stringWithFormat:@"Phone %d", phone.phone + 1];
    KPTextWeight(detail, CGRectMake(s.origin.x + 738, y + 29, 300, 22), 16, KPP->secondaryText, NSFontWeightRegular, NSTextAlignmentLeft);
    y += KPPhoneRowHeight;
  }
}
@end

static KPScreen *KPMakeConnectScreen() { return [[KPConnectScreen alloc] initWithFrame:NSZeroRect]; }

// For phones (KartPadPhoneControllers.inc.mm): while one of KartPad's screens is up, the controllers are
// its, so phones show the menus' controls.
static BOOL KPPhoneOverlayActive() { return KPOverlay().active; }

// The Miis window: one place on Mac to create, edit, duplicate, import, export and remove Miis, and
// to rename, relink and delete licenses. The screen itself is shared with iPhone and iPad
// (KartPadMiiBrowser.inc.mm); this file keeps it above the game. Player → Miis…, Settings and
// holding the Miis buttons on a controller open it, the Mii editor opens above it, and closing it
// returns the keyboard to the game.

static NSWindow *KPGameWindow() {
  // The SDL game window has no window controller; the Mii editor has one.
  for (NSWindow *window in NSApp.windows) {
    if (![window isKindOfClass:NSPanel.class] && window.visible &&
        window.windowController == nil) {
      return window;
    }
  }
  return nil;
}

// Exclusive SDL windows sit above the menu-bar level. A normal panel would open
// behind the game even though the menu item or hotkey was received.
static NSInteger KPAuxiliaryWindowLevel() {
  NSWindow *game = KPGameWindow();
  return std::max<NSInteger>(NSFloatingWindowLevel, game != nil ? game.level + 1 : 0);
}

static void KPCenterOnGameScreen(NSWindow *window) {
  NSScreen *screen = KPGameWindow().screen ?: NSScreen.mainScreen;
  if (screen == nil) return;
  NSRect available = screen.visibleFrame;
  NSRect frame = window.frame;
  frame.origin = NSMakePoint(NSMidX(available) - frame.size.width / 2,
                             NSMidY(available) - frame.size.height / 2);
  [window setFrame:frame display:NO];
}

@interface KPMiisWindow : NSObject <NSWindowDelegate>
// The shell controller, which owns quitting.
@property(nonatomic, weak) id owner;
@property(nonatomic, strong) NSPanel *panel;
@property(nonatomic, strong) NSViewController<KartPadMiiBrowser> *browser;
- (void)show;
@end

@implementation KPMiisWindow

- (void)build {
  self.browser = (NSViewController<KartPadMiiBrowser> *)KartPadMakeMiiBrowser();
  self.panel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 820, 560)
      styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable
      backing:NSBackingStoreBuffered defer:NO];
  self.panel.title = @"Miis";
  self.panel.releasedWhenClosed = NO;
  self.panel.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
      NSWindowCollectionBehaviorFullScreenAuxiliary;
  self.panel.hidesOnDeactivate = YES;
  self.panel.delegate = self;
  self.panel.contentViewController = self.browser;
  self.panel.contentMinSize = NSMakeSize(640, 460);
  [self.panel setContentSize:NSMakeSize(820, 560)];
  self.panel.initialFirstResponder = self.browser.view;
  __weak KPMiisWindow *weakSelf = self;
  self.browser.done = ^{ [weakSelf.panel performClose:nil]; };
  self.browser.restart = ^{ [NSApp sendAction:@selector(restartKartPad:) to:weakSelf.owner from:nil]; };
}

// When the last Mii window (this one or the editor) closes, the keyboard goes back to the game.
+ (void)returnFocusToGameAfterClosing {
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    [NSNotificationCenter.defaultCenter addObserverForName:NSWindowWillCloseNotification object:nil queue:nil
        usingBlock:^(NSNotification *note) {
      if (!KartPadMiiWindowsVisible()) return;
      NSWindow *closing = note.object;
      dispatch_async(dispatch_get_main_queue(), ^{
        if (KartPadMiiWindowsVisible() || !NSApp.active || closing.visible) return;
        [KPGameWindow() makeKeyAndOrderFront:nil];
      });
    }];
  });
}

- (void)show {
  [KPMiisWindow returnFocusToGameAfterClosing];
  if (self.panel == nil) {
    [self build];
    KPCenterOnGameScreen(self.panel);
  }
  if (!self.panel.visible) [self.browser willShow];
  [self.browser reload];
  self.panel.level = KPAuxiliaryWindowLevel();
  [NSApp activateIgnoringOtherApps:YES];
  [self.panel makeKeyAndOrderFront:nil];
}

- (void)windowDidBecomeKey:(NSNotification *)notification {
  (void)notification;
  // The editor closes after saving; show the pending state when focus returns.
  [self.browser reload];
}

- (void)windowWillClose:(NSNotification *)notification {
  (void)notification;
  [self.browser willClose];
}

@end

// Controllers on the Miis window and the Mii editor (KartPadMiiGamepad.inc.mm decides what each
// press does). While either is open the game ignores the pads, and it keeps ignoring them until
// they are let go, so the B that closes the window doesn't also go back in the game. A timer reads
// them, since the game loop (and its pad updates) stops while an alert or menu runs its own loop.
static NSTimer *KPMiiPadTimer;
// When the game loop last ran; after that stops, the reader updates the pads itself.
static NSTimeInterval KPGameLoopTime;
static uint32_t KPMiiPadHeld;
static bool KPMiiPadOwned;
static NSTimeInterval KPMiiPadRepeatAt;
static constexpr uint32_t KPMiiPadDirections =
    1u << KartPadMiiPadUp | 1u << KartPadMiiPadDown | 1u << KartPadMiiPadLeft | 1u << KartPadMiiPadRight;

static bool KPMiiPadOwnsInput() { return KPMiiPadOwned || KartPadMiiWindowsVisible(); }

// Every connected pad counts. The bottom and right face buttons are the game's confirm and back.
static uint32_t KPMiiPadRead(bool *anyHeld) {
  uint32_t held = 0;
  *anyHeld = false;
  for (unsigned i = 0; i < PADCount(); ++i) {
    SDL_Gamepad *pad = PADGetSDLGamepadForIndex(i);
    if (pad == nullptr) continue;
    auto down = [&](SDL_GamepadButton button) { return SDL_GetGamepadButton(pad, button); };
    auto set = [&](KartPadMiiPadButton button, bool on) { if (on) held |= 1u << button; };
    for (int button = 0; button < SDL_GAMEPAD_BUTTON_COUNT; ++button)
      *anyHeld |= down((SDL_GamepadButton)button);
    // The stick moves along its stronger axis once past half way.
    const int x = SDL_GetGamepadAxis(pad, SDL_GAMEPAD_AXIS_LEFTX);
    const int y = SDL_GetGamepadAxis(pad, SDL_GAMEPAD_AXIS_LEFTY);
    const bool horizontal = std::abs(x) >= std::abs(y), tilted = std::max(std::abs(x), std::abs(y)) > 16000;
    *anyHeld |= tilted;
    set(KartPadMiiPadUp, down(SDL_GAMEPAD_BUTTON_DPAD_UP) || (tilted && !horizontal && y < 0));
    set(KartPadMiiPadDown, down(SDL_GAMEPAD_BUTTON_DPAD_DOWN) || (tilted && !horizontal && y > 0));
    set(KartPadMiiPadLeft, down(SDL_GAMEPAD_BUTTON_DPAD_LEFT) || (tilted && horizontal && x < 0));
    set(KartPadMiiPadRight, down(SDL_GAMEPAD_BUTTON_DPAD_RIGHT) || (tilted && horizontal && x > 0));
    set(KartPadMiiPadConfirm, down(SDL_GAMEPAD_BUTTON_SOUTH));
    set(KartPadMiiPadBack, down(SDL_GAMEPAD_BUTTON_EAST));
    set(KartPadMiiPadUndo, down(SDL_GAMEPAD_BUTTON_WEST));
    set(KartPadMiiPadRedo, down(SDL_GAMEPAD_BUTTON_NORTH));
    set(KartPadMiiPadPreviousTab, down(SDL_GAMEPAD_BUTTON_LEFT_SHOULDER));
    set(KartPadMiiPadNextTab, down(SDL_GAMEPAD_BUTTON_RIGHT_SHOULDER));
    set(KartPadMiiPadStart, down(SDL_GAMEPAD_BUTTON_START));
  }
  return held;
}

// Each press runs from its own turn of the run loop, so one that opens an alert or menu (which
// runs a loop of its own) leaves the reader free to drive it.
static void KPMiiPadSend(KartPadMiiPadButton button, BOOL down) {
  NSTimer *timer = [NSTimer timerWithTimeInterval:0 repeats:NO block:^(NSTimer *t) {
    (void)t;
    @autoreleasepool { KartPadMiiPadPress(button, down); }
  }];
  [NSRunLoop.mainRunLoop addTimer:timer forMode:NSRunLoopCommonModes];
}

static void KPMiiPadPoll() {
  const NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
  if (now - KPGameLoopTime > 0.1) SDL_UpdateGamepads();
  const bool visible = KartPadMiiWindowsVisible();
  bool anyHeld = false;
  const uint32_t held = KPMiiPadRead(&anyHeld);
  // Buttons already down when a window opens aren't presses for it, and don't repeat.
  const bool listening = KPMiiPadOwned && visible;
  if (visible && !KPMiiPadOwned) KPMiiPadRepeatAt = DBL_MAX;
  const uint32_t pressed = listening ? held & ~KPMiiPadHeld : 0;
  const uint32_t released = listening ? KPMiiPadHeld & ~held : 0;
  uint32_t fire = pressed;
  // Directions repeat while held, after a pause.
  if (pressed & KPMiiPadDirections) {
    KPMiiPadRepeatAt = now + 0.4;
  } else if (listening && (held & KPMiiPadDirections) && now >= KPMiiPadRepeatAt) {
    fire |= held & KPMiiPadDirections;
    KPMiiPadRepeatAt = now + 0.11;
  }
  KPMiiPadHeld = held;
  if (visible) {
    KPMiiPadOwned = true;
  } else if (!anyHeld) {
    KPMiiPadOwned = false;
    [KPMiiPadTimer invalidate];
    KPMiiPadTimer = nil;
    return;
  }
  for (int button = 0; button < KartPadMiiPadButtonCount; ++button) {
    if (fire & (1u << button)) KPMiiPadSend((KartPadMiiPadButton)button, YES);
    if (button == KartPadMiiPadConfirm && (released & (1u << button))) KPMiiPadSend(KartPadMiiPadConfirm, NO);
  }
}

// From the game loop: start reading once a Mii window is open.
static void KPMiiPadTick() {
  if (KPMiiPadTimer != nil || !KartPadMiiWindowsVisible()) return;
  KPMiiPadOwned = false;
  KPMiiPadTimer = [NSTimer timerWithTimeInterval:1.0 / 60 repeats:YES block:^(NSTimer *t) {
    (void)t;
    @autoreleasepool { KPMiiPadPoll(); }
  }];
  [NSRunLoop.mainRunLoop addTimer:KPMiiPadTimer forMode:NSRunLoopCommonModes];
  KPMiiPadPoll();
}

// Holding the Miis buttons on any controller opens the Miis window, so the whole Mii flow works
// without a keyboard or mouse. Settings → Game & Data chooses the buttons (any held together) and
// how long to hold them. The default is View (Select, Share, −) for a second, which the game
// doesn't use. Not while the Mii windows have the pads, KartPad is in the background, or Controllers
// is listening for a binding; and after opening, not again until the buttons are let go.
static NSString *const KPMiisPadEnabledKey = @"KartPadMiisControllerShortcut";
static NSString *const KPMiisPadButtonsKey = @"KartPadMiisControllerButtons";
static NSString *const KPMiisPadHoldKey = @"KartPadMiisControllerHold";
static NSTimeInterval KPMiisPadSince;
static bool KPMiisPadLatched;
// Choosing the buttons in Settings: whatever is held together before everything is let go.
static void (^KPMiisPadCapture)(uint64_t buttons);
static uint64_t KPMiisPadCaptured;
static bool KPMiisPadCaptureArmed;
static void KPOpenMiisFromController();  // KartPadMacShell.mm

static bool KPMiisPadEnabled() {
  id value = [NSUserDefaults.standardUserDefaults objectForKey:KPMiisPadEnabledKey];
  return [value isKindOfClass:NSNumber.class] ? [value boolValue] : true;
}
// SDL gamepad buttons as bits.
static uint64_t KPMiisPadButtons() {
  uint64_t buttons = 0;
  id saved = [NSUserDefaults.standardUserDefaults objectForKey:KPMiisPadButtonsKey];
  if ([saved isKindOfClass:NSArray.class])
    for (id button in saved)
      if ([button isKindOfClass:NSNumber.class] && [button intValue] >= 0 && [button intValue] < SDL_GAMEPAD_BUTTON_COUNT)
        buttons |= 1ull << [button intValue];
  return buttons ? buttons : 1ull << SDL_GAMEPAD_BUTTON_BACK;
}
static void KPMiisPadSetButtons(uint64_t buttons) {
  NSMutableArray *list = [NSMutableArray array];
  for (int button = 0; button < SDL_GAMEPAD_BUTTON_COUNT; ++button)
    if (buttons & (1ull << button)) [list addObject:@(button)];
  [NSUserDefaults.standardUserDefaults setObject:list forKey:KPMiisPadButtonsKey];
}
static NSTimeInterval KPMiisPadHold() {
  const double seconds = [NSUserDefaults.standardUserDefaults doubleForKey:KPMiisPadHoldKey];
  return seconds > 0 ? std::clamp(seconds, 0.25, 5.0) : 1.0;
}
// Named as the first controller labels them ("View + Menu").
static NSString *KPMiisPadButtonNames(uint64_t buttons) {
  SDL_Gamepad *pad = PADCount() ? PADGetSDLGamepadForIndex(0) : nullptr;
  NSMutableArray *names = [NSMutableArray array];
  for (int button = 0; button < SDL_GAMEPAD_BUTTON_COUNT; ++button)
    if (buttons & (1ull << button)) [names addObject:KPButtonLabel(pad, button)];
  return [names componentsJoinedByString:@" + "];
}
// Buttons the game reads still act there while they are held; macOS may answer the Guide button.
static NSString *KPMiisPadWarning(uint64_t buttons) {
  uint64_t game = 0;
  for (int port = 0; port < 4; ++port) {
    unsigned count = 0, altCount = 0;
    PADButtonMapping *mappings = PADGetButtonMappings(port, &count), *alternates = PADGetAltButtonMappings(port, &altCount);
    for (unsigned i = 0; mappings && i < count; ++i)
      if (mappings[i].nativeButton < SDL_GAMEPAD_BUTTON_COUNT) game |= 1ull << mappings[i].nativeButton;
    for (unsigned i = 0; alternates && i < altCount; ++i)
      if (alternates[i].nativeButton < SDL_GAMEPAD_BUTTON_COUNT) game |= 1ull << alternates[i].nativeButton;
  }
  if (buttons & game)
    return [NSString stringWithFormat:@"%@ also %@ in the game, so the game still responds while you hold %@.",
        KPMiisPadButtonNames(buttons & game), __builtin_popcountll(buttons & game) > 1 ? @"act" : @"acts",
        __builtin_popcountll(buttons) > 1 ? @"them" : @"it"];
  if (buttons & (1ull << SDL_GAMEPAD_BUTTON_GUIDE)) return @"macOS may also respond to the Guide button.";
  return nil;
}
static bool KPMiisPadCapturing() { return KPMiisPadCapture != nil; }
static void KPMiisPadBeginCapture(void (^done)(uint64_t buttons)) {
  KPMiisPadCapture = [done copy];
  KPMiisPadCaptured = 0;
  KPMiisPadCaptureArmed = false;
}
static void KPMiisPadCancelCapture() { KPMiisPadCapture = nil; }

static void KPMiisPadTick() {
  const uint64_t buttons = KPMiisPadButtons();
  uint64_t held = 0;
  bool chord = false;
  for (unsigned i = 0; i < PADCount(); ++i) {
    SDL_Gamepad *pad = PADGetSDLGamepadForIndex(i);
    if (pad == nullptr) continue;
    uint64_t down = 0;
    for (int button = 0; button < SDL_GAMEPAD_BUTTON_COUNT; ++button)
      if (SDL_GetGamepadButton(pad, (SDL_GamepadButton)button)) down |= 1ull << button;
    held |= down;
    chord |= (down & buttons) == buttons;
  }
  if (KPMiisPadCapture) {
    // Settings closed, or the buttons were let go after being held.
    if (!KPControllers().panel.visible) { KPMiisPadCapture = nil; return; }
    KPMiisPadLatched = true;
    if (!KPMiisPadCaptureArmed) { KPMiisPadCaptureArmed = held == 0; return; }
    KPMiisPadCaptured |= held;
    if (held == 0 && KPMiisPadCaptured) {
      void (^done)(uint64_t) = KPMiisPadCapture;
      const uint64_t captured = KPMiisPadCaptured;
      KPMiisPadCapture = nil;
      dispatch_async(dispatch_get_main_queue(), ^{ done(captured); });
    }
    return;
  }
  if (!chord) { KPMiisPadSince = 0; KPMiisPadLatched = false; return; }
  if (KPMiisPadLatched || !KPMiisPadEnabled()) return;
  if (KartPadMiiWindowsVisible() || !NSApp.active || KPControllers().capture >= 0) { KPMiisPadLatched = true; return; }
  const NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
  if (KPMiisPadSince == 0) KPMiisPadSince = now;
  if (now - KPMiisPadSince < KPMiisPadHold()) return;
  KPMiisPadLatched = true;
  KPMiisPadSince = 0;
  AppendSessionLine(@"miis=opened-from-controller");
  // The game loop can run inside a guest fiber; AppKit opens the window on the next turn.
  dispatch_async(dispatch_get_main_queue(), ^{
    KPOpenMiisFromController();
    KartPadMiiPadShowFocus();
  });
}

extern "C" void KartPadControllersTick() {
  @autoreleasepool {
    KPGameLoopTime = NSProcessInfo.processInfo.systemUptime;
    [KPControllers() tick];
    KPMiiPadTick();
    KPMiisPadTick();
  }
}
// The runtime keeps pad and keyboard input from the game (and the pointer visible) while this is
// true: the Controllers window is open, or the pads belong to the Mii windows.
extern "C" bool KartPadControllersVisible() { return KPControllers().panel.visible || KPMiiPadOwnsInput(); }

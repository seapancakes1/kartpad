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

// When KartPad opens, the game window takes the focus as soon as it appears, so play starts without
// a click. The window only shows once loading is done, by when macOS may not hand it the focus.
// Once per launch, and not if another KartPad window (Settings, say) already has it.
static void KPFocusGameWindowAtLaunch() {
  static bool done;
  NSWindow *game = KPGameWindow();
  if (done || game == nil) return;
  done = true;
  NSWindow *key = NSApp.keyWindow;
  if (key != nil && key != game) return;
  // The game loop can run inside a guest fiber; AppKit takes over on the next turn.
  dispatch_async(dispatch_get_main_queue(), ^{
    [NSApp activateIgnoringOtherApps:YES];
    [game makeKeyAndOrderFront:nil];
  });
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

// Controllers on the Miis window, the Mii editor and Settings (KartPadMiiGamepad.inc.mm decides what
// each press does). While one is open the game ignores the pads, and it keeps ignoring them until
// they are let go, so the B that closes the window doesn't also go back in the game. A timer reads
// them, since the game loop (and its pad updates) stops while an alert or menu runs its own loop.
static NSTimer *KPMiiPadTimer;
// When the game loop last ran; after that stops, the reader updates the pads itself.
static NSTimeInterval KPGameLoopTime;
static uint32_t KPMiiPadHeld;
static bool KPMiiPadOwned;
static NSTimeInterval KPMiiPadRepeatAt;
// Controllers listening for a binding, or Settings for shortcut buttons, read the pads themselves:
// those presses, and anything still held after, don't move around the window.
static bool KPMiiPadQuiet;
static constexpr uint32_t KPMiiPadDirections =
    1u << KartPadMiiPadUp | 1u << KartPadMiiPadDown | 1u << KartPadMiiPadLeft | 1u << KartPadMiiPadRight;
static bool KPPadCapturing();

// The Settings panel is the Controllers panel too.
static bool KPPadWindowsVisible() { return KartPadMiiWindowsVisible() || KPControllers().panel.visible; }
static bool KPMiiPadOwnsInput() { return KPMiiPadOwned || KPPadWindowsVisible(); }

// Every connected pad counts. The bottom and right face buttons are the game's confirm and back.
// pressedBy is the pad that pressed something since the last read (0 if none did).
static uint32_t KPMiiPadRead(bool *anyHeld, SDL_JoystickID *pressedBy) {
  static NSMutableDictionary<NSNumber *, NSNumber *> *before = [NSMutableDictionary dictionary];
  NSMutableDictionary<NSNumber *, NSNumber *> *now = [NSMutableDictionary dictionary];
  uint32_t held = 0;
  *anyHeld = false;
  *pressedBy = 0;
  for (unsigned i = 0; i < PADCount(); ++i) {
    SDL_Gamepad *pad = PADGetSDLGamepadForIndex(i);
    if (pad == nullptr) continue;
    uint32_t mine = 0;
    auto down = [&](SDL_GamepadButton button) { return SDL_GetGamepadButton(pad, button); };
    auto set = [&](KartPadMiiPadButton button, bool on) { if (on) mine |= 1u << button; };
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
    held |= mine;
    NSNumber *identifier = @(SDL_GetGamepadID(pad));
    if (mine & ~before[identifier].unsignedIntValue) *pressedBy = identifier.unsignedIntValue;
    now[identifier] = @(mine);
  }
  [before setDictionary:now];
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
  const bool visible = KPPadWindowsVisible();
  bool anyHeld = false;
  SDL_JoystickID pressedBy = 0;
  const uint32_t held = KPMiiPadRead(&anyHeld, &pressedBy);
  if (KPControllers().capture >= 0 || KPPadCapturing()) KPMiiPadQuiet = true;
  else if (!anyHeld) KPMiiPadQuiet = false;
  // Buttons already down when a window opens aren't presses for it, and don't repeat.
  const bool listening = KPMiiPadOwned && visible && !KPMiiPadQuiet;
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
  // Settings → Controllers shows the controller in use, so it can choose its own player.
  if (listening && pressedBy && KPControllers().panel.keyWindow) [KPControllers() followPad:pressedBy];
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

// From the game loop: start reading once one of those windows is open.
static void KPMiiPadTick() {
  if (KPMiiPadTimer != nil || !KPPadWindowsVisible()) return;
  KPMiiPadOwned = false;
  KPMiiPadTimer = [NSTimer timerWithTimeInterval:1.0 / 60 repeats:YES block:^(NSTimer *t) {
    (void)t;
    @autoreleasepool { KPMiiPadPoll(); }
  }];
  [NSRunLoop.mainRunLoop addTimer:KPMiiPadTimer forMode:NSRunLoopCommonModes];
  KPMiiPadPoll();
}

// Holding buttons on any controller opens the Miis window or Settings, so both work without a
// keyboard or mouse. Settings → Controllers chooses the buttons for each (any held together) and how
// long to hold them. Miis default to View (Select, Share, −) for a second, which the game doesn't
// use; Settings to View + Menu, whose Menu pauses a race on the way. When one shortcut's buttons
// include the other's, holding them all opens the larger one (Settings on a tie). Neither opens
// while a window the pads drive is open, KartPad is in the background, or Controllers is listening
// for a binding; and after opening, not again until its buttons are let go.
enum KPPadShortcutKind { KPPadShortcutMiis, KPPadShortcutSettings, KPPadShortcutCount };
struct KPPadShortcut {
  __unsafe_unretained NSString *enabledKey, *buttonsKey, *holdKey, *opens;
  uint64_t fallback;
  NSTimeInterval since;
  bool latched;
};
static KPPadShortcut KPPadShortcuts[KPPadShortcutCount] = {
  {@"KartPadMiisControllerShortcut", @"KartPadMiisControllerButtons", @"KartPadMiisControllerHold", @"Miis",
   1ull << SDL_GAMEPAD_BUTTON_BACK, 0, false},
  {@"KartPadSettingsControllerShortcut", @"KartPadSettingsControllerButtons", @"KartPadSettingsControllerHold",
   @"Settings", 1ull << SDL_GAMEPAD_BUTTON_BACK | 1ull << SDL_GAMEPAD_BUTTON_START, 0, false},
};
// Choosing the buttons in Settings: whatever is held together before everything is let go.
static void (^KPPadCapture)(uint64_t buttons);
static uint64_t KPPadCaptured;
static bool KPPadCaptureArmed;
static void KPOpenMiisFromController();  // KartPadMacShell.mm
static void KPOpenSettingsFromController();  // KartPadMacShell.mm

static bool KPPadShortcutEnabled(int kind) {
  id value = [NSUserDefaults.standardUserDefaults objectForKey:KPPadShortcuts[kind].enabledKey];
  return [value isKindOfClass:NSNumber.class] ? [value boolValue] : true;
}
// SDL gamepad buttons as bits.
static uint64_t KPPadShortcutButtons(int kind) {
  uint64_t buttons = 0;
  id saved = [NSUserDefaults.standardUserDefaults objectForKey:KPPadShortcuts[kind].buttonsKey];
  if ([saved isKindOfClass:NSArray.class])
    for (id button in saved)
      if ([button isKindOfClass:NSNumber.class] && [button intValue] >= 0 && [button intValue] < SDL_GAMEPAD_BUTTON_COUNT)
        buttons |= 1ull << [button intValue];
  return buttons ? buttons : KPPadShortcuts[kind].fallback;
}
static void KPPadShortcutSetButtons(int kind, uint64_t buttons) {
  NSMutableArray *list = [NSMutableArray array];
  for (int button = 0; button < SDL_GAMEPAD_BUTTON_COUNT; ++button)
    if (buttons & (1ull << button)) [list addObject:@(button)];
  [NSUserDefaults.standardUserDefaults setObject:list forKey:KPPadShortcuts[kind].buttonsKey];
}
static NSTimeInterval KPPadShortcutHold(int kind) {
  const double seconds = [NSUserDefaults.standardUserDefaults doubleForKey:KPPadShortcuts[kind].holdKey];
  return seconds > 0 ? std::clamp(seconds, 0.25, 5.0) : 1.0;
}
// Named as the first controller labels them ("View + Menu").
static NSString *KPPadButtonNames(uint64_t buttons) {
  SDL_Gamepad *pad = PADCount() ? PADGetSDLGamepadForIndex(0) : nullptr;
  NSMutableArray *names = [NSMutableArray array];
  for (int button = 0; button < SDL_GAMEPAD_BUTTON_COUNT; ++button)
    if (buttons & (1ull << button)) [names addObject:KPButtonLabel(pad, button)];
  return [names componentsJoinedByString:@" + "];
}
// Buttons the game reads still act there while they are held; macOS may answer the Guide button.
static NSString *KPPadButtonsWarning(uint64_t buttons) {
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
    return [NSString stringWithFormat:@"The game also uses %@, so it reacts while you hold %@.",
        [KPPadButtonNames(buttons & game) stringByReplacingOccurrencesOfString:@" + " withString:@" and "],
        __builtin_popcountll(buttons & game) > 1 ? @"them" : @"it"];
  if (buttons & (1ull << SDL_GAMEPAD_BUTTON_GUIDE)) return @"macOS may also react to the Guide button.";
  return nil;
}
static bool KPPadCapturing() { return KPPadCapture != nil; }
static void KPPadBeginCapture(void (^done)(uint64_t buttons)) {
  KPPadCapture = [done copy];
  KPPadCaptured = 0;
  KPPadCaptureArmed = false;
}
static void KPPadCancelCapture() { KPPadCapture = nil; }

static void KPPadShortcutsTick() {
  uint64_t buttons[KPPadShortcutCount], held = 0;
  bool chord[KPPadShortcutCount] = {};
  for (int kind = 0; kind < KPPadShortcutCount; ++kind) buttons[kind] = KPPadShortcutButtons(kind);
  for (unsigned i = 0; i < PADCount(); ++i) {
    SDL_Gamepad *pad = PADGetSDLGamepadForIndex(i);
    if (pad == nullptr) continue;
    uint64_t down = 0;
    for (int button = 0; button < SDL_GAMEPAD_BUTTON_COUNT; ++button)
      if (SDL_GetGamepadButton(pad, (SDL_GamepadButton)button)) down |= 1ull << button;
    held |= down;
    for (int kind = 0; kind < KPPadShortcutCount; ++kind) chord[kind] |= (down & buttons[kind]) == buttons[kind];
  }
  if (KPPadCapture) {
    // Settings closed, or the buttons were let go after being held.
    if (!KPControllers().panel.visible) { KPPadCapture = nil; return; }
    for (KPPadShortcut &shortcut : KPPadShortcuts) shortcut.latched = true;
    if (!KPPadCaptureArmed) { KPPadCaptureArmed = held == 0; return; }
    KPPadCaptured |= held;
    if (held == 0 && KPPadCaptured) {
      void (^done)(uint64_t) = KPPadCapture;
      const uint64_t captured = KPPadCaptured;
      KPPadCapture = nil;
      dispatch_async(dispatch_get_main_queue(), ^{ done(captured); });
    }
    return;
  }
  for (int kind = 0; kind < KPPadShortcutCount; ++kind) {
    KPPadShortcut &shortcut = KPPadShortcuts[kind];
    if (!chord[kind]) { shortcut.since = 0; shortcut.latched = false; continue; }
    if (shortcut.latched || !KPPadShortcutEnabled(kind)) continue;
    if (KPPadWindowsVisible() || !NSApp.active || KPControllers().capture >= 0) { shortcut.latched = true; continue; }
    // Held inside the other's buttons, which are held too: the other one is opening.
    const int other = 1 - kind;
    if (chord[other] && KPPadShortcutEnabled(other) && (buttons[other] & buttons[kind]) == buttons[kind] &&
        (buttons[other] != buttons[kind] || kind == KPPadShortcutMiis)) {
      shortcut.since = 0;
      continue;
    }
    const NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    if (shortcut.since == 0) shortcut.since = now;
    if (now - shortcut.since < KPPadShortcutHold(kind)) continue;
    shortcut.latched = true;
    shortcut.since = 0;
    AppendSessionLine(kind == KPPadShortcutMiis ? @"miis=opened-from-controller" : @"settings=opened-from-controller");
    // The game loop can run inside a guest fiber; AppKit opens the window on the next turn.
    dispatch_async(dispatch_get_main_queue(), ^{
      if (kind == KPPadShortcutMiis) {
        KPOpenMiisFromController();
        KartPadMiiPadShowFocus();
      } else {
        KPOpenSettingsFromController();
        KartPadSettingsPadShowFocus();
      }
    });
    return;
  }
}

extern "C" void KartPadControllersTick() {
  @autoreleasepool {
    KPGameLoopTime = NSProcessInfo.processInfo.systemUptime;
    KPFocusGameWindowAtLaunch();
    [KPControllers() tick];
    KPMiiPadTick();
    KPPadShortcutsTick();
  }
}
// The runtime keeps pad and keyboard input from the game (and the pointer visible) while this is
// true: the Controllers window is open, or the pads belong to the Mii windows.
extern "C" bool KartPadControllersVisible() { return KPControllers().panel.visible || KPMiiPadOwnsInput(); }

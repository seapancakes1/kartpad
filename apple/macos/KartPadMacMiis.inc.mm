// The Miis window: one place on Mac to create, edit, duplicate, import, export and remove Miis, and
// to rename, relink and delete licenses. The screen itself is shared with iPhone and iPad
// (KartPadMiiBrowser.inc.mm); this file keeps it above the game. Player → Miis…, Settings and
// holding the Miis buttons on a controller open it, the Mii editor opens above it, and closing it
// returns the keyboard to the game.

#import <objc/runtime.h>

// Automated checks (KARTPAD_BACKGROUND=1) leave the focus where it is: KartPad never comes forward.
// Only builds with the QA hooks (KP_QA_HOOKS) look; otherwise it's never so.
#if KP_QA_HOOKS
static BOOL KPUIBackgroundAutomation() {
  static const BOOL background = [NSProcessInfo.processInfo.environment[@"KARTPAD_BACKGROUND"] isEqual:@"1"];
  return background;
}
#else
static constexpr BOOL KPUIBackgroundAutomation() { return NO; }
#endif

// KartPad's screens over the game (KartPadOverlay.inc.mm): HOME, Controllers, Settings and the rest.
static bool KPOverlayActive();
static bool KPOverlayTakesPads();
static void KPOverlayPadPress(KartPadMiiPadButton button, BOOL down);
static void KPHomeTick();
static void KPOverlayGameTick();
// What Discord shows (KartPadDiscordPresence.inc.mm).
static void KPDiscordPresenceTick();

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
  if (done) return;
  NSWindow *game = KPGameWindow();
  if (game == nil) return;
  done = true;
  // SDL's app delegate ignores the first "became active" it hears (so a window created minimized
  // stays so), then restores a minimized full-screen window on each one after. KartPad was active
  // before SDL arrived (KartPadMacShellPrepareGameData), so that first one has been had already;
  // otherwise coming back to an exclusive full-screen game once would leave it minimized. SDL keeps
  // the flag in a public instance variable of its delegate, and no SDL call or hint sets it (SDL sets
  // it itself only when the app already had a delegate, which would lose SDL's quit handling). So
  // it's set only where it is still a BOOL by that name: an SDL that renames or drops it leaves the
  // first activation to SDL rather than throwing.
  NSObject *delegate = (NSObject *)NSApp.delegate;
  Ivar flag = [NSStringFromClass(delegate.class) isEqualToString:@"SDL3AppDelegate"]
      ? class_getInstanceVariable(delegate.class, "seenFirstActivate") : nullptr;
  const char *type = flag ? ivar_getTypeEncoding(flag) : nullptr;
  if (type != nullptr && strcmp(type, @encode(BOOL)) == 0) {
    @try {
      [delegate setValue:@YES forKey:@"seenFirstActivate"];
    } @catch (NSException *exception) {
      NSLog(@"[KartPad] SDL's activation flag couldn't be set: %@", exception.reason);
    }
  } else if (delegate != nil) {
    NSLog(@"[KartPad] SDL's activation flag wasn't found on %@", delegate.class);
  }
  NSWindow *key = NSApp.keyWindow;
  if (key != nil && key != game) return;
  if (KPUIBackgroundAutomation()) return;
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
// each press does). While one is open the game ignores the pads. Once none is, the game has them
// again at once; the runtime keeps from it only what is still held (the B that closed the window),
// pad by pad and button by button until each is let go (settings_overlay.cpp ApplyInputBlockState).
// A timer reads them, since the game loop (and its pad updates) stops while an alert or menu runs
// its own loop.
static NSTimer *KPMiiPadTimer;
// When the game loop last ran; after that stops, the reader updates the pads itself.
static NSTimeInterval KPGameLoopTime;
static uint32_t KPMiiPadHeld;
static bool KPMiiPadOwned;
static NSTimeInterval KPMiiPadRepeatAt;
// Controllers listening for a binding, or Settings for shortcut buttons, read the pads themselves:
// those presses, and anything still held after, don't move around the window.
static bool KPMiiPadQuiet;
// The controller behind the latest press, so a screen can tell who pressed (Controllers lets a pad
// that isn't playing join with it).
static SDL_JoystickID KPPadLastPresser;
// A screen reading each controller's presses itself (Controllers, while players press A on the
// controller they want): the reader stays out of the way, as for a binding.
static bool KPPadListening;
static constexpr uint32_t KPMiiPadDirections =
    1u << KartPadMiiPadUp | 1u << KartPadMiiPadDown | 1u << KartPadMiiPadLeft | 1u << KartPadMiiPadRight;

// The connected pads, read once per turn of the game loop (KartPadControllersTick) for the ticks that
// look at every pad each frame (HOME's button, joining by pressing); read again by the next turn.
static std::vector<SDL_JoystickID> KPTickPads;
static bool KPTickPadsRead;
static const std::vector<SDL_JoystickID> &KPConnectedPads() {
  if (!KPTickPadsRead) {
    KPTickPadsRead = true;
    int count = 0;
    SDL_JoystickID *ids = SDL_GetGamepads(&count);
    KPTickPads.assign(ids, ids + (ids ? count : 0));
    SDL_free(ids);
  }
  return KPTickPads;
}

// The Settings panel is the Controllers panel too.
static bool KPPadWindowsVisible() { return KartPadMiiWindowsVisible() || KPControllers().panel.visible || KPOverlayActive(); }

// The buttons a pad plays the game's A, B, X and Y with, which menus confirm, go back, and do X and Y
// with (so a remapped pad confirms with its new A). A pad that isn't playing has the runtime's default
// for it (pad.cpp): Nintendo's labelled layout on a Switch Pro, Joy-Cons in the grip and a Wii U Pro
// (A on the right, B at the bottom), positions on the rest. A Wii Remote's A is SDL's east button, B
// (the trigger) south, 1 west and 2 north.
struct KPPadFace {
  SDL_GamepadButton a, b, x, y;
};
static KPPadFace KPPadFaceButtons(SDL_Gamepad *pad) {
  const char *name = SDL_GetGamepadName(pad);
  if (name != nullptr && strncmp(name, "Nintendo Wii Remote", 19) == 0)
    return {SDL_GAMEPAD_BUTTON_EAST, SDL_GAMEPAD_BUTTON_SOUTH, SDL_GAMEPAD_BUTTON_WEST, SDL_GAMEPAD_BUTTON_NORTH};
  const SDL_GamepadType type = SDL_GetGamepadType(pad);
  const bool labelled = (type == SDL_GAMEPAD_TYPE_NINTENDO_SWITCH_PRO && SDL_GetGamepadProduct(pad) != 0x2073) ||
                        type == SDL_GAMEPAD_TYPE_NINTENDO_SWITCH_JOYCON_PAIR || (name && strstr(name, "Wii U Pro Controller"));
  const KPPadFace standard = labelled
      ? KPPadFace{SDL_GAMEPAD_BUTTON_EAST, SDL_GAMEPAD_BUTTON_SOUTH, SDL_GAMEPAD_BUTTON_NORTH, SDL_GAMEPAD_BUTTON_WEST}
      : KPPadFace{SDL_GAMEPAD_BUTTON_SOUTH, SDL_GAMEPAD_BUTTON_EAST, SDL_GAMEPAD_BUTTON_WEST, SDL_GAMEPAD_BUTTON_NORTH};
  KPPadFace face = standard;
  for (int port = 0; port < 4; ++port) {
    const int index = PADGetIndexForPort(port);
    if (index < 0 || PADGetSDLGamepadForIndex(index) != pad) continue;
    unsigned count = 0;
    PADButtonMapping *mappings = PADGetButtonMappings(port, &count);
    for (unsigned i = 0; mappings && i < count; ++i) {
      if (mappings[i].nativeButton >= SDL_GAMEPAD_BUTTON_COUNT) continue;
      const auto native = (SDL_GamepadButton)mappings[i].nativeButton;
      if (mappings[i].padButton == PAD_BUTTON_A) face.a = native;
      if (mappings[i].padButton == PAD_BUTTON_B) face.b = native;
      if (mappings[i].padButton == PAD_BUTTON_X) face.x = native;
      if (mappings[i].padButton == PAD_BUTTON_Y) face.y = native;
    }
    if (face.a == face.b) {
      face.a = standard.a;
      face.b = standard.b;
    }
    break;
  }
  return face;
}
static void KPPadConfirmBack(SDL_Gamepad *pad, SDL_GamepadButton *confirm, SDL_GamepadButton *back) {
  const KPPadFace face = KPPadFaceButtons(pad);
  *confirm = face.a;
  *back = face.b;
}

// Every connected pad counts, Wii Remotes included. pressedBy is the pad that pressed something since
// the last read (0 if none did). turn is the right stick across, -1 to 1, from the pad pushing it furthest.
static uint32_t KPMiiPadRead(bool *anyHeld, SDL_JoystickID *pressedBy, float *turn) {
  static NSMutableDictionary<NSNumber *, NSNumber *> *before = [NSMutableDictionary dictionary];
  NSMutableDictionary<NSNumber *, NSNumber *> *now = [NSMutableDictionary dictionary];
  uint32_t held = 0;
  *anyHeld = false;
  *pressedBy = 0;
  int turnX = 0;
  int padCount = 0;
  SDL_JoystickID *padIDs = SDL_GetGamepads(&padCount);
  for (int i = 0; i < padCount; ++i) {
    SDL_Gamepad *pad = SDL_GetGamepadFromID(padIDs[i]);
    if (pad == nullptr) continue;
    const KPPadFace face = KPPadFaceButtons(pad);
    const SDL_GamepadButton confirm = face.a, back = face.b;
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
    // The right stick is free: the left one moves the focus.
    const int right = SDL_GetGamepadAxis(pad, SDL_GAMEPAD_AXIS_RIGHTX);
    if (std::abs(right) > std::abs(turnX)) turnX = right;
    set(KartPadMiiPadUp, down(SDL_GAMEPAD_BUTTON_DPAD_UP) || (tilted && !horizontal && y < 0));
    set(KartPadMiiPadDown, down(SDL_GAMEPAD_BUTTON_DPAD_DOWN) || (tilted && !horizontal && y > 0));
    set(KartPadMiiPadLeft, down(SDL_GAMEPAD_BUTTON_DPAD_LEFT) || (tilted && horizontal && x < 0));
    set(KartPadMiiPadRight, down(SDL_GAMEPAD_BUTTON_DPAD_RIGHT) || (tilted && horizontal && x > 0));
    set(KartPadMiiPadConfirm, down(confirm));
    set(KartPadMiiPadBack, down(back));
    auto other = [&](SDL_GamepadButton button) { return button != confirm && button != back && down(button); };
    set(KartPadMiiPadUndo, other(face.x));
    set(KartPadMiiPadRedo, other(face.y));
    set(KartPadMiiPadPreviousTab, down(SDL_GAMEPAD_BUTTON_LEFT_SHOULDER));
    set(KartPadMiiPadNextTab, down(SDL_GAMEPAD_BUTTON_RIGHT_SHOULDER));
    set(KartPadMiiPadStart, down(SDL_GAMEPAD_BUTTON_START));
    held |= mine;
    NSNumber *identifier = @(SDL_GetGamepadID(pad));
    if (mine & ~before[identifier].unsignedIntValue) *pressedBy = identifier.unsignedIntValue;
    now[identifier] = @(mine);
  }
  SDL_free(padIDs);
  [before setDictionary:now];
  // Past a dead zone, scaled from there to full tilt.
  constexpr float deadZone = 8000;
  const float past = std::clamp((std::abs(turnX) - deadZone) / (32767 - deadZone), 0.0f, 1.0f);
  *turn = turnX < 0 ? -past : past;
  return held;
}

// Each press runs from its own turn of the run loop, so one that opens an alert or menu (which
// runs a loop of its own) leaves the reader free to drive it.
static void KPMiiPadSend(KartPadMiiPadButton button, BOOL down) {
  NSTimer *timer = [NSTimer timerWithTimeInterval:0 repeats:NO block:^(NSTimer *t) {
    (void)t;
    @autoreleasepool {
      // KartPad's screens answer only while KartPad is in front, as HOME and the shortcuts do: the
      // controller may be playing something else. (A release always goes, so nothing stays pressed.)
      if (KPOverlayTakesPads()) {
        if (NSApp.active || !down) KPOverlayPadPress(button, down);
      } else KartPadMiiPadPress(button, down);
    }
  }];
  [NSRunLoop.mainRunLoop addTimer:timer forMode:NSRunLoopCommonModes];
}

static void KPMiiPadPoll() {
  const NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
  if (now - KPGameLoopTime > 0.1) {
    SDL_UpdateGamepads();
    // The game loop isn't calling in (an alert's loop, a stall): HOME still answers.
    KPTickPadsRead = false;
    KPHomeTick();
  }
  const bool visible = KPPadWindowsVisible();
  bool anyHeld = false;
  SDL_JoystickID pressedBy = 0;
  float turn = 0;
  const uint32_t held = KPMiiPadRead(&anyHeld, &pressedBy, &turn);
  if (KPControllers().capture >= 0 || KPPadListening) KPMiiPadQuiet = true;
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
  if (pressedBy) KPPadLastPresser = pressedBy;
  // Settings → Controllers shows the controller in use, so it can choose its own player.
  if (listening && pressedBy && KPControllers().panel.keyWindow) [KPControllers() followPad:pressedBy];
  // The last window closed: the pads go back to the game straight away (what's still held stays out
  // of it in the runtime), and the reader stops.
  if (!visible) {
    KPMiiPadOwned = false;
    [KPMiiPadTimer invalidate];
    KPMiiPadTimer = nil;
    return;
  }
  KPMiiPadOwned = true;
  static NSTimeInterval turnedAt;
  if (listening && turn != 0) KartPadMiiPadTurn(turn, now - turnedAt);
  turnedAt = now;
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

// Holding Menu (Start, +) for a second on any controller opens HOME, for pads whose HOME / Guide
// button macOS keeps or that have none (a GameCube pad); Menu pauses a race on the way. Not while a
// window the pads drive is open, KartPad is in the background or Controllers is listening for a
// binding, and after opening, not again until Menu is let go.
static constexpr NSTimeInterval KPHomeHoldSeconds = 1.0;
static void KPOpenHomeFromController();  // KartPadHomeScreen.inc.mm

static void KPHomeHoldTick() {
  static NSTimeInterval since;
  static bool latched;
  bool held = false;
  for (unsigned i = 0; i < PADCount() && !held; ++i) {
    SDL_Gamepad *pad = PADGetSDLGamepadForIndex(i);
    held = pad && SDL_GetGamepadButton(pad, SDL_GAMEPAD_BUTTON_START);
  }
  if (!held) {
    since = 0;
    latched = false;
    return;
  }
  if (latched) return;
  if (KPPadWindowsVisible() || !NSApp.active || KPControllers().capture >= 0) {
    latched = true;
    return;
  }
  const NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
  if (since == 0) since = now;
  if (now - since < KPHomeHoldSeconds) return;
  latched = true;
  since = 0;
  AppendSessionLine(@"home=opened-from-controller");
  // The game loop can run inside a guest fiber; AppKit opens HOME on the next turn.
  dispatch_async(dispatch_get_main_queue(), ^{ KPOpenHomeFromController(); });
}

extern "C" void KartPadControllersTick() {
  @autoreleasepool {
    KPGameLoopTime = NSProcessInfo.processInfo.systemUptime;
    KPTickPadsRead = false;
    KPFocusGameWindowAtLaunch();
    [KPControllers() tick];
    KPMiiPadTick();
    KPHomeHoldTick();
    KPHomeTick();
    KPOverlayGameTick();
    KPDiscordPresenceTick();
    KPPhoneRaceTick();
  }
}
// The runtime keeps pad and keyboard input from the game (and the pointer visible) while this is
// true: one of the windows or screens the pads drive is open. Only that long: as it closes the game
// has its input back, less what is still held (settings_overlay.cpp ApplyInputBlockState).
extern "C" bool KartPadControllersVisible() { return KPPadWindowsVisible(); }

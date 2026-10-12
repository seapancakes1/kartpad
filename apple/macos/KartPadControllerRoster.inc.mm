// Every controller KartPad can see, as players see them: what kind it is, who it plays as (P1–P4,
// or nobody), its battery, the Mii of the person holding it, and what it's pressing right now. The
// HOME strip, the Controllers screen and the connect toasts all read this. It also keeps two things
// in step that players shouldn't have to: each pad's light in its player's colour, and the keyboard
// on a player of its own. (Aurora's keyboard replaces whatever pad shares its GameCube port, so the
// keyboard moves to the first free player unless it's been given one.)
// Included by KartPadMacShell.mm after KartPadControllers.inc.mm.

#include "KartPadStyle.h"

typedef NS_ENUM(NSInteger, KPPadFamily) {
  KPFamilyKeyboard, KPFamilyXbox, KPFamilyPlayStation, KPFamilySwitch, KPFamilyJoyCon,
  KPFamilyWiiRemote, KPFamilyGameCube, KPFamilyGeneric
};

static constexpr int KPPlayerCount = 4;
static NSString *const KPKeyboardPlayerKey = @"KartPadKeyboardPlayer";  // 0–3 pinned, -1 not playing, absent: first free
static NSString *const KPControllerMiisKey = @"KartPadControllerMiis";  // profile key or "keyboard" → Mii create ID (hex)
static NSString *const KPPlayerMiisKey = @"KartPadPlayerMiis";          // "0"–"3" → Mii create ID, for twin pads

static NSString *KPHex(NSData *data) {
  NSMutableString *text = [NSMutableString string];
  const uint8_t *bytes = (const uint8_t *)data.bytes;
  for (NSUInteger i = 0; i < data.length; ++i) [text appendFormat:@"%02x", bytes[i]];
  return text;
}

@interface KPPadDevice : NSObject {
@public
  float axes[SDL_GAMEPAD_AXIS_COUNT];
}
@property(nonatomic, copy) NSString *identifier;  // "sdl:<id>" or "keyboard"
@property(nonatomic) SDL_JoystickID joystick;
@property(nonatomic) KPPadFamily family;
@property(nonatomic, copy) NSString *name, *systemName, *profileKey;
// What stays the same while SDL closes and reopens the controller under a new ID (switching its Wii
// driver off and on does that to every Wii Remote): its HID path, else its serial. nil for neither.
@property(nonatomic, copy) NSString *stableKey;
@property(nonatomic) int slot;          // 0–3, -1 when not playing
@property(nonatomic) int battery;       // percent, -1 unknown
@property(nonatomic) BOOL charging, wired, canRumble, hasLight, twin;
@property(nonatomic) uint64_t buttons;  // SDL gamepad buttons held (bits), keyboard: game keys held
@property(nonatomic) NSTimeInterval lastInput, connectedAt;
@property(nonatomic) NSInteger rawCount;  // SDL joystick without a gamepad mapping
- (BOOL)isKeyboard;
- (SDL_Gamepad *)gamepad;
@end

@implementation KPPadDevice
- (BOOL)isKeyboard { return self.joystick == 0; }
- (SDL_Gamepad *)gamepad { return self.joystick ? SDL_GetGamepadFromID(self.joystick) : nullptr; }
@end

static BOOL KPIsWiiRemoteName(const char *name) { return name != nullptr && strncmp(name, "Nintendo Wii Remote", 19) == 0; }

static KPPadFamily KPFamilyFor(SDL_Gamepad *pad) {
  const char *name = SDL_GetGamepadName(pad);
  if (KPIsWiiRemoteName(name)) return KPFamilyWiiRemote;
  const Uint16 vendor = SDL_GetGamepadVendor(pad), product = SDL_GetGamepadProduct(pad);
  if (name && (strstr(name, "GameCube") || strstr(name, "Gamecube"))) return KPFamilyGameCube;
  if (vendor == 0x057e && (product == 0x0337 || product == 0x2073)) return KPFamilyGameCube;
  switch (SDL_GetGamepadType(pad)) {
    case SDL_GAMEPAD_TYPE_XBOX360:
    case SDL_GAMEPAD_TYPE_XBOXONE: return KPFamilyXbox;
    case SDL_GAMEPAD_TYPE_PS3:
    case SDL_GAMEPAD_TYPE_PS4:
    case SDL_GAMEPAD_TYPE_PS5: return KPFamilyPlayStation;
    case SDL_GAMEPAD_TYPE_NINTENDO_SWITCH_PRO: return KPFamilySwitch;
    case SDL_GAMEPAD_TYPE_NINTENDO_SWITCH_JOYCON_LEFT:
    case SDL_GAMEPAD_TYPE_NINTENDO_SWITCH_JOYCON_RIGHT:
    case SDL_GAMEPAD_TYPE_NINTENDO_SWITCH_JOYCON_PAIR: return KPFamilyJoyCon;
    default: return KPFamilyGeneric;
  }
}

// What a person calls it. Model names are only words; nothing borrows a maker's logo.
static NSString *KPFriendlyName(SDL_Gamepad *pad, KPPadFamily family) {
  const char *raw = SDL_GetGamepadName(pad);
  NSString *name = raw ? @(raw) : @"";
  NSString *lower = name.lowercaseString;
  switch (family) {
    case KPFamilyXbox: return @"Xbox controller";
    case KPFamilyPlayStation:
      if ([lower containsString:@"dualsense"]) return [lower containsString:@"edge"] ? @"DualSense Edge" : @"DualSense";
      if ([lower containsString:@"dualshock"] || SDL_GetGamepadType(pad) == SDL_GAMEPAD_TYPE_PS4) return @"DualShock 4";
      return @"PlayStation controller";
    case KPFamilySwitch: return @"Pro Controller";
    case KPFamilyJoyCon:
      switch (SDL_GetGamepadType(pad)) {
        case SDL_GAMEPAD_TYPE_NINTENDO_SWITCH_JOYCON_LEFT: return @"Joy\u2011Con (L)";
        case SDL_GAMEPAD_TYPE_NINTENDO_SWITCH_JOYCON_RIGHT: return @"Joy\u2011Con (R)";
        default: return @"Joy\u2011Con pair";
      }
    case KPFamilyWiiRemote:
      if ([name containsString:@"Nunchuk"]) return @"Wii Remote + Nunchuk";
      if ([name containsString:@"Classic"]) return @"Wii Remote + Classic";
      if ([name containsString:@"Wii U Pro"]) return @"Wii U Pro Controller";
      return @"Wii Remote";
    case KPFamilyGameCube: return @"GameCube controller";
    case KPFamilyKeyboard: return @"Keyboard";
    case KPFamilyGeneric:
      if (SDL_GetGamepadVendor(pad) == 0x2dc8) return @"8BitDo controller";
      return name.length && name.length <= 24 && ![name isEqualToString:@"Controller"] ? name : @"Controller";
  }
  return @"Controller";
}

// The button that opens HOME, as the controller in hand shows it.
static NSString *KPHomeButtonName(KPPadFamily family) {
  switch (family) {
    case KPFamilyKeyboard: return @"esc";
    case KPFamilyXbox: return @"the Xbox button";
    case KPFamilyPlayStation: return @"the PS button";
    case KPFamilySwitch:
    case KPFamilyJoyCon:
    case KPFamilyWiiRemote: return @"HOME";
    case KPFamilyGameCube: return @"Start";  // held
    case KPFamilyGeneric: return @"HOME";
  }
  return @"HOME";
}

// The port the keyboard plays on: the one Aurora reads keys for (-1 for none).
static int KPKeyboardPort() {
  for (int port = 0; port < KPPlayerCount; ++port) {
    u32 count = 0;
    if (PADGetKeyButtonBindings(port, &count) != nullptr) return port;
  }
  return -1;
}

// Pads on a GameCube port. Wii Remotes have one too (Aurora gives every controller a port; the
// remote's Wii channel is the same number).
static int KPPortForGamepad(SDL_Gamepad *pad) {
  for (int port = 0; port < KPPlayerCount; ++port) {
    const int index = PADGetIndexForPort(port);
    if (index >= 0 && PADGetSDLGamepadForIndex(index) == pad) return port;
  }
  return -1;
}
static int KPIndexForGamepad(SDL_Gamepad *pad) {
  for (unsigned i = 0; i < PADCount(); ++i)
    if (PADGetSDLGamepadForIndex(i) == pad) return (int)i;
  return -1;
}

extern "C" void KartPadSetKeyboardDrivesWiiChannel0(bool drives);  // runtime kpad.cpp

// SDL's own mapping for a Wii Remote with nothing attached reads the D-pad from a hat that its Wii
// driver never makes: the driver reports the D-pad as buttons, as it does with a Nunchuk attached
// (whose mapping does read them). Without this a bare remote's D-pad can't move around KartPad's
// screens or light up in its drawing. The game reads the remote's raw buttons, so it isn't affected.
static void KPFixBareWiiRemoteMapping(SDL_JoystickID id) {
  const char *name = SDL_GetGamepadNameForID(id);
  if (name == nullptr || strcmp(name, "Nintendo Wii Remote") != 0) return;
  char guid[64];
  SDL_GUIDToString(SDL_GetJoystickGUIDForID(id), guid, sizeof guid);
  NSString *mapping = [NSString stringWithFormat:@"%s,Nintendo Wii Remote,a:b0,b:b1,back:b4,dpdown:b12,dpleft:b13,dpright:b14,"
                                                 @"dpup:b11,guide:b5,start:b6,x:b2,y:b3,", guid];
  if (SDL_AddGamepadMapping(mapping.UTF8String) < 0) NSLog(@"[KartPad] Wii Remote D-pad mapping not added: %s", SDL_GetError());
}

@protocol KPRosterListener <NSObject>
- (void)rosterChanged;
@end

@interface KPControllerRoster : NSObject
@property(nonatomic, strong) NSArray<KPPadDevice *> *devices;  // keyboard first, then pads by player
@property(nonatomic, strong) KPPadDevice *lastActive;
@property(nonatomic, strong) NSHashTable<id<KPRosterListener>> *listeners;
@property(nonatomic) BOOL quiet;  // the Controllers screen animates changes itself; no toasts meanwhile
// Controllers someone took out with Stop playing: pressing a button doesn't bring them back in
// (KPAutoJoinTick) until they're given a player again. Until they disconnect, by identifier.
@property(nonatomic, strong) NSMutableSet<NSString *> *benched;
+ (instancetype)shared;
- (void)refresh;
- (KPPadDevice *)deviceInSlot:(int)slot;
- (KPPadDevice *)deviceWithIdentifier:(NSString *)identifier;
- (void)move:(KPPadDevice *)device toSlot:(int)slot;
- (void)identify:(KPPadDevice *)device;
- (NSData *)miiFor:(KPPadDevice *)device;
- (NSDictionary *)miiRecordFor:(KPPadDevice *)device;
- (void)setMii:(NSDictionary *)record forDevice:(KPPadDevice *)device;
@end

// Connect, disconnect and low-battery toasts (KartPadControllersScreen.inc.mm, with the overlay).
@interface KPControllerRoster (Toasts)
- (void)announceConnected:(KPPadDevice *)device;
- (void)announceGone:(KPPadDevice *)device;
- (void)checkBattery:(KPPadDevice *)device announce:(BOOL)announce;
@end

static void KPHintDeviceChanged();  // KartPadHints.inc.mm

@implementation KPControllerRoster {
  NSMutableDictionary<NSString *, KPPadDevice *> *_known;
  NSMutableDictionary<NSString *, NSNumber *> *_lightSlot;
  std::array<PADKeyButtonBinding, PAD_BUTTON_COUNT> _keyButtons;
  std::array<PADKeyAxisBinding, PAD_AXIS_COUNT> _keyAxes;
  BOOL _haveKeys, _started;
  NSTimeInterval _startedAt, _keyboardMovedAt;
  NSArray<NSDictionary *> *_miiRecords;
  NSTimeInterval _miiRecordsAt;
  // The records by create ID (hex), and each controller's Mii as last looked up (NSNull for none),
  // until the records are read again or who plays as whom changes: cards draw it every frame.
  NSDictionary<NSString *, NSDictionary *> *_miiByID;
  NSMutableDictionary<NSString *, id> *_miiForDevice;
  // Who was on which player at the last refresh. The devices themselves are updated in place, so
  // comparing them with the previous list would never see a controller change player.
  NSString *_seating;
}
// The screens' button hints follow the controller used last.
- (void)setLastActive:(KPPadDevice *)device {
  if (device == _lastActive) return;
  _lastActive = device;
  KPHintDeviceChanged();
}

+ (instancetype)shared {
  static KPControllerRoster *roster;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ roster = [KPControllerRoster new]; });
  return roster;
}

- (instancetype)init {
  if ((self = [super init])) {
    _known = [NSMutableDictionary dictionary];
    _lightSlot = [NSMutableDictionary dictionary];
    _devices = @[];
    _listeners = [NSHashTable weakObjectsHashTable];
    _benched = [NSMutableSet set];
    _miiForDevice = [NSMutableDictionary dictionary];
  }
  return self;
}

- (KPPadDevice *)deviceInSlot:(int)slot {
  for (KPPadDevice *device in self.devices)
    if (device.slot == slot) return device;
  return nil;
}
- (KPPadDevice *)deviceWithIdentifier:(NSString *)identifier {
  for (KPPadDevice *device in self.devices)
    if ([device.identifier isEqualToString:identifier]) return device;
  return nil;
}

#pragma mark Keyboard placement

// The keys the keyboard plays with, read from whichever port has them, so they travel with it.
- (void)rememberKeyboardBindings {
  const int port = KPKeyboardPort();
  if (port < 0) return;
  u32 count = 0, axisCount = 0;
  PADKeyButtonBinding *buttons = PADGetKeyButtonBindings(port, &count);
  PADKeyAxisBinding *axes = PADGetKeyAxisBindings(port, &axisCount);
  if (buttons == nullptr || axes == nullptr || count != PAD_BUTTON_COUNT || axisCount != PAD_AXIS_COUNT) return;
  std::copy(buttons, buttons + PAD_BUTTON_COUNT, _keyButtons.begin());
  std::copy(axes, axes + PAD_AXIS_COUNT, _keyAxes.begin());
  _haveKeys = YES;
}

- (void)placeKeyboardOn:(int)port {
  const int current = KPKeyboardPort();
  if (current == port) return;
  [self rememberKeyboardBindings];
  for (int other = 0; other < KPPlayerCount; ++other)
    if (other != port) PADSetKeyboardActive(other, FALSE);
  if (port >= 0) {
    if (_haveKeys) {
      for (const auto &binding : _keyButtons) PADSetKeyButtonBinding(port, binding);
      for (const auto &binding : _keyAxes) PADSetKeyAxisBinding(port, binding);
    }
    PADSetKeyboardActive(port, TRUE);
  }
  KartPadSetKeyboardDrivesWiiChannel0(port == 0);
  _keyboardMovedAt = NSProcessInfo.processInfo.systemUptime;
  AppendSessionLine([NSString stringWithFormat:@"keyboardPlayer=%d", port + 1]);
}

// Pinned to a player, or the first player without a pad. A pad that comes back to the keyboard's
// player takes it back a moment later (so a pad that flickers off and on doesn't move it twice).
- (int)wantedKeyboardPort:(NSArray<KPPadDevice *> *)pads {
  id pinned = [NSUserDefaults.standardUserDefaults objectForKey:KPKeyboardPlayerKey];
  if ([pinned isKindOfClass:NSNumber.class]) return std::clamp([pinned intValue], -1, KPPlayerCount - 1);
  bool taken[KPPlayerCount] = {};
  for (KPPadDevice *pad in pads)
    if (pad.slot >= 0 && pad.slot < KPPlayerCount) taken[pad.slot] = true;
  for (int port = 0; port < KPPlayerCount; ++port)
    if (!taken[port]) return port;
  return -1;
}

#pragma mark Refresh

- (void)refresh {
  const NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
  if (!_started) {
    _started = YES;
    _startedAt = now;
  }
  NSMutableArray<KPPadDevice *> *pads = [NSMutableArray array];
  NSMutableSet<NSString *> *seen = [NSMutableSet set];
  NSMutableDictionary<NSString *, NSNumber *> *keyCounts = [NSMutableDictionary dictionary];
  int count = 0;
  SDL_JoystickID *ids = SDL_GetGamepads(&count);
  for (int i = 0; i < count; ++i) {
    SDL_Gamepad *pad = SDL_GetGamepadFromID(ids[i]);
    if (pad == nullptr) continue;
    NSString *identifier = [NSString stringWithFormat:@"sdl:%u", ids[i]];
    KPPadDevice *device = _known[identifier];
    if (device == nil) {
      KPFixBareWiiRemoteMapping(ids[i]);
      device = [KPPadDevice new];
      device.identifier = identifier;
      device.joystick = ids[i];
      device.family = KPFamilyFor(pad);
      device.name = KPFriendlyName(pad, device.family);
      device.systemName = @(SDL_GetGamepadName(pad) ?: "Controller");
      device.profileKey = KPProfileKey(pad);
      const char *path = SDL_GetGamepadPath(pad), *serial = SDL_GetGamepadSerial(pad);
      device.stableKey = path && *path ? [NSString stringWithFormat:@"path:%s", path]
                       : serial && *serial ? [@"serial:" stringByAppendingString:device.profileKey] : nil;
      device.connectedAt = now;
      SDL_PropertiesID props = SDL_GetGamepadProperties(pad);
      device.canRumble = SDL_GetBooleanProperty(props, SDL_PROP_GAMEPAD_CAP_RUMBLE_BOOLEAN, false);
      device.hasLight = SDL_GetBooleanProperty(props, SDL_PROP_GAMEPAD_CAP_RGB_LED_BOOLEAN, false);
      _known[identifier] = device;
    }
    [seen addObject:identifier];
    device.slot = KPPortForGamepad(pad);
    int percent = -1;
    const SDL_PowerState power = SDL_GetGamepadPowerInfo(pad, &percent);
    device.battery = power == SDL_POWERSTATE_ON_BATTERY || power == SDL_POWERSTATE_CHARGING ? percent : -1;
    device.charging = power == SDL_POWERSTATE_CHARGING || power == SDL_POWERSTATE_CHARGED;
    device.wired = power == SDL_POWERSTATE_NO_BATTERY || SDL_GetGamepadConnectionState(pad) == SDL_JOYSTICK_CONNECTION_WIRED;
    uint64_t held = 0;
    for (int button = 0; button < SDL_GAMEPAD_BUTTON_COUNT; ++button)
      if (SDL_GetGamepadButton(pad, (SDL_GamepadButton)button)) held |= 1ull << button;
    bool moved = false;
    for (int axis = 0; axis < SDL_GAMEPAD_AXIS_COUNT; ++axis) {
      const float value = SDL_GetGamepadAxis(pad, (SDL_GamepadAxis)axis) / 32767.0f;
      device->axes[axis] = value;
      moved |= std::fabs(value) > (axis >= SDL_GAMEPAD_AXIS_LEFT_TRIGGER ? 0.3f : 0.5f);
    }
    if ((held & ~device.buttons) || (moved && now - device.lastInput > 0.5)) {
      device.lastInput = now;
      self.lastActive = device;
    }
    device.buttons = held;
    keyCounts[device.profileKey] = @(keyCounts[device.profileKey].intValue + 1);
    [pads addObject:device];
  }
  SDL_free(ids);
  for (KPPadDevice *pad in pads) pad.twin = keyCounts[pad.profileKey].intValue > 1;

  // The keyboard is always here; it plays as one player at most.
  KPPadDevice *keyboard = _known[@"keyboard"];
  if (keyboard == nil) {
    keyboard = [KPPadDevice new];
    keyboard.identifier = @"keyboard";
    keyboard.family = KPFamilyKeyboard;
    keyboard.name = @"Keyboard";
    keyboard.systemName = @"Keyboard";
    keyboard.profileKey = @"keyboard";
    keyboard.wired = YES;
    _known[@"keyboard"] = keyboard;
  }
  [self rememberKeyboardBindings];
  const int wanted = [self wantedKeyboardPort:pads];
  const int keyboardPort = KPKeyboardPort();
  if (wanted != keyboardPort) {
    // A pad has just claimed the keyboard's player (it came back): wait a moment before moving.
    const BOOL pinned = [[NSUserDefaults.standardUserDefaults objectForKey:KPKeyboardPlayerKey] isKindOfClass:NSNumber.class];
    if (pinned || now - _keyboardMovedAt > 1.5) [self placeKeyboardOn:wanted];
  }
  keyboard.slot = KPKeyboardPort();
  // The keyboard's Wii Remote (channel 0) speaks only while it plays as Player 1, including when
  // it was left on another player last time.
  {
    static int lastDrives = -1;
    const int drives = keyboard.slot == 0 ? 1 : 0;
    if (drives != lastDrives) {
      lastDrives = drives;
      KartPadSetKeyboardDrivesWiiChannel0(drives);
    }
  }
  // A pad that shares the keyboard's port isn't heard by the game; show it as not playing.
  if (keyboard.slot >= 0)
    for (KPPadDevice *pad in pads)
      if (pad.slot == keyboard.slot) pad.slot = -1;
  {
    int keyCount = 0;
    const bool *keys = SDL_GetKeyboardState(&keyCount);
    uint64_t held = 0;
    static const SDL_Scancode watched[] = {SDL_SCANCODE_RETURN, SDL_SCANCODE_SPACE, SDL_SCANCODE_BACKSPACE,
      SDL_SCANCODE_W, SDL_SCANCODE_A, SDL_SCANCODE_S, SDL_SCANCODE_D, SDL_SCANCODE_UP, SDL_SCANCODE_DOWN,
      SDL_SCANCODE_LEFT, SDL_SCANCODE_RIGHT, SDL_SCANCODE_E, SDL_SCANCODE_Q, SDL_SCANCODE_LSHIFT,
      SDL_SCANCODE_LCTRL, SDL_SCANCODE_LALT, SDL_SCANCODE_U, SDL_SCANCODE_M};
    for (size_t i = 0; i < std::size(watched); ++i)
      if ((int)watched[i] < keyCount && keys[watched[i]]) held |= 1ull << i;
    if (held & ~keyboard.buttons) {
      keyboard.lastInput = now;
      self.lastActive = keyboard;
    }
    keyboard.buttons = held;
  }

  // Connections and disconnections.
  NSMutableArray<KPPadDevice *> *gone = [NSMutableArray array];
  for (NSString *identifier in _known.allKeys) {
    if ([identifier isEqualToString:@"keyboard"] || [seen containsObject:identifier]) continue;
    [gone addObject:_known[identifier]];
    [_known removeObjectForKey:identifier];
  }
  NSArray<KPPadDevice *> *previous = self.devices;
  NSMutableArray<KPPadDevice *> *added = [NSMutableArray array];
  for (KPPadDevice *pad in pads)
    if (![previous containsObject:pad]) [added addObject:pad];

  [pads sortUsingComparator:^NSComparisonResult(KPPadDevice *a, KPPadDevice *b) {
    const int sa = a.slot < 0 ? 99 : a.slot, sb = b.slot < 0 ? 99 : b.slot;
    if (sa != sb) return sa < sb ? NSOrderedAscending : NSOrderedDescending;
    return a.connectedAt < b.connectedAt ? NSOrderedAscending : NSOrderedDescending;
  }];
  NSMutableArray *all = [NSMutableArray arrayWithObject:keyboard];
  [all addObjectsFromArray:pads];
  NSMutableString *seating = [NSMutableString string];
  for (KPPadDevice *device in all) [seating appendFormat:@"%@=%d;", device.identifier, device.slot];
  const BOOL changed = added.count || gone.count || ![seating isEqualToString:_seating ?: @""];
  _seating = seating;
  self.devices = all;
  if (changed) [_miiForDevice removeAllObjects];
  // A controller coming or going makes the runtime lay Config.toml's shared bindings over every port
  // again; each controller's own profile goes back on top on the next tick.
  if (added.count || gone.count) [KPControllers().applied removeAllObjects];

  for (KPPadDevice *pad in pads) [self updateLight:pad];
  // The first moments after launch are the pads that were already on: no toast for those.
  const BOOL announce = !self.quiet && now - _startedAt > 4;
  if (announce) {
    for (KPPadDevice *pad in added) [self announceConnected:pad];
    for (KPPadDevice *pad in gone) [self announceGone:pad];
  }
  for (KPPadDevice *pad in pads) [self checkBattery:pad announce:announce];
  if (changed)
    for (id<KPRosterListener> listener in self.listeners.allObjects) [listener rosterChanged];
}

#pragma mark Lights

// A pad with a colour light glows in its player's colour; a pad that isn't playing glows dim white.
- (void)updateLight:(KPPadDevice *)device {
  if (!device.hasLight) return;
  NSNumber *last = _lightSlot[device.identifier];
  if (last && last.intValue == device.slot) return;
  _lightSlot[device.identifier] = @(device.slot);
  SDL_Gamepad *pad = device.gamepad;
  if (pad == nullptr) return;
  if (device.slot >= 0) {
    const unsigned char *rgb = KPPlayerLights[device.slot];
    SDL_SetGamepadLED(pad, rgb[0], rgb[1], rgb[2]);
    PADSetColor(device.slot, rgb[0], rgb[1], rgb[2]);
  } else {
    SDL_SetGamepadLED(pad, 40, 40, 40);
  }
}

// "This one is me": two buzzes and the light flashing white, the card answering on screen.
- (void)identify:(KPPadDevice *)device {
  AppendSessionLine([NSString stringWithFormat:@"controllerIdentify=%@", device.name]);
  SDL_Gamepad *pad = device.gamepad;
  if (pad == nullptr) return;
  const SDL_JoystickID joystick = device.joystick;
  for (int pulse = 0; pulse < 3; ++pulse) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(pulse * 0.32 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
      SDL_Gamepad *live = SDL_GetGamepadFromID(joystick);
      if (live == nullptr) return;
      if (pulse < 2 && device.canRumble) SDL_RumbleGamepad(live, 0xb000, 0xd000, 180);
      if (device.hasLight) SDL_SetGamepadLED(live, 255, 255, 255);
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((pulse * 0.32 + 0.16) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
      SDL_Gamepad *live = SDL_GetGamepadFromID(joystick);
      if (live == nullptr || !device.hasLight) return;
      if (device.slot >= 0) {
        const unsigned char *rgb = KPPlayerLights[device.slot];
        SDL_SetGamepadLED(live, rgb[0], rgb[1], rgb[2]);
      } else {
        SDL_SetGamepadLED(live, 40, 40, 40);
      }
    });
  }
}

#pragma mark Players

// Puts a controller on a player. Whoever was there swaps to where it came from (or stops playing),
// so every player keeps exactly one controller. The game's own Register Controllers screen still
// decides who races; this is the port each controller reports on, as Settings set it before.
- (void)move:(KPPadDevice *)device toSlot:(int)slot {
  if (device == nil) return;
  const int from = device.slot;
  if (from == slot) {
    // Already there: the keyboard is now pinned there rather than following free players.
    if (device.isKeyboard) [NSUserDefaults.standardUserDefaults setObject:@(slot) forKey:KPKeyboardPlayerKey];
    return;
  }
  KPPadDevice *occupant = slot >= 0 ? [self deviceInSlot:slot] : nil;
  NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
  auto placePad = [](KPPadDevice *pad, int port) {
    SDL_Gamepad *gamepad = pad.gamepad;
    if (gamepad == nullptr) return;
    const int current = KPPortForGamepad(gamepad);
    if (port < 0) {
      if (current >= 0) PADClearPort(current);
      return;
    }
    Wup028Adapter::SetPortAssignment(port, -1);
    const int index = KPIndexForGamepad(gamepad);
    if (index >= 0) PADSetPortForIndex(index, port);
  };
  if (device.isKeyboard) {
    [defaults setObject:@(slot) forKey:KPKeyboardPlayerKey];
    if (occupant && !occupant.isKeyboard) placePad(occupant, from);
    [self placeKeyboardOn:slot];
  } else {
    if (occupant.isKeyboard) {
      // The keyboard steps to the pad's old player (or the first free one).
      if (from >= 0) [defaults setObject:@(from) forKey:KPKeyboardPlayerKey];
      else [defaults removeObjectForKey:KPKeyboardPlayerKey];
      [self placeKeyboardOn:from];
    } else if (occupant) {
      placePad(occupant, from);
    }
    placePad(device, slot);
    // A pad taking the keyboard's player while the keyboard just follows free players: it moves on.
    if (slot >= 0 && slot == KPKeyboardPort() && ![[defaults objectForKey:KPKeyboardPlayerKey] isKindOfClass:NSNumber.class])
      [self placeKeyboardOn:-1];
  }
  [KPControllers().applied removeAllObjects];
  if (slot >= 0) [_benched removeObject:device.identifier];
  AppendSessionLine([NSString stringWithFormat:@"controllerMove=%@; player=%d", device.name, slot + 1]);
  _lightSlot[device.identifier] = nil;
  if (occupant) _lightSlot[occupant.identifier] = nil;
  _keyboardMovedAt = NSProcessInfo.processInfo.systemUptime;
  [self refresh];
}

#pragma mark Miis

// Miis label controllers so players can tell them apart; they don't change who races in the game.
// A pad remembers its Mii; identical pads that can't be told apart (no serial) share their player's.
- (NSArray<NSDictionary *> *)miiRecords {
  const NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
  if (_miiRecords == nil || now - _miiRecordsAt > 5) {
    _miiRecords = KartPadMiiRecords(nil);
    _miiRecordsAt = now;
    NSMutableDictionary<NSString *, NSDictionary *> *byID = [NSMutableDictionary dictionary];
    for (NSDictionary *record in _miiRecords) {
      NSString *key = KPHex(record[@"createIdBytes"]);
      if (byID[key] == nil) byID[key] = record;
    }
    _miiByID = byID;
    [_miiForDevice removeAllObjects];
  }
  return _miiRecords;
}
- (void)forgetMiiRecords { _miiRecords = nil; }
- (NSString *)miiKeyFor:(KPPadDevice *)device { return device.isKeyboard ? @"keyboard" : device.profileKey; }
- (NSDictionary *)miiRecordFor:(KPPadDevice *)device {
  if (device == nil) return nil;
  [self miiRecords];  // read again every few seconds
  if (id known = _miiForDevice[device.identifier]) return known == NSNull.null ? nil : known;
  NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
  NSString *wanted = nil;
  if (!device.twin) wanted = [defaults dictionaryForKey:KPControllerMiisKey][[self miiKeyFor:device]];
  if (!wanted && device.slot >= 0) wanted = [defaults dictionaryForKey:KPPlayerMiisKey][[@(device.slot) stringValue]];
  NSDictionary *record = [wanted isKindOfClass:NSString.class] ? _miiByID[wanted] : nil;
  if (device.identifier) _miiForDevice[device.identifier] = record ?: NSNull.null;
  return record;
}
- (NSData *)miiFor:(KPPadDevice *)device { return [self miiRecordFor:device][@"mii"]; }
- (void)setMii:(NSDictionary *)record forDevice:(KPPadDevice *)device {
  NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
  NSString *value = record ? KPHex(record[@"createIdBytes"]) : nil;
  NSString *key = device.twin ? KPPlayerMiisKey : KPControllerMiisKey;
  NSString *entry = device.twin ? [@(device.slot) stringValue] : [self miiKeyFor:device];
  if (entry == nil || (device.twin && device.slot < 0)) return;
  NSMutableDictionary *map = [[defaults dictionaryForKey:key] mutableCopy] ?: [NSMutableDictionary dictionary];
  if (value) map[entry] = value;
  else [map removeObjectForKey:entry];
  [defaults setObject:map forKey:key];
  [_miiForDevice removeAllObjects];
  for (id<KPRosterListener> listener in self.listeners.allObjects) [listener rosterChanged];
}

@end

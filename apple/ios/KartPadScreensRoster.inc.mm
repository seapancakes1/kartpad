// Every controller as players see it, on iPhone and iPad: the same KPPadDevice and
// KPControllerRoster the Mac screens read (apple/macos/KartPadControllerRoster.inc.mm), filled
// from GameController. Who plays as whom is KartPadPhysicalControllers' (the game reads players
// from there); the touch screen is player 1 while no controller is. Buttons and sticks are kept in
// SDL's gamepad numbering, the screens' vocabulary for drawing controllers, and the pads' lights
// follow the players' colours as on the Mac. Included by KartPadScreensPlatform.inc.mm.

#import "KartPadPhysicalControllers.h"
#import <CoreHaptics/CoreHaptics.h>
__asm__(".linker_option \"-framework\", \"CoreHaptics\"");

typedef NS_ENUM(NSInteger, KPPadFamily) {
  KPFamilyKeyboard, KPFamilyXbox, KPFamilyPlayStation, KPFamilySwitch, KPFamilyJoyCon,
  KPFamilyWiiRemote, KPFamilyGameCube, KPFamilyGeneric,
  KPFamilyPhone  // the touch screen
};

static constexpr int KPPlayerCount = 4;
static NSString *const KPControllerMiisKey = @"KartPadControllerMiis";  // profile key → Mii create ID (hex)
static NSString *const KPPlayerMiisKey = @"KartPadPlayerMiis";          // "0"–"3" → Mii create ID, for twin pads
static NSString *const KPTouchIdentifier = @"touch";

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
@property(nonatomic, copy) NSString *identifier;  // "sdl:<n>" (KartPad's own n) or "touch"
@property(nonatomic) SDL_JoystickID joystick;     // a number of KartPad's own, never SDL's
@property(nonatomic) KPPadFamily family;
@property(nonatomic, copy) NSString *name, *systemName, *profileKey;
@property(nonatomic, copy) NSString *stableKey;
@property(nonatomic) int slot;          // 0–3, -1 when not playing
@property(nonatomic) int battery;       // percent, -1 unknown
@property(nonatomic) BOOL charging, wired, canRumble, hasLight, twin;
@property(nonatomic) uint64_t buttons;  // held, as SDL gamepad button bits
@property(nonatomic) NSTimeInterval lastInput, connectedAt;
@property(nonatomic) NSInteger rawCount;
@property(nonatomic, weak) GCController *controller;  // nil for the touch screen
@property(nonatomic, strong) CHHapticEngine *haptics;
- (BOOL)isKeyboard;
- (BOOL)isPhone;
- (BOOL)isTouch;
- (SDL_Gamepad *)gamepad;
@end

// The screens pass a device's gamepad to the label functions (KPButtonLabel, KPPadFaceButtons): here
// it is a token for the device itself, which only KPDeviceForGamepad reads. Nothing hands it to SDL.
static NSHashTable<KPPadDevice *> *KPLiveDevices() {
  static NSHashTable *live;
  if (live == nil) live = [NSHashTable weakObjectsHashTable];
  return live;
}
static KPPadDevice *KPDeviceForGamepad(SDL_Gamepad *pad) {
  if (pad == nullptr) return nil;
  for (KPPadDevice *device in KPLiveDevices())
    if ((__bridge void *)device == (void *)pad) return device;
  return nil;
}

@implementation KPPadDevice
- (BOOL)isKeyboard { return NO; }
- (BOOL)isPhone { return self.family == KPFamilyPhone; }
- (BOOL)isTouch { return [self.identifier isEqualToString:KPTouchIdentifier]; }
- (SDL_Gamepad *)gamepad { return self.controller ? (SDL_Gamepad *)(__bridge void *)self : nullptr; }
@end

static BOOL KPIsWiiRemoteName(const char *name) { return name != nullptr && strncmp(name, "Nintendo Wii Remote", 19) == 0; }

static KPPadFamily KPFamilyForController(GCController *controller) {
  NSString *category = (controller.productCategory ?: @"").lowercaseString;
  NSString *vendor = (controller.vendorName ?: @"").lowercaseString;
  if ([controller.extendedGamepad isKindOfClass:GCDualSenseGamepad.class] ||
      [controller.extendedGamepad isKindOfClass:GCDualShockGamepad.class] || [category containsString:@"dualshock"] ||
      [category containsString:@"dualsense"])
    return KPFamilyPlayStation;
  if ([controller.extendedGamepad isKindOfClass:GCXboxGamepad.class] || [category containsString:@"xbox"]) return KPFamilyXbox;
  if ([category containsString:@"joy-con"] || [vendor containsString:@"joy-con"]) return KPFamilyJoyCon;
  if ([category containsString:@"switch"] || [category containsString:@"pro controller"] || [vendor containsString:@"pro controller"])
    return KPFamilySwitch;
  if ([category containsString:@"gamecube"] || [vendor containsString:@"gamecube"]) return KPFamilyGameCube;
  return KPFamilyGeneric;
}

static NSString *KPFriendlyNameForController(GCController *controller, KPPadFamily family) {
  NSString *category = controller.productCategory ?: @"", *vendor = controller.vendorName ?: @"";
  switch (family) {
    case KPFamilyXbox: return @"Xbox controller";
    case KPFamilyPlayStation:
      if ([category.lowercaseString containsString:@"dualsense"])
        return [category.lowercaseString containsString:@"edge"] ? @"DualSense Edge" : @"DualSense";
      return @"DualShock 4";
    case KPFamilySwitch: return @"Pro Controller";
    case KPFamilyJoyCon:
      if ([category containsString:@"(L/R)"] || [vendor containsString:@"(L/R)"]) return @"Joy‑Con pair";
      if ([category containsString:@"(L)"] || [vendor containsString:@"(L)"]) return @"Joy‑Con (L)";
      if ([category containsString:@"(R)"] || [vendor containsString:@"(R)"]) return @"Joy‑Con (R)";
      return @"Joy‑Con";
    case KPFamilyGameCube: return @"GameCube controller";
    case KPFamilyPhone: return @"Touch screen";
    default:
      if ([vendor.lowercaseString containsString:@"8bitdo"]) return @"8BitDo controller";
      return vendor.length && vendor.length <= 24 && ![vendor isEqualToString:@"Controller"] ? vendor : @"Controller";
  }
}

// The button that opens HOME, as the controller in hand shows it. On iPhone and iPad it's the Menu
// button, held, wherever the system keeps the HOME / PS / Xbox button for itself.
static NSString *KPHomeButtonName(KPPadFamily family) {
  switch (family) {
    case KPFamilyPlayStation: return @"Options";
    case KPFamilySwitch:
    case KPFamilyJoyCon:
    case KPFamilyWiiRemote: return @"+";
    case KPFamilyGameCube: return @"Start";
    case KPFamilyPhone: return @"⋯";
    default: return @"Menu";
  }
}

// The profile a controller's settings are kept under: its kind and name.
static NSString *KPProfileKeyForController(GCController *controller) {
  return [NSString stringWithFormat:@"gc:%@|%@", controller.productCategory ?: @"", controller.vendorName ?: @""];
}

// A controller's state in SDL's numbering (the controller drawings light the buttons held).
static uint64_t KPSDLButtonsFor(GCController *controller, float *axes) {
  for (int axis = 0; axis < SDL_GAMEPAD_AXIS_COUNT; ++axis) axes[axis] = 0;
  uint64_t held = 0;
  auto set = [&](SDL_GamepadButton button, BOOL down) {
    if (down) held |= 1ull << button;
  };
  if (GCExtendedGamepad *pad = controller.extendedGamepad) {
    set(SDL_GAMEPAD_BUTTON_SOUTH, pad.buttonA.isPressed);
    set(SDL_GAMEPAD_BUTTON_EAST, pad.buttonB.isPressed);
    set(SDL_GAMEPAD_BUTTON_WEST, pad.buttonX.isPressed);
    set(SDL_GAMEPAD_BUTTON_NORTH, pad.buttonY.isPressed);
    set(SDL_GAMEPAD_BUTTON_LEFT_SHOULDER, pad.leftShoulder.isPressed);
    set(SDL_GAMEPAD_BUTTON_RIGHT_SHOULDER, pad.rightShoulder.isPressed);
    set(SDL_GAMEPAD_BUTTON_START, pad.buttonMenu.isPressed);
    set(SDL_GAMEPAD_BUTTON_BACK, pad.buttonOptions.isPressed);
    set(SDL_GAMEPAD_BUTTON_GUIDE, pad.buttonHome.isPressed);
    set(SDL_GAMEPAD_BUTTON_LEFT_STICK, pad.leftThumbstickButton.isPressed);
    set(SDL_GAMEPAD_BUTTON_RIGHT_STICK, pad.rightThumbstickButton.isPressed);
    set(SDL_GAMEPAD_BUTTON_DPAD_UP, pad.dpad.up.isPressed);
    set(SDL_GAMEPAD_BUTTON_DPAD_DOWN, pad.dpad.down.isPressed);
    set(SDL_GAMEPAD_BUTTON_DPAD_LEFT, pad.dpad.left.isPressed);
    set(SDL_GAMEPAD_BUTTON_DPAD_RIGHT, pad.dpad.right.isPressed);
    // SDL's sticks run downwards on y.
    axes[SDL_GAMEPAD_AXIS_LEFTX] = pad.leftThumbstick.xAxis.value;
    axes[SDL_GAMEPAD_AXIS_LEFTY] = -pad.leftThumbstick.yAxis.value;
    axes[SDL_GAMEPAD_AXIS_RIGHTX] = pad.rightThumbstick.xAxis.value;
    axes[SDL_GAMEPAD_AXIS_RIGHTY] = -pad.rightThumbstick.yAxis.value;
    axes[SDL_GAMEPAD_AXIS_LEFT_TRIGGER] = pad.leftTrigger.value;
    axes[SDL_GAMEPAD_AXIS_RIGHT_TRIGGER] = pad.rightTrigger.value;
  } else if (GCMicroGamepad *micro = controller.microGamepad) {
    set(SDL_GAMEPAD_BUTTON_SOUTH, micro.buttonA.isPressed);
    set(SDL_GAMEPAD_BUTTON_WEST, micro.buttonX.isPressed);
    set(SDL_GAMEPAD_BUTTON_START, micro.buttonMenu.isPressed);
    axes[SDL_GAMEPAD_AXIS_LEFTX] = micro.dpad.xAxis.value;
    axes[SDL_GAMEPAD_AXIS_LEFTY] = -micro.dpad.yAxis.value;
  }
  return held;
}

@protocol KPRosterListener <NSObject>
- (void)rosterChanged;
@end

@interface KPControllerRoster : NSObject
@property(nonatomic, strong) NSArray<KPPadDevice *> *devices;  // the touch screen first, then pads by player
@property(nonatomic, strong) KPPadDevice *lastActive;
@property(nonatomic, strong) NSHashTable<id<KPRosterListener>> *listeners;
@property(nonatomic) BOOL quiet;  // the Controllers screen animates changes itself; no toasts meanwhile
@property(nonatomic, strong) KPPadDevice *leaving;
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

@interface KPControllerRoster (Toasts)
- (void)announceConnected:(KPPadDevice *)device;
- (void)announceGone:(KPPadDevice *)device;
- (void)checkBattery:(KPPadDevice *)device announce:(BOOL)announce;
@end

static void KPHintDeviceChanged();  // KartPadHints.inc.mm

@implementation KPControllerRoster {
  NSMapTable<GCController *, KPPadDevice *> *_known;
  KPPadDevice *_touch;
  NSMutableDictionary<NSString *, NSNumber *> *_lightColor;
  SDL_JoystickID _nextID;
  BOOL _started;
  NSTimeInterval _startedAt;
  NSArray<NSDictionary *> *_miiRecords;
  NSTimeInterval _miiRecordsAt;
  NSDictionary<NSString *, NSDictionary *> *_miiByID;
  NSMutableDictionary<NSString *, id> *_miiForDevice;
  NSString *_seating;
}
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
    _known = [NSMapTable weakToStrongObjectsMapTable];
    _lightColor = [NSMutableDictionary dictionary];
    _devices = @[];
    _listeners = [NSHashTable weakObjectsHashTable];
    _benched = [NSMutableSet set];
    _miiForDevice = [NSMutableDictionary dictionary];
    _nextID = 1;
    _touch = [KPPadDevice new];
    _touch.identifier = KPTouchIdentifier;
    _touch.family = KPFamilyPhone;
    _touch.name = UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad ? @"Touch screen (iPad)" : @"Touch screen";
    _touch.systemName = @"Touch screen";
    _touch.profileKey = KPTouchIdentifier;
    _touch.battery = -1;
    _touch.joystick = 0;
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

- (void)refresh {
  const NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
  if (!_started) {
    _started = YES;
    _startedAt = now;
  }
  KartPadPhysicalControllers *physical = [KartPadPhysicalControllers sharedControllers];
  NSMutableArray<KPPadDevice *> *pads = [NSMutableArray array];
  NSMutableDictionary<NSString *, NSNumber *> *keyCounts = [NSMutableDictionary dictionary];
  NSMutableSet<GCController *> *seen = [NSMutableSet set];
  for (GCController *controller in GCController.controllers) {
    if (controller.extendedGamepad == nil && controller.microGamepad == nil) continue;
    KPPadDevice *device = [_known objectForKey:controller];
    if (device == nil) {
      device = [KPPadDevice new];
      device.controller = controller;
      device.joystick = _nextID++;
      device.identifier = [NSString stringWithFormat:@"sdl:%u", device.joystick];  // the Mac's form, which the screens look up
      device.family = KPFamilyForController(controller);
      device.name = KPFriendlyNameForController(controller, device.family);
      device.systemName = controller.vendorName ?: @"Controller";
      device.profileKey = KPProfileKeyForController(controller);
      device.connectedAt = now;
      device.canRumble = controller.haptics != nil;
      device.hasLight = controller.light != nil;
      [_known setObject:device forKey:controller];
      [KPLiveDevices() addObject:device];
    }
    [seen addObject:controller];
    device.slot = -1;
    for (int slot = 0; slot < KPPlayerCount; ++slot)
      if ([physical controllerForPlayer:slot] == controller) device.slot = slot;
    GCDeviceBattery *battery = controller.battery;
    device.battery = battery && battery.batteryState != GCDeviceBatteryStateUnknown ? (int)std::lround(battery.batteryLevel * 100) : -1;
    device.charging = battery.batteryState == GCDeviceBatteryStateCharging || battery.batteryState == GCDeviceBatteryStateFull;
    device.wired = NO;
    const uint64_t held = KPSDLButtonsFor(controller, device->axes);
    bool moved = false;
    for (int axis = 0; axis < SDL_GAMEPAD_AXIS_COUNT; ++axis)
      moved |= std::fabs(device->axes[axis]) > (axis >= SDL_GAMEPAD_AXIS_LEFT_TRIGGER ? 0.3f : 0.5f);
    if ((held & ~device.buttons) || (moved && now - device.lastInput > 0.5)) {
      device.lastInput = now;
      self.lastActive = device;
    }
    device.buttons = held;
    keyCounts[device.profileKey] = @(keyCounts[device.profileKey].intValue + 1);
    [pads addObject:device];
  }
  for (KPPadDevice *pad in pads) pad.twin = keyCounts[pad.profileKey].intValue > 1;
  // The touch screen plays as player 1 while no controller does.
  _touch.slot = [physical controllerForPlayer:0] ? -1 : 0;

  NSMutableArray<KPPadDevice *> *gone = [NSMutableArray array];
  for (GCController *controller in _known.keyEnumerator.allObjects) {
    if ([seen containsObject:controller]) continue;
    [gone addObject:[_known objectForKey:controller]];
    [_known removeObjectForKey:controller];
  }
  // A controller that has gone (its GCController released) may have left its device behind.
  NSMutableSet<KPPadDevice *> *present = [NSMutableSet setWithArray:pads];
  for (KPPadDevice *device in self.devices)
    if (!device.isTouch && ![present containsObject:device] && ![gone containsObject:device]) [gone addObject:device];
  NSArray<KPPadDevice *> *previous = self.devices;
  NSMutableArray<KPPadDevice *> *added = [NSMutableArray array];
  for (KPPadDevice *pad in pads)
    if (![previous containsObject:pad]) [added addObject:pad];
  if (self.lastActive && ![present containsObject:self.lastActive]) self.lastActive = nil;

  [pads sortUsingComparator:^NSComparisonResult(KPPadDevice *a, KPPadDevice *b) {
    const int sa = a.slot < 0 ? 99 : a.slot, sb = b.slot < 0 ? 99 : b.slot;
    if (sa != sb) return sa < sb ? NSOrderedAscending : NSOrderedDescending;
    return a.connectedAt < b.connectedAt ? NSOrderedAscending : NSOrderedDescending;
  }];
  // The touch screen is listed only while it plays (it can't be moved to another player).
  NSMutableArray *all = _touch.slot >= 0 ? [NSMutableArray arrayWithObject:_touch] : [NSMutableArray array];
  [all addObjectsFromArray:pads];
  NSMutableString *seating = [NSMutableString string];
  for (KPPadDevice *device in all) [seating appendFormat:@"%@=%d;", device.identifier, device.slot];
  const BOOL changed = added.count || gone.count || ![seating isEqualToString:_seating ?: @""];
  _seating = seating;
  self.devices = all;
  if (changed) [_miiForDevice removeAllObjects];

  for (KPPadDevice *pad in pads) [self updateLight:pad];
  const BOOL announce = !self.quiet && now - _startedAt > 4;
  if (announce) {
    for (KPPadDevice *pad in added) [self announceConnected:pad];
    for (KPPadDevice *pad in gone) {
      self.leaving = pad;
      [self announceGone:pad];
      self.leaving = nil;
    }
  }
  for (KPPadDevice *pad in pads) [self checkBattery:pad announce:announce];
  if (changed)
    for (id<KPRosterListener> listener in self.listeners.allObjects) [listener rosterChanged];
}

#pragma mark Lights

static const unsigned char KPMiiLights[11][3] = {{255, 0, 0},   {255, 60, 0},  {255, 170, 0},  {110, 255, 0},
                                                 {0, 255, 40},  {0, 70, 255},  {0, 190, 255},  {255, 30, 110},
                                                 {140, 0, 255}, {160, 50, 0},  {255, 255, 255}};

// A playing pad glows in its Mii's favourite colour, or its player's colour without one; a pad that
// isn't playing glows dim white.
- (unsigned)lightFor:(KPPadDevice *)device {
  if (device.slot < 0) return 0x282828;
  const unsigned char *rgb = KPPlayerLights[device.slot];
  NSNumber *favorite = [self miiRecordFor:device][@"favoriteColor"];
  if (favorite && favorite.unsignedIntValue < std::size(KPMiiLights)) rgb = KPMiiLights[favorite.unsignedIntValue];
  return rgb[0] << 16 | rgb[1] << 8 | rgb[2];
}

static void KPSetLight(GCController *controller, unsigned light) {
  controller.light.color = [[GCColor alloc] initWithRed:(light >> 16) / 255.0f green:((light >> 8) & 255) / 255.0f
                                                   blue:(light & 255) / 255.0f];
}

- (void)updateLight:(KPPadDevice *)device {
  if (!device.hasLight || device.controller == nil) return;
  const unsigned light = [self lightFor:device];
  NSNumber *last = _lightColor[device.identifier];
  if (last && last.unsignedIntValue == light) return;
  _lightColor[device.identifier] = @(light);
  KPSetLight(device.controller, light);
}

// A short buzz on the controller's own motors (CoreHaptics), where it has them.
static void KPBuzz(KPPadDevice *device, NSTimeInterval seconds, float strength) {
  GCController *controller = device.controller;
  if (controller.haptics == nil || strength <= 0) return;
  if (device.haptics == nil) {
    device.haptics = [controller.haptics createEngineWithLocality:GCHapticsLocalityDefault];
    device.haptics.playsHapticsOnly = YES;
    device.haptics.autoShutdownEnabled = YES;
  }
  NSError *error = nil;
  if (![device.haptics startAndReturnError:&error]) return;
  CHHapticEvent *event = [[CHHapticEvent alloc]
      initWithEventType:CHHapticEventTypeHapticContinuous
             parameters:@[[[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticIntensity
                                                                       value:std::clamp(strength, 0.0f, 1.0f)]]
           relativeTime:0
               duration:seconds];
  CHHapticPattern *pattern = [[CHHapticPattern alloc] initWithEvents:@[event] parameters:@[] error:&error];
  if (pattern == nil) return;
  id<CHHapticPatternPlayer> player = [device.haptics createPlayerWithPattern:pattern error:&error];
  [player startAtTime:CHHapticTimeImmediate error:&error];
}

// "This one is me": two buzzes and the light flashing white, the card answering on screen.
- (void)identify:(KPPadDevice *)device {
  AppendSessionLine([NSString stringWithFormat:@"controllerIdentify=%@", device.name]);
  if (device.controller == nil) return;
  for (int pulse = 0; pulse < 3; ++pulse) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(pulse * 0.32 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
      if (device.controller == nil) return;
      if (pulse < 2) KPBuzz(device, 0.18, 0.8);
      if (device.hasLight) KPSetLight(device.controller, 0xffffff);
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((pulse * 0.32 + 0.16) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
      if (device.controller == nil || !device.hasLight) return;
      KPSetLight(device.controller, [self lightFor:device]);
    });
  }
}

#pragma mark Players

// Who plays as whom changes on Controllers (KartPadPhysicalControllers keeps it).
- (void)move:(KPPadDevice *)device toSlot:(int)slot {
  if (device == nil || device.isTouch) return;
  if (device.controller) [[KartPadPhysicalControllers sharedControllers] moveController:device.controller toPlayer:slot];
  if (slot >= 0) [_benched removeObject:device.identifier];
  else [_benched addObject:device.identifier];
  AppendSessionLine([NSString stringWithFormat:@"controllerMove=%@; player=%d", device.name, slot + 1]);
  [_lightColor removeAllObjects];
  [self refresh];
}

#pragma mark Miis

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
- (NSString *)miiKeyFor:(KPPadDevice *)device { return device.profileKey; }
- (NSDictionary *)miiRecordFor:(KPPadDevice *)device {
  if (device == nil) return nil;
  [self miiRecords];
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
  [_lightColor removeAllObjects];
  for (id<KPRosterListener> listener in self.listeners.allObjects) [listener rosterChanged];
}

@end

#pragma mark Button names

// The buttons a pad confirms, goes back and does X and Y with in KartPad's screens: positions on
// most pads, and on Nintendo's own (A on the right, B at the bottom) their letters, unless the
// game plays them by position (Settings › Controls › Nintendo button layout).
struct KPPadFace {
  SDL_GamepadButton a, b, x, y;
};
static KPPadFace KPPadFaceButtons(SDL_Gamepad *pad) {
  KPPadDevice *device = KPDeviceForGamepad(pad);
  // As the game reads it (KartPadPhysicalControllers.mm), so menus confirm with the game's A.
  if (device.controller && KartPadNintendoLayoutEnabled() && KartPadControllerHasNintendoFace(device.controller))
    return {SDL_GAMEPAD_BUTTON_EAST, SDL_GAMEPAD_BUTTON_SOUTH, SDL_GAMEPAD_BUTTON_NORTH, SDL_GAMEPAD_BUTTON_WEST};
  return {SDL_GAMEPAD_BUTTON_SOUTH, SDL_GAMEPAD_BUTTON_EAST, SDL_GAMEPAD_BUTTON_WEST, SDL_GAMEPAD_BUTTON_NORTH};
}

// What a button is called on the pad in hand ("A", "Cross", "LB").
static NSString *KPButtonLabel(SDL_Gamepad *pad, int button) {
  KPPadDevice *device = KPDeviceForGamepad(pad);
  const KPPadFamily family = device ? device.family : KPFamilyXbox;
  const bool ps = family == KPFamilyPlayStation, nintendo = family == KPFamilySwitch || family == KPFamilyJoyCon;
  if (button >= 0 && button < 4) {
    if (ps) return @[@"Cross", @"Circle", @"Square", @"Triangle"][button];
    if (nintendo) return @[@"B", @"A", @"Y", @"X"][button];
    if (family == KPFamilyGameCube) return @[@"A", @"X", @"B", @"Y"][button];
    return @[@"A", @"B", @"X", @"Y"][button];
  }
  switch (button) {
    case SDL_GAMEPAD_BUTTON_BACK: return ps ? @"Share" : nintendo ? @"−" : @"View";
    case SDL_GAMEPAD_BUTTON_START: return ps ? @"Options" : nintendo ? @"+" : @"Menu";
    case SDL_GAMEPAD_BUTTON_LEFT_SHOULDER: return ps ? @"L1" : nintendo ? @"L" : @"LB";
    case SDL_GAMEPAD_BUTTON_RIGHT_SHOULDER: return ps ? @"R1" : nintendo ? @"R" : @"RB";
    case SDL_GAMEPAD_BUTTON_LEFT_STICK: return ps ? @"L3" : @"Left stick";
    case SDL_GAMEPAD_BUTTON_RIGHT_STICK: return ps ? @"R3" : @"Right stick";
    case SDL_GAMEPAD_BUTTON_GUIDE: return ps ? @"PS" : @"HOME";
    case SDL_GAMEPAD_BUTTON_DPAD_UP: return @"D-pad up";
    case SDL_GAMEPAD_BUTTON_DPAD_DOWN: return @"D-pad down";
    case SDL_GAMEPAD_BUTTON_DPAD_LEFT: return @"D-pad left";
    case SDL_GAMEPAD_BUTTON_DPAD_RIGHT: return @"D-pad right";
    default: return @"Unbound";
  }
}

// The touch screen's drawing, where the Mac draws a phone playing through its controller page: a
// handset with the stick and buttons on it.
static void KPDrawPhoneArt(CGContextRef c, CGRect r, unsigned accent) {
  const CGFloat w = std::min(r.size.width, r.size.height * 2.1), h = w / 2.1;
  const CGRect body = CGRectMake(CGRectGetMidX(r) - w / 2, CGRectGetMidY(r) - h / 2, w, h);
  KPFill(c, body, 0x1d2027, h * 0.18);
  const CGRect screen = CGRectInset(body, h * 0.07, h * 0.07);
  KPFill(c, screen, 0x2a2f39, h * 0.12);
  const CGFloat u = screen.size.height;
  KPSetInk(c, 0xffffff, 0.18);
  CGContextFillEllipseInRect(c, CGRectMake(screen.origin.x + u * 0.22, screen.origin.y + u * 0.28, u * 0.5, u * 0.5));
  KPSetInk(c, accent);
  CGContextFillEllipseInRect(c, CGRectMake(screen.origin.x + u * 0.37, screen.origin.y + u * 0.43, u * 0.2, u * 0.2));
  CGContextFillEllipseInRect(c, CGRectMake(CGRectGetMaxX(screen) - u * 0.55, screen.origin.y + u * 0.42, u * 0.42, u * 0.42));
  KPSetInk(c, 0xffffff, 0.35);
  CGContextFillEllipseInRect(c, CGRectMake(CGRectGetMaxX(screen) - u * 0.95, screen.origin.y + u * 0.5, u * 0.3, u * 0.3));
  CGContextFillEllipseInRect(c, CGRectMake(CGRectGetMaxX(screen) - u * 0.45, screen.origin.y + u * 0.1, u * 0.24, u * 0.24));
}

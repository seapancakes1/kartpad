// Pairing flow derived from Dolphin WiimotePair and WiimotePairPlus.
// Copyright 2024 Dolphin Emulator Project
// Copyright 2026 Gabriel Lascoski Ferraz
// SPDX-License-Identifier: GPL-2.0-or-later

#import "KartPadWiimotePairing.h"

#import <AppKit/AppKit.h>
#import <IOBluetooth/IOBluetooth.h>
#import <IOKit/IOKitLib.h>
#import <IOKit/hid/IOHIDKeys.h>
#import <IOKit/hid/IOHIDManager.h>

#include <SDL3/SDL_gamepad.h>
#include <SDL3/SDL_hints.h>
#include <SDL3/SDL_joystick.h>

#include <cctype>
#include <cstring>

NSString *const KartPadExperimentalWiimoteDefaultsKey =
    @"KartPadExperimentalWiimoteEnabled";

@interface IOBluetoothCoreBluetoothCoordinator : NSObject
+ (IOBluetoothCoreBluetoothCoordinator *)sharedInstance;
- (void)pairPeer:(id)peer forType:(NSUInteger)type withKey:(NSNumber *)key;
@end

@interface IOBluetoothDevice (KartPadPrivatePairing)
- (id)classicPeer;
@end

@interface IOBluetoothDevicePair (KartPadPrivatePairing)
- (void)setUserDefinedPincode:(BOOL)enabled;
- (NSUInteger)currentPairingType;
@end

@interface KartPadWiimotePairController : NSObject
    <IOBluetoothDeviceInquiryDelegate, IOBluetoothDevicePairDelegate,
     NSWindowDelegate>
// Set for pairing from KartPad's own screen, which shows the status itself.
@property(nonatomic, copy) void (^statusHandler)(NSString *message, BOOL busy);
- (void)show;
- (void)beginPairing;
- (void)cancelPairingWork;
- (void)deviceMatched:(id)object;
@end

namespace {

NSString *const kSyntheticDeviceKey = @"GCSyntheticDevice";
// About a minute of searching, as for other controllers (kGamepadSearchRounds below): an inquiry
// slows other Bluetooth while it runs.
constexpr int kWiimoteSearchRounds = 6;
// How long SDL gets to open the remote once macOS has it, looked at every 300 ms.
constexpr int kHandoffChecks = 10;

NSNumber *HIDNumber(IOHIDDeviceRef device, CFStringRef key) {
  CFTypeRef value = IOHIDDeviceGetProperty(device, key);
  return value != nullptr && CFGetTypeID(value) == CFNumberGetTypeID()
      ? (__bridge NSNumber *)value : nil;
}

NSString *HIDString(IOHIDDeviceRef device, CFStringRef key) {
  CFTypeRef value = IOHIDDeviceGetProperty(device, key);
  return value != nullptr && CFGetTypeID(value) == CFStringGetTypeID()
      ? (__bridge NSString *)value : nil;
}

uint64_t HIDRegistryID(IOHIDDeviceRef device) {
  uint64_t identifier = 0;
  const io_service_t service = IOHIDDeviceGetService(device);
  if (service != IO_OBJECT_NULL) IORegistryEntryGetRegistryEntryID(service, &identifier);
  return identifier;
}

// A Bluetooth address as just its hex digits, lowercase. macOS writes it "00-1f-32-…", for the
// Bluetooth device and as the HID device's serial number, which SDL passes on as the pad's.
NSString *AddressDigits(NSString *address) {
  NSMutableString *digits = [NSMutableString string];
  for (NSUInteger i = 0; i < address.length; ++i) {
    const unichar c = [address characterAtIndex:i];
    if (c < 128 && isxdigit(c)) [digits appendFormat:@"%c", (char)tolower(c)];
  }
  return digits;
}

void DeviceMatched(void *context, IOReturn result, void *sender,
                   IOHIDDeviceRef device) {
  (void)sender;
  KartPadWiimotePairController *controller =
      (__bridge KartPadWiimotePairController *)context;
  [controller deviceMatched:(__bridge id)device];
  if (result != kIOReturnSuccess) {
    NSLog(@"[KartPad] Wii Remote HID match failed: 0x%x", result);
  }
}

// The Wii Remotes SDL has now, by SDL ID.
NSSet<NSNumber *> *ConnectedRemotes() {
  NSMutableSet<NSNumber *> *remotes = [NSMutableSet set];
  int count = 0;
  SDL_JoystickID *ids = SDL_GetGamepads(&count);
  for (int index = 0; index < count; ++index) {
    const char *name = SDL_GetGamepadNameForID(ids[index]);
    if (name != nullptr && strstr(name, "Nintendo Wii Remote") != nullptr) [remotes addObject:@(ids[index])];
  }
  SDL_free(ids);
  return remotes;
}

} // namespace

// Pairing keeps SDL's Wii driver on throughout, so the remotes already connected stay connected (and
// keep their SDL IDs): the new one pairs over Bluetooth, macOS publishes it, and SDL opens it as it
// does any remote that connects. The driver setting goes back to what it was afterwards, unless a
// remote connected meanwhile, which keeps it on for the rest of this run.
@implementation KartPadWiimotePairController {
  NSPanel *_panel;
  NSTextField *_status;
  NSProgressIndicator *_progress;
  NSButton *_doneButton;
  NSButton *_againButton;
  IOBluetoothDeviceInquiry *_inquiry;
  IOBluetoothDevicePair *_pair;
  IOBluetoothDevice *_bluetoothDevice;
  IOHIDManagerRef _hidManager;
  NSSet<NSNumber *> *_hidBefore;      // HID devices (registry IDs) there when the search began
  NSSet<NSNumber *> *_remotesBefore;  // SDL's remotes then
  NSString *_driverHintBefore;
  BOOL _driverHintOwned;
  BOOL _connected;
  BOOL _handedOff;
  int _rounds;
  NSUInteger _attempt;  // so a check left from an earlier attempt does nothing
}

- (void)dealloc {
  [self cancelPairingWork];
}

- (void)tearDownHIDManager {
  if (_hidManager != nullptr) {
    IOHIDManagerRegisterDeviceMatchingCallback(_hidManager, nullptr, nullptr);
    IOHIDManagerUnscheduleFromRunLoop(_hidManager, CFRunLoopGetMain(),
                                      kCFRunLoopDefaultMode);
    IOHIDManagerClose(_hidManager, kIOHIDOptionsTypeNone);
    CFRelease(_hidManager);
    _hidManager = nullptr;
  }
}

// SDL's Wii driver on while pairing, the setting before remembered for afterwards.
- (void)holdDriverOn {
  if (!_driverHintOwned) {
    const char *hint = SDL_GetHint(SDL_HINT_JOYSTICK_HIDAPI_WII);
    _driverHintBefore = hint ? [NSString stringWithUTF8String:hint] : nil;
    _driverHintOwned = YES;
  }
  SDL_SetHint(SDL_HINT_JOYSTICK_HIDAPI_WII, "1");
}

- (void)releaseDriver {
  if (!_driverHintOwned) return;
  _driverHintOwned = NO;
  if (_connected) return;  // the new remote stays connected
  if (_driverHintBefore) SDL_SetHint(SDL_HINT_JOYSTICK_HIDAPI_WII, _driverHintBefore.UTF8String);
  else SDL_ResetHint(SDL_HINT_JOYSTICK_HIDAPI_WII);
}

- (void)cancelPairingWork {
  ++_attempt;
  [_inquiry stop];
  _inquiry = nil;
  if (!_handedOff) [_pair stop];
  _pair = nil;
  [self tearDownHIDManager];
  [self releaseDriver];
}

- (void)closePairingPanel:(id)sender {
  (void)sender;
  [_panel close];
}

- (void)searchAgain:(id)sender {
  (void)sender;
  [self beginPairing];
}

- (void)windowWillClose:(NSNotification *)notification {
  (void)notification;
  [self cancelPairingWork];
}

- (void)setStatus:(NSString *)status spinning:(BOOL)spinning {
  if (self.statusHandler) self.statusHandler(status, spinning);
  _status.stringValue = status;
  _progress.hidden = !spinning;
  _againButton.hidden = spinning;
  if (spinning) [_progress startAnimation:nil];
  else [_progress stopAnimation:nil];
}

- (void)show {
  if (_panel == nil) {
    _panel = [[NSPanel alloc]
        initWithContentRect:NSMakeRect(0, 0, 520, 230)
                  styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable)
                    backing:NSBackingStoreBuffered defer:NO];
    _panel.title = @"Pair Wii Remote";
    _panel.releasedWhenClosed = NO;
    _panel.delegate = self;

    NSTextField *title = [NSTextField labelWithString:
        @"Press the red SYNC button inside the Wii Remote battery cover."];
    title.font = [NSFont systemFontOfSize:15 weight:NSFontWeightSemibold];
    title.maximumNumberOfLines = 2;
    title.lineBreakMode = NSLineBreakByWordWrapping;
    _status = [NSTextField labelWithString:@"Preparing Bluetooth…"];
    _status.maximumNumberOfLines = 3;
    _status.lineBreakMode = NSLineBreakByWordWrapping;
    _status.textColor = NSColor.secondaryLabelColor;
    _progress = [NSProgressIndicator new];
    _progress.style = NSProgressIndicatorStyleSpinning;
    _progress.controlSize = NSControlSizeSmall;
    [_progress startAnimation:nil];
    _doneButton = [NSButton buttonWithTitle:@"Close" target:self
                                     action:@selector(closePairingPanel:)];
    _againButton = [NSButton buttonWithTitle:@"Search Again" target:self
                                      action:@selector(searchAgain:)];
    _againButton.hidden = YES;
    NSStackView *statusRow = [NSStackView stackViewWithViews:@[_progress, _status]];
    statusRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    statusRow.alignment = NSLayoutAttributeCenterY;
    statusRow.spacing = 10;
    NSView *spacer = [NSView new];
    NSStackView *buttons = [NSStackView stackViewWithViews:@[spacer, _againButton, _doneButton]];
    buttons.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    [spacer setContentHuggingPriority:NSLayoutPriorityDefaultLow
                       forOrientation:NSLayoutConstraintOrientationHorizontal];
    NSTextField *note = [NSTextField labelWithString:
        @"Experimental. Connect the Nunchuk after the remote."];
    note.maximumNumberOfLines = 3;
    note.lineBreakMode = NSLineBreakByWordWrapping;
    note.textColor = NSColor.tertiaryLabelColor;
    NSStackView *content = [NSStackView stackViewWithViews:
        @[title, statusRow, note, buttons]];
    content.translatesAutoresizingMaskIntoConstraints = NO;
    content.orientation = NSUserInterfaceLayoutOrientationVertical;
    content.alignment = NSLayoutAttributeLeading;
    content.spacing = 16;
    _panel.contentView = [NSView new];
    [_panel.contentView addSubview:content];
    [NSLayoutConstraint activateConstraints:@[
      [content.leadingAnchor constraintEqualToAnchor:_panel.contentView.leadingAnchor constant:24],
      [content.trailingAnchor constraintEqualToAnchor:_panel.contentView.trailingAnchor constant:-24],
      [content.topAnchor constraintEqualToAnchor:_panel.contentView.topAnchor constant:24],
      [content.bottomAnchor constraintLessThanOrEqualToAnchor:_panel.contentView.bottomAnchor constant:-20],
      [title.widthAnchor constraintEqualToAnchor:content.widthAnchor],
      [statusRow.widthAnchor constraintEqualToAnchor:content.widthAnchor],
      [note.widthAnchor constraintEqualToAnchor:content.widthAnchor],
      [buttons.widthAnchor constraintEqualToAnchor:content.widthAnchor],
    ]];
  }
  [_panel center];
  [_panel makeKeyAndOrderFront:nil];
  [NSApp activateIgnoringOtherApps:YES];
  [self beginPairing];
}

- (void)beginPairing {
  ++_attempt;
  [_inquiry stop];
  _inquiry = nil;
  if (!_handedOff) [_pair stop];
  _pair = nil;
  // A remote paired earlier this run isn't the one this search is for.
  _bluetoothDevice = nil;
  _handedOff = NO;
  _rounds = 0;
  [self tearDownHIDManager];
  [self holdDriverOn];
  _remotesBefore = ConnectedRemotes();
  [self setStatus:@"Looking for a Wii Remote…"
         spinning:YES];
  [self setupHIDManager];
  _inquiry = [IOBluetoothDeviceInquiry inquiryWithDelegate:self];
  _inquiry.searchType = kIOBluetoothDeviceSearchClassic;
  IOReturn result = [_inquiry start];
  if (result != kIOReturnSuccess) {
    _inquiry = nil;
    [self setStatus:[NSString stringWithFormat:
        @"Bluetooth discovery could not start (0x%x). Check System Settings → Privacy & Security → Bluetooth.",
        result] spinning:NO];
  }
}

- (void)setupHIDManager {
  if (_hidManager != nullptr) return;
  _hidManager = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
  NSArray *matches = @[
    @{@kIOHIDVendorIDKey: @0x057e, @kIOHIDProductIDKey: @0x0306,
      kSyntheticDeviceKey: @NO},
    @{@kIOHIDVendorIDKey: @0x057e, @kIOHIDProductIDKey: @0x0330,
      kSyntheticDeviceKey: @NO},
  ];
  IOHIDManagerSetDeviceMatchingMultiple(_hidManager, (__bridge CFArrayRef)matches);
  IOHIDManagerRegisterDeviceMatchingCallback(_hidManager, DeviceMatched,
                                              (__bridge void *)self);
  IOHIDManagerScheduleWithRunLoop(_hidManager, CFRunLoopGetMain(),
                                  kCFRunLoopDefaultMode);
  IOHIDManagerOpen(_hidManager, kIOHIDOptionsTypeNone);
  NSMutableSet<NSNumber *> *before = [NSMutableSet set];
  CFSetRef devices = IOHIDManagerCopyDevices(_hidManager);
  if (devices != nullptr) {
    for (id object in (__bridge NSSet *)devices) [before addObject:@(HIDRegistryID((__bridge IOHIDDeviceRef)object))];
    CFRelease(devices);
  }
  _hidBefore = before;
}

// The HID device macOS published for the remote this search found: by its Bluetooth address, or
// where the device gives none, a remote of its kind that wasn't there when the search began.
- (BOOL)matchesPairedDevice:(IOHIDDeviceRef)device {
  if (_bluetoothDevice == nil) return NO;
  CFTypeRef synthetic = IOHIDDeviceGetProperty(
      device, (__bridge CFStringRef)kSyntheticDeviceKey);
  if (synthetic == kCFBooleanTrue) return NO;
  NSNumber *vendor = HIDNumber(device, CFSTR(kIOHIDVendorIDKey));
  NSNumber *product = HIDNumber(device, CFSTR(kIOHIDProductIDKey));
  if (vendor.unsignedIntegerValue != 0x057e) return NO;
  NSString *serial = AddressDigits(HIDString(device, CFSTR(kIOHIDSerialNumberKey)));
  NSString *address = AddressDigits(_bluetoothDevice.addressString);
  if (serial.length == 12 && address.length == 12) return [serial isEqualToString:address];
  if ([_hidBefore containsObject:@(HIDRegistryID(device))]) return NO;
  const BOOL remotePlus = [_bluetoothDevice.name containsString:@"-TR"];
  return product.unsignedIntegerValue == (remotePlus ? 0x0330 : 0x0306);
}

- (void)deviceMatched:(id)object {
  IOHIDDeviceRef device = (__bridge IOHIDDeviceRef)object;
  if (_handedOff || ![self matchesPairedDevice:device]) return;
  [self handOffToSDL];
}

// macOS has the remote: SDL's Wii driver, on all along, opens it as it does any remote that
// connects. KartPad doesn't open it too, so the two never set its reports at once.
- (void)handOffToSDL {
  _handedOff = YES;
  [self setStatus:@"Connecting…" spinning:YES];
  [self tearDownHIDManager];
  [self checkSDLHandoff:kHandoffChecks];
}

- (void)checkSDLHandoff:(int)checksLeft {
  const NSUInteger attempt = _attempt;
  __weak KartPadWiimotePairController *weakSelf = self;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 300 * NSEC_PER_MSEC),
                 dispatch_get_main_queue(), ^{
    KartPadWiimotePairController *controller = weakSelf;
    if (controller == nil || controller->_attempt != attempt) return;
    SDL_UpdateJoysticks();
    NSString *found = [controller arrivedRemote];
    if (found != nil) {
      controller->_connected = YES;
      [controller setStatus:[NSString stringWithFormat:
          @"Connected as %@. Attach the Nunchuk any time.",
          found] spinning:NO];
    } else if (checksLeft > 1) {
      [controller checkSDLHandoff:checksLeft - 1];
    } else {
      [controller setStatus:@"Paired. Press A on the Wii Remote."
                   spinning:NO];
    }
  });
}

// SDL's name for the remote this search found, once SDL has it: the remote with its Bluetooth
// address, or else one that wasn't connected when the search began.
- (NSString *)arrivedRemote {
  NSString *address = AddressDigits(_bluetoothDevice.addressString);
  NSString *found = nil;
  for (NSNumber *identifier in ConnectedRemotes()) {
    const char *name = SDL_GetGamepadNameForID(identifier.unsignedIntValue);
    if (name == nullptr) continue;
    SDL_Gamepad *pad = SDL_GetGamepadFromID(identifier.unsignedIntValue);
    const char *serial = pad ? SDL_GetGamepadSerial(pad) : nullptr;
    if (serial != nullptr && address.length == 12 && [AddressDigits(@(serial)) isEqualToString:address])
      return [NSString stringWithUTF8String:name];
    if (found == nil && ![_remotesBefore containsObject:identifier]) found = [NSString stringWithUTF8String:name];
  }
  return found;
}

- (void)preparePairedDevice:(IOBluetoothDevice *)device {
  _bluetoothDevice = device;
  [self setStatus:@"Paired. Connecting…" spinning:YES];
  CFSetRef devices = _hidManager != nullptr
      ? IOHIDManagerCopyDevices(_hidManager) : nullptr;
  if (devices != nullptr) {
    for (id object in (__bridge NSSet *)devices) {
      [self deviceMatched:object];
      if (_handedOff) break;
    }
    CFRelease(devices);
  }
}

- (void)deviceInquiryDeviceFound:(IOBluetoothDeviceInquiry *)sender
                          device:(IOBluetoothDevice *)device {
  if (![device.name hasPrefix:@"Nintendo RVL-CNT-01"]) return;
  [sender stop];
  if (device.isPaired) {
    [self preparePairedDevice:device];
    return;
  }
  _pair = [IOBluetoothDevicePair pairWithDevice:device];
  _pair.delegate = self;
  [_pair setUserDefinedPincode:YES];
  IOReturn result = [_pair start];
  if (result != kIOReturnSuccess) {
    [self setStatus:[NSString stringWithFormat:@"Pairing could not start (0x%x).", result]
           spinning:NO];
  } else {
    [self setStatus:@"Wii Remote found. Completing Bluetooth pairing…"
           spinning:YES];
  }
}

// The search goes round again until a remote turns up, for about a minute.
- (void)deviceInquiryComplete:(IOBluetoothDeviceInquiry *)sender
                         error:(IOReturn)error aborted:(BOOL)aborted {
  if (aborted || sender != _inquiry || _bluetoothDevice != nil) return;
  if (error == kIOReturnSuccess && ++_rounds < kWiimoteSearchRounds) {
    [sender clearFoundDevices];
    [sender start];
    return;
  }
  _inquiry = nil;
  [self setStatus:@"Didn't find one. Press SYNC, then Search Again." spinning:NO];
}

- (void)devicePairingPINCodeRequest:(id)sender {
  IOBluetoothDevicePair *pair = (IOBluetoothDevicePair *)sender;
  IOBluetoothDevice *device = pair.device;
  BluetoothDeviceAddress address{};
  IOBluetoothNSStringToDeviceAddress(
      IOBluetoothHostController.defaultController.addressAsString, &address);
  uint8_t reversed[6]{};
  for (int index = 0; index < 6; ++index) reversed[index] = address.data[5 - index];
  uint64_t key = 0;
  memcpy(&key, reversed, sizeof(reversed));
  [[IOBluetoothCoreBluetoothCoordinator sharedInstance]
      pairPeer:device.classicPeer forType:pair.currentPairingType withKey:@(key)];
}

- (void)devicePairingFinished:(id)sender error:(IOReturn)error {
  IOBluetoothDevicePair *pair = (IOBluetoothDevicePair *)sender;
  if (pair != _pair) return;
  if (error != kIOReturnSuccess) {
    [self setStatus:[NSString stringWithFormat:@"Bluetooth pairing failed (0x%x).", error]
           spinning:NO];
    [_pair stop];
    _pair = nil;
    return;
  }
  // Do not call -stop here. Remote Plus devices can power off before macOS
  // publishes their physical HID device when the pairing object is stopped.
  [self preparePairedDevice:pair.device];
}

@end

static KartPadWiimotePairController *gKartPadWiimotePairController;

void KartPadShowWiimotePairing(void) {
  if (gKartPadWiimotePairController == nil) {
    gKartPadWiimotePairController = [KartPadWiimotePairController new];
  }
  [gKartPadWiimotePairController show];
}

void KartPadApplyExperimentalWiimotePreference(void) {
  const BOOL enabled = [NSUserDefaults.standardUserDefaults
      boolForKey:KartPadExperimentalWiimoteDefaultsKey];
  SDL_SetHint(SDL_HINT_JOYSTICK_HIDAPI_WII, enabled ? "1" : "0");
}

// Pairing turns Wii Remote support on (Pair Wii Remote…); the classic Settings window can turn it
// off again. Pairing switches SDL's Wii driver on only while it needs it.
void KartPadBeginWiimotePairing(void (^status)(NSString *message, BOOL busy)) {
  if (gKartPadWiimotePairController == nil) {
    gKartPadWiimotePairController = [KartPadWiimotePairController new];
  }
  gKartPadWiimotePairController.statusHandler = status;
  [gKartPadWiimotePairController beginPairing];
}

void KartPadCancelWiimotePairing(void) {
  if (gKartPadWiimotePairController.statusHandler == nil) return;
  gKartPadWiimotePairController.statusHandler = nil;
  [gKartPadWiimotePairController cancelPairingWork];
}

#pragma mark Other Bluetooth controllers

// PlayStation, Switch and most other controllers use classic Bluetooth with "just works" pairing,
// so the public IOBluetooth calls are enough: search, pair, and let the controller open its HID
// link. macOS's HID driver then publishes it, and SDL and KartPad's roster see a new controller.
@interface KartPadGamepadPairController : NSObject
    <IOBluetoothDeviceInquiryDelegate, IOBluetoothDevicePairDelegate>
@property(nonatomic, copy) void (^statusHandler)(NSString *message, BOOL busy);
@property(nonatomic, copy) void (^logHandler)(NSString *line);
- (void)begin;
- (void)cancel;
@end

namespace {

// About a minute of searching: an inquiry slows other Bluetooth (headphones, connected
// controllers) while it runs, so it doesn't run for as long as the screen stays open.
constexpr int kGamepadSearchRounds = 6;
constexpr int64_t kGamepadConnectTimeout = 20 * NSEC_PER_SEC;
// A controller the Mac already knows that turns up in a search is in pairing mode again, so its
// half of the old pairing may be gone (paired to a console since, say). If it hasn't come in after
// a moment, the player forgets it in Bluetooth settings: KartPad doesn't forget a pairing itself
// (there's no public call, and a controller that connects but isn't one SDL can use would lose its
// pairing for nothing).
constexpr int64_t kGamepadKnownTimeout = 8 * NSEC_PER_SEC;

BOOL IsGamepad(IOBluetoothDevice *device) {
  NSString *name = device.name ?: @"";
  // Wii Remotes have their own path, which needs the Mac's address as the PIN.
  if ([name hasPrefix:@"Nintendo RVL-"]) return NO;
  if (device.deviceClassMajor == kBluetoothDeviceClassMajorPeripheral) {
    const BluetoothDeviceClassMinor minor = device.deviceClassMinor & 0x0f;
    if (minor == kBluetoothDeviceClassMinorPeripheral2Joystick ||
        minor == kBluetoothDeviceClassMinorPeripheral2Gamepad) return YES;
  }
  // Some controllers say they're something else; their names give them away.
  for (NSString *hint in @[@"Controller", @"DualSense", @"DUALSHOCK", @"Joy-Con", @"Gamepad", @"8BitDo"])
    if ([name rangeOfString:hint options:NSCaseInsensitiveSearch].location != NSNotFound) return YES;
  return NO;
}

} // namespace

@implementation KartPadGamepadPairController {
  IOBluetoothDeviceInquiry *_inquiry;
  IOBluetoothDevicePair *_pair;
  IOBluetoothDevice *_device;
  NSMutableSet<NSString *> *_seen;  // addresses already logged this search
  int _rounds;
  NSUInteger _attempt;  // so a stale timer from an earlier attempt does nothing
}

- (void)setStatus:(NSString *)status busy:(BOOL)busy {
  if (self.statusHandler) self.statusHandler(status, busy);
}

- (void)log:(NSString *)format, ... NS_FORMAT_FUNCTION(1, 2) {
  if (!self.logHandler) return;
  va_list args;
  va_start(args, format);
  self.logHandler([[NSString alloc] initWithFormat:format arguments:args]);
  va_end(args);
}

// Runs block after delay unless a newer attempt (or cancel) has come along.
- (void)after:(int64_t)delay do:(void (^)(KartPadGamepadPairController *controller))block {
  const NSUInteger attempt = _attempt;
  __weak KartPadGamepadPairController *weakSelf = self;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, delay), dispatch_get_main_queue(), ^{
    KartPadGamepadPairController *controller = weakSelf;
    if (controller != nil && controller->_attempt == attempt) block(controller);
  });
}

- (void)cancel {
  ++_attempt;
  [_inquiry stop];
  _inquiry = nil;
  [_pair stop];
  _pair = nil;
  _device = nil;
}

- (void)begin {
  [self cancel];
  if (IOBluetoothHostController.defaultController.powerState != kBluetoothHCIPowerStateON) {
    [self log:@"search=bluetooth-off"];
    [self setStatus:@"Bluetooth is off. Turn it on in Control Center, then Search Again." busy:NO];
    return;
  }
  _rounds = 0;
  _seen = [NSMutableSet set];
  _inquiry = [IOBluetoothDeviceInquiry inquiryWithDelegate:self];
  _inquiry.searchType = kIOBluetoothDeviceSearchClassic;
  _inquiry.updateNewDeviceNames = YES;
  const IOReturn result = [_inquiry start];
  if (result != kIOReturnSuccess) {
    _inquiry = nil;
    [self log:@"search=failed; error=0x%x", result];
    [self setStatus:@"Bluetooth search couldn't start. Check that KartPad may use Bluetooth in System Settings → Privacy & Security."
               busy:NO];
    return;
  }
  [self log:@"search=started"];
  [self setStatus:@"Looking for it…" busy:YES];
}

- (void)found:(IOBluetoothDevice *)device {
  if (_device != nil) return;
  const BOOL gamepad = IsGamepad(device);
  NSString *address = device.addressString ?: @"";
  // Names only for controllers: the search also sees the neighbours' phones and headphones.
  if (![_seen containsObject:address] || gamepad) {
    [_seen addObject:address];
    [self log:@"seen=%@; class=0x%02x/0x%02x; paired=%d", gamepad ? (device.name ?: @"(no name yet)") : @"other",
              device.deviceClassMajor, device.deviceClassMinor, device.isPaired];
  }
  if (!gamepad) return;
  _device = device;
  [_inquiry stop];
  _inquiry = nil;
  if (device.isPaired) {
    [self connectKnown];
    return;
  }
  [self pair];
}

- (void)pair {
  _pair = [IOBluetoothDevicePair pairWithDevice:_device];
  _pair.delegate = self;
  const IOReturn result = [_pair start];
  if (result != kIOReturnSuccess) {
    [self log:@"pair=failed-to-start; error=0x%x", result];
    _pair = nil;
    _device = nil;
    [self setStatus:@"Pairing couldn't start. Put it in pairing mode again, then Search Again." busy:NO];
    return;
  }
  [self setStatus:[NSString stringWithFormat:@"Found %@. Pairing…", _device.name.length ? _device.name : @"a controller"] busy:YES];
}

// The controller opens its own HID link once it's paired (or, if the Mac already knows it, once it
// hears from it); opening the baseband connection nudges ones that wait to be called.
- (void)openConnection {
  if (!_device.isConnected) [_device openConnection:self];  // asynchronous with a target
}

- (void)connectionComplete:(IOBluetoothDevice *)device status:(IOReturn)status {
  (void)device;
  [self log:@"baseband=0x%x", status];  // the HID link, not this, says whether it worked
}

- (void)connectKnown {
  [self openConnection];
  [self setStatus:@"Found it. Connecting…" busy:YES];
  [self after:kGamepadKnownTimeout do:^(KartPadGamepadPairController *controller) {
    const BOOL connected = controller->_device.isConnected;
    [controller log:@"connect=known-timed-out; connected=%d", connected];
    [controller setStatus:connected ? @"It connected, but KartPad can't use it."
                                    : @"It didn't connect. Forget it in Bluetooth settings, then Search Again."
                     busy:NO];
  }];
}

- (void)paired {
  [self openConnection];
  [self setStatus:@"Paired. Connecting…" busy:YES];
  [self after:kGamepadConnectTimeout do:^(KartPadGamepadPairController *controller) {
    [controller log:@"connect=timed-out; connected=%d", controller->_device.isConnected];
    [controller setStatus:@"It paired, but hasn't connected. Press its PS or HOME button." busy:NO];
  }];
}

- (void)deviceInquiryDeviceFound:(IOBluetoothDeviceInquiry *)sender device:(IOBluetoothDevice *)device {
  (void)sender;
  [self found:device];
}

- (void)deviceInquiryDeviceNameUpdated:(IOBluetoothDeviceInquiry *)sender
                                device:(IOBluetoothDevice *)device
                      devicesRemaining:(uint32_t)devicesRemaining {
  (void)sender;
  (void)devicesRemaining;
  [self found:device];
}

- (void)deviceInquiryComplete:(IOBluetoothDeviceInquiry *)sender error:(IOReturn)error aborted:(BOOL)aborted {
  if (aborted || sender != _inquiry || _device != nil) return;
  if (error == kIOReturnSuccess && ++_rounds < kGamepadSearchRounds) {
    [sender clearFoundDevices];
    [sender start];
    return;
  }
  _inquiry = nil;
  [self log:@"search=gave-up; rounds=%d; error=0x%x", _rounds, error];
  [self setStatus:@"Didn't find one. Put it in pairing mode, then Search Again." busy:NO];
}

- (void)devicePairingPINCodeRequest:(id)sender {
  // Only older controllers ask; the common default.
  [self log:@"pair=pin-requested"];
  BluetoothPINCode code{};
  memcpy(code.data, "0000", 4);
  [(IOBluetoothDevicePair *)sender replyPINCode:4 PINCode:&code];
}

- (void)devicePairingUserConfirmationRequest:(id)sender numericValue:(BluetoothNumericValue)numericValue {
  (void)numericValue;
  [self log:@"pair=confirmation-requested"];
  [(IOBluetoothDevicePair *)sender replyUserConfirmation:YES];
}

- (void)devicePairingFinished:(id)sender error:(IOReturn)error {
  if (sender != _pair) return;
  [self log:@"pair=finished; error=0x%x", error];
  if (error != kIOReturnSuccess) {
    [_pair stop];
    _pair = nil;
    _device = nil;
    [self setStatus:@"Pairing didn't finish. Put it in pairing mode again, then Search Again." busy:NO];
    return;
  }
  [self paired];
}

@end

static KartPadGamepadPairController *gKartPadGamepadPairController;

void KartPadBeginGamepadPairing(void (^status)(NSString *message, BOOL busy), void (^log)(NSString *line)) {
  if (gKartPadGamepadPairController == nil) gKartPadGamepadPairController = [KartPadGamepadPairController new];
  gKartPadGamepadPairController.statusHandler = status;
  gKartPadGamepadPairController.logHandler = log;
  [gKartPadGamepadPairController begin];
}

void KartPadCancelGamepadPairing(void) {
  gKartPadGamepadPairController.statusHandler = nil;
  gKartPadGamepadPairController.logHandler = nil;
  [gKartPadGamepadPairController cancel];
}

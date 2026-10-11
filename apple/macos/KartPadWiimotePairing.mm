// Pairing flow derived from Dolphin WiimotePair and WiimotePairPlus.
// Copyright 2024 Dolphin Emulator Project
// Copyright 2026 Gabriel Lascoski Ferraz
// SPDX-License-Identifier: GPL-2.0-or-later

#import "KartPadWiimotePairing.h"

#import <AppKit/AppKit.h>
#import <IOBluetooth/IOBluetooth.h>
#import <IOKit/hid/IOHIDKeys.h>
#import <IOKit/hid/IOHIDManager.h>

#include <SDL3/SDL_gamepad.h>
#include <SDL3/SDL_hints.h>
#include <SDL3/SDL_joystick.h>

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
- (void)inputConfirmed;
@end

namespace {

constexpr size_t kInputBufferSize = 64;
NSString *const kSyntheticDeviceKey = @"GCSyntheticDevice";

NSNumber *HIDNumber(IOHIDDeviceRef device, CFStringRef key) {
  CFTypeRef value = IOHIDDeviceGetProperty(device, key);
  return value != nullptr && CFGetTypeID(value) == CFNumberGetTypeID()
      ? (__bridge NSNumber *)value : nil;
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

void InputReport(void *context, IOReturn result, void *sender,
                 IOHIDReportType type, uint32_t reportID, uint8_t *report,
                 CFIndex length) {
  (void)sender;
  (void)type;
  (void)reportID;
  (void)report;
  (void)length;
  if (result != kIOReturnSuccess) return;
  KartPadWiimotePairController *controller =
      (__bridge KartPadWiimotePairController *)context;
  [controller inputConfirmed];
}

} // namespace

@implementation KartPadWiimotePairController {
  NSPanel *_panel;
  NSTextField *_status;
  NSProgressIndicator *_progress;
  NSButton *_doneButton;
  IOBluetoothDeviceInquiry *_inquiry;
  IOBluetoothDevicePair *_pair;
  IOBluetoothDevice *_bluetoothDevice;
  IOHIDManagerRef _hidManager;
  IOHIDDeviceRef _hidDevice;
  uint8_t _inputBuffer[kInputBufferSize];
  BOOL _inputReceived;
  BOOL _handedOff;
}

- (void)dealloc {
  [self cancelPairingWork];
}

- (void)tearDownHIDManager {
  [self closeHID];
  if (_hidManager != nullptr) {
    IOHIDManagerRegisterDeviceMatchingCallback(_hidManager, nullptr, nullptr);
    IOHIDManagerUnscheduleFromRunLoop(_hidManager, CFRunLoopGetMain(),
                                      kCFRunLoopDefaultMode);
    IOHIDManagerClose(_hidManager, kIOHIDOptionsTypeNone);
    CFRelease(_hidManager);
    _hidManager = nullptr;
  }
}

- (void)cancelPairingWork {
  [_inquiry stop];
  _inquiry = nil;
  if (!_handedOff) [_pair stop];
  _pair = nil;
  [self tearDownHIDManager];
  KartPadApplyExperimentalWiimotePreference();
}

- (void)closePairingPanel:(id)sender {
  (void)sender;
  [_panel close];
}

- (void)windowWillClose:(NSNotification *)notification {
  (void)notification;
  [self cancelPairingWork];
}

- (void)setStatus:(NSString *)status spinning:(BOOL)spinning {
  if (self.statusHandler) self.statusHandler(status, spinning);
  _status.stringValue = status;
  _progress.hidden = !spinning;
  if (spinning) [_progress startAnimation:nil];
  else [_progress stopAnimation:nil];
}

- (void)show {
  if (_panel == nil) {
    _panel = [[NSPanel alloc]
        initWithContentRect:NSMakeRect(0, 0, 520, 230)
                  styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable)
                    backing:NSBackingStoreBuffered defer:NO];
    _panel.title = @"Experimental Wii Remote + Nunchuk";
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
    NSStackView *statusRow = [NSStackView stackViewWithViews:@[_progress, _status]];
    statusRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    statusRow.alignment = NSLayoutAttributeCenterY;
    statusRow.spacing = 10;
    NSView *spacer = [NSView new];
    NSStackView *buttons = [NSStackView stackViewWithViews:@[spacer, _doneButton]];
    buttons.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    [spacer setContentHuggingPriority:NSLayoutPriorityDefaultLow
                       forOrientation:NSLayoutConstraintOrientationHorizontal];
    NSTextField *note = [NSTextField labelWithString:
        @"This direct Bluetooth path is experimental, requires macOS 12 or later, and does not use a DolphinBar. Attach the Nunchuk after the remote connects."];
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
  [_inquiry stop];
  _inquiry = nil;
  _pair = nil;
  _inputReceived = NO;
  _handedOff = NO;
  SDL_SetHint(SDL_HINT_JOYSTICK_HIDAPI_WII, "0");
  [self setStatus:@"Searching for an original Wii Remote or Wii Remote Plus…"
         spinning:YES];
  [self setupHIDManager];
  _inquiry = [IOBluetoothDeviceInquiry inquiryWithDelegate:self];
  _inquiry.searchType = kIOBluetoothDeviceSearchClassic;
  IOReturn result = [_inquiry start];
  if (result != kIOReturnSuccess) {
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
}

- (BOOL)matchesPairedDevice:(IOHIDDeviceRef)device {
  if (_bluetoothDevice == nil) return NO;
  CFTypeRef synthetic = IOHIDDeviceGetProperty(
      device, (__bridge CFStringRef)kSyntheticDeviceKey);
  if (synthetic == kCFBooleanTrue) return NO;
  NSNumber *vendor = HIDNumber(device, CFSTR(kIOHIDVendorIDKey));
  NSNumber *product = HIDNumber(device, CFSTR(kIOHIDProductIDKey));
  if (vendor.unsignedIntegerValue != 0x057e) return NO;
  const BOOL remotePlus = [_bluetoothDevice.name containsString:@"-TR"];
  return product.unsignedIntegerValue == (remotePlus ? 0x0330 : 0x0306);
}

- (void)deviceMatched:(id)object {
  IOHIDDeviceRef device = (__bridge IOHIDDeviceRef)object;
  if (![self matchesPairedDevice:device] || _hidDevice != nullptr) return;
  IOReturn result = IOHIDDeviceOpen(device, kIOHIDOptionsTypeNone);
  if (result == kIOReturnExclusiveAccess) {
    [self handOffToSDL:@"The Wii Remote is paired and already in use by KartPad."];
    return;
  }
  if (result != kIOReturnSuccess) {
    [self setStatus:@"The remote paired, but its physical HID device could not be opened."
           spinning:NO];
    return;
  }
  _hidDevice = (IOHIDDeviceRef)CFRetain(device);
  memset(_inputBuffer, 0, sizeof(_inputBuffer));
  IOHIDDeviceRegisterInputReportCallback(_hidDevice, _inputBuffer,
      sizeof(_inputBuffer), InputReport, (__bridge void *)self);
  const uint8_t led[] = {0x11, 0x10};
  const uint8_t mode[] = {0x12, 0x04, 0x30};
  const uint8_t status[] = {0x15, 0x00};
  IOHIDDeviceSetReport(_hidDevice, kIOHIDReportTypeOutput, 0x11, led, sizeof(led));
  IOHIDDeviceSetReport(_hidDevice, kIOHIDReportTypeOutput, 0x12, mode, sizeof(mode));
  IOHIDDeviceSetReport(_hidDevice, kIOHIDReportTypeOutput, 0x15, status, sizeof(status));
  [self setStatus:@"Paired. Waiting for the first controller input packet…"
         spinning:YES];
}

- (void)inputConfirmed {
  if (_inputReceived) return;
  _inputReceived = YES;
  [self handOffToSDL:@"Input confirmed. Handing the remote to KartPad…"];
}

- (void)closeHID {
  if (_hidDevice == nullptr) return;
  IOHIDDeviceRegisterInputReportCallback(_hidDevice, _inputBuffer,
      sizeof(_inputBuffer), nullptr, nullptr);
  IOHIDDeviceClose(_hidDevice, kIOHIDOptionsTypeNone);
  CFRelease(_hidDevice);
  _hidDevice = nullptr;
}

- (void)handOffToSDL:(NSString *)message {
  _handedOff = YES;
  [self setStatus:message spinning:YES];
  [self tearDownHIDManager];
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 300 * NSEC_PER_MSEC),
                 dispatch_get_main_queue(), ^{
    SDL_SetHint(SDL_HINT_JOYSTICK_HIDAPI_WII, "1");
    SDL_UpdateJoysticks();
    [self verifySDLHandoff];
  });
}

- (void)verifySDLHandoff {
  int count = 0;
  SDL_JoystickID *ids = SDL_GetGamepads(&count);
  NSString *found = nil;
  for (int index = 0; index < count; ++index) {
    const char *name = SDL_GetGamepadNameForID(ids[index]);
    if (name != nullptr && strstr(name, "Nintendo Wii Remote") != nullptr) {
      found = [NSString stringWithUTF8String:name];
      break;
    }
  }
  SDL_free(ids);
  if (found != nil) {
    [self setStatus:[NSString stringWithFormat:
        @"Connected as %@. Attach the Nunchuk any time.",
        found] spinning:NO];
  } else {
    [self setStatus:@"Pairing completed. Press A on the Wii Remote; KartPad will finish connecting through SDL."
           spinning:NO];
  }
}

- (void)preparePairedDevice:(IOBluetoothDevice *)device {
  _bluetoothDevice = device;
  [self setStatus:[NSString stringWithFormat:@"Bluetooth paired: %@. Waiting for physical HID…",
      device.name ?: @"Wii Remote"] spinning:YES];
  CFSetRef devices = _hidManager != nullptr
      ? IOHIDManagerCopyDevices(_hidManager) : nullptr;
  if (devices != nullptr) {
    for (id object in (__bridge NSSet *)devices) {
      [self deviceMatched:object];
      if (_hidDevice != nullptr) break;
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

- (void)deviceInquiryComplete:(IOBluetoothDeviceInquiry *)sender
                         error:(IOReturn)error aborted:(BOOL)aborted {
  if (!aborted && _bluetoothDevice == nil && error == kIOReturnSuccess) {
    [sender clearFoundDevices];
    [sender start];
  }
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

void KartPadBeginWiimotePairing(void (^status)(NSString *message, BOOL busy)) {
  if (gKartPadWiimotePairController == nil) {
    gKartPadWiimotePairController = [KartPadWiimotePairController new];
  }
  [NSUserDefaults.standardUserDefaults setBool:YES forKey:KartPadExperimentalWiimoteDefaultsKey];
  KartPadApplyExperimentalWiimotePreference();
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

// Forgetting a pairing, as the Mac's Bluetooth settings do; there's no public call for it.
@interface IOBluetoothDevice (KartPadPrivateRemove)
- (void)remove;
@end

namespace {

// About a minute of searching: an inquiry slows other Bluetooth (headphones, connected
// controllers) while it runs, so it doesn't run for as long as the screen stays open.
constexpr int kGamepadSearchRounds = 6;
constexpr int64_t kGamepadConnectTimeout = 20 * NSEC_PER_SEC;
// A controller the Mac already knows that turns up in a search is in pairing mode again, so its
// half of the old pairing may be gone (paired to a console since, say). Give the old one a moment,
// then forget it and pair afresh.
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
  [self after:kGamepadKnownTimeout do:^(KartPadGamepadPairController *controller) { [controller forgetAndPair]; }];
}

- (void)forgetAndPair {
  if (![_device respondsToSelector:@selector(remove)]) {
    [self log:@"forget=unavailable"];
    [self setStatus:@"It didn't connect. Forget it in Bluetooth settings, then Search Again." busy:NO];
    return;
  }
  [self log:@"forget=started"];
  [self setStatus:@"Pairing it again…" busy:YES];
  [_device closeConnection];
  [_device remove];
  [self waitForgotten:12];
}

// Forgetting finishes in the background; pair once it has (or try anyway after about 3 seconds).
- (void)waitForgotten:(int)triesLeft {
  if (!_device.isPaired || triesLeft == 0) {
    [self log:@"forget=%@", _device.isPaired ? @"still-paired" : @"done"];
    [self pair];
    return;
  }
  [self after:250 * NSEC_PER_MSEC do:^(KartPadGamepadPairController *controller) { [controller waitForgotten:triesLeft - 1]; }];
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

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

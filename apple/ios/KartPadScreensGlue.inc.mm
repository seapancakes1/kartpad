// The screens on iPhone and iPad, after the Mac's files: touches, the Miis screen, restarts (which
// iOS leaves to the player), the controllers each frame, and the C functions the overlay host calls
// (KartPadScreens.h). Included last by KartPadScreens.mm, so the AppKit names of
// KartPadAppKitShimNames.h still stand for their UIKit equivalents here.

#pragma mark Touch

// A touch drives the screens: the controller hints step aside until a controller is pressed again
// (KPScreensPadUsed). KPScreensTouching is KartPadScreensPlatform.inc.mm's.
static void KPScreensTouchUsed() {
  if (KPScreensTouching) return;
  KPScreensTouching = YES;
  KPRedrawUIViews(KPOverlay().host);
}
static void KPScreensPadUsed() {
  if (!KPScreensTouching) return;
  KPScreensTouching = NO;
  KPRedrawUIViews(KPOverlay().host);
}

// Decoration takes no touches, as it takes no clicks on the Mac.
@implementation KPUIView (KPTouch)
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
  (void)point;
  (void)event;
  return nil;
}
@end

// The smallest a control may be under a finger, in points, whatever the canvas's scale.
static constexpr CGFloat KPTouchTarget = 44;

static NSMapTable<KPUIButton *, NSNumber *> *KPButtonsSliding() {
  static NSMapTable *sliding;
  if (sliding == nil) sliding = [NSMapTable weakToStrongObjectsMapTable];
  return sliding;
}

@implementation KPUIButton (KPTouch)
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
  (void)event;
  const CGRect r = self.bounds;
  const CGFloat dx = std::max<CGFloat>(0, (KPTouchTarget - r.size.width) / 2);
  const CGFloat dy = std::max<CGFloat>(0, (KPTouchTarget - r.size.height) / 2);
  return CGRectContainsPoint(CGRectInset(r, -dx, -dy), point);
}
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
  if (self.hidden || !self.enabled || self.alpha < 0.01) return nil;
  return [self pointInside:point withEvent:event] ? self : nil;
}
- (CGPoint)designPointFor:(UITouch *)touch {
  const CGPoint local = [touch locationInView:self];
  return CGPointMake(local.x / self.scale, local.y / self.scale);
}
- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
  (void)event;
  KPScreensTouchUsed();
  if (!self.enabled) return;
  if (self.screen == KPOverlay().top) [KPOverlay() focus:self sound:NO];
  if (self.slide && self.slide([self designPointFor:touches.anyObject], self.faceRect, YES)) {
    [KPButtonsSliding() setObject:@YES forKey:self];
    return;
  }
  self.pressed = YES;
}
- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
  UITouch *touch = touches.anyObject;
  if ([KPButtonsSliding() objectForKey:self]) {
    if (self.slide) self.slide([self designPointFor:touch], self.faceRect, NO);
    return;
  }
  self.pressed = [self pointInside:[touch locationInView:self] withEvent:event];
}
- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
  if ([KPButtonsSliding() objectForKey:self]) {
    [KPButtonsSliding() removeObjectForKey:self];
    KPSaveSlide();
    return;
  }
  const BOOL fire = self.pressed && [self pointInside:[touches.anyObject locationInView:self] withEvent:event];
  self.pressed = NO;
  if (fire) [self fire:YES];
}
- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
  (void)touches;
  (void)event;
  if ([KPButtonsSliding() objectForKey:self]) {
    [KPButtonsSliding() removeObjectForKey:self];
    KPSaveSlide();
  }
  self.pressed = NO;
}
// VoiceOver's double tap.
- (BOOL)accessibilityActivate {
  [self fire];
  return YES;
}
- (UIAccessibilityTraits)accessibilityTraits {
  return UIAccessibilityTraitButton | (self.enabled ? 0 : UIAccessibilityTraitNotEnabled);
}
@end

// A screen catches every touch, so none reaches the game under it; its controls are asked first.
@implementation KPScreen (KPTouch)
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
  if (self.hidden || ![self pointInside:point withEvent:event]) return nil;
  for (UIView *child in self.subviews.reverseObjectEnumerator) {
    if (child.hidden || !child.userInteractionEnabled) continue;
    if (UIView *hit = [child hitTest:[self convertPoint:point toView:child] withEvent:event]) return hit;
  }
  return self;
}
- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
  (void)touches;
  (void)event;
  KPScreensTouchUsed();
}
- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event { (void)touches; (void)event; }
- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event { (void)touches; (void)event; }
- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event { (void)touches; (void)event; }
@end

// Over the game the host lets every touch through (to the touch controls) unless a screen is open.
@implementation KPOverlayHost (KPTouch)
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
  if (!KPOverlay().active) return nil;
  for (UIView *child in self.subviews.reverseObjectEnumerator) {
    if (child.hidden || [child isKindOfClass:KPToastView.class]) continue;
    if (UIView *hit = [child hitTest:[self convertPoint:point toView:child] withEvent:event]) return hit;
  }
  return self;
}
- (void)layoutSubviews {
  [super layoutSubviews];
  static CGSize laidOut;
  if (CGSizeEqualToSize(laidOut, self.bounds.size)) return;
  laidOut = self.bounds.size;
  [KPOverlay() relayout];
}
@end

#pragma mark Miis

// The shared Miis screen, as iPhone and iPad have always shown it: full screen over the game. This
// screen stands under it, so HOME is there again when it's done.
@interface KPMiisScreen : KPScreen
@property(nonatomic, strong) UIViewController<KartPadMiiBrowser> *browser;
@property(nonatomic) BOOL shown;
@end
@implementation KPMiisScreen
- (void)build {
  self.solid = YES;
  self.title = @"Miis";
  self.forwardsPads = YES;  // controllers drive the Mii browser (KartPadMiiGamepad.inc.mm)
}
- (void)back {
  if (self.browser.done) self.browser.done();
  else [KPOverlay() pop];
}
- (NSArray<KPUIButton *> *)focusables { return @[]; }
- (KPUIButton *)initialFocus { return nil; }
- (void)didAppear {
  if (self.shown) return;
  self.shown = YES;
  UIViewController *presenter = [KPHost() screensPresenter];
  if (presenter == nil) {
    [KPOverlay() pop];
    return;
  }
  self.browser = (UIViewController<KartPadMiiBrowser> *)KartPadMakeMiiBrowser();
  self.browser.modalPresentationStyle = UIModalPresentationFullScreen;
  // It follows the launcher's light or dark choice, as the game's other sheets do.
  self.browser.overrideUserInterfaceStyle = presenter.traitCollection.userInterfaceStyle;
  __weak KPMiisScreen *weakSelf = self;
  self.browser.done = ^{
    KPMiisScreen *screen = weakSelf;
    [screen.browser dismissViewControllerAnimated:YES completion:^{
      if (KPOverlay().top == screen) [KPOverlay() pop];
    }];
  };
  // Opened from a controller: the ring is on the selected Mii straight away.
  const BOOL fromPad = !KPScreensTouching;
  [presenter presentViewController:self.browser animated:YES completion:^{
    if (fromPad) KartPadMiiPadShowFocus();
  }];
}
// Swiped away, or closed some other way: back to where it was opened from.
- (void)tick {
  if (self.shown && self.browser.presentingViewController == nil && KPOverlay().top == self) [KPOverlay() pop];
}
@end
static KPScreen *KPMakeMiisScreen() { return [[KPMiisScreen alloc] initWithFrame:NSZeroRect]; }

#pragma mark Restarts and game switching

// iOS can't relaunch an app: the player closes KartPad and opens it again, which applies what's
// waiting (Mii changes, the other game). The card says so.
static void KPRestartWithCurtain(NSString *heading, NSString *detail) {
  (void)detail;
  AppendSessionLine([NSString stringWithFormat:@"restartAsked=%@", heading]);
  KPAsk(heading.length ? heading : @"Restart KartPad",
        @"Close KartPad in the app switcher, then open it again.", @[@"OK"], 0, -1, ^(NSInteger choice) { (void)choice; });
}
static void KPCurtainDone() {}

// Retro Rewind isn't downloaded from these screens on iOS: its own manager installs it.
static BOOL KPRetroDownloadOffered() { return YES; }
static void KPShowRetroDownload(BOOL start) {
  (void)start;
  [KPHost() screensManageRetroRewind];
}

// The touch screen's card on Controllers: it can't change player or stop, so its menu is the Mii and
// the touch layout.
@interface KPControllersScreen (KPTouchCard)
- (void)beginAssigning:(int)slot;
@end
static void KPOpenTouchCard(KPControllersScreen *screen, int slot, KPPadDevice *device) {
  KPControllerRoster *roster = KPControllerRoster.shared;
  KPMenuScreen *menu = [[KPMenuScreen alloc] initWithFrame:NSZeroRect];
  NSDictionary *mii = [roster miiRecordFor:device];
  menu.heading = [NSString stringWithFormat:@"%@ · %@", KPPlayerName(slot), mii[@"name"] ?: device.name];
  __weak KPControllersScreen *weakScreen = screen;
  [menu add:@"Use a controller" detail:@"Press A on the controller for this player." glyph:(int)KPUIGlyph::Swap enabled:YES
        run:^{ [weakScreen beginAssigning:slot]; }];
  [menu add:mii ? @"Change Mii" : @"Choose a Mii" detail:nil glyph:(int)KPUIGlyph::Mii enabled:YES run:^{ KPChooseMii(device); }];
  [menu add:@"Touch controls" detail:@"Layout, size and auto-accelerate." glyph:(int)KPUIGlyph::Buttons enabled:YES
        run:^{ [KPHost() screensShowTouchControls]; }];
  [KPOverlay() present:menu];
}

#pragma mark The game held

// Per player: the buttons kept from the game since a screen closed (all of them at first, then
// only those not yet let go).
static std::array<uint32_t, 4> KPQuietButtons{};

#pragma mark Files

// Picking a file in Files, for Import (ghosts): a copy the app may read, or nil when cancelled.
@interface KPScreensPicker : NSObject <UIDocumentPickerDelegate>
@property(nonatomic, copy) void (^done)(NSURL *url);
@end
@implementation KPScreensPicker
- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
  (void)controller;
  if (self.done) self.done(urls.firstObject);
  self.done = nil;
}
- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
  (void)controller;
  if (self.done) self.done(nil);
  self.done = nil;
}
@end
static void KPScreensChooseFile(NSArray<UTType *> *types, void (^done)(NSURL *url)) {
  UIViewController *presenter = [KPHost() screensPresenter];
  if (presenter == nil) return;
  static KPScreensPicker *picker;
  picker = [KPScreensPicker new];
  picker.done = done;
  UIDocumentPickerViewController *files = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:types asCopy:YES];
  files.delegate = picker;
  files.allowsMultipleSelection = NO;
  [presenter presentViewController:files animated:YES completion:nil];
}
// A file out to Files, AirDrop or another app.
static void KPScreensShareFile(NSURL *file) {
  UIViewController *presenter = [KPHost() screensPresenter];
  if (presenter == nil) return;
  UIActivityViewController *share = [[UIActivityViewController alloc] initWithActivityItems:@[file] applicationActivities:nil];
  share.popoverPresentationController.sourceView = presenter.view;
  share.popoverPresentationController.sourceRect =
      CGRectMake(CGRectGetMidX(presenter.view.bounds), CGRectGetMidY(presenter.view.bounds), 1, 1);
  share.popoverPresentationController.permittedArrowDirections = 0;
  [presenter presentViewController:share animated:YES completion:nil];
}

extern "C" bool KartPadGameStarting();
extern "C" bool Network_HLE_HasOpenSockets();

#pragma mark Vibration

// The game's rumble (the Wii Remote motor, per player: WPADControlMotor in the runtime) on that
// player's controller, or for a player on the touch screen, on the iPhone itself.
static BOOL KPVibrationEnabled() {
  NSNumber *saved = [NSUserDefaults.standardUserDefaults objectForKey:KPVibrationKey];
  return saved == nil || saved.boolValue;
}
struct KPRumblePlayer {
  __weak GCController *controller = nil;
  CHHapticEngine *engine = nil;
  id<CHHapticPatternPlayer> player = nil;
};
static std::array<KPRumblePlayer, 4> KPRumblePlayers;
static void KPRumbleSet(NSUInteger player, bool on) {
  static int logged;
  if (logged < 12) {
    ++logged;
    AppendSessionLine([NSString stringWithFormat:@"rumble player=%lu on=%d", (unsigned long)player + 1, on]);
  }
  KPRumblePlayer &rumble = KPRumblePlayers[player];
  [rumble.player stopAtTime:CHHapticTimeImmediate error:nil];
  rumble.player = nil;
  if (!on || !KPVibrationEnabled()) return;
  GCController *controller = [[KartPadPhysicalControllers sharedControllers] controllerForPlayer:player];
  if (controller != rumble.controller || rumble.engine == nil) {
    rumble.controller = controller;
    rumble.engine = nil;
    if (controller.haptics) rumble.engine = [controller.haptics createEngineWithLocality:GCHapticsLocalityDefault];
    else if (controller == nil && player == 0 && CHHapticEngine.capabilitiesForHardware.supportsHaptics)
      rumble.engine = [[CHHapticEngine alloc] initAndReturnError:nil];
    rumble.engine.playsHapticsOnly = YES;
    rumble.engine.autoShutdownEnabled = YES;
  }
  if (rumble.engine == nil || ![rumble.engine startAndReturnError:nil]) return;
  CHHapticEvent *event = [[CHHapticEvent alloc]
      initWithEventType:CHHapticEventTypeHapticContinuous
             parameters:@[[[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticIntensity value:0.75],
                          [[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticSharpness value:0.3]]
           relativeTime:0
               duration:30];
  CHHapticPattern *pattern = [[CHHapticPattern alloc] initWithEvents:@[event] parameters:@[] error:nil];
  if (pattern == nil) return;
  rumble.player = [rumble.engine createPlayerWithPattern:pattern error:nil];
  [rumble.player startAtTime:CHHapticTimeImmediate error:nil];
}
// From the game thread, every time the game sets a motor; only changes go on.
extern "C" void KartPadMobileSetRumble(uint32_t chan, bool on) {
  static std::array<std::atomic<bool>, 4> state{};
  if (chan >= state.size() || state[chan].exchange(on) == on) return;
  dispatch_async(dispatch_get_main_queue(), ^{ KPRumbleSet(chan, on); });
}
// The game held (a screen open) or in the background: the motors stop.
static void KPRumbleStopAll() {
  for (NSUInteger player = 0; player < KPRumblePlayers.size(); ++player) {
    [KPRumblePlayers[player].player stopAtTime:CHHapticTimeImmediate error:nil];
    KPRumblePlayers[player].player = nil;
  }
}

#include "KartPadScreensPads.inc.mm"
#include "KartPadScreensQA.inc.mm"

#pragma mark For the overlay host

void KartPadScreensAttach(UIWindow *gameWindow, UIView *container, id<KartPadScreensHost> host) {
  (void)container;
  KPScreensGameWindow = gameWindow;
  KPScreensHostObject = host;
  KPOverlayController *overlay = KPOverlay();
  overlay.host.userInteractionEnabled = YES;
  [overlay attach];
  [KPControllerRoster.shared refresh];
  KPQAStart();
}

void KartPadScreensBringToFront(void) {
  KPOverlayController *overlay = KPOverlay();
  if (overlay.host.superview) [overlay.host.superview bringSubviewToFront:overlay.host];
  else [overlay attach];
}

void KartPadScreensToggleHome(void) {
  KPScreensTouchUsed();
  KPToggleHome();
}

// Online the game can't hold (the connection would drop), as on the Mac: it runs on under the
// screens, without input (KartPadScreensActive).
BOOL KartPadScreensHoldGame(void) { return KartPadOverlayPauseWanted() && !Network_HLE_HasOpenSockets(); }

BOOL KartPadScreensActive(void) { return KPOverlay().active; }

void KartPadScreensFrameTick(void) {
  KPPadFrameTick();
  // A screen that closed without holding the game (online): what's held stays out of it too.
  static BOOL wasActive;
  const BOOL active = KPOverlay().active;
  if (wasActive && !active) KartPadScreensQuietHeldButtons();
  wasActive = active;
  static NSTimeInterval lastRefresh;
  const NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
  if (now - lastRefresh > 0.5) {
    lastRefresh = now;
    [KPControllerRoster.shared refresh];
    [KPOverlay() attach];
  }
}

void KartPadScreensHoldTick(void) {
  KPRumbleStopAll();
  KPPadFrameTick();
}

void KartPadScreensCloseAll(void) { [KPOverlay() closeAll]; }

void KartPadScreensQuietHeldButtons(void) { KPQuietButtons.fill(~0u); }

uint32_t KartPadScreensMaskHeld(NSUInteger player, uint32_t buttons) {
  if (player >= KPQuietButtons.size()) return buttons;
  const uint32_t quiet = KPQuietButtons[player] & buttons;
  KPQuietButtons[player] = quiet;  // a button let go is the game's again
  return buttons & ~quiet;
}

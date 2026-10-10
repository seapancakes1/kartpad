// Restarting without the window going away. Switching games, or applying changes that need a fresh
// start, still means a new process (the game can't be torn down and started again in place), so a
// curtain covers the gap: the window shows a "Starting Retro Rewind" card; a second copy of KartPad,
// started in curtain mode (KARTPAD_CURTAIN, no Dock icon or menus), puts the same card in a window of
// its own at exactly the same place; this process quits; the curtain starts KartPad again and stays
// up until the new game is on screen, then fades away. To the player the card simply stays while the
// game changes behind it.
// Included by KartPadMacShell.mm after the screens; KartPadMacShellPrepareGameData runs the curtain.

static NSString *const KPCurtainVariable = @"KARTPAD_CURTAIN";        // the handoff file (curtain process)
static NSString *const KPCurtainTokenVariable = @"KARTPAD_CURTAIN_TOKEN";  // the new game process
static NSString *KPCurtainNotice(NSString *token, NSString *what) {
  return [NSString stringWithFormat:@"dev.kartpad.curtain.%@.%@", what, token];
}

// The card itself, drawn the same in the game window and in the curtain's window.
static void KPDrawCurtainCard(CGContextRef c, CGSize size, NSString *heading, NSString *detail, CGFloat phase) {
  KPFill(c, CGRectMake(0, 0, size.width, size.height), KPP->background);
  KPPinstripes(c, CGRectMake(0, 0, size.width, size.height), KPP->stripe);
  const CGFloat scale = std::min(size.width / KPUIDesignWidth, size.height / KPUIDesignHeight);
  CGContextSaveGState(c);
  CGContextTranslateCTM(c, (size.width - KPUIDesignWidth * scale) / 2, (size.height - KPUIDesignHeight * scale) / 2);
  CGContextScaleCTM(c, scale, scale);
  const CGRect card = CGRectMake(340, 210, 600, 300);
  CGContextSaveGState(c);
  CGContextSetShadowWithColor(c, CGSizeMake(0, 10), 30, [NSColor colorWithWhite:0 alpha:0.22].CGColor);
  KPFill(c, card, KPP->panel, 30);
  CGContextRestoreGState(c);
  KPStroke(c, card, KPP->panelStroke, 1.5, 30);
  // A row of dots that bounce in turn, Wii-loading style.
  for (int dot = 0; dot < 5; ++dot) {
    const CGFloat lift = std::max(0.0, sin(phase * 2 * M_PI - dot * 0.7)) * 14;
    const CGRect r = CGRectMake(560 + dot * 34, 290 - lift, 22, 22);
    KPSetInk(c, KPPlayerColors[dot % 4]);
    CGContextFillEllipseInRect(c, r);
  }
  // The heading sits lower when there's no line under it.
  KPTextWeight(heading, CGRectMake(card.origin.x + 30, card.origin.y + (detail.length ? 132 : 150), card.size.width - 60, 46), 32,
               KPP->text, NSFontWeightBold);
  if (detail.length)
    KPTextWeight(detail, CGRectMake(card.origin.x + 30, card.origin.y + 186, card.size.width - 60, 60), 20, KPP->secondaryText,
                 NSFontWeightMedium);
  CGContextRestoreGState(c);
}

@interface KPCurtainScreen : KPScreen
@property(nonatomic, copy) NSString *heading, *detail;
@property(nonatomic) CFTimeInterval started;
@end
@implementation KPCurtainScreen
- (void)build {
  self.solid = YES;
  self.started = CACurrentMediaTime();
}
- (NSArray<KPUIButton *> *)focusables { return @[]; }
- (KPUIButton *)initialFocus { return nil; }
- (BOOL)handle:(KartPadMiiPadButton)button { (void)button; return YES; }
- (void)back {}
- (void)tick { self.needsDisplay = YES; }
- (void)drawDesign:(CGContextRef)c size:(CGSize)size {
  CGContextSaveGState(c);
  // The card draws at its own scale from the full window size.
  CGContextScaleCTM(c, 1 / self.scale, 1 / self.scale);
  KPDrawCurtainCard(c, CGSizeMake(size.width * self.scale, size.height * self.scale), self.heading, self.detail,
                    fmod((CACurrentMediaTime() - self.started) / 1.2, 1));
  CGContextRestoreGState(c);
}
@end

static NSString *KPQADirectory();  // KartPadQA.inc.mm

static void KPRestartWithCurtain(NSString *heading, NSString *detail) {
  NSWindow *game = KPGameWindow();
  NSString *app = NSBundle.mainBundle.bundlePath;
  // An open Mii editor asks about unsaved changes first; Keep Editing stays put.
  if (![Controller() closeWindows:nil]) return;
  if (game == nil || ![app.pathExtension isEqualToString:@"app"]) {
    [KPOverlay() closeAll];
    [Controller() restartKartPad:nil];
    return;
  }
  AppendSessionLine(@"restart=curtain");
  // The card shows in the window first.
  KPCurtainScreen *card = [[KPCurtainScreen alloc] initWithFrame:NSZeroRect];
  card.heading = heading;
  card.detail = detail;
  KPOverlayController *overlay = KPOverlay();
  while (overlay.stack.count) {
    KPScreen *screen = overlay.stack.lastObject;
    [screen willDisappear];
    [screen removeFromSuperview];
    [overlay.stack removeLastObject];
  }
  [overlay present:card];
  KPUIPlay(KPUISound::Saved);

  NSString *token = NSUUID.UUID.UUIDString;
  const BOOL dark = [[game.effectiveAppearance bestMatchFromAppearancesWithNames:@[NSAppearanceNameAqua, NSAppearanceNameDarkAqua]]
      isEqualToString:NSAppearanceNameDarkAqua];
  NSDictionary *handoff = @{
    @"token": token,
    @"frame": NSStringFromRect(game.frame),
    @"fullscreen": @(aurora_get_display_mode() != AURORA_DISPLAY_MODE_WINDOWED),
    @"level": @(game.level),
    @"heading": heading,
    @"detail": detail,
    @"dark": @(dark),
    @"pid": @(NSProcessInfo.processInfo.processIdentifier),
    @"app": app,
  };
  NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"KartPadCurtain-%@.plist", token]];
  NSTask *task = [NSTask new];
  task.executableURL = NSBundle.mainBundle.executableURL;
  NSMutableDictionary *environment = [NSProcessInfo.processInfo.environment mutableCopy];
  environment[KPCurtainVariable] = path;
  [environment removeObjectForKey:KPCurtainTokenVariable];
  task.environment = environment;
  task.standardOutput = NSFileHandle.fileHandleWithNullDevice;
  task.standardError = NSFileHandle.fileHandleWithNullDevice;
  NSError *error = nil;
  if (![handoff writeToURL:[NSURL fileURLWithPath:path] error:&error] || ![task launchAndReturnError:&error]) {
    AppendSessionLine(@"restart=curtain-failed; falling back");
    [KPOverlay() closeAll];
    [Controller() restartKartPad:nil];
    return;
  }
  // Quit once the curtain is up (or after a moment if it never says so).
  __block BOOL quitting = NO;
  __block id observer = nil;
  void (^quit)(void) = ^{
    if (quitting) return;
    quitting = YES;
    if (observer) [NSDistributedNotificationCenter.defaultCenter removeObserver:observer];
    [Controller() finishQuitting:nil];
  };
  observer = [NSDistributedNotificationCenter.defaultCenter addObserverForName:KPCurtainNotice(token, @"ready") object:nil queue:nil
                                                                    usingBlock:^(NSNotification *note) {
    (void)note;
    dispatch_async(dispatch_get_main_queue(), quit);
  }];
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), quit);
}

// The new game process tells the curtain it can go: the game is on screen, or something needs the
// player before the game starts (an alert the curtain mustn't hide).
static void KPCurtainDone() {
  static bool done;
  NSString *token = NSProcessInfo.processInfo.environment[KPCurtainTokenVariable];
  if (done || token.length == 0) return;
  done = true;
  [NSDistributedNotificationCenter.defaultCenter postNotificationName:KPCurtainNotice(token, @"shown") object:nil userInfo:nil
                                                   deliverImmediately:YES];
}

#pragma mark Curtain process

@interface KPCurtainView : NSView
@property(nonatomic, copy) NSString *heading, *detail;
@property(nonatomic) CFTimeInterval started;
@end
@implementation KPCurtainView
- (BOOL)isFlipped { return YES; }
- (void)drawRect:(NSRect)rect {
  (void)rect;
  KPUsePalette(self);
  KPDrawCurtainCard(NSGraphicsContext.currentContext.CGContext, self.bounds.size, self.heading, self.detail,
                    fmod((CACurrentMediaTime() - self.started) / 1.2, 1));
}
@end

// Runs instead of the game when KARTPAD_CURTAIN names a handoff file. Returns once the new game has
// taken over (or after a minute, whatever happens).
static void KPRunCurtain(NSString *path) {
  NSDictionary *handoff = [NSDictionary dictionaryWithContentsOfFile:path];
  [NSFileManager.defaultManager removeItemAtPath:path error:nil];
  if (handoff == nil) return;
  NSApplication *app = NSApplication.sharedApplication;
  [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
  [app finishLaunching];
  NSString *token = handoff[@"token"];
  const NSRect frame = NSRectFromString(handoff[@"frame"]);
  const BOOL fullscreen = [handoff[@"fullscreen"] boolValue], background = KPUIBackgroundAutomation();
  NSWindow *window = [[NSWindow alloc] initWithContentRect:frame styleMask:NSWindowStyleMaskBorderless
                                                   backing:NSBackingStoreBuffered defer:NO];
  window.appearance = [NSAppearance appearanceNamed:[handoff[@"dark"] boolValue] ? NSAppearanceNameDarkAqua : NSAppearanceNameAqua];
  window.opaque = YES;
  window.hasShadow = !fullscreen;
  window.releasedWhenClosed = NO;
  window.ignoresMouseEvents = YES;
  window.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorStationary |
                              NSWindowCollectionBehaviorFullScreenAuxiliary | NSWindowCollectionBehaviorIgnoresCycle;
  window.level = background ? NSNormalWindowLevel
                            : fullscreen ? NSScreenSaverWindowLevel : std::max<NSInteger>(NSFloatingWindowLevel, [handoff[@"level"] integerValue] + 1);
  KPCurtainView *view = [[KPCurtainView alloc] initWithFrame:NSMakeRect(0, 0, frame.size.width, frame.size.height)];
  view.heading = handoff[@"heading"];
  view.detail = handoff[@"detail"];
  view.started = CACurrentMediaTime();
  window.contentView = view;
  [window setFrame:frame display:YES];
  if (background) [window orderBack:nil];
  else [window orderFrontRegardless];
  NSTimer *animate = [NSTimer timerWithTimeInterval:1.0 / 30 repeats:YES block:^(NSTimer *timer) {
    (void)timer;
    view.needsDisplay = YES;
  }];
  [NSRunLoop.mainRunLoop addTimer:animate forMode:NSRunLoopCommonModes];
  [NSDistributedNotificationCenter.defaultCenter postNotificationName:KPCurtainNotice(token, @"ready") object:nil userInfo:nil
                                                   deliverImmediately:YES];
  // Automated checks get a picture of the curtain.
  if (NSString *qa = KPQADirectory()) {
    [view displayIfNeeded];
    NSBitmapImageRep *rep = [view bitmapImageRepForCachingDisplayInRect:view.bounds];
    [view cacheDisplayInRect:view.bounds toBitmapImageRep:rep];
    [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:[qa stringByAppendingPathComponent:@"curtain.png"]
                                                                            atomically:YES];
  }

  __block BOOL shown = NO;
  id observer = [NSDistributedNotificationCenter.defaultCenter addObserverForName:KPCurtainNotice(token, @"shown") object:nil queue:nil
                                                                       usingBlock:^(NSNotification *note) {
    (void)note;
    shown = YES;
  }];
  // Wait for the old process to go, then start KartPad again.
  const pid_t pid = [handoff[@"pid"] intValue];
  const CFTimeInterval start = CACurrentMediaTime();
  while (kill(pid, 0) == 0 && CACurrentMediaTime() - start < 20)
    [NSRunLoop.mainRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
  // A new copy of KartPad (this process is KartPad too, so plain opening would bring it forward),
  // told which curtain to dismiss. Automated checks keep their settings.
  NSMutableArray<NSString *> *arguments = [NSMutableArray arrayWithObjects:@"-n", nil];
  if (background) [arguments addObject:@"-g"];
  [arguments addObjectsFromArray:@[@"--env", [NSString stringWithFormat:@"%@=%@", KPCurtainTokenVariable, token]]];
  for (NSString *name in @[@"KARTPAD_MUTED", @"KARTPAD_BACKGROUND", @"KARTPAD_QA_DIR"]) {
    NSString *value = NSProcessInfo.processInfo.environment[name];
    if (value.length) [arguments addObjectsFromArray:@[@"--env", [NSString stringWithFormat:@"%@=%@", name, value]]];
  }
  [arguments addObject:handoff[@"app"]];
  NSTask *open = [NSTask new];
  open.executableURL = [NSURL fileURLWithPath:@"/usr/bin/open"];
  open.arguments = arguments;
  // Not this curtain's variable: the new copy would start as a curtain itself.
  NSMutableDictionary *environment = [NSProcessInfo.processInfo.environment mutableCopy];
  [environment removeObjectForKey:KPCurtainVariable];
  open.environment = environment;
  // Automated checks start the program itself, so it keeps the checker's file access rather than
  // asking for its own (a copy opened by Finder or open is responsible for itself).
  if (KPQADirectory()) {
    environment[KPCurtainTokenVariable] = token;
    open.executableURL = [[NSURL fileURLWithPath:handoff[@"app"]] URLByAppendingPathComponent:@"Contents/MacOS/KartPad"];
    open.arguments = @[];
    open.environment = environment;
    open.standardOutput = NSFileHandle.fileHandleWithNullDevice;
    open.standardError = NSFileHandle.fileHandleWithNullDevice;
  }
  NSError *error = nil;
  const BOOL failed = ![open launchAndReturnError:&error];
  if (failed) NSLog(@"[KartPad] curtain could not reopen KartPad: %@", error);
  // Until the new KartPad says it's up, or it exits (or never appears), or a minute passes.
  const CFTimeInterval reopened = CACurrentMediaTime();
  BOOL appeared = NO;
  CFTimeInterval checked = 0;
  while (!shown && !failed && CACurrentMediaTime() - reopened < 60) {
    [NSRunLoop.mainRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    if (CACurrentMediaTime() - checked < 0.5) continue;
    checked = CACurrentMediaTime();
    BOOL running = NO;
    for (NSRunningApplication *other in [NSRunningApplication runningApplicationsWithBundleIdentifier:NSBundle.mainBundle.bundleIdentifier])
      if (other.processIdentifier != NSProcessInfo.processInfo.processIdentifier && !other.terminated) running = YES;
    if (running) appeared = YES;
    else if (appeared || CACurrentMediaTime() - reopened > 20) break;
  }
  [NSDistributedNotificationCenter.defaultCenter removeObserver:observer];
  // A breath for the game's first frame, then fade.
  [NSRunLoop.mainRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.25]];
  [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
    context.duration = KPUIReduceMotion() ? 0.15 : 0.35;
    window.animator.alphaValue = 0;
  }];
  [NSRunLoop.mainRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.45]];
  [animate invalidate];
  [window orderOut:nil];
}
